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
        $silentArgs = Read-Win32ToolkitValidatedText -Message 'Silent-install switch(es) (e.g. /S, or /qn /norestart). Blank for an MSI or MSIX; an EXE without a switch becomes an Advanced app' -AllowEmpty
    }

    # Template
    $template = Get-Win32ToolkitTemplateChoice -BasePath $BasePath
    if ([string]::IsNullOrWhiteSpace($template)) { return }
    # The template folder (Projects\<Template>): the Advanced hand-off and the not-configured lines of a failed
    # build (TUI audit G4) both need it.
    $paths = Get-Win32ToolkitPaths -BasePath $BasePath
    $templateSeg = Sanitize-ProjectName -Name $template
    if ([string]::IsNullOrWhiteSpace($templateSeg)) { $templateSeg = 'Default' }
    $templateDir = Join-Path $paths.Projects $templateSeg
    # The project this build creates (TUI audit G6): the dependency picker leaves it out; the Advanced hand-off falls
    # back to it only when the scaffold's result carries no path.
    $projName    = '{0}_{1}_{2}' -f (Sanitize-ProjectName -Name $name), (Sanitize-ProjectName -Name $arch), (Sanitize-ProjectName -Name $version)
    $projPath    = Join-Path (Join-Path $paths.Projects $templateSeg) $projName

    # Dependencies — apps Intune must install BEFORE this one (e.g. a VC++ redistributable). Also staged
    # into the test/capture guest so the run installs them first, like Intune does on a device.
    $deps = @()
    if (Read-SpectreConfirm -Message 'Does this app need another app installed FIRST (e.g. a VC++ redistributable)?' -DefaultAnswer 'n') {
        # The project this build creates or replaces is never offered (TUI audit G9).
        $deps = @(Show-Win32ToolkitDependencyPicker -BasePath $BasePath -ExcludeProject "$templateSeg\$projName")
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
    # Blank switches: what New-Win32ToolkitManualApp makes of the build depends on the installer (TUI audit G6): an
    # EXE without a switch becomes an Advanced app.
    $srcExt   = if (Test-Path -LiteralPath $source -PathType Leaf) { [System.IO.Path]::GetExtension($source).ToLowerInvariant() } else { '' }
    $modeStr  = if ($advanced) { 'Advanced (you write the install logic)' }
                elseif ($silentArgs) { "Easy (silent: $silentArgs)" }
                elseif ($srcExt -eq '.exe') { 'Advanced (an EXE with no silent switch: you write the install logic)' }
                elseif ($srcExt -eq '.msi') { 'Easy (MSI / Zero-Config)' }
                elseif ($srcExt -in @('.msix', '.appx')) { 'Easy (MSIX / APPX package)' }
                else { 'Easy if the installer is an MSI or MSIX; an EXE without a switch becomes Advanced' }
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

    # Common params for New-Win32ToolkitManualApp. NoPublishPrompt: the wizard asked about publishing above, so
    # packaging never asks 'Upload ... now?' (TUI audit G5).
    $p = @{ Name = $name; Version = $version; Architecture = $arch; SourcePath = $source; TemplateName = $template; BasePath = $BasePath; Force = $true; NoPublishPrompt = $true }
    if ($publisher) { $p.Publisher = $publisher }
    if ($descr)     { $p.Description = $descr }
    if ($infoUrl)   { $p.InformationUrl = $infoUrl }
    if ($iconPath)  { $p.IconPath = $iconPath }
    if ($deps)      { $p.DependsOn = $deps }   # declared into AppConfig + staged into the test/capture guest

    # Kept-and-marked lines (TUI audit G4): a project this run left marked not configured (Find-Win32ToolkitNotConfiguredProject).
    $keptLines = { param([string]$Path) @("The project folder was kept and marked not configured: $Path", 'Package and Publish refuse it until you package the app again (that replaces the folder).') }
    $keptData = {
        param($ErrorRecord, [datetime]$Since)
        $d = "[red]$(Get-SpectreEscapedText -Text $ErrorRecord.Exception.Message)[/]"
        foreach ($kept in @(Find-Win32ToolkitNotConfiguredProject -TemplateDirectory $templateDir -SinceUtc $Since -ProjectPath ([string]$ErrorRecord.TargetObject))) {
            $d += "`n`n" + ((& $keptLines $kept | ForEach-Object { Get-SpectreEscapedText -Text $_ }) -join "`n")
        }
        $d
    }

    if ($advanced) {
        # Scaffold only, then hand off to the two-step finish screen.
        Clear-Host
        Write-SpectreRule -Title "Scaffolding $(Get-SpectreEscapedText -Text $name)…" -Color Blue
        $p.Advanced = $true
        $runStartUtc = [datetime]::UtcNow
        # The scaffold is judged by its result object, and its warnings are shown before the next screen clears
        # them (TUI audit G6).
        $scaffoldWarnings = $null
        try { $out = @(New-Win32ToolkitManualApp @p -WarningVariable scaffoldWarnings) }
        catch {
            Format-SpectrePanel -Data (& $keptData $_ $runStartUtc) -Header 'Scaffold failed' -Border Rounded -Color Red
            Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null
            return
        }
        $r = @($out | Where-Object { $null -ne $_ -and $_.PSObject.TypeNames -contains 'Win32Toolkit.RunResult' }) | Select-Object -Last 1
        if (-not $r -or $r.Status -eq 'Failed') {
            # Blank entries are skipped: Get-SpectreEscapedText refuses an empty string.
            $problems = @(if ($r) { @($r.Problems) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } })
            $whyLines = if ($problems.Count) { @($problems | ForEach-Object { "- $(Get-SpectreEscapedText -Text ([string]$_))" }) }
                        else { @('- New-Win32ToolkitManualApp returned no result.') }
            Format-SpectrePanel -Data ("The project was not scaffolded:`n" + ($whyLines -join "`n") + "`n`nReview the messages above for details.") -Header 'Scaffold failed' -Border Rounded -Color Red
            # A non-W32T error after the scaffold returns a Failed result (no throw): name the folder it left marked.
            if ($r -and $r.ProjectPath) {
                foreach ($kept in @(Find-Win32ToolkitNotConfiguredProject -TemplateDirectory $templateDir -SinceUtc $runStartUtc -ProjectPath ([string]$r.ProjectPath))) {
                    foreach ($line in (& $keptLines $kept)) { Write-SpectreHost "[yellow]$(Get-SpectreEscapedText -Text $line)[/]" }
                }
            }
            Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null
            return
        }
        $warned = @($scaffoldWarnings | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Message) })
        if ($warned.Count) {
            $warnLines = @($warned | ForEach-Object { "- $(Get-SpectreEscapedText -Text ([string]$_.Message))" })
            Format-SpectrePanel -Data ("Scaffolding $(Get-SpectreEscapedText -Text $name) printed $($warned.Count) warning(s):`n" + ($warnLines -join "`n") + "`n`nRead them before you write the install code.") -Header 'Check these warnings' -Border Rounded -Color Yellow
            Read-SpectrePause -Message 'Press any key to continue to the next step' -AnyKey | Out-Null
        }
        $advPath = if ($r.ProjectPath) { [string]$r.ProjectPath } else { $projPath }
        Show-Win32ToolkitAdvancedFinish -ProjectPath $advPath -DoTest:$doTest -DoPackage:$doPackage -DoPublish:$doPublish
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
        $runStartUtc = [datetime]::UtcNow
        $advPath = $null
        try {
            # The run is judged by its result object (TUI audit G2): Done only when it Succeeded.
            $out = @(New-Win32ToolkitManualApp @p)
            $r = @($out | Where-Object { $null -ne $_ -and $_.PSObject.TypeNames -contains 'Win32Toolkit.RunResult' }) | Select-Object -Last 1
            if ($r -and $r.Mode -eq 'Advanced') {
                # An EXE with blank switches was set up as an Advanced app: go on with the Advanced step, keeping the
                # ticked actions, instead of ending on a 'Scaffolded' panel (TUI audit G6).
                Format-SpectrePanel -Data "No silent switch was given for this EXE, so $(Get-SpectreEscapedText -Text $name) was set up as an Advanced app: write the install code yourself, then choose Finish setup. Your test, package and publish choices are kept." -Header 'Advanced app' -Border Rounded -Color Yellow
                $advPath = if ($r.ProjectPath) { [string]$r.ProjectPath } else { $projPath }
            }
            else {
                Show-Win32ToolkitRunResult -Result $out -Name $name
                # A non-W32T error after the scaffold returns a Failed result (no throw): name the folder it left marked.
                if ($r -and $r.Status -eq 'Failed' -and $r.ProjectPath) {
                    foreach ($kept in @(Find-Win32ToolkitNotConfiguredProject -TemplateDirectory $templateDir -SinceUtc $runStartUtc -ProjectPath ([string]$r.ProjectPath))) {
                        foreach ($line in (& $keptLines $kept)) { Write-SpectreHost "[yellow]$(Get-SpectreEscapedText -Text $line)[/]" }
                    }
                }
            }
        }
        catch {
            Format-SpectrePanel -Data (& $keptData $_ $runStartUtc) -Header 'Something went wrong' -Border Rounded -Color Red
        }
        if ($advPath) {
            Read-SpectrePause -Message 'Press any key to continue to the next step' -AnyKey | Out-Null
            Show-Win32ToolkitAdvancedFinish -ProjectPath $advPath -DoTest:$doTest -DoPackage:$doPackage -DoPublish:$doPublish
            return
        }
        Read-SpectrePause -Message 'Press any key to return to the menu' -AnyKey | Out-Null
    }
}
