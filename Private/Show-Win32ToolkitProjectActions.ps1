function Show-Win32ToolkitProjectActions {
    <#
    .SYNOPSIS
        "Work with an existing project" screen (Spectre): pick a project, then test / finalize /
        package / publish (gated) / open. Thin front-end over the existing commands.
        See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BasePath)

    while ($true) {
        Clear-Host
        Write-SpectreRule -Title 'Work with an existing project' -Color Blue

        $projects = @(Get-PSADTProjects -BasePath $BasePath)
        if ($projects.Count -eq 0) {
            Format-SpectrePanel -Data 'No projects yet — create one with [blue]Package an app[/].' -Header 'No projects' -Border Rounded -Color Yellow
            Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null
            return
        }

        # Select a project (string label + lookup)
        $map = [ordered]@{}
        $labels = foreach ($p in ($projects | Sort-Object Template, Name)) {
            # A project whose build stopped after its folder was created (TUI audit G4): Package and Publish refuse it.
            $label = Get-SpectreEscapedText -Text ('{0}  /  {1}{2}' -f $p.Template, $p.Name, $(if ($p.PSObject.Properties['NotConfigured'] -and $p.NotConfigured) { '  (not configured)' } else { '' }))
            $map[$label] = $p
            $label
        }
        $chosen = Read-SpectreSelection -Message 'Select a project (type to filter)' -Choices @($labels) -Color Blue -EnableSearch -PageSize 15
        $project = $map[$chosen]
        if (-not $project) { return }

        $reselect = $false
        while (-not $reselect) {
            Clear-Host
            Write-SpectreRule -Title (Get-SpectreEscapedText -Text ('{0} / {1}' -f $project.Template, $project.Name)) -Color Blue

            # An unreadable SupportFiles\AppConfig.json must not end the screen (TUI audit G7): one red line, and the
            # action menu still comes up. Every error is handled the same way here (the TUI is the display sink, Dv8).
            try {
                $depNow = @(Get-Win32ToolkitDependencies -ProjectPath $project.Path)
                $depText = if ($depNow.Count) { "$($depNow.Count) declared" } else { 'none' }
            }
            catch {
                $depNow = @()
                $depText = 'unknown: AppConfig.json cannot be read'
                $depWhy = ([string]$_.Exception.Message).TrimEnd('.', ' ')
                Write-SpectreHost "[red]$(Get-SpectreEscapedText -Text "SupportFiles\AppConfig.json of this project cannot be read: $depWhy. Fix the JSON or re-create the project; Package and Publish refuse it until then.")[/]"
            }
            $act = Read-SpectreSelection -Message 'What would you like to do?' -Choices @(
                [pscustomobject]@{ Key = 'test';    Label = 'Run a test (Windows Sandbox or Hyper-V VM)' }
                [pscustomobject]@{ Key = 'deps';    Label = "Dependencies — apps installed BEFORE this one ($depText)" }
                [pscustomobject]@{ Key = 'finish';  Label = "Finalize / refresh ($((Get-Win32ToolkitBackendInfo).Label) capture -> auto uninstall)" }
                [pscustomobject]@{ Key = 'package'; Label = 'Package to .intunewin' }
                [pscustomobject]@{ Key = 'publish'; Label = 'Publish to Intune' }
                [pscustomobject]@{ Key = 'doc';     Label = 'Generate customer documentation (Documentation.md)' }
                [pscustomobject]@{ Key = 'open';    Label = 'Open the project folder' }
                [pscustomobject]@{ Key = 'another'; Label = 'Pick another project' }
                [pscustomobject]@{ Key = 'back';    Label = 'Back to the main menu' }
            ) -ChoiceLabelProperty 'Label' -Color Blue -PageSize 10

            switch ($act.Key) {
                'deps' {
                    Clear-Host; Write-SpectreRule -Title 'Dependencies' -Color Blue
                    Write-SpectreHost '[grey]Intune installs these BEFORE this app. They are also installed first in the test/capture run, so the app is never tested without its runtime.[/]'
                    $current = @($depNow | ForEach-Object { "$($_.Source):$($_.Ref)" })
                    # The project being edited is never offered (TUI audit G9: an app cannot depend on itself).
                    $chosen  = @(Show-Win32ToolkitDependencyPicker -BasePath $BasePath -Existing $current -ExcludeProject "$($project.Template)\$($project.Name)")
                    try {
                        # The picker returns the AUTHORITATIVE list, so -Clear first and re-declare it.
                        if ($chosen.Count -eq 0) { $null = Set-Win32ToolkitAppDependency -ProjectPath $project.Path -Clear }
                        else                     { $null = Set-Win32ToolkitAppDependency -ProjectPath $project.Path -DependsOn $chosen -Clear }
                        $shown = if ($chosen.Count) { $chosen -join ', ' } else { '(none)' }
                        Format-SpectrePanel -Data "Dependencies saved: $(Get-SpectreEscapedText -Text $shown)`n`nRe-run Finalize/refresh so the capture reflects them, and re-publish to attach the Intune relationships." -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
                'test' {
                    $backend = Read-SpectreSelection -Message 'Which test backend?' -Choices @(
                        [pscustomobject]@{ Key = 'Sandbox'; Label = 'Windows Sandbox' }
                        [pscustomobject]@{ Key = 'HyperV';  Label = 'Hyper-V VM (fast — needs a provisioned test VM; see Settings)' }
                    ) -ChoiceLabelProperty 'Label' -Color Blue

                    # Both scenarios run on both backends now (Update-on-HyperV drives the same
                    # PreBaseline -> install-old -> PreUpdate -> pause -> update -> PostUpdate sequence
                    # as the Sandbox LogonCommand, with a HOST pause instead of the in-guest countdown).
                    $scenChoices = @(
                        [pscustomobject]@{ Key = 'InstallUninstall'; Label = 'Install then uninstall (any app)' }
                        [pscustomobject]@{ Key = 'Update';           Label = 'Update from an older version (winget download or a local packaged baseline)' }
                    )
                    $sc = Read-SpectreSelection -Message 'Test scenario' -Choices $scenChoices -ChoiceLabelProperty 'Label' -Color Blue

                    $testSplat = @{ ProjectPath = $project.Path; Scenario = $sc.Key; Backend = $backend.Key }
                    # The run-mode question and -TestMode follow what will run (TUI audit G3): a Hyper-V pick that is not
                    # ready falls back to Sandbox inside the test, which then follows SandboxTestMode (no question).
                    $resolvedBackend = Get-Win32ToolkitTestBackend -Backend $backend.Key -WarningAction SilentlyContinue
                    # Said on the run screen, after it is cleared (below); for the Update scenario also here, above the
                    # baseline questions that follow on this screen.
                    $notReadyLine = if ($backend.Key -eq 'HyperV' -and $resolvedBackend -ne 'HyperV') {
                        '[yellow]Hyper-V is not ready, so Windows Sandbox runs this test (it follows SandboxTestMode). See Settings for the reasons.[/]'
                    } else { $null }
                    if ($notReadyLine -and $sc.Key -eq 'Update') { Write-SpectreHost $notReadyLine }
                    if ($resolvedBackend -eq 'HyperV') {
                        $pauseWhat = if ($sc.Key -eq 'Update') { 'verify the OLD install, then update' } else { 'test the app, then uninstall' }
                        $interactiveChoice = [pscustomobject]@{ Key = 'interactive'; Label = "Interactive — watch the PSADT GUI in the VM console, $pauseWhat" }
                        $unattendedChoice  = [pscustomobject]@{ Key = 'unattended';  Label = 'Unattended — Intune parity: the published command line from a 32-bit parent, as SYSTEM (no pause)' }
                        # The mode a run without -TestMode would get (HyperVTestMode) is listed first, so it is the
                        # highlighted default: HyperVTestMode=Unattended keeps Intune parity as the menu's default.
                        $modeChoices = if ((Get-Win32ToolkitTestMode -Backend HyperV -WarningAction SilentlyContinue) -eq 'Unattended') { @($unattendedChoice, $interactiveChoice) }
                                       else { @($interactiveChoice, $unattendedChoice) }
                        $mode = Read-SpectreSelection -Message 'Hyper-V run mode' -Choices $modeChoices -ChoiceLabelProperty 'Label' -Color Blue
                        # The pick is this run's -TestMode: it overrides HyperVTestMode (a host that cannot prompt still
                        # runs unattended).
                        $testSplat['TestMode'] = if ($mode.Key -eq 'unattended') { 'Unattended' } else { 'Interactive' }
                    }
                    $abort = $false
                    if ($sc.Key -eq 'Update') {
                        # Old-version baseline source: download an older winget version, OR install a LOCAL
                        # packaged project as the baseline (the friendly 'project:' way — same as
                        # -BaselineProject on the cmdlet). A manual (non-winget) app has no winget baseline,
                        # so a local package is the only option there (and today's default winget path would
                        # hard-error mid-run for it).
                        $wingetId = Get-WingetIdFromProject -FilesPath (Join-Path $project.Path 'Files')
                        $isWinget = -not [string]::IsNullOrWhiteSpace($wingetId)
                        $baselineCandidates = @(Get-PSADTProjects -BasePath $BasePath | Where-Object { $_.Path -ne $project.Path })

                        $useLocal = $false
                        if ($isWinget) {
                            $srcPick = Read-SpectreSelection -Message 'Old-version baseline source' -Choices @(
                                [pscustomobject]@{ Key = 'winget';  Label = 'Download an older version from winget' }
                                [pscustomobject]@{ Key = 'project'; Label = "Use a local packaged project ($($baselineCandidates.Count) available)" }
                            ) -ChoiceLabelProperty 'Label' -Color Blue
                            $useLocal = ($srcPick.Key -eq 'project')
                            if ($useLocal -and $baselineCandidates.Count -eq 0) {
                                Format-SpectrePanel -Data 'No other packaged projects to use as a baseline yet — falling back to the winget download.' -Header 'No local baseline' -Border Rounded -Color Yellow | Out-SpectreHost
                                $useLocal = $false
                            }
                        }
                        elseif ($baselineCandidates.Count -eq 0) {
                            # Manual app AND nothing to use as a baseline — the update test cannot run.
                            Format-SpectrePanel -Data 'This is a manual (non-winget) app, so the update test needs a LOCAL packaged project as the old-version baseline — and none are available yet. Package an older version first, then re-run.' -Header 'No baseline available' -Border Rounded -Color Yellow | Out-SpectreHost
                            Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                            $abort = $true
                        }
                        else {
                            Write-SpectreHost '[grey]Manual (non-winget) app — choose a local packaged project as the old-version baseline.[/]'
                            $useLocal = $true
                        }

                        if (-not $abort -and $useLocal) {
                            $bmap = [ordered]@{}
                            $blabels = foreach ($bp in ($baselineCandidates | Sort-Object Template, Name)) {
                                $bver = $null
                                try { $bver = (Get-Win32ToolkitAppConfig -ProjectPath $bp.Path).App.Version } catch { $bver = $null }
                                $label = Get-SpectreEscapedText -Text ('{0}  /  {1}{2}' -f $bp.Template, $bp.Name, $(if ($bver) { "  (v$bver)" } else { '' }))
                                $bmap[$label] = $bp
                                $label
                            }
                            $bchosen = Read-SpectreSelection -Message 'Baseline project (the OLDER version to upgrade FROM)' -Choices @($blabels) -Color Blue -EnableSearch -PageSize 15
                            $bproj = $bmap[$bchosen]
                            if ($bproj) { $testSplat['BaselineProjectPath'] = $bproj.Path } else { $abort = $true }
                        }

                        if (-not $abort -and $isWinget -and -not $useLocal) {
                            # Baseline installer technology (D5, Dv5), resolved BEFORE the test so the operator knows
                            # which technology the old version must ship. Asked only when winget ships another
                            # technology that can be tested; otherwise one grey line names the only one.
                            try {
                                $legs = @(Resolve-Win32ToolkitBaselineFamily -ProjectPath $project.Path -Mode Both | Where-Object { $_ })
                                if ($legs.Count -gt 1) {
                                    $packagedLeg = @($legs | Where-Object { $_.Origin -eq 'Packaged' }) + @($legs) | Select-Object -First 1
                                    $siblingLeg  = @($legs | Where-Object { $_ -ne $packagedLeg }) | Select-Object -First 1
                                    $techPick = Read-SpectreSelection -Message 'Baseline installer technology' -Choices @(
                                        [pscustomobject]@{ Key = 'Auto';     Label = Get-SpectreEscapedText -Text "Auto - start from the other technology ($($siblingLeg.Label))" }
                                        [pscustomobject]@{ Key = 'Both';     Label = "Test both technologies ($($legs.Count) runs)" }
                                        [pscustomobject]@{ Key = 'Packaged'; Label = Get-SpectreEscapedText -Text "Only the packaged technology ($($packagedLeg.Label))" }
                                    ) -ChoiceLabelProperty 'Label' -Color Blue
                                    $testSplat['BaselineInstallerType'] = $techPick.Key
                                }
                                elseif ($legs.Count -eq 1) {
                                    Write-SpectreHost "[grey]Baseline technology: $(Get-SpectreEscapedText -Text ([string]$legs[0].Label))[/]"
                                }
                            }
                            catch {
                                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                                Write-SpectreHost "[grey]Baseline technology: not resolved here ($(Get-SpectreEscapedText -Text $_.Exception.Message)); the test resolves it.[/]"
                            }

                            # Baseline VERSION, asked here: the test itself uses the previous version without asking
                            # when the run is unattended (the Hyper-V run mode Unattended, -TestMode, SandboxTestMode / HyperVTestMode;
                            # test campaign F5), but an operator at this menu can always choose. Newest first.
                            $olderVersions = @()
                            $versionError = $null
                            try {
                                $yamlInfo = Get-YAMLInstallerInfo -FilesPath (Join-Path $project.Path 'Files')
                                $packagedVersion = if ($yamlInfo) { [string]$yamlInfo.PackageVersion } else { '' }
                                $olderVersions = @(Get-WingetVersions -AppId $wingetId -CurrentVersion $packagedVersion | Where-Object { $_ })
                            }
                            catch {
                                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                                $versionError = $_.Exception.Message
                            }
                            if ($olderVersions.Count -gt 0) {
                                $vmap = [ordered]@{}
                                $vlabels = for ($vi = 0; $vi -lt $olderVersions.Count; $vi++) {
                                    $vlabel = Get-SpectreEscapedText -Text ('{0}{1}' -f $olderVersions[$vi], $(if ($vi -eq 0) { '  (previous version)' } else { '' }))
                                    $vmap[$vlabel] = [string]$olderVersions[$vi]
                                    $vlabel
                                }
                                $vchosen = Read-SpectreSelection -Message 'Baseline version (the OLDER version to upgrade FROM)' -Choices @($vlabels) -Color Blue -EnableSearch -PageSize 15
                                if ($vmap.Contains([string]$vchosen)) { $testSplat['SpecificVersion'] = $vmap[[string]$vchosen] } else { $abort = $true }
                            }
                            else {
                                $why = if ($versionError) { "Could not list the older winget versions of $wingetId ($versionError)." }
                                       else { "winget lists no version of $wingetId older than the packaged one." }
                                Format-SpectrePanel -Data (Get-SpectreEscapedText -Text "$why Use a local packaged project as the baseline, or run Test-Win32ToolkitProject with -SpecificVersion.") -Header 'No baseline version' -Border Rounded -Color Yellow | Out-SpectreHost
                                Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                                $abort = $true
                            }
                        }

                        if (-not $abort) {
                            if (-not (Read-SpectreConfirm -Message 'Also verify the update-app requirement rule during the test? (recommended)' -DefaultAnswer 'y')) {
                                $testSplat['SkipRequirementCheck'] = $true
                            }
                        }
                    }
                    if (-not $abort) {
                        # Titled by what runs ($resolvedBackend), never by the pick.
                        Clear-Host; Write-SpectreRule -Title "Running the $resolvedBackend test…" -Color Blue
                        if ($notReadyLine) { Write-SpectreHost $notReadyLine }
                        # The run's effective test mode (TUI audit G3), chosen by what runs ($resolvedBackend), never by
                        # the pick. Constant texts only.
                        $modeSplat = @{ Backend = $resolvedBackend }
                        if ($testSplat.ContainsKey('TestMode')) { $modeSplat['TestMode'] = $testSplat['TestMode'] }
                        $effMode = Get-Win32ToolkitTestMode @modeSplat -WarningAction SilentlyContinue
                        $modeLine = if ($resolvedBackend -eq 'HyperV') {
                            if ($testSplat['TestMode'] -eq 'Unattended') { '[grey]Test mode: Unattended (your choice for this run): the Intune command line as SYSTEM, no pause.[/]' }
                            elseif ($effMode -eq 'Unattended') { '[yellow]Test mode: Unattended. This console cannot answer prompts, so the run cannot be watched.[/]' }
                            else { '[grey]Test mode: Interactive (your choice for this run): watch the PSADT dialogs in the VM window.[/]' }
                        }
                        elseif ($effMode -eq 'Unattended') { '[grey]Test mode: Unattended (SandboxTestMode = Unattended): a silent run, the sandbox closes itself.[/]' }
                        else { '[grey]Test mode: Interactive (watched: a 2-minute countdown, the sandbox stays open; SandboxTestMode changes the default).[/]' }
                        Write-SpectreHost $modeLine
                        try {
                            $testStartUtc = [datetime]::UtcNow
                            $verdict = Test-Win32ToolkitProject @testSplat
                            if ($sc.Key -eq 'Update') {
                                # A failed Update test whose surviving registration belongs to another installer
                                # technology (V42) gets its own panel: devices with that install must not get it.
                                $switches = @()
                                if ($verdict -eq $false) {
                                    try { $switches = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $project.Path | Where-Object { $_ }) }
                                    catch {
                                        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                                        Write-Verbose "Technology-switch check failed: $($_.Exception.Message)"
                                        $switches = @()
                                    }
                                }
                                if     ($verdict -eq $true)  { Format-SpectrePanel -Data 'All in-sandbox assertions passed.' -Header 'UPDATE TEST PASSED' -Border Rounded -Color Green }
                                elseif ($switches.Count -gt 0) {
                                    $switchText = @($switches | ForEach-Object { [string]$_.Message }) -join "`n`n"
                                    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $switchText) -Header 'TECHNOLOGY SWITCH' -Border Rounded -Color Red
                                }
                                elseif ($verdict -eq $false) {
                                    # Name the failed run's own log folder (each leg of a Both run has one; test campaign F2).
                                    $failedLogs = @(Get-Win32ToolkitTestRunLogFolder -ProjectPath $project.Path -Scenario 'Update' -SinceUtc $testStartUtc |
                                            ForEach-Object { Join-Path $_ 'UpdateAssertions.log' })
                                    $failedText = if ($failedLogs.Count) { 'One or more assertions FAILED - see ' + ($failedLogs -join ' and ') + '.' }
                                                  else { 'One or more assertions FAILED - see Sandbox\Logs\UpdateAssertions.log in the project folder.' }
                                    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $failedText) -Header 'UPDATE TEST FAILED' -Border Rounded -Color Red
                                }
                                else {
                                    $incText = 'No conclusive assertion results (sandbox closed early, timeout, or everything skipped).'
                                    if ($testSplat['TestMode'] -eq 'Unattended') { $incText += "`nIf the Intune-parity pre-check did not start it, run it again with the Interactive Hyper-V run mode." }
                                    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $incText) -Header 'Inconclusive' -Border Rounded -Color Yellow
                                }
                            }
                            else {
                                # InstallUninstall (TUI audit G1): PASSED / FAILED (each failed check with its reason, and
                                # the run's own log folder) / Inconclusive. Test-Win32ToolkitProject returns the verdict.
                                if ($verdict -eq $true) { Format-SpectrePanel -Data 'All install and uninstall assertions passed.' -Header 'INSTALL/UNINSTALL TEST PASSED' -Border Rounded -Color Green }
                                elseif ($verdict -eq $false) {
                                    $iuLogs = @(Get-Win32ToolkitTestRunLogFolder -ProjectPath $project.Path -Scenario 'InstallUninstall' -SinceUtc $testStartUtc |
                                            ForEach-Object { Join-Path $_ 'InstallAssertions.log' })
                                    if ($iuLogs.Count) { $iuLog = $iuLogs[-1]; $iuLogText = $iuLog }
                                    else { $iuLog = Join-Path $project.Path 'Sandbox\Logs\InstallAssertions.log'; $iuLogText = 'Sandbox\Logs\InstallAssertions.log in the project folder' }
                                    $iuLines = [System.Collections.Generic.List[string]]::new()
                                    $iuLines.Add("One or more assertions FAILED - see $iuLogText.")
                                    # Name and Reason come from the guest log, already through ConvertTo-Win32ToolkitSafeText.
                                    $iuFailures = @(Get-Win32ToolkitAssertionFailure -LogPath $iuLog)
                                    foreach ($iuFailure in $iuFailures) {
                                        $iuLines.Add(('- {0}: {1}' -f $iuFailure.Name, $(if ($iuFailure.Reason) { $iuFailure.Reason } else { 'no reason given' })))
                                    }
                                    if ($iuFailures.Count -eq 0) { $iuLines.Add("- no FAIL line was found in $iuLogText") }
                                    $iuLines.Add('')
                                    $iuLines.Add('Do not publish this package until you know why: Publish to Intune shows this failure again under "Review before you publish" (a warning; it does not block).')
                                    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text ($iuLines -join "`n")) -Header 'INSTALL/UNINSTALL TEST FAILED' -Border Rounded -Color Red
                                }
                                else {
                                    $incText = 'No conclusive assertion results (the run was closed early, timed out, skipped every assertion, or was not started; see the messages above).'
                                    if ($testSplat['TestMode'] -eq 'Unattended') { $incText += "`nIf the Intune-parity pre-check did not start it, run it again with the Interactive Hyper-V run mode." }
                                    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $incText) -Header 'Inconclusive' -Border Rounded -Color Yellow
                                }
                            }
                        }
                        catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                        Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                    }
                }
                'finish' {
                    Clear-Host; Write-SpectreRule -Title 'Finalizing…' -Color Blue
                    try {
                        # Its result object decides the panel (TUI audit G2); captured, so it never prints raw.
                        # -NoPublishPrompt: nothing is packaged here, but the menu never asks 'Upload ... now?' (TUI audit G5).
                        $out = @(Complete-Win32ToolkitManualApp -ProjectPath $project.Path -NoPublishPrompt)
                        Show-Win32ToolkitRunResult -Result $out -Name $project.Name
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
                'package' {
                    Clear-Host; Write-SpectreRule -Title 'Packaging…' -Color Blue
                    try {
                        Export-Win32ToolkitIntuneWin -ProjectPath $project.Path -NoPublishPrompt
                        Format-SpectrePanel -Data 'Package created. See the messages above for the .intunewin path.' -Header 'Done' -Border Rounded -Color Green
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
                'publish' {
                    # An unreadable AppConfig.json must not end the screen (TUI audit G7): the summary then shows the
                    # project name only, and the advisory below reports UNSAFE-CLEANUP ('could not be read').
                    try { $cfg = Get-Win32ToolkitAppConfig -ProjectPath $project.Path }
                    catch { $cfg = $null }
                    $app = if ($cfg -and $cfg.PSObject.Properties.Name -contains 'App') { $cfg.App } else { $null }
                    $summary = @(
                        "Application : $(if ($app.Name) { $app.Name } else { $project.Name })"
                        "Version     : $($app.Version)"
                        "Publisher   : $($app.Vendor)"
                    ) -join "`n"
                    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $summary) -Header 'About to PUBLISH to Intune' -Border Rounded -Color Yellow

                    # A project marked not configured (TUI audit G4) is refused by Export and Publish: say so now and go
                    # back to the action menu, before the advisory, "Publish which app?" and "Package and upload now?".
                    $notConfigured = $false
                    try { Assert-Win32ToolkitProjectConfigured -ProjectPath $project.Path -Operation Publish }
                    catch {
                        $notConfigured = $true
                        $ncHeader = if ($_.FullyQualifiedErrorId -eq 'W32T.ProjectNotConfigured') { 'Not configured' } else { 'Error' }
                        Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header $ncHeader -Border Rounded -Color Red
                        Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                    }

                    if (-not $notConfigured) {
                        # Advisory run scope (L20): this action shows the package advisory once, as a panel, and the
                        # Export / Publish calls below stay quiet for this project. Closed after Export returns.
                        $ownsAdvisoryRun = $null -eq $script:W32TAdvisoryRun
                        if ($ownsAdvisoryRun) { $script:W32TAdvisoryRun = @{} }
                        try {
                            # Package advisory (D1: warn, never block): red when an install/uninstall test failed or gave no
                            # verdict, an Update test failed, a technology switch was seen or the uninstall cleanup paths are
                            # unsafe (TUI audit G1); yellow for other warnings.
                            try {
                                $advisory = Get-Win32ToolkitPackageAdvisory -ProjectPath $project.Path -Context Tui -ProbeIfMissing
                                $advWarnings = @($advisory.Findings | Where-Object { $_ -and $_.Severity -eq 'Warning' })
                                if ($advWarnings.Count -gt 0) {
                                    $severe = @($advWarnings | Where-Object { $_.Code -in @('UNSAFE-CLEANUP', 'INSTALL-FAILED', 'UPDATE-FAILED', 'ID-TECH-SWITCH', 'INSTALL-INCONCLUSIVE') }).Count -gt 0
                                    $advText = @($advWarnings | ForEach-Object { [string]$_.Message }) -join "`n`n"
                                    $advHeader = if ($severe) { 'Review before you publish' } else { 'Check before you publish' }
                                    $advColor  = if ($severe) { 'Red' } else { 'Yellow' }
                                    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $advText) -Header $advHeader -Border Rounded -Color $advColor | Out-SpectreHost
                                }
                                foreach ($advInfo in @($advisory.Findings | Where-Object { $_ -and $_.Severity -ne 'Warning' })) {
                                    Write-SpectreHost "[grey]$(Get-SpectreEscapedText -Text ([string]$advInfo.Message))[/]"
                                }
                            }
                            catch {
                                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                                Write-Warning "Could not check the Update test and identity warnings: $($_.Exception.Message)"
                            }
                            if ($script:W32TAdvisoryRun -is [hashtable]) {
                                $script:W32TAdvisoryRun[[System.IO.Path]::GetFullPath($project.Path).TrimEnd('\')] = $true
                            }

                            $which = Read-SpectreSelection -Message 'Publish which app?' -Choices @(
                                [pscustomobject]@{ Key = 'install'; Label = 'Install app — normal deployment (assign to target devices)' }
                                [pscustomobject]@{ Key = 'both';    Label = 'Install app + Update app (2nd app, only where already installed)' }
                                [pscustomobject]@{ Key = 'update';  Label = 'Update app only — applies only where the app is already installed' }
                                [pscustomobject]@{ Key = 'cancel';  Label = 'Cancel' }
                            ) -ChoiceLabelProperty 'Label' -Color Blue -PageSize 10

                            if ($which.Key -ne 'cancel') {
                                Write-SpectreHost "[yellow]You will sign in to Microsoft Graph — the target tenant is shown during sign-in.[/]"
                                if (Read-SpectreConfirm -Message 'Package and upload now?' -DefaultAnswer 'n') {
                                    Clear-Host; Write-SpectreRule -Title 'Publishing to Intune…' -Color Blue
                                    try {
                                        $splat = @{ ProjectPath = $project.Path }
                                        switch ($which.Key) {
                                            'install' { $splat['PublishIntune'] = $true }
                                            'update'  { $splat['PublishUpdate'] = $true }
                                            'both'    { $splat['PublishIntune'] = $true; $splat['PublishUpdate'] = $true }
                                        }
                                        Export-Win32ToolkitIntuneWin @splat
                                        Format-SpectrePanel -Data 'Published. See the messages above for the app ID(s) and portal link.' -Header 'Done' -Border Rounded -Color Green
                                    }
                                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                                }
                            }
                        }
                        finally {
                            if ($ownsAdvisoryRun) { $script:W32TAdvisoryRun = $null }
                        }
                    }
                }
                'doc' {
                    Clear-Host; Write-SpectreRule -Title 'Generate customer documentation' -Color Blue
                    Write-SpectreHost '[grey]A clean one-page Documentation.md summarising the app, how it deploys, and the tests that were run — safe to hand to a customer.[/]'
                    $inclIds = Read-SpectreConfirm -Message 'Include the Intune app id + portal link? (only if the customer owns the tenant)' -DefaultAnswer 'n'
                    try {
                        $out = Export-Win32ToolkitDocumentation -ProjectPath $project.Path -IncludeIntuneIds:$inclIds
                        Format-SpectrePanel -Data "Documentation written to:`n$(Get-SpectreEscapedText -Text $out)" -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
                'open' { try { Invoke-Item -LiteralPath $project.Path } catch { } }
                'another' { $reselect = $true }
                'back'    { return }
            }
        }
    }
}
