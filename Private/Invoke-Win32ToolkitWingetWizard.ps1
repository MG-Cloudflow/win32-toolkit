function Invoke-Win32ToolkitWingetWizard {
    <#
    .SYNOPSIS
        Guided winget packaging wizard (Spectre): search → select → arch → template → installer
        technology → options → summary → confirm → run. A thin front-end over Invoke-Win32Toolkit (driven
        non-interactively). The installer-technology question is asked once, only when winget ships more
        than one technology that can be packaged for the version, or no longer ships the technology of the
        published/pinned earlier version (skip this version, switch on purpose, or keep and stop)
        (installer-identity PR 1, D4, L3).
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
    # The template folder (Projects\<Template>): the technology checks below and the not-configured lines of the
    # result (TUI audit G4) both need it, also when the version is unknown.
    $paths = Get-Win32ToolkitPaths -BasePath $BasePath
    $templateSeg = Sanitize-ProjectName -Name $template
    if ([string]::IsNullOrWhiteSpace($templateSeg)) { $templateSeg = 'Default' }
    $templateDir = Join-Path $paths.Projects $templateSeg

    # 4a. Installer technology (installer-identity PR 1, D4): ask once when winget ships more than one
    # technology for this version. A published/pinned earlier version (same winget id, this template) is kept
    # by Invoke-Win32Toolkit itself (continuity), so 'Keep' passes nothing; any other choice is passed as
    # -InstallerType <pin value>. When the probe answers and the version ships no packageable installer of the
    # anchor's family, Keep would stop the build (W32T.InstallerVariantUnavailable): the wizard says so and asks
    # (skip - recommended, switch, keep). Probe and predecessor lookup are fail-open: no answer -> no question.
    # The project this build replaces and the template's tenant (data only), read BEFORE the version check: the
    # resolver in Invoke-Win32Toolkit applies the rebuilt version's own technology before it looks at the version
    # (TUI audit G8), so the labels below must too.
    $wouldBe = Join-Path $templateDir ('{0}_{1}_{2}' -f (Sanitize-ProjectName -Name $picked.Name), (Sanitize-ProjectName -Name $arch), (Sanitize-ProjectName -Name $picked.Version))
    $tenantId = ''
    try {
        $tplFile = Join-Path $paths.Templates "$template.json"
        if (Test-Path -LiteralPath $tplFile) {
            $tpl = Get-Content -LiteralPath $tplFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($tpl.PSObject.Properties['TenantId'] -and $tpl.TenantId) { $tenantId = [string]$tpl.TenantId }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Template tenant not read: $($_.Exception.Message)"
    }
    # Rebuilding a version that is itself published or pinned keeps its own technology (the resolver reads the
    # same self-anchor before the old folder is deleted, so 'Keep' still passes nothing and its label stays true,
    # L3). A self-anchor whose type cannot be pinned is dropped, exactly as the resolver drops it, so the earlier
    # versions anchor instead.
    $selfAnchor = Get-Win32ToolkitSelfAnchor -ProjectPath $wouldBe -TenantId $tenantId
    $selfRow = if ($selfAnchor) { Get-Win32ToolkitInstallerFamily -Type ([string]$selfAnchor.InstallerType) }
    if ($selfAnchor -and -not ($selfRow -and $selfRow.PinValue)) { $selfAnchor = $null }
    $whose = if ($selfAnchor) { 'the rebuilt version' } else { 'the earlier version' }

    $techPin = ''
    $techSummary = "winget's choice"
    $verText = ([string]$picked.Version).Trim()
    if (-not $verText -or $verText -notmatch '^[vV]?\d+(\.\d+)*') {
        if ($selfAnchor) {
            # The resolver keeps the rebuilt version's technology before its own version check.
            $selfHow = if ([string]$selfAnchor.AnchorReason -eq 'published') { 'published' } else { 'pinned' }
            Write-SpectreHost "[grey]$(Get-SpectreEscapedText -Text ('Installer technology: keeps {0} ({1} is {2}; rebuilding it); the other technologies were not checked (version unknown).' -f $selfRow.EffectiveType, $selfAnchor.Name, $selfHow))[/]"
            $techSummary = "keeps $($selfRow.EffectiveType) ($($selfAnchor.Name) is $selfHow; rebuilding it; not checked: version unknown)"
        }
        else {
            Write-SpectreHost "[grey]Installer technology: not checked (version unknown); the checks after the download still run.[/]"
            $techSummary = "winget's choice (not checked: version unknown)"
        }
    }
    else {
        $anchor = if ($selfAnchor) { $selfAnchor }
                  else { (Get-Win32ToolkitPreviousProject -TemplateDirectory $templateDir -WingetId $picked.Id -Version $verText -ExcludePath $wouldBe -TenantId $tenantId).Anchor }
        Write-SpectreHost "[grey]Checking which installer technologies winget ships for $(Get-SpectreEscapedText -Text ('{0} {1} ({2})' -f $picked.Id, $verText, $arch))...[/]"
        $probe = Get-Win32ToolkitSiblingInstaller -WingetId $picked.Id -Version $verText -Architecture $arch

        # Families winget ships for this architecture: testable ones can be chosen (pin value of the
        # highest-precedence testable type: msstore/msix/appx -> msix); zip-wrapped / Store-only cannot.
        $families = [System.Collections.Generic.List[object]]::new()
        $untestable = [System.Collections.Generic.List[string]]::new()
        $sibs = @()
        if ($probe -and $probe.Status -eq 'Ok') {
            $sibs = @($probe.Siblings | Where-Object { $_.Registers } | Sort-Object -Stable -Property Precedence)
            foreach ($fam in @($sibs | ForEach-Object { [string]$_.Family } | Select-Object -Unique)) {
                $top = @($sibs | Where-Object { $_.Family -eq $fam -and $_.Testable -and $_.PinValue }) | Select-Object -First 1
                if ($top) {
                    $families.Add([pscustomobject]@{ Family = $fam; PinValue = [string]$top.PinValue; Label = [string]$top.Label })
                } else {
                    foreach ($u in @($sibs | Where-Object { $_.Family -eq $fam })) { $untestable.Add([string]$u.Label) }
                }
            }
        }
        foreach ($u in $untestable) {
            Write-SpectreHost "[grey]winget also ships $(Get-SpectreEscapedText -Text $u) for ${arch}: it cannot be packaged.[/]"
        }

        # An anchor whose type cannot be pinned is not kept by the download either (Resolve-Win32ToolkitInstallerPin).
        $anchorRow = if ($anchor) { Get-Win32ToolkitInstallerFamily -Type ([string]$anchor.InstallerType) } else { $null }
        if ($anchorRow -and -not $anchorRow.PinValue) { $anchor = $null }

        if ($anchor) {
            $how = if ([string]$anchor.AnchorReason -eq 'published') { 'published' } else { 'pinned' }
            if ($selfAnchor) { $how = "$how; rebuilding it" }
            $others = @($families | Where-Object { $_.Family -ne $anchorRow.Family })
            $anchorOffered = @($families | Where-Object { $_.Family -eq $anchorRow.Family }).Count -ge 1
            if ($probe -and $probe.Status -eq 'Ok' -and -not $anchorOffered) {
                # The probe answered and this version ships no installer of the anchor's family that can be packaged:
                # keeping it stops the build (Download-WingetApp throws W32T.InstallerVariantUnavailable), so neither
                # 'keeps ...' nor 'recommended' would be true. Say so and ask once with the two options of that error
                # (skip this version - recommended; switch technology on purpose) and Keep as the last choice.
                $zipOnly = @($sibs | Where-Object { $_.Family -eq $anchorRow.Family }).Count -ge 1
                $what = "winget does not ship $($anchorRow.Label) for this version ($arch)"
                if ($zipOnly) { $what = "winget ships $($anchorRow.Label) for this version ($arch) only in a form that cannot be packaged" }
                $code = if ($zipOnly) { '' } else { ' (W32T.InstallerVariantUnavailable)' }
                $switchNote = if ($families.Count -ge 1) { '; switching gives devices that already have it a second registration' } else { '' }
                $line = '{0}, the technology of {1} ({2}): keeping it will stop the build{3}. Skipping this version is recommended{4}.' -f $what, $anchor.Name, $how, $code, $switchNote
                Write-SpectreHost "[yellow]$(Get-SpectreEscapedText -Text $line)[/]"
                $skipLabel = 'Skip this version (recommended)'
                $techMap = [ordered]@{}
                foreach ($f in $families) { $techMap[(Get-SpectreEscapedText -Text ('Switch to {0}' -f $f.Label))] = $f.PinValue }
                $keepLabel = Get-SpectreEscapedText -Text ('Keep {0} (not offered for this version: the build will stop)' -f $anchorRow.Label)
                $techMap[$keepLabel] = ''
                $choice = Read-SpectreSelection -Message ('Installer technology for {0} in this tenant' -f (Get-SpectreEscapedText -Text $picked.Name)) -Choices @(@($skipLabel) + @($techMap.Keys)) -Color Blue
                if ([string]$choice -eq $skipLabel -or -not $techMap.Contains([string]$choice)) {
                    Write-SpectreHost "[yellow]$(Get-SpectreEscapedText -Text ('Skipped: nothing was built. Package a later version that ships {0} again.' -f $anchorRow.Label))[/]"
                    Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null
                    return
                }
                $techPin = [string]$techMap[[string]$choice]
                $techSummary = if ($techPin) { "$techPin (your choice; $whose is $($anchorRow.EffectiveType))" } else { "keeps $($anchorRow.EffectiveType) ($($anchor.Name) is $how; not offered for this version: the build will stop)" }
            }
            elseif ($families.Count -ge 2 -and $others.Count -ge 1) {
                $techMap = [ordered]@{}
                $keepLabel = Get-SpectreEscapedText -Text ('Keep {0} (recommended: {1} is {2})' -f $anchorRow.Label, $anchor.Name, $how)
                $techMap[$keepLabel] = ''
                foreach ($f in $others) { $techMap[(Get-SpectreEscapedText -Text ('Switch to {0}' -f $f.Label))] = $f.PinValue }
                $choice = Read-SpectreSelection -Message ('Installer technology for {0} in this tenant' -f (Get-SpectreEscapedText -Text $picked.Name)) -Choices @($techMap.Keys) -Color Blue
                $techPin = if ($techMap.Contains([string]$choice)) { [string]$techMap[[string]$choice] } else { '' }
                $techSummary = if ($techPin) { "$techPin (your choice; $whose is $($anchorRow.EffectiveType))" } else { "keeps $($anchorRow.EffectiveType) ($($anchor.Name) is $how)" }
            }
            else {
                Write-SpectreHost "[grey]$(Get-SpectreEscapedText -Text ('Installer technology: keeps {0} ({1} is {2}).' -f $anchorRow.EffectiveType, $anchor.Name, $how))[/]"
                $techSummary = "keeps $($anchorRow.EffectiveType) ($($anchor.Name) is $how)"
            }
        }
        elseif ($families.Count -ge 2) {
            Write-SpectreHost '[grey]Devices that already have the other technology would get two registrations; pick the one your devices already have.[/]'
            $techMap = [ordered]@{}
            for ($i = 0; $i -lt $families.Count; $i++) {
                $text = if ($i -eq 0) { "$($families[$i].Label) - winget's default" } else { $families[$i].Label }
                $techMap[(Get-SpectreEscapedText -Text $text)] = $families[$i].PinValue
            }
            $choice = Read-SpectreSelection -Message ('Installer technology for {0}' -f (Get-SpectreEscapedText -Text $picked.Name)) -Choices @($techMap.Keys) -Color Blue
            if ($techMap.Contains([string]$choice)) { $techPin = [string]$techMap[[string]$choice] }
            $techSummary = if ($techPin) { "$techPin (your choice)" } else { "winget's choice" }
        }
        elseif ($probe -and $probe.Status -eq 'Ok') {
            $only = if ($families.Count -eq 1) { $families[0].Label } else { 'one technology' }
            Write-SpectreHost "[grey]$(Get-SpectreEscapedText -Text ("Installer technology: winget ships $only for this version; nothing to choose."))[/]"
        }
        else {
            $reason = if ($probe -and $probe.Reason) { [string]$probe.Reason } else { 'no answer' }
            Write-SpectreHost "[grey]$(Get-SpectreEscapedText -Text ("Installer technology: winget's choice (the other technologies could not be checked: $reason); the checks after the download still run."))[/]"
            $techSummary = "winget's choice (not checked: $reason)"
        }
    }

    # 4b. Dependencies — apps Intune must install BEFORE this one (e.g. a VC++ redistributable).
    # Sourced from winget or an already-packaged project; stored as data in AppConfig.json.
    $deps = @()
    if (Read-SpectreConfirm -Message 'Does this app need another app installed FIRST (e.g. a VC++ redistributable)?' -DefaultAnswer 'n') {
        # The project this build creates or replaces is never offered (TUI audit G9).
        $deps = @(Show-Win32ToolkitDependencyPicker -BasePath $BasePath -ExcludeProject "$templateSeg\$(Split-Path -Leaf $wouldBe)")
    }

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
    $summaryLines = [System.Collections.Generic.List[string]]::new()
    $summaryLines.Add("Application  : $($picked.Name)  (v$($picked.Version))")
    $summaryLines.Add("Winget ID    : $($picked.Id)")
    $summaryLines.Add("Architecture : $arch")
    $summaryLines.Add("Installer tech : $techSummary")
    $summaryLines.Add("Template     : $template")
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
    # NoPublishPrompt: the wizard asked about publishing above, so packaging never asks 'Upload ... now?' (TUI audit G5).
    $p = @{ Id = $picked.Id; Architecture = $arch; TemplateName = $template; BasePath = $BasePath; Force = $true; NoPublishPrompt = $true }
    if ($techPin)   { $p.InstallerType = $techPin }
    if ($deps)      { $p.DependsOn = $deps }
    if ($doTest)    { $p.RunTest = 'InstallUninstall' }
    if ($doPackage) { $p.PackageIntune = $true }
    if ($doPublish) { $p.PublishIntune = $true }
    # Kept-and-marked lines (TUI audit G4): a project this run left marked not configured (Find-Win32ToolkitNotConfiguredProject).
    $keptLines = { param([string]$Path) @("The project folder was kept and marked not configured: $Path", 'Package and Publish refuse it until you package the app again (that replaces the folder).') }
    $runStartUtc = [datetime]::UtcNow
    try {
        # The run is judged by its result object (TUI audit G2): Done only when it Succeeded.
        $out = @(Invoke-Win32Toolkit @p)
        Show-Win32ToolkitRunResult -Result $out -Name $picked.Name
        # A non-W32T error after the scaffold returns a Failed result (no throw): name the folder it left marked.
        $r = @($out | Where-Object { $null -ne $_ -and $_.PSObject.TypeNames -contains 'Win32Toolkit.RunResult' }) | Select-Object -Last 1
        if ($r -and $r.Status -eq 'Failed' -and $r.ProjectPath) {
            foreach ($kept in @(Find-Win32ToolkitNotConfiguredProject -TemplateDirectory $templateDir -SinceUtc $runStartUtc -ProjectPath ([string]$r.ProjectPath))) {
                foreach ($line in (& $keptLines $kept)) { Write-SpectreHost "[yellow]$(Get-SpectreEscapedText -Text $line)[/]" }
            }
        }
    }
    catch {
        $data = "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]"
        foreach ($kept in @(Find-Win32ToolkitNotConfiguredProject -TemplateDirectory $templateDir -SinceUtc $runStartUtc -ProjectPath ([string]$_.TargetObject))) {
            $data += "`n`n" + ((& $keptLines $kept | ForEach-Object { Get-SpectreEscapedText -Text $_ }) -join "`n")
        }
        Format-SpectrePanel -Data $data -Header 'Something went wrong' -Border Rounded -Color Red
    }
    Read-SpectrePause -Message 'Press any key to return to the menu' -AnyKey | Out-Null
}
