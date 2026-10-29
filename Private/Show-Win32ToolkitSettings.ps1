function Show-Win32ToolkitSettings {
    <#
    .SYNOPSIS
        Settings screen (base folder, PSADT version, test VM, update check, re-check). Persists a base-folder change
        to the registry and RETURNS NOTHING — the caller re-reads Get-Win32ToolkitBasePath. TUI screens
        render THROUGH their success stream (PwshSpectreConsole 2.6.x render commands return their
        rendered text; it displays at Out-Default), so callers must never capture or Out-Null them
        (issue #67). See knowledge-base/designs/tui.md.
    .DESCRIPTION
        Menu selectors (knowledge-base/designs/menu-selectors.md, D1): the PSAppDeployToolkit version item opens
        Show-Win32ToolkitPsadtVersion and its label shows what new projects get; the Hyper-V test VM item's label shows
        the test VM and checkpoint tests use (Get-Win32ToolkitHyperVTarget -NoThrow). Both labels are display only and
        fail open to a plain label.
    #>
    [CmdletBinding()]
    param([string]$BasePath)

    while ($true) {
        Write-SpectreRule -Title 'Settings' -Color Grey
        Write-SpectreHost "Base folder: [blue]$(Get-SpectreEscapedText -Text $BasePath)[/]"
        $psadtLabel = 'PSAppDeployToolkit version'
        try {
            $psadtSel = Select-Win32ToolkitPsadtModule
            $psadtLabel += switch ($psadtSel.Status) {
                'Selected' {
                    $how = switch ($psadtSel.PreferredSource) { 'Environment' { 'pinned in this window' } 'Registry' { 'pinned' } default { 'newest installed' } }
                    ": $($psadtSel.VersionText) ($how)"
                }
                'PreferredNotFound' { ': the pinned version is not installed' }
                'NoneInstalled'     { ': none installed yet' }
                default             { ': no supported version installed' }
            }
        }
        catch { $psadtLabel = 'PSAppDeployToolkit version' }
        $vmLabel = 'Hyper-V test VM'
        try {
            $vmTarget = Get-Win32ToolkitHyperVTarget -NoThrow
            if (-not $vmTarget.Problem) { $vmLabel += ": $(ConvertTo-Win32ToolkitSafeText -Text $vmTarget.VMName -MaxLength 64) / $(ConvertTo-Win32ToolkitSafeText -Text $vmTarget.CheckpointName -MaxLength 64)" }
        }
        catch { $vmLabel = 'Hyper-V test VM' }
        $choices = @(
            [pscustomobject]@{ Key = 'basepath'; Label = 'Change the base folder' }
            [pscustomobject]@{ Key = 'psadt';    Label = (Get-SpectreEscapedText -Text $psadtLabel) }
            [pscustomobject]@{ Key = 'testvm';   Label = (Get-SpectreEscapedText -Text "$vmLabel (backend / choose / provision / reset / remove)") }
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
            'psadt'   { Show-Win32ToolkitPsadtVersion }
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
