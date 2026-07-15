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
            $label = Get-SpectreEscapedText -Text ('{0}  /  {1}' -f $p.Template, $p.Name)
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

            $depNow = @(Get-Win32ToolkitDependencies -ProjectPath $project.Path)
            $act = Read-SpectreSelection -Message 'What would you like to do?' -Choices @(
                [pscustomobject]@{ Key = 'test';    Label = 'Run a test (Windows Sandbox or Hyper-V VM)' }
                [pscustomobject]@{ Key = 'deps';    Label = "Dependencies — apps installed BEFORE this one ($(if ($depNow.Count) { "$($depNow.Count) declared" } else { 'none' }))" }
                [pscustomobject]@{ Key = 'finish';  Label = "Finalize / refresh ($((Get-Win32ToolkitBackendInfo).Label) capture -> auto uninstall)" }
                [pscustomobject]@{ Key = 'package'; Label = 'Package to .intunewin' }
                [pscustomobject]@{ Key = 'publish'; Label = 'Publish to Intune' }
                [pscustomobject]@{ Key = 'open';    Label = 'Open the project folder' }
                [pscustomobject]@{ Key = 'another'; Label = 'Pick another project' }
                [pscustomobject]@{ Key = 'back';    Label = 'Back to the main menu' }
            ) -ChoiceLabelProperty 'Label' -Color Blue -PageSize 10

            switch ($act.Key) {
                'deps' {
                    Clear-Host; Write-SpectreRule -Title 'Dependencies' -Color Blue
                    Write-SpectreHost '[grey]Intune installs these BEFORE this app. They are also installed first in the test/capture run, so the app is never tested without its runtime.[/]'
                    $current = @($depNow | ForEach-Object { "$($_.Source):$($_.Ref)" })
                    $chosen  = @(Show-Win32ToolkitDependencyPicker -BasePath $BasePath -Existing $current)
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
                    if ($backend.Key -eq 'HyperV') {
                        $pauseWhat = if ($sc.Key -eq 'Update') { 'verify the OLD install, then update' } else { 'test the app, then uninstall' }
                        $mode = Read-SpectreSelection -Message 'Hyper-V run mode' -Choices @(
                            [pscustomobject]@{ Key = 'interactive'; Label = "Interactive — watch the PSADT GUI in the VM console, $pauseWhat" }
                            [pscustomobject]@{ Key = 'unattended';  Label = 'Silent — run every phase back-to-back (no GUI, no pause)' }
                        ) -ChoiceLabelProperty 'Label' -Color Blue
                        if ($mode.Key -eq 'unattended') { $testSplat['Unattended'] = $true }
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

                        if (-not $abort) {
                            if (-not (Read-SpectreConfirm -Message 'Also verify the update-app requirement rule during the test? (recommended)' -DefaultAnswer 'y')) {
                                $testSplat['SkipRequirementCheck'] = $true
                            }
                        }
                    }
                    if (-not $abort) {
                        Clear-Host; Write-SpectreRule -Title "Running the $($backend.Key) test…" -Color Blue
                        try {
                            $verdict = Test-Win32ToolkitProject @testSplat
                            if ($sc.Key -eq 'Update') {
                                if     ($verdict -eq $true)  { Format-SpectrePanel -Data 'All in-sandbox assertions passed.' -Header 'UPDATE TEST PASSED' -Border Rounded -Color Green }
                                elseif ($verdict -eq $false) { Format-SpectrePanel -Data 'One or more assertions FAILED - see Sandbox\Logs\UpdateAssertions.log in the project folder.' -Header 'UPDATE TEST FAILED' -Border Rounded -Color Red }
                                else                         { Format-SpectrePanel -Data 'No conclusive assertion results (sandbox closed early, timeout, or everything skipped).' -Header 'Inconclusive' -Border Rounded -Color Yellow }
                            }
                        }
                        catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                        Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                    }
                }
                'finish' {
                    Clear-Host; Write-SpectreRule -Title 'Finalizing…' -Color Blue
                    try { Complete-Win32ToolkitManualApp -ProjectPath $project.Path }
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
                    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $project.Path
                    $app = if ($cfg.PSObject.Properties.Name -contains 'App') { $cfg.App } else { $null }
                    $summary = @(
                        "Application : $(if ($app.Name) { $app.Name } else { $project.Name })"
                        "Version     : $($app.Version)"
                        "Publisher   : $($app.Vendor)"
                    ) -join "`n"
                    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $summary) -Header 'About to PUBLISH to Intune' -Border Rounded -Color Yellow

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
                'open' { try { Invoke-Item -LiteralPath $project.Path } catch { } }
                'another' { $reselect = $true }
                'back'    { return }
            }
        }
    }
}
