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

        # Show the VM's current CPU/RAM (live if it exists, else the configured spec the next provision will use).
        $vmName = Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden'
        $liveVm = $null; try { $liveVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue } catch { }
        if ($liveVm) {
            $hCpu = (Get-VMProcessor -VMName $vmName).Count
            $hMem = (Get-VMMemory -VMName $vmName).Startup
            Write-SpectreHost "VM resources: [blue]$hCpu vCPU[/] / [blue]$([math]::Round($hMem / 1GB, 1)) GB[/]  [grey]($vmName)[/]"
        } else {
            $hCpu = Get-Win32ToolkitConfigValue -Name 'HyperVProcessorCount' -Default '2'
            $hMem = [uint64](Get-Win32ToolkitConfigValue -Name 'HyperVMemoryStartupBytes' -Default ([uint64]4GB))
            Write-SpectreHost "VM resources (next provision): [blue]$hCpu vCPU[/] / [blue]$([math]::Round($hMem / 1GB, 1)) GB[/]"
        }

        $sel = Read-SpectreSelection -Message 'Hyper-V test VM' -Choices @(
            [pscustomobject]@{ Key = 'backend';   Label = 'Set the default test backend (Sandbox / Hyper-V)' }
            [pscustomobject]@{ Key = 'provision'; Label = 'Provision the test VM from a Windows 11 ISO (one-time, ~30-60 min)' }
            [pscustomobject]@{ Key = 'resources'; Label = 'Change VM resources (CPU / memory) — reconfigures + re-checkpoints (minutes)' }
            [pscustomobject]@{ Key = 'reset';     Label = 'Reset the VM to its clean checkpoint' }
            [pscustomobject]@{ Key = 'autologon'; Label = 'Configure guest AutoLogon + re-checkpoint (fix a login-screen checkpoint)' }
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
                    # Detect a leftover VM / golden VHDX from a previous build. Without this, the underlying
                    # New-Win32ToolkitGoldenVhdx throws "VHDX already exists (use -Force)" the instant it starts
                    # — the TUI never passed -Force — so a repeat provisioning attempt appeared to "do nothing"
                    # (it errored before any progress output). Offer a rebuild instead of dead-ending.
                    $vmName    = Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden'
                    $vhdxPath  = Join-Path (Get-Win32ToolkitHyperVPaths -BasePath (Get-Win32ToolkitBasePath)).Golden "$vmName.vhdx"
                    $existingVhdx = Test-Path -LiteralPath $vhdxPath
                    $existingVm   = $false
                    try { $existingVm = [bool](Get-VM -Name $vmName -ErrorAction SilentlyContinue) } catch { }

                    $proceed = $true
                    $force   = $false
                    if ($existingVm -or $existingVhdx) {
                        $what = @(); if ($existingVm) { $what += "VM '$vmName'" }; if ($existingVhdx) { $what += 'golden VHDX' }
                        Write-SpectreHost "[yellow]An existing $($what -join ' + ') from a previous build was found.[/]"
                        Write-SpectreHost '[grey]Provisioning cannot proceed without rebuilding it — this is why a second attempt looked like it did nothing.[/]'
                        if (Read-SpectreConfirm -Message 'Delete it and rebuild from scratch?' -DefaultAnswer 'y') {
                            $force = $true
                        }
                        else {
                            $proceed = $false
                            Write-SpectreHost '[grey]Cancelled — nothing changed.[/]'
                            Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                        }
                    }

                    if ($proceed) {
                        Clear-Host
                        Write-SpectreRule -Title 'Provisioning the Hyper-V test VM…' -Color Blue
                        Write-SpectreHost '[yellow]Requires an elevated session. You will be prompted for a guest admin password — it must NOT be blank.[/]'
                        Write-SpectreHost '[grey]This runs once and takes ~30-60 minutes (ISO -> VHDX -> VM -> warm checkpoint).[/]'
                        Write-SpectreHost '[grey]When the VM is up, its console opens and provisioning PAUSES: sign in, run Windows Update, let all reboots finish, then press Enter to confirm. The clean-base checkpoint captures that fully-patched desktop — every test run reverts to it.[/]'
                        try {
                            $newArgs = @{ IsoPath = $iso; Verbose = $true }
                            if ($force) { $newArgs['Force'] = $true }
                            New-Win32ToolkitTestVM @newArgs | Out-Null
                            Format-SpectrePanel -Data 'Test VM provisioned and checkpointed. The default backend can now be Hyper-V.' -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                        }
                        catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                        Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                    }
                }
            }
            'resources' {
                Clear-Host; Write-SpectreRule -Title 'VM resources (CPU / memory)' -Color Blue
                $rvm = $null; try { $rvm = Get-VM -Name $vmName -ErrorAction SilentlyContinue } catch { }
                if (-not $rvm) {
                    Format-SpectrePanel -Data "No test VM ('$vmName') is provisioned yet — provision it first." -Header 'No VM' -Border Rounded -Color Yellow | Out-SpectreHost
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
                else {
                    $curCpu = (Get-VMProcessor -VMName $vmName).Count
                    $curMem = (Get-VMMemory -VMName $vmName).Startup
                    $vmHost = Get-VMHost
                    Write-SpectreHost "Current: [blue]$curCpu vCPU[/] / [blue]$([math]::Round($curMem / 1GB, 2)) GB[/]"
                    Write-SpectreHost "[grey]Host capacity: $($vmHost.LogicalProcessorCount) logical processors / $([math]::Round($vmHost.MemoryCapacity / 1GB, 1)) GB RAM (requests above this are refused).[/]"

                    $cpuIn = Read-SpectreText -Message "New vCPU count (blank = keep $curCpu)" -DefaultAnswer ''
                    $memIn = Read-SpectreText -Message "New memory, e.g. 6GB or 6144MB (blank = keep $([math]::Round($curMem / 1GB, 2)) GB)" -DefaultAnswer ''

                    $bad = $false
                    $rargs = @{}
                    if (-not [string]::IsNullOrWhiteSpace($cpuIn)) {
                        $pc = 0
                        if ([int]::TryParse($cpuIn.Trim(), [ref]$pc) -and $pc -ge 1) { $rargs['ProcessorCount'] = $pc }
                        else { Write-SpectreHost "[red]Invalid vCPU count: '$(Get-SpectreEscapedText -Text $cpuIn)'.[/]"; $bad = $true }
                    }
                    if (-not [string]::IsNullOrWhiteSpace($memIn)) {
                        $bytes = ConvertTo-Win32ToolkitByteSize -Text $memIn
                        if ($bytes) { $rargs['MemoryStartupBytes'] = $bytes }
                        else { Write-SpectreHost "[red]Invalid memory: '$(Get-SpectreEscapedText -Text $memIn)' — try 6GB or 6144MB.[/]"; $bad = $true }
                    }

                    if ($bad) {
                        Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                    }
                    elseif ($rargs.Count -eq 0) {
                        Write-SpectreHost '[grey]No changes entered — nothing to do.[/]'
                        Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                    }
                    else {
                        Write-SpectreHost '[yellow]This turns the VM OFF, applies the change, cold-boots it to the AutoLogon desktop, and re-takes the clean-base checkpoint (a few minutes).[/]'
                        if (Read-SpectreConfirm -Message 'Apply now?' -DefaultAnswer 'y') {
                            Clear-Host; Write-SpectreRule -Title 'Reconfiguring the VM…' -Color Blue
                            try {
                                Set-Win32ToolkitTestVMResource @rargs | Out-Null
                                Format-SpectrePanel -Data 'VM resources updated and the clean-base checkpoint recreated.' -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                            }
                            catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                            Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                        }
                    }
                }
            }
            'reset' {
                Clear-Host; Write-SpectreRule -Title 'Reverting to clean-base…' -Color Blue
                try {
                    Reset-Win32ToolkitTestVM
                    Format-SpectrePanel -Data 'VM reverted to the clean checkpoint.' -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                }
                catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
            }
            'remove' {
                if (Read-SpectreConfirm -Message 'Remove the test VM and delete its VHDX?' -DefaultAnswer 'n') {
                    Clear-Host; Write-SpectreRule -Title 'Removing the test VM…' -Color Blue
                    try {
                        Remove-Win32ToolkitTestVM -RemoveVhdx
                        Format-SpectrePanel -Data 'Test VM removed.' -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'autologon' {
                Clear-Host; Write-SpectreRule -Title 'Configuring guest AutoLogon + re-checkpoint…' -Color Blue
                try {
                    $vm = Get-Win32ToolkitConfigValue -Name 'HyperVVMName'     -Default 'win32tk-golden'
                    $cp = Get-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Default 'clean-base'
                    $gc = Get-Win32ToolkitGuestCredential
                    if (-not $gc) { throw 'No guest credential is configured — provision the VM first.' }
                    Reset-Win32ToolkitTestVM
                    Set-Win32ToolkitGuestAutoLogon -VMName $vm -Credential $gc
                    if (Confirm-Win32ToolkitGuestDesktop -VMName $vm -Credential $gc) {
                        Get-VMCheckpoint -VMName $vm -ErrorAction SilentlyContinue | Remove-VMCheckpoint -ErrorAction SilentlyContinue
                        Set-VM -Name $vm -CheckpointType Standard
                        Checkpoint-VM -VMName $vm -SnapshotName $cp
                        Format-SpectrePanel -Data 'AutoLogon configured and the checkpoint re-taken at a logged-in desktop. Interactive GUI testing is now safe.' -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                    } else {
                        Format-SpectrePanel -Data 'Could not reach a desktop to re-checkpoint. Log in once in the VM window, then run this again.' -Header 'Warning' -Border Rounded -Color Yellow | Out-SpectreHost
                    }
                }
                catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
            }
            'back' { return }
        }
    }
}
