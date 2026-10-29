function Show-Win32ToolkitTestVM {
    <#
    .SYNOPSIS
        Hyper-V test-VM screen (Spectre): choose the test VM and checkpoint, set the default backend, provision / reset /
        remove the VM. Thin front-end over Show-Win32ToolkitTestVMSelect, New/Reset/Remove-Win32ToolkitTestVM,
        Set-Win32ToolkitTestVMResource, Repair-Win32ToolkitTestVMCheckpoint and the test-backend config. See
        knowledge-base/designs/hyperv-backend-plan.md and menu-selectors.md (D10: every item acts on the session's VM and
        checkpoint, passes them by name and names them in its question).
    #>
    [CmdletBinding()]
    param()

    while ($true) {
        Clear-Host
        Write-SpectreRule -Title 'Hyper-V test VM' -Color Blue

        $backend = Get-Win32ToolkitConfigValue -Name 'TestBackend' -Default 'Sandbox'
        Write-SpectreHost "Default test backend: [blue]$backend[/]"

        # The session's VM and checkpoint (speed-up PR 3, D11: a W32T_HYPERV_VM / W32T_HYPERV_CHECKPOINT pin first, then the
        # registry). Menu selectors D10: every item below acts on exactly these, passes them by name and names them in its
        # question; an invalid pin passes nothing, so the command itself stops with W32T.HyperVTargetNotReady.
        $target = Get-Win32ToolkitHyperVTarget -NoThrow
        $vmName = $target.VMName
        $cpName = $target.CheckpointName
        $on = @{}; $onName = @{}
        if ($target.Problem) {
            Write-SpectreHost "[red]Test VM pin not valid:[/] $(Get-SpectreEscapedText -Text $target.Problem)"
        }
        else {
            $on = @{ Name = $vmName; CheckpointName = $cpName }; $onName = @{ Name = $vmName }
            $why = switch ($target.Source) { 'Environment' { 'pinned by W32T_HYPERV_VM in this window' } 'Registry' { 'saved in Settings' } default { 'the default' } }
            Write-SpectreHost "Test VM: [blue]$(Get-SpectreEscapedText -Text $vmName)[/], checkpoint [blue]$(Get-SpectreEscapedText -Text $cpName)[/] [grey]($why)[/]"
        }
        $vmText = Get-SpectreEscapedText -Text "'$vmName'"
        $cpText = Get-SpectreEscapedText -Text "'$cpName'"
        $golden = $vmName -eq 'win32tk-golden'

        $reasons = @(Test-Win32ToolkitHyperVReady)
        if ($reasons.Count -eq 0) {
            Write-SpectreHost '[green]Hyper-V backend is READY[/] — VM, checkpoint and guest credential are configured.'
        } else {
            Write-SpectreHost "[yellow]Hyper-V backend not ready:[/] $(Get-SpectreEscapedText -Text ($reasons -join '; '))"
        }

        # Show the VM's current CPU/RAM (live if it exists, else the configured spec the next provision will use).
        $liveVm = $null; if ($vmName) { try { $liveVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue } catch { } }
        if ($liveVm) {
            $hCpu = (Get-VMProcessor -VMName $vmName).Count
            $hMem = (Get-VMMemory -VMName $vmName).Startup
            Write-SpectreHost "VM resources: [blue]$hCpu vCPU[/] / [blue]$([math]::Round($hMem / 1GB, 1)) GB[/]  [grey]($(Get-SpectreEscapedText -Text $vmName))[/]"
        } else {
            $hCpu = Get-Win32ToolkitConfigValue -Name 'HyperVProcessorCount' -Default '2'
            $hMem = [uint64](Get-Win32ToolkitConfigValue -Name 'HyperVMemoryStartupBytes' -Default ([uint64]4GB))
            Write-SpectreHost "VM resources (next provision): [blue]$hCpu vCPU[/] / [blue]$([math]::Round($hMem / 1GB, 1)) GB[/]"
        }

        $sel = Read-SpectreSelection -Message 'Hyper-V test VM' -Choices @(
            [pscustomobject]@{ Key = 'select';    Label = 'Choose the test VM and checkpoint' }
            [pscustomobject]@{ Key = 'backend';   Label = 'Set the default test backend (Sandbox / Hyper-V)' }
            [pscustomobject]@{ Key = 'provision'; Label = 'Provision the test VM from a Windows 11 ISO (one-time, ~30-60 min)' }
            [pscustomobject]@{ Key = 'resources'; Label = 'Change VM resources (CPU / memory) — reconfigures + re-checkpoints (minutes)' }
            [pscustomobject]@{ Key = 'reset';     Label = 'Reset the VM to its clean checkpoint' }
            [pscustomobject]@{ Key = 'autologon'; Label = 'Configure guest AutoLogon + re-checkpoint (fix a login-screen / missing checkpoint or credential)' }
            [pscustomobject]@{ Key = 'remove';    Label = 'Remove the test VM (and its VHDX)' }
            [pscustomobject]@{ Key = 'back';      Label = 'Back' }
        ) -ChoiceLabelProperty 'Label' -Color Blue -PageSize 10

        switch ($sel.Key) {
            # Bare call: the subscreen renders through this screen's stream (issue #67).
            'select' { Show-Win32ToolkitTestVMSelect }
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
                # Explorer's "Copy as path" wraps the path in double quotes — strip them so the
                # blank-cancel check and provisioning see the real path (issue #66). The public
                # cmdlet trims too; doing it here keeps the TUI's own messages/checks clean.
                if ($iso) { $iso = $iso.Trim().Trim('"') }
                if (-not [string]::IsNullOrWhiteSpace($iso) -and $target.Problem) {
                    Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $target.Problem)[/]`nFix or remove the pin first: nothing was built." -Header 'Not started' -Border Rounded -Color Red | Out-SpectreHost
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
                elseif (-not [string]::IsNullOrWhiteSpace($iso)) {
                    # Detect a leftover VM / golden VHDX from a previous build. Without this, the underlying
                    # New-Win32ToolkitGoldenVhdx throws "VHDX already exists (use -Force)" the instant it starts
                    # — the TUI never passed -Force — so a repeat provisioning attempt appeared to "do nothing"
                    # (it errored before any progress output). Offer a rebuild instead of dead-ending.
                    # Menu selectors D10: the check and the build use the SAME VM: the session's, passed by name below
                    # (New-Win32ToolkitTestVM alone would build win32tk-golden, and with -Force delete it, whatever VM
                    # this screen checked).
                    $vhdxPath  = Join-Path (Get-Win32ToolkitHyperVPaths -BasePath (Get-Win32ToolkitBasePath)).Golden "$vmName.vhdx"
                    $existingVhdx = Test-Path -LiteralPath $vhdxPath
                    $existingVm   = $false
                    try { $existingVm = [bool](Get-VM -Name $vmName -ErrorAction SilentlyContinue) } catch { }

                    $proceed = $true
                    $force   = $false
                    if ($existingVm -or $existingVhdx) {
                        $what = @(); if ($existingVm) { $what += "VM $vmText" }; if ($existingVhdx) { $what += "its golden VHDX ($(Get-SpectreEscapedText -Text "$vmName.vhdx"))" }
                        Write-SpectreHost "[yellow]An existing $($what -join ' + ') from a previous build was found.[/]"
                        Write-SpectreHost '[grey]Provisioning cannot proceed without rebuilding it — this is why a second attempt looked like it did nothing.[/]'
                        if (Read-SpectreConfirm -Message "Delete $($what -join ' and ') and rebuild VM $vmText from scratch?" -DefaultAnswer $(if ($golden) { 'y' } else { 'n' })) {
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
                            $newArgs = @{ IsoPath = $iso; Verbose = $true } + $on
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
                $rvm = $null; if ($vmName) { try { $rvm = Get-VM -Name $vmName -ErrorAction SilentlyContinue } catch { } }
                if (-not $rvm) {
                    Format-SpectrePanel -Data "No test VM ($vmText) is provisioned yet — provision it first." -Header 'No VM' -Border Rounded -Color Yellow | Out-SpectreHost
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
                        Write-SpectreHost "[yellow]This turns VM $vmText OFF, applies the change, cold-boots it to the AutoLogon desktop, and re-takes its checkpoint $cpText (a few minutes).[/]"
                        if (Read-SpectreConfirm -Message "Apply the change to VM $vmText now?" -DefaultAnswer 'y') {
                            Clear-Host; Write-SpectreRule -Title 'Reconfiguring the VM…' -Color Blue
                            try {
                                Set-Win32ToolkitTestVMResource @rargs @on | Out-Null
                                Format-SpectrePanel -Data "VM resources updated and the checkpoint $cpText recreated." -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                            }
                            catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                            Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                        }
                    }
                }
            }
            'reset' {
                # Menu selectors D10: restoring discards every change in the VM since the checkpoint, so ask, naming both.
                if (Read-SpectreConfirm -Message "Reset VM $vmText to its checkpoint $($cpText)? Every change made in the VM since then is lost." -DefaultAnswer $(if ($golden) { 'y' } else { 'n' })) {
                    Clear-Host; Write-SpectreRule -Title "Reverting $vmText to $cpText…" -Color Blue
                    try {
                        Reset-Win32ToolkitTestVM @on
                        Format-SpectrePanel -Data "VM $vmText reverted to the checkpoint $cpText." -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'remove' {
                if (Read-SpectreConfirm -Message "Remove VM $vmText and delete its virtual disks?" -DefaultAnswer 'n') {
                    Clear-Host; Write-SpectreRule -Title 'Removing the test VM…' -Color Blue
                    try {
                        Remove-Win32ToolkitTestVM -RemoveVhdx @onName
                        Format-SpectrePanel -Data 'Test VM removed.' -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'autologon' {
                # Menu selectors D10: the repair removes EVERY checkpoint of the VM (Repair-Win32ToolkitTestVMCheckpoint), so ask.
                if (Read-SpectreConfirm -Message "This removes every checkpoint of VM $vmText and takes a new $cpText at a signed-in desktop. Continue?" -DefaultAnswer $(if ($golden) { 'y' } else { 'n' })) {
                    Clear-Host; Write-SpectreRule -Title 'Configuring guest AutoLogon + re-checkpoint…' -Color Blue
                    try {
                        # Repair-… handles the half-provisioned states an interrupted provision leaves behind:
                        # it PROMPTS for the baked-in guest credential when none is stored (persisting it only
                        # after PowerShell Direct verifies it) and boots the VM when there is no checkpoint to
                        # revert to — this screen must never dead-end on the very pieces it exists to fix.
                        if (Repair-Win32ToolkitTestVMCheckpoint @on) {
                            Format-SpectrePanel -Data 'AutoLogon configured and the checkpoint re-taken at a logged-in desktop. Interactive GUI testing is now safe.' -Header 'Done' -Border Rounded -Color Green | Out-SpectreHost
                        } else {
                            Format-SpectrePanel -Data 'Could not reach a desktop to re-checkpoint. Log in once in the VM window, then run this again.' -Header 'Warning' -Border Rounded -Color Yellow | Out-SpectreHost
                        }
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'back' { return }
        }
    }
}
