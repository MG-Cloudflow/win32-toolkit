function Invoke-Win32ToolkitWingetWizard {
    <#
    .SYNOPSIS
        Guided winget packaging wizard (Spectre): search → select → arch → template → options →
        summary → confirm → run. A thin front-end over Invoke-Win32Toolkit (driven non-interactively).
        See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BasePath)

    Clear-Host
    Write-SpectreRule -Title 'Package an app from winget' -Color Blue

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Format-SpectrePanel -Data "[red]winget is not available on this PC.[/]`nInstall 'App Installer' from the Microsoft Store, or use a manual app instead." -Header 'winget missing' -Border Rounded -Color Red
        Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null
        return
    }

    # 1. Search term
    $term = Read-SpectreText -Message 'Search winget for (e.g. "notepad++", "git")'
    if ([string]::IsNullOrWhiteSpace($term)) { return }

    # 2. Search + select
    Write-SpectreHost "[grey]Searching winget for '$(Get-SpectreEscapedText -Text ([string]$term))'…[/]"
    $apps = @(Search-WingetApps -SearchTerm $term | Where-Object { $_.Source -ne 'msstore' })
    if ($apps.Count -eq 0) {
        Format-SpectrePanel -Data "No winget results for [yellow]$(Get-SpectreEscapedText -Text ([string]$term))[/]." -Header 'Nothing found' -Border Rounded -Color Yellow
        Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null
        return
    }
    # Use plain string choices + a lookup (robust regardless of how selection returns objects).
    # Choice labels render as Spectre markup — escape names that may contain [ ]; key the lookup
    # by the same (escaped) label so the returned selection maps back to the app.
    $labelMap = [ordered]@{}
    $labels = foreach ($a in $apps) {
        $label = Get-SpectreEscapedText -Text ('{0}  ({1})  v{2}' -f $a.Name, $a.Id, $a.Version)
        $labelMap[$label] = $a
        $label
    }
    $chosen = Read-SpectreSelection -Message 'Select the application (type to filter)' -Choices @($labels) -Color Blue -EnableSearch -PageSize 15
    $picked = $labelMap[$chosen]
    if (-not $picked -or [string]::IsNullOrWhiteSpace($picked.Id)) {
        Write-SpectreHost '[yellow]No application selected.[/]'
        Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null
        return
    }

    # 3. Architecture (Get-WingetAppDetails may return a single string; force an array; 6>$null quiets it)
    $archs = @(@(Get-WingetAppDetails -AppId $picked.Id 6>$null) | Where-Object { $_ -in @('x64', 'x86', 'arm64') })
    if ($archs.Count -eq 0) { $archs = @('x64', 'x86', 'arm64') }
    $arch = if ($archs.Count -eq 1) { $archs[0] } else { Read-SpectreSelection -Message 'Target architecture' -Choices @($archs) -Color Blue }

    # 4. Template (client)
    $template = Get-Win32ToolkitTemplateChoice -BasePath $BasePath
    if ([string]::IsNullOrWhiteSpace($template)) { return }

    # 5. What to do after building. NOTE: the documentation capture ALWAYS runs, and both it and the
    # optional test follow the CONFIGURED backend — so name the real backend instead of hard-coding
    # "Windows Sandbox" (the TUI used to claim Sandbox while actually running in the Hyper-V VM).
    $bi = Get-Win32ToolkitBackendInfo
    if ($bi.FellBack) {
        Write-SpectreHost "[yellow]Hyper-V is selected but NOT ready — falling back to Windows Sandbox:[/] $(Get-SpectreEscapedText -Text ($bi.Reasons -join '; '))"
    }
    $testLabel = "Run an install/uninstall test in $($bi.Label)"
    $actions = @(Read-SpectreMultiSelection -Message 'After building, also… (space to toggle, enter to accept)' -Choices @(
            $testLabel
            'Package to .intunewin'
            'Publish to Intune'
        ) -Color Blue -AllowEmpty)
    $doTest    = $actions -contains $testLabel
    $doPackage = $actions -contains 'Package to .intunewin'
    $doPublish = $actions -contains 'Publish to Intune'

    # 6. Pre-flight summary
    $after = @()
    if ($doTest)    { $after += 'install/uninstall test' }
    if ($doPackage) { $after += 'package (.intunewin)' }
    if ($doPublish) { $after += 'PUBLISH to Intune' }
    $afterStr = if ($after) { $after -join ', ' } else { 'nothing (just build the project)' }
    $summary = @(
        "Application  : $($picked.Name)  (v$($picked.Version))"
        "Winget ID    : $($picked.Id)"
        "Architecture : $arch"
        "Template     : $template"
        "Base folder  : $BasePath"
        "Test/capture : $($bi.Label)"
        "After build  : $afterStr"
    ) -join "`n"
    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $summary) -Header 'Review' -Border Rounded -Color Blue

    # 7. Confirm (+ extra gate for publish)
    if (-not (Read-SpectreConfirm -Message 'Build this now?' -DefaultAnswer 'n')) {
        Write-SpectreHost '[yellow]Cancelled.[/]'; Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null; return
    }
    if ($doPublish -and -not (Read-SpectreConfirm -Message 'Publishing UPLOADS to your Intune tenant (you will sign in). Continue?' -DefaultAnswer 'n')) {
        $doPublish = $false
        Write-SpectreHost '[yellow]Publish skipped — will build/package only.[/]'
    }

    # 8. Run (Invoke shows its own progress; the capture/test run in the resolved backend)
    Clear-Host
    Write-SpectreRule -Title "Building $(Get-SpectreEscapedText -Text $picked.Name)…" -Color Blue
    $p = @{ Id = $picked.Id; Architecture = $arch; TemplateName = $template; BasePath = $BasePath; Force = $true }
    if ($doTest)    { $p.RunTest = 'InstallUninstall' }
    if ($doPackage) { $p.PackageIntune = $true }
    if ($doPublish) { $p.PublishIntune = $true }
    try {
        Invoke-Win32Toolkit @p
        Format-SpectrePanel -Data "Finished [green]$(Get-SpectreEscapedText -Text $picked.Name)[/].`nUse [blue]Browse projects[/] to find it; review the messages above for details." -Header 'Done' -Border Rounded -Color Green
    }
    catch {
        Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Something went wrong' -Border Rounded -Color Red
    }
    Read-SpectrePause -Message 'Press any key to return to the menu' -AnyKey | Out-Null
}
