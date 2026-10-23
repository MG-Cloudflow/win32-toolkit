function Invoke-Win32ToolkitManualWizard {
    <#
    .SYNOPSIS
        Guided manual (non-winget) packaging wizard (Spectre): metadata → installer → mode →
        template → options → summary → confirm → New-Win32ToolkitManualApp. Advanced apps get a
        two-step finish (edit the Install region, then Complete-…). See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BasePath)

    Clear-Host
    Write-SpectreRule -Title 'Package a manual app (not in winget)' -Color Blue

    # Mode
    $modeSel = Read-SpectreSelection -Message 'How does this app install?' -Choices @(
        [pscustomobject]@{ Key = 'easy';     Label = 'Easy — a silent switch installs it (e.g. /S, /qn), or it is an MSI' }
        [pscustomobject]@{ Key = 'advanced'; Label = 'Advanced — I will write the install logic myself' }
    ) -ChoiceLabelProperty 'Label' -Color Blue
    $advanced = ($modeSel.Key -eq 'advanced')

    # Installer
    $source = Read-Win32ToolkitValidatedText -Message 'Full path to the installer file (or a folder of files)' `
        -Validator { Test-Path -LiteralPath ($args[0].Trim().Trim('"')) } `
        -ErrorMessage 'Not found — enter a valid path to the installer file or folder.'
    $source = $source.Trim().Trim('"')

    # Metadata
    $name    = Read-Win32ToolkitValidatedText -Message 'Application name' -Validator { -not [string]::IsNullOrWhiteSpace($args[0]) } -ErrorMessage 'Name is required.'
    $version = Read-Win32ToolkitValidatedText -Message 'Version (e.g. 1.2.3)' -Validator { -not [string]::IsNullOrWhiteSpace($args[0]) } -ErrorMessage 'Version is required.'
    $arch    = Read-SpectreSelection -Message 'Target architecture' -Choices @('x64', 'x86', 'arm64') -Color Blue

    $publisher = Read-Win32ToolkitValidatedText -Message 'Publisher (optional)' -AllowEmpty
    $descr     = Read-Win32ToolkitValidatedText -Message 'Description (optional)' -AllowEmpty
    $infoUrl   = Read-Win32ToolkitValidatedText -Message 'Information URL (optional)' -AllowEmpty
    $iconPath  = Read-Win32ToolkitValidatedText -Message 'Path to an icon .png/.ico (optional)' -AllowEmpty `
        -Validator { [string]::IsNullOrWhiteSpace($args[0]) -or (Test-Path -LiteralPath ($args[0].Trim().Trim('"')) -PathType Leaf) } `
        -ErrorMessage 'Icon file not found.'
    if ($iconPath) { $iconPath = $iconPath.Trim().Trim('"') }

    # Easy: silent args
    $silentArgs = ''
    if (-not $advanced) {
        $silentArgs = Read-Win32ToolkitValidatedText -Message 'Silent-install switch(es) (e.g. /S, or /qn /norestart; blank if MSI)' -AllowEmpty
    }

    # Template
    $template = Get-Win32ToolkitTemplateChoice -BasePath $BasePath
    if ([string]::IsNullOrWhiteSpace($template)) { return }

    # Dependencies — apps Intune must install BEFORE this one (e.g. a VC++ redistributable). Also staged
    # into the test/capture guest so the run installs them first, like Intune does on a device.
    $deps = @()
    if (Read-SpectreConfirm -Message 'Does this app need another app installed FIRST (e.g. a VC++ redistributable)?' -DefaultAnswer 'n') {
        $deps = @(Show-Win32ToolkitDependencyPicker -BasePath $BasePath)
    }

    # After-build options. The documentation capture ALWAYS runs, and both it and the optional test follow
    # the CONFIGURED backend — name the real backend rather than hard-coding "Windows Sandbox".
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

    # Summary
    $after = @()
    if ($doTest)    { $after += 'install/uninstall test' }
    if ($doPackage) { $after += 'package (.intunewin)' }
    if ($doPublish) { $after += 'PUBLISH to Intune' }
    $afterStr = if ($after) { $after -join ', ' } else { 'nothing (just build the project)' }
    $modeStr  = if ($advanced) { 'Advanced (you write the install logic)' } elseif ($silentArgs) { "Easy (silent: $silentArgs)" } else { 'Easy (MSI / Zero-Config)' }
    $summaryLines = [System.Collections.Generic.List[string]]::new()
    $summaryLines.Add("Application  : $name  (v$version)")
    $summaryLines.Add("Architecture : $arch")
    $summaryLines.Add("Installer    : $source")
    $summaryLines.Add("Publisher    : $(if ($publisher) { $publisher } else { '(none)' })")
    $summaryLines.Add("Template     : $template")
    $summaryLines.Add("Mode         : $modeStr")
    $summaryLines.Add("Base folder  : $BasePath")
    $summaryLines.Add("Test/capture : $($bi.Label)")
    if ($doTest) {
        # The test's effective mode (TUI audit G3), information only: the wizard does not pick one (Run a test does).
        $cfgName = if ($bi.Resolved -eq 'HyperV') { 'HyperVTestMode' } else { 'SandboxTestMode' }
        $effMode = Get-Win32ToolkitTestMode -Backend $bi.Resolved -WarningAction SilentlyContinue
        $why = if ((Get-Win32ToolkitConfigValue -Name $cfgName -Default '') -eq 'Unattended') { "$cfgName = Unattended" }
               elseif ($effMode -eq 'Unattended') { 'this console cannot answer prompts' } else { 'default' }
        $summaryLines.Add("Test mode    : $effMode ($why)")
    }
    $summaryLines.Add("Depends on   : $(if ($deps) { $deps -join ', ' } else { '(nothing)' })")
    $summaryLines.Add("After build  : $afterStr")
    $summary = $summaryLines -join "`n"
    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $summary) -Header 'Review' -Border Rounded -Color Blue

    # Confirm (+ publish gate)
    if (-not (Read-SpectreConfirm -Message 'Continue?' -DefaultAnswer 'n')) {
        Write-SpectreHost '[yellow]Cancelled.[/]'; Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null; return
    }
    if ($doPublish -and -not (Read-SpectreConfirm -Message 'Publishing UPLOADS to your Intune tenant (you will sign in). Continue?' -DefaultAnswer 'n')) {
        $doPublish = $false
        Write-SpectreHost '[yellow]Publish skipped.[/]'
    }

    # Common params for New-Win32ToolkitManualApp
    $p = @{ Name = $name; Version = $version; Architecture = $arch; SourcePath = $source; TemplateName = $template; BasePath = $BasePath; Force = $true }
    if ($publisher) { $p.Publisher = $publisher }
    if ($descr)     { $p.Description = $descr }
    if ($infoUrl)   { $p.InformationUrl = $infoUrl }
    if ($iconPath)  { $p.IconPath = $iconPath }
    if ($deps)      { $p.DependsOn = $deps }   # declared into AppConfig + staged into the test/capture guest

    if ($advanced) {
        # Scaffold only, then hand off to the two-step finish screen.
        Clear-Host
        Write-SpectreRule -Title "Scaffolding $(Get-SpectreEscapedText -Text $name)…" -Color Blue
        $p.Advanced = $true
        try { New-Win32ToolkitManualApp @p | Out-Null }
        catch {
            Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Scaffold failed' -Border Rounded -Color Red
            Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null
            return
        }
        $paths       = Get-Win32ToolkitPaths -BasePath $BasePath
        $templateSeg = Sanitize-ProjectName -Name $template
        if ([string]::IsNullOrWhiteSpace($templateSeg)) { $templateSeg = 'Default' }
        $projName    = '{0}_{1}_{2}' -f (Sanitize-ProjectName -Name $name), (Sanitize-ProjectName -Name $arch), (Sanitize-ProjectName -Name $version)
        $projPath    = Join-Path (Join-Path $paths.Projects $templateSeg) $projName
        Show-Win32ToolkitAdvancedFinish -ProjectPath $projPath -DoTest:$doTest -DoPackage:$doPackage -DoPublish:$doPublish
    }
    else {
        # Easy — build end to end inline.
        $p.SilentArgs = $silentArgs
        $p.Continue = $true
        if ($doTest)    { $p.RunTest = 'InstallUninstall' }
        if ($doPackage) { $p.PackageIntune = $true }
        if ($doPublish) { $p.PublishIntune = $true }
        Clear-Host
        Write-SpectreRule -Title "Building $(Get-SpectreEscapedText -Text $name)…" -Color Blue
        try {
            # The run is judged by its result object (TUI audit G2): Done only when it Succeeded.
            $out = @(New-Win32ToolkitManualApp @p)
            Show-Win32ToolkitRunResult -Result $out -Name $name
        }
        catch {
            Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Something went wrong' -Border Rounded -Color Red
        }
        Read-SpectrePause -Message 'Press any key to return to the menu' -AnyKey | Out-Null
    }
}
