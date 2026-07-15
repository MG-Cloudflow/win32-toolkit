function Set-Win32ToolkitTestVMResource {
<#
.SYNOPSIS
    Changes the CPU count and/or startup memory of the Hyper-V test VM and re-freezes its clean-base checkpoint.
.DESCRIPTION
    Reconfigures an EXISTING test VM's hardware in place — it does NOT rebuild from ISO, so the installed
    golden guest and its disk are preserved (minutes, not the ~hour a full re-provision costs).

    Why this is more than a one-liner: the VM uses a STANDARD (memory-state) 'clean-base' checkpoint. Changing
    static memory / vCPU count requires the VM to be powered OFF, and the existing checkpoint encodes the OLD
    memory state — so a change would be silently reverted by the next Reset-Win32ToolkitTestVM unless the
    checkpoint is recreated. This command therefore:

        Stop-VM -TurnOff  ->  remove checkpoints  ->  Set-VMProcessor / Set-VMMemory  ->  Start-VM
        ->  wait for the AutoLogon desktop  ->  re-take the Standard 'clean-base' checkpoint  ->  persist

    The chosen values are saved (HyperVProcessorCount / HyperVMemoryStartupBytes) and become the defaults for the
    next New-Win32ToolkitTestVM. Requested CPU/RAM above the host's capacity is REFUSED.
.PARAMETER ProcessorCount
    New virtual processor count (1-64). Omit to leave CPU unchanged.
.PARAMETER MemoryStartupBytes
    New static startup memory in bytes (accepts PowerShell size literals, e.g. 6GB). Omit to leave RAM unchanged.
.PARAMETER Name
    VM name. Defaults to the configured HyperVVMName ('win32tk-golden').
.PARAMETER CheckpointName
    Clean-base checkpoint name to recreate. Defaults to the configured HyperVCheckpoint ('clean-base').
.PARAMETER Credential
    Guest admin credential (to confirm the desktop is up before the warm checkpoint). Defaults to the stored
    DPAPI-protected guest credential.
.EXAMPLE
    Set-Win32ToolkitTestVMResource -ProcessorCount 4 -MemoryStartupBytes 8GB
.EXAMPLE
    Set-Win32ToolkitTestVMResource -MemoryStartupBytes 6GB   # RAM only; CPU unchanged
.OUTPUTS
    The reconfigured VM (Get-VM), or nothing under -WhatIf.
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

    if (-not $Name)           { $Name           = Get-Win32ToolkitConfigValue -Name 'HyperVVMName'     -Default 'win32tk-golden' }
    if (-not $CheckpointName) { $CheckpointName = Get-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Default 'clean-base' }

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

    Write-Host "Reconfiguring '$Name': $curCpu vCPU / $([math]::Round($curMem / 1GB, 2)) GB  ->  $newCpu vCPU / $([math]::Round($newMem / 1GB, 2)) GB" -ForegroundColor Cyan

    # 1. Off. Static memory / vCPU count cannot change on a running VM. CONFIRM it actually powered off before
    #    anything destructive: if Stop-VM silently failed and we removed the checkpoint anyway, we'd destroy the
    #    only recovery point for a change that then can't apply (VM stuck running, OLD hardware, NO checkpoint).
    Write-Verbose "Stopping '$Name'..."
    Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
    if ((Get-VM -Name $Name -ErrorAction SilentlyContinue).State -ne 'Off') {
        throw "Could not power off VM '$Name' — refusing to remove its clean-base checkpoint. Stop it manually (Stop-VM -Name '$Name' -TurnOff) and retry."
    }

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
    Set-VM -Name $Name -CheckpointType Standard
    Checkpoint-VM -VMName $Name -SnapshotName $CheckpointName
    Write-Host "✓ '$CheckpointName' checkpoint recreated at $newCpu vCPU / $([math]::Round($newMem / 1GB, 2)) GB." -ForegroundColor Green

    # 6. Persist the new specs (and re-affirm the VM identity) so New-Win32ToolkitTestVM reuses them.
    Set-Win32ToolkitConfigValue -Name 'HyperVVMName'            -Value $Name
    Set-Win32ToolkitConfigValue -Name 'HyperVCheckpoint'        -Value $CheckpointName
    Set-Win32ToolkitConfigValue -Name 'HyperVProcessorCount'    -Value $newCpu
    Set-Win32ToolkitConfigValue -Name 'HyperVMemoryStartupBytes' -Value $newMem

    return (Get-VM -Name $Name -ErrorAction SilentlyContinue)
}
