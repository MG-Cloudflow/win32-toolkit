function Show-Win32ToolkitTestVM {
    <#
    .SYNOPSIS
        Hyper-V test-VM screen (Spectre): set the default backend, provision / reset / remove the VM.
        Thin front-end over New/Reset/Remove-Win32ToolkitTestVM + the test-backend config.
        See knowledge-base/designs/hyperv-backend-plan.md.
    #>
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        Write-SpectreRule -Title 'Hyper-V test VM' -Color Blue

        $backend = Get-Win32ToolkitConfigValue -Name 'TestBackend' -Default 'Sandbox'
        Write-SpectreHost "Default test backend: [blue]$backend[/]"

        $reasons = @(Test-Win32ToolkitHyperVReady)
        if ($reasons.Count -eq 0) {
            Write-SpectreHost '[green]Hyper-V backend is READY[/] — VM, checkpoint and guest credential are configured.'
        } else {
            Write-SpectreHost "[yellow]Hyper-V backend not ready:[/] $(Get-SpectreEscapedText -Text ($reasons -join '; '))"
        }

        $sel = Read-SpectreSelection -Message 'Hyper-V test VM' -Choices @(
            [pscustomobject]@{ Key = 'backend';   Label = 'Set the default test backend (Sandbox / Hyper-V)' }
            [pscustomobject]@{ Key = 'provision'; Label = 'Provision the test VM from a Windows 11 ISO (one-time, ~30-60 min)' }
            [pscustomobject]@{ Key = 'reset';     Label = 'Reset the VM to its clean checkpoint' }
            [pscustomobject]@{ Key = 'remove';    Label = 'Remove the test VM (and its VHDX)' }
            [pscustomobject]@{ Key = 'back';      Label = 'Back' }
        ) -ChoiceLabelProperty 'Label' -Color Blue -PageSize 10

        switch ($sel.Key) {
            'backend' {
                $b = Read-SpectreSelection -Message 'Default test backend' -Choices @(
                    [pscustomobject]@{ Key = 'Sandbox'; Label = 'Windows Sandbox (default)' }
                    [pscustomobject]@{ Key = 'HyperV';  Label = 'Hyper-V VM (fast; falls back to Sandbox if not ready)' }
                ) -ChoiceLabelProperty 'Label' -Color Blue
                Set-Win32ToolkitConfigValue -Name 'TestBackend' -Value $b.Key
                Write-SpectreHost "[green]Default backend set to $($b.Key).[/]"
                Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
            }
            'provision' {
                $iso = Read-SpectreText -Message 'Path to a Windows 11 x64 ISO (blank to cancel)' -DefaultAnswer ''
                if (-not [string]::IsNullOrWhiteSpace($iso)) {
                    Clear-Host
                    Write-SpectreRule -Title 'Provisioning the Hyper-V test VM…' -Color Blue
                    Write-SpectreHost '[yellow]Requires an elevated session. You will be prompted for a guest admin password — it must NOT be blank.[/]'
                    Write-SpectreHost '[grey]This runs once and takes ~30-60 minutes (ISO -> VHDX -> VM -> warm checkpoint).[/]'
                    try {
                        New-Win32ToolkitTestVM -IsoPath $iso -Verbose | Out-Null
                        Format-SpectrePanel -Data 'Test VM provisioned and checkpointed. The default backend can now be Hyper-V.' -Header 'Done' -Border Rounded -Color Green
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'reset' {
                Clear-Host; Write-SpectreRule -Title 'Reverting to clean-base…' -Color Blue
                try {
                    Reset-Win32ToolkitTestVM
                    Format-SpectrePanel -Data 'VM reverted to the clean checkpoint.' -Header 'Done' -Border Rounded -Color Green
                }
                catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
            }
            'remove' {
                if (Read-SpectreConfirm -Message 'Remove the test VM and delete its VHDX?' -DefaultAnswer 'n') {
                    Clear-Host; Write-SpectreRule -Title 'Removing the test VM…' -Color Blue
                    try {
                        Remove-Win32ToolkitTestVM -RemoveVhdx
                        Format-SpectrePanel -Data 'Test VM removed.' -Header 'Done' -Border Rounded -Color Green
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'back' { return }
        }
    }
}
