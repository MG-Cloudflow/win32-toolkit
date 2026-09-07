function Show-Win32ToolkitSettings {
    <#
    .SYNOPSIS
        Settings screen (base folder, test VM, update check, re-check). Persists a base-folder change
        to the registry and RETURNS NOTHING — the caller re-reads Get-Win32ToolkitBasePath. TUI screens
        render THROUGH their success stream (PwshSpectreConsole 2.6.x render commands return their
        rendered text; it displays at Out-Default), so callers must never capture or Out-Null them
        (issue #67). See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([string]$BasePath)

    while ($true) {
        Write-SpectreRule -Title 'Settings' -Color Grey
        Write-SpectreHost "Base folder: [blue]$(Get-SpectreEscapedText -Text $BasePath)[/]"
        $choices = @(
            [pscustomobject]@{ Key = 'basepath'; Label = 'Change the base folder' }
            [pscustomobject]@{ Key = 'testvm';   Label = 'Hyper-V test VM (backend / provision / reset / remove)' }
            [pscustomobject]@{ Key = 'update';   Label = "Update check: $(if ((Get-Win32ToolkitConfigValue -Name 'UpdateCheck' -Default 'On') -eq 'Off') { 'Off' } else { 'On' }) (toggle / check now)" }
            [pscustomobject]@{ Key = 'recheck';  Label = 'Re-run the system check' }
            [pscustomobject]@{ Key = 'back';     Label = 'Back to main menu' }
        )
        $sel = Read-SpectreSelection -Message 'Settings' -Choices $choices -ChoiceLabelProperty 'Label' -Color Blue
        switch ($sel.Key) {
            'basepath' {
                $new = Read-SpectreText -Message 'Enter the base folder for all output' -DefaultAnswer $BasePath
                if (-not [string]::IsNullOrWhiteSpace($new)) {
                    $BasePath = Get-Win32ToolkitBasePath -Set $new
                    Write-SpectreHost "[green]Saved:[/] $(Get-SpectreEscapedText -Text $BasePath)"
                }
            }
            # Bare call — the subtree's rendered text must flow out to Out-Default to be visible.
            # (An earlier '| Out-Null' here made every rule/panel inside the test-VM screen invisible.)
            'testvm'  { Show-Win32ToolkitTestVM }
            'update'  {
                $now = Get-Win32ToolkitConfigValue -Name 'UpdateCheck' -Default 'On'
                $new = if ($now -eq 'Off') { 'On' } else { 'Off' }
                Set-Win32ToolkitConfigValue -Name 'UpdateCheck' -Value $new
                Write-SpectreHost "[green]Update check set to:[/] $new"
                if ($new -eq 'On') {
                    $info = Get-Win32ToolkitUpdateInfo -Force
                    if ($info -and $info.UpdateAvailable) { Show-Win32ToolkitUpdateNotice -Force }
                    elseif ($info)                        { Write-SpectreHost "[grey]You are on the latest version (v$($info.Installed)).[/]" }
                    else                                  { Write-SpectreHost '[grey]Could not check for updates right now.[/]' }
                }
            }
            'recheck' { Show-Win32ToolkitHealth -BasePath $BasePath }
            'back'    { return }
        }
    }
}
