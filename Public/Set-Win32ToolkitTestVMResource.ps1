function Set-Win32ToolkitTestVMResource {
<#
.SYNOPSIS
    Changes the processors and memory of the Hyper-V test VM and takes a new clean checkpoint.
.DESCRIPTION
    Set-Win32ToolkitTestVMResource changes the processors, the memory, or both, of the Hyper-V
    test VM. It turns the VM off and deletes all its checkpoints, including the ones you made
    yourself. Then it changes the hardware and starts the VM. At the signed-in desktop, it takes a
    new clean-base checkpoint: the saved state for every test.

    Use it when tests are slow or an installer needs more memory. Reset the VM first with
    Reset-Win32ToolkitTestVM: the new checkpoint keeps every disk change since the last reset. In
    the menu: Settings > Hyper-V test VM > Change VM resources.

    It does not ask for confirmation and changes nothing in Intune. It saves the new values as
    the defaults for New-Win32ToolkitTestVM (not for a VM pinned with W32T_HYPERV_VM).

    It stops before any change when a value is outside its limits, or when it has no VM password.
    If the desktop does not appear within 10 minutes, the VM has no clean-base checkpoint. Repair
    it in the menu: Configure guest AutoLogon + re-checkpoint. W32T.HyperVLeaseTimeout means that
    another PowerShell window kept the VM too long.
.PARAMETER ProcessorCount
    The new number of virtual processors, from 1 to 64 and not more than your PC has. Without it,
    the processors stay as they are. Give -ProcessorCount, -MemoryStartupBytes or both.
.PARAMETER MemoryStartupBytes
    The new memory of the VM, for example 8GB. It must be at least 2 GB, and at most the memory of
    your PC minus 2 GB. Without it, the memory stays as it is.
.PARAMETER Name
    The VM to change. Default: the VM in the W32T_HYPERV_VM environment variable if it is set,
    else your saved test VM (win32tk-golden unless you chose another name).
.PARAMETER CheckpointName
    The name of the new clean checkpoint. Default: the name in the W32T_HYPERV_CHECKPOINT
    environment variable if it is set, else your saved checkpoint name (clean-base unless you
    chose another name).
.PARAMETER Credential
    The user name and password of the administrator account in the VM. The command uses them to
    check the desktop before the new checkpoint. Default: the password that the toolkit saved for
    the VM. Use it when no password is saved.
.EXAMPLE
    Set-Win32ToolkitTestVMResource -ProcessorCount 4 -MemoryStartupBytes 8GB

    This gives the test VM 4 processors and 8 GB of memory. It deletes the checkpoints of the VM
    and takes a new clean-base checkpoint.
.EXAMPLE
    Set-Win32ToolkitTestVMResource -MemoryStartupBytes 6GB

    This changes only the memory. The number of processors stays the same.
.EXAMPLE
    Reset-Win32ToolkitTestVM; Set-Win32ToolkitTestVMResource -MemoryStartupBytes 8GB

    This puts the VM back to its clean checkpoint first, then gives it 8 GB of memory. The new
    checkpoint keeps no changes from earlier tests or from your own work.
.EXAMPLE
    Set-Win32ToolkitTestVMResource -ProcessorCount 4 -WhatIf

    This shows the current and the new size of the VM, and changes nothing.
.OUTPUTS
    The VM object from Hyper-V, as Get-VM shows it.
    If the VM already has the values you give, the command says so and returns the VM unchanged.
    Otherwise -WhatIf returns nothing.
.NOTES
    Needs: PowerShell 7 run as administrator. Time: a few minutes. Only one PowerShell window at a
    time can use the test VM.
.LINK
    https://win32toolkit.com/reference/Set-Win32ToolkitTestVMResource/
.LINK
    https://win32toolkit.com/hyperv-vm-care/
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Microsoft.HyperV.PowerShell.VirtualMachine')]
    param(
        [ValidateRange(1, 64)]
        [int]$ProcessorCount,

        [uint64]$MemoryStartupBytes,

        [string]$Name,

        [string]$CheckpointName,

        [pscredential]$Credential
    )

    # At least one thing to change.
    $changeCpu = $PSBoundParameters.ContainsKey('ProcessorCount')
    $changeMem = $PSBoundParameters.ContainsKey('MemoryStartupBytes')
    if (-not ($changeCpu -or $changeMem)) {
        throw 'Nothing to change: pass -ProcessorCount and/or -MemoryStartupBytes.'
    }

    # The session's test VM and checkpoint (speed-up PR 3, D11): a W32T_HYPERV_VM / W32T_HYPERV_CHECKPOINT pin first.
    if (-not $Name)           { $Name           = (Get-Win32ToolkitHyperVTarget).VMName }
    if (-not $CheckpointName) { $CheckpointName = (Get-Win32ToolkitHyperVTarget).CheckpointName }

    # The VM must exist — this reconfigures an existing one, it does not create.
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        throw "Test VM '$Name' does not exist. Provision it first (New-Win32ToolkitTestVM / the TUI's Hyper-V test VM screen)."
    }

    # ── Hard-block above host capacity ─────────────────────────────────────────────
    # A guest cannot be given more vCPU than the host has logical processors, and giving it (nearly) all the
    # host's RAM will hang the host — so cap RAM at host physical RAM minus a reserve for the host OS.
    $vmHost      = Get-VMHost
    $hostCpu     = [int]$vmHost.LogicalProcessorCount
    $hostRam     = [uint64]$vmHost.MemoryCapacity
    $hostReserve = [uint64]2GB
    $minRam      = [uint64]2GB    # Windows 11 needs ~2 GB

    if ($changeCpu) {
        if ($ProcessorCount -gt $hostCpu) {
            throw "Requested $ProcessorCount vCPU exceeds the host's $hostCpu logical processors."
        }
    }
    if ($changeMem) {
        if ($MemoryStartupBytes -lt $minRam) {
            throw "Requested $([math]::Round($MemoryStartupBytes / 1GB, 2)) GB is below the $([math]::Round($minRam / 1GB, 1)) GB minimum (Windows 11 needs it)."
        }
        $maxRam = if ($hostRam -gt $hostReserve) { $hostRam - $hostReserve } else { [uint64]0 }
        if ($MemoryStartupBytes -gt $maxRam) {
            throw ("Requested {0} GB exceeds usable host RAM: the host has {1} GB, and a {2} GB reserve is kept for the host OS (max {3} GB)." -f `
                [math]::Round($MemoryStartupBytes / 1GB, 2), [math]::Round($hostRam / 1GB, 1), [math]::Round($hostReserve / 1GB, 1), [math]::Round($maxRam / 1GB, 2))
        }
    }

    # Current specs (for the summary + to fill in the value we are NOT changing).
    $curCpu = [int](Get-VMProcessor -VMName $Name).Count
    $curMem = [uint64](Get-VMMemory -VMName $Name).Startup
    $newCpu = if ($changeCpu) { $ProcessorCount } else { $curCpu }
    $newMem = if ($changeMem) { $MemoryStartupBytes } else { $curMem }

    if ($newCpu -eq $curCpu -and $newMem -eq $curMem) {
        Write-Host "VM '$Name' already has $curCpu vCPU / $([math]::Round($curMem / 1GB, 2)) GB — nothing to do." -ForegroundColor Yellow
        return $vm
    }

    $action = "Reconfigure to $newCpu vCPU / $([math]::Round($newMem / 1GB, 2)) GB (currently $curCpu vCPU / $([math]::Round($curMem / 1GB, 2)) GB) — this turns the VM OFF, recreates the '$CheckpointName' checkpoint, and cold-boots it"
    if (-not $PSCmdlet.ShouldProcess($Name, $action)) { return }

    # Need the guest credential to confirm the desktop is up before re-freezing.
    if (-not $Credential) {
        $Credential = Get-Win32ToolkitGuestCredential
        if (-not $Credential) {
            throw "No guest credential is stored — cannot verify the VM desktop before re-checkpointing. Re-run New-Win32ToolkitTestVM to (re)store it, or pass -Credential."
        }
    }

    # One process at a time on the VM (speed-up PR 3, D10): the whole reconfigure holds the VM's lease (a W32T.HyperVLeaseTimeout
    # stops it before anything changes).
    $lease = Enter-Win32ToolkitHyperVLease -VMName $Name -VMId ([string]$vm.Id) -Purpose 'resource change'
    try {
        Write-Host "Reconfiguring '$Name': $curCpu vCPU / $([math]::Round($curMem / 1GB, 2)) GB  ->  $newCpu vCPU / $([math]::Round($newMem / 1GB, 2)) GB" -ForegroundColor Cyan

        # Invalidate the process-local clean marker / readiness cache — the checkpoint is about to be
        # destroyed and recreated, so nothing cached about the VM's state may survive this.
        Clear-Win32ToolkitHyperVStateCache

        # 1. Off. Static memory / vCPU count cannot change on a running VM. CONFIRM it actually powered off before
        #    anything destructive: if Stop-VM silently failed and we removed the checkpoint anyway, we'd destroy the
        #    only recovery point for a change that then can't apply (VM stuck running, OLD hardware, NO checkpoint).
        Write-Verbose "Stopping '$Name'..."
        Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
        if ((Get-VM -Name $Name -ErrorAction SilentlyContinue).State -ne 'Off') {
            throw "Could not power off VM '$Name' — refusing to remove its clean-base checkpoint. Stop it manually (Stop-VM -Name '$Name' -TurnOff) and retry."
        }
        # Automatic checkpoints off before the start below (speed-up PR 1, D5).
        $null = Set-VM -Name $Name -AutomaticCheckpointsEnabled $false -ErrorAction Stop

        # 2. Remove ALL checkpoints — a Standard checkpoint encodes the OLD memory state, so keeping it would let
        #    the next Reset revert the change (and can block the memory reconfigure).
        Get-VMCheckpoint -VMName $Name -ErrorAction SilentlyContinue | Remove-VMCheckpoint -ErrorAction SilentlyContinue

        # 3. Apply the new hardware (static memory, matching provisioning).
        if ($changeCpu) { Set-VMProcessor -VMName $Name -Count $newCpu }
        if ($changeMem) { Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes $newMem }

        # 4. Cold-boot and wait for the AutoLogon desktop, so the warm checkpoint captures a real logged-in shell.
        Write-Verbose "Starting '$Name' and waiting for the guest to be ready..."
        Start-VM -Name $Name -ErrorAction Stop
        Wait-Win32ToolkitVMReady -VMName $Name -Credential $Credential | Out-Null

        Write-Verbose 'Waiting for the guest desktop to settle (explorer)...'
        $deadline = (Get-Date).AddMinutes(10)
        $shellUp  = $false
        do {
            Start-Sleep -Seconds 10
            $shellUp = [bool](Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock {
                [bool](Get-Process -Name explorer -ErrorAction SilentlyContinue)
            } -ErrorAction SilentlyContinue)
        } until ($shellUp -or (Get-Date) -gt $deadline)
        if (-not $shellUp) {
            throw "The guest desktop (explorer) did not come up within 10 minutes after the reconfigure — refusing to freeze a broken state. The VM '$Name' is running with the new hardware but has NO clean-base checkpoint; check AutoLogon / the console, then re-run."
        }

        # 5. Re-freeze the clean base at the new hardware level.
        $null = Set-VM -Name $Name -CheckpointType Standard -AutomaticCheckpointsEnabled $false
        # A failed checkpoint stops here (speed-up PR 2, V-Fe11): no success line and no settings for a VM without one.
        Checkpoint-VM -VMName $Name -SnapshotName $CheckpointName -ErrorAction Stop
        Write-Host "✓ '$CheckpointName' checkpoint recreated at $newCpu vCPU / $([math]::Round($newMem / 1GB, 2)) GB." -ForegroundColor Green

        # 6. Persist the new specs (and re-affirm the VM identity) so New-Win32ToolkitTestVM reuses them. Not for the VM this
        #    session pins with W32T_HYPERV_VM (speed-up PR 3, A-10): a process-scoped pin never repoints the user's defaults.
        $pin = Get-Win32ToolkitHyperVTarget -NoThrow
        if ($pin.Pinned -and -not $pin.Problem -and $pin.VMName -eq $Name) {
            Write-Host "VM '$(ConvertTo-Win32ToolkitSafeText -Text $Name -MaxLength 64)' is pinned by W32T_HYPERV_VM for this session only: its name, checkpoint and size were not saved as your defaults." -ForegroundColor Yellow
        }
        else {
            Set-Win32ToolkitConfigValue -Name 'HyperVVMName'            -Value $Name
            Set-Win32ToolkitConfigValue -Name 'HyperVCheckpoint'        -Value $CheckpointName
            Set-Win32ToolkitConfigValue -Name 'HyperVProcessorCount'    -Value $newCpu
            Set-Win32ToolkitConfigValue -Name 'HyperVMemoryStartupBytes' -Value $newMem
        }

        return (Get-VM -Name $Name -ErrorAction SilentlyContinue)
    }
    finally { $null = Exit-Win32ToolkitHyperVLease -Lease $lease }
}
