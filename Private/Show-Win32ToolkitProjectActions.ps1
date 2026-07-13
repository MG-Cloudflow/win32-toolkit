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

            $act = Read-SpectreSelection -Message 'What would you like to do?' -Choices @(
                [pscustomobject]@{ Key = 'test';    Label = 'Run a test (Windows Sandbox or Hyper-V VM)' }
                [pscustomobject]@{ Key = 'finish';  Label = 'Finalize / refresh (Sandbox capture -> auto uninstall)' }
                [pscustomobject]@{ Key = 'package'; Label = 'Package to .intunewin' }
                [pscustomobject]@{ Key = 'publish'; Label = 'Publish to Intune' }
                [pscustomobject]@{ Key = 'open';    Label = 'Open the project folder' }
                [pscustomobject]@{ Key = 'another'; Label = 'Pick another project' }
                [pscustomobject]@{ Key = 'back';    Label = 'Back to the main menu' }
            ) -ChoiceLabelProperty 'Label' -Color Blue -PageSize 10

            switch ($act.Key) {
                'test' {
                    $backend = Read-SpectreSelection -Message 'Which test backend?' -Choices @(
                        [pscustomobject]@{ Key = 'Sandbox'; Label = 'Windows Sandbox' }
                        [pscustomobject]@{ Key = 'HyperV';  Label = 'Hyper-V VM (fast — needs a provisioned test VM; see Settings)' }
                    ) -ChoiceLabelProperty 'Label' -Color Blue

                    # Hyper-V currently wires InstallUninstall; Update/capture still run on Sandbox.
                    $scenChoices = @([pscustomobject]@{ Key = 'InstallUninstall'; Label = 'Install then uninstall (any app)' })
                    if ($backend.Key -eq 'Sandbox') {
                        $scenChoices += [pscustomobject]@{ Key = 'Update'; Label = 'Update from an older version (winget apps only)' }
                    } else {
                        Write-SpectreHost '[grey]Hyper-V currently supports Install/Uninstall. Update runs on Windows Sandbox for now.[/]'
                    }
                    $sc = Read-SpectreSelection -Message 'Test scenario' -Choices $scenChoices -ChoiceLabelProperty 'Label' -Color Blue

                    $testSplat = @{ ProjectPath = $project.Path; Scenario = $sc.Key; Backend = $backend.Key }
                    if ($sc.Key -eq 'Update') {
                        if (-not (Read-SpectreConfirm -Message 'Also verify the update-app requirement rule during the test? (recommended)' -DefaultAnswer 'y')) {
                            $testSplat['SkipRequirementCheck'] = $true
                        }
                    }
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
