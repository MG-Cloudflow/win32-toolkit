function Show-Win32ToolkitAdvancedFinish {
    <#
    .SYNOPSIS
        Advanced (hard) manual-app two-step: after scaffolding, let the operator edit the Install
        region, then finalize via Complete-Win32ToolkitManualApp. See knowledge-base/designs/tui.md.
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
            "Edit the Install region in Invoke-AppDeployToolkit.ps1 (add your Pre-Install / Install / " +
            "Post-Install logic), then choose [green]Finish setup[/].`n" +
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
                $cp = @{ ProjectPath = $ProjectPath }
                if ($DoTest)    { $cp.RunTest = 'InstallUninstall' }
                if ($DoPackage) { $cp.PackageIntune = $true }
                if ($DoPublish) { $cp.PublishIntune = $true }
                try {
                    Complete-Win32ToolkitManualApp @cp
                    Format-SpectrePanel -Data 'Finished. Review the messages above for details.' -Header 'Done' -Border Rounded -Color Green
                }
                catch {
                    Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Something went wrong' -Border Rounded -Color Red
                }
                Read-SpectrePause -Message 'Press any key to return to the menu' -AnyKey | Out-Null
                return
            }
            'later' { return }
        }
    }
}
