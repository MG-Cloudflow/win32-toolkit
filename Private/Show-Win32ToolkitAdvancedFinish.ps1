function Show-Win32ToolkitAdvancedFinish {
    <#
    .SYNOPSIS
        Advanced (hard) manual-app two-step: after scaffolding, let the operator write the install code
        (between the manual-install and install-done blocks), then finalize via
        Complete-Win32ToolkitManualApp. See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [switch]$DoTest,
        [switch]$DoPackage,
        [switch]$DoPublish
    )

    $scriptFile = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'

    while ($true) {
        Clear-Host
        Format-SpectrePanel -Header 'Advanced app — your turn' -Border Rounded -Color Yellow -Data (
            "Project scaffolded at:`n[blue]$(Get-SpectreEscapedText -Text $ProjectPath)[/]`n`n" +
            "In Invoke-AppDeployToolkit.ps1 write your install code between the " +
            "'## win32-toolkit:Install:manual-install' block and the 'install-done' block (under " +
            "'## MARK: Install' on PSADT 4.2, inside Install-ADTDeployment on 4.1). Fail with 'throw', never " +
            "'return'; never assign PSADT variable names. Then choose [green]Finish setup[/].`n" +
            "The uninstall is captured automatically — you don't need to write it.")

        $sel = Read-SpectreSelection -Message 'Advanced app' -Choices @(
            [pscustomobject]@{ Key = 'open';   Label = 'Open the project folder' }
            [pscustomobject]@{ Key = 'edit';   Label = 'Open Invoke-AppDeployToolkit.ps1 in Notepad' }
            [pscustomobject]@{ Key = 'finish'; Label = "Finish setup now — I've edited the Install region" }
            [pscustomobject]@{ Key = 'later';  Label = 'Do it later — back to the menu' }
        ) -ChoiceLabelProperty 'Label' -Color Blue

        switch ($sel.Key) {
            'open' { try { Invoke-Item -LiteralPath $ProjectPath } catch { } }
            'edit' { try { Start-Process notepad.exe -ArgumentList "`"$scriptFile`"" } catch { } }
            'finish' {
                Clear-Host
                Write-SpectreRule -Title 'Finishing setup…' -Color Blue
                # NoPublishPrompt: the publish choice was made in the wizard (TUI audit G5).
                $cp = @{ ProjectPath = $ProjectPath; NoPublishPrompt = $true }
                if ($DoTest)    { $cp.RunTest = 'InstallUninstall' }
                if ($DoPackage) { $cp.PackageIntune = $true }
                if ($DoPublish) { $cp.PublishIntune = $true }
                $finished = $true
                try {
                    # The run is judged by its result object (TUI audit G2): Done only when it Succeeded.
                    $out = @(Complete-Win32ToolkitManualApp @cp)
                    Show-Win32ToolkitRunResult -Result $out -Name (Split-Path -Leaf $ProjectPath)
                }
                catch {
                    if ($_.FullyQualifiedErrorId -eq 'W32T.PackageNotReady') {
                        # The deploy script was refused (TUI audit G11): stay on this screen so the operator can fix it
                        # and choose Finish setup again, with the same test, package and publish choices.
                        $finished = $false
                        Format-SpectrePanel -Data ("[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]`n`n" +
                            'Fix the deploy script (Open Invoke-AppDeployToolkit.ps1 in Notepad), then choose Finish setup again: your test, package and publish choices are kept.') -Header 'Not ready to finish' -Border Rounded -Color Red
                    }
                    else {
                        Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Something went wrong' -Border Rounded -Color Red
                    }
                }
                $pauseText = if ($finished) { 'Press any key to return to the menu' } else { 'Press any key to continue' }
                Read-SpectrePause -Message $pauseText -AnyKey | Out-Null
                # 'continue' would only end the switch: return leaves the loop; otherwise the loop shows the screen again.
                if ($finished) { return }
            }
            'later' { return }
        }
    }
}
