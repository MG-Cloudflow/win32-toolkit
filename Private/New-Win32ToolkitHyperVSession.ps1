function New-Win32ToolkitHyperVSession {
    <#
    .SYNOPSIS
        Reverts the test VM to its warm checkpoint and opens a PowerShell Direct session to it.
    .DESCRIPTION
        The Hyper-V backend's "initialize" step. Restores the standard (memory-state) checkpoint — which
        returns the guest to a running, logged-in desktop with no boot — waits until PowerShell Direct is
        reachable, and returns an open PSSession for the run. HOST-ONLY (Hyper-V + elevation).
        The restore goes through Restore-Win32ToolkitTestVMCheckpoint (speed-up PR 2: by default the VM is turned
        off first, so Hyper-V does not save the memory it is about to discard). A VM found Saved is started
        silently (resumed); one found in any other state but Running gets the cold-checkpoint warning and a start.
        See knowledge-base/designs/hyperv-backend-plan.md.
    .PARAMETER VMName
        The test VM name.
    .PARAMETER Credential
        The guest local-admin credential (PowerShell Direct).
    .PARAMETER CheckpointName
        The warm checkpoint to revert to (default 'clean-base').
    .PARAMETER SkipRevert
        Connect to the VM as-is without reverting (e.g. when it is already clean).
    .PARAMETER Info
        Optional hashtable the open fills for the caller's record and caches (Hyper-V speed-up PR 1):
        RevertSkipped ($true when no checkpoint was restored: the clean marker was used, or -SkipRevert),
        SecondsSinceTeardown (the marker's age when it was used, else $null), VM (the Get-VM object read after
        the restore), VMId (its Id, or '') and Warm ($false when the checkpoint landed the VM Off, even when
        Restore-Win32ToolkitTestVMCheckpoint then started it, or when the VM was not Running or Saved here and had
        to be started). Speed-up PR 2: RevertMode (TurnOffFirst or Legacy, the mode the restore used; $null when
        nothing was restored). The output is unchanged: exactly the session.
    .PARAMETER Lease
        The VM lease the caller holds (Enter-Win32ToolkitHyperVLease, speed-up PR 3). The clean marker is used only
        under a lease, and only when it was stamped under the same lease epoch with the generation this lease follows
        (A-2): no other process held the VM since the teardown that stamped it. Without -Lease the open always restores.

        A marker whose teardown parked the VM Saved (speed-up PR 4, HyperVTeardownPark) is used only while the VM is still
        Saved and its last state change (WMI Msvm_ComputerSystem.TimeOfLastStateChange) is not later than the marker's
        stamp (V-17); the open then only starts the VM. Otherwise, or when that time cannot be read, it restores.
    .OUTPUTS
        A PSSession (System.Management.Automation.Runspaces.PSSession).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$VMName,
        [Parameter(Mandatory)] [ValidateNotNull()]        [pscredential]$Credential,
        [string]$CheckpointName = 'clean-base',
        [switch]$SkipRevert,

        # Interactive GUI runs need a real logged-in desktop; if the checkpoint landed on the login
        # screen, recover by rebooting to trigger AutoLogon (Confirm-Win32ToolkitGuestDesktop).
        [switch]$EnsureDesktop,

        # Filled for the caller (speed-up PR 1): RevertSkipped, SecondsSinceTeardown, VM, VMId, Warm; PR 2: RevertMode.
        [hashtable]$Info,

        # The VM lease the caller holds (speed-up PR 3, A-2): the clean marker is honoured only under it.
        [object]$Lease
    )

    # Nothing is restored with -SkipRevert; a used clean marker also skips the restore (below).
    $revertSkipped = [bool]$SkipRevert
    $sinceTeardown = $null
    $vm = $null
    $revertMode = $null
    $landedOff = $false
    if (-not $SkipRevert) {
        # Skip the open-revert only when THIS process verified a teardown revert of the SAME VM+checkpoint
        # moments ago (Remove-Win32ToolkitHyperVSession stamps $script:HyperVCleanMarker strictly AFTER a
        # successful restore; every VM-management cmdlet clears it). Back-to-back runs in one pipeline
        # otherwise revert twice with zero use in between. Fail-safe by construction: no marker, any
        # mismatch, or age > 10 min ⇒ revert exactly as before. The marker is deliberately PROCESS-LOCAL —
        # VM Notes have untested survive/erase semantics across a Standard-checkpoint restore.
        # Guard (speed-up PR 1, D25): another process may restore, start or use the VM in between. A restore or a
        # start resets the VM's uptime, so the marker is used only while the VM is still the one the teardown left
        # (same VM Id), Running, and up for at least the marker's age (5 s of slack); anything else restores.
        $m = $script:HyperVCleanMarker
        $markerFresh = $false
        if ($m -and ($m.VMName -eq $VMName) -and ($m.CheckpointName -eq $CheckpointName) -and (((Get-Date) - $m.StampedAt).TotalMinutes -lt 10)) {
            $age = ((Get-Date) - $m.StampedAt).TotalSeconds
            $why = $null
            # Speed-up PR 3 (A-2): another process may have held the VM since the teardown. The marker counts only under
            # the lease this run holds, stamped under the same lease epoch, with a generation this lease follows directly
            # (the file's generation before this acquisition, or the same generation for a nested hold).
            $markGen = $m.LeaseGeneration -as [long]
            if ($null -eq $Lease) { $why = 'no VM lease is held' }
            elseif (-not $m.LeaseEpoch -or [string]$m.LeaseEpoch -ne [string]$Lease.Epoch) { $why = 'it was not stamped under the current VM lease' }
            elseif ($null -eq $markGen -or ($markGen -ne ($Lease.Generation -as [long]) -and $markGen -ne ($Lease.PreviousGeneration -as [long]))) {
                $why = 'another process used the VM since the teardown (the lease generation changed)'
            }
            $guardVm = $null
            if (-not $why) {
                try { $guardVm = Get-VM -Name $VMName -ErrorAction Stop }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    $why = "the VM could not be read ($($_.Exception.Message))"
                }
            }
            if (-not $why) {
                if (-not $m.VMId -or $null -eq $guardVm -or [string]$guardVm.Id -ne [string]$m.VMId) { $why = 'its VM Id is not the one the teardown left clean' }
                elseif ([string]$m.Parked -eq 'Saved') {
                    # Speed-up PR 4 (D9, V-17): the teardown parked the VM Saved (HyperVTeardownPark). The parked analogue of
                    # the uptime rule: it must still be Saved, and its last state change (WMI Msvm_ComputerSystem
                    # TimeOfLastStateChange) not later than the stamp (5 s of slack): a start and a save by another tool
                    # since then move it. Unreadable: restore (fail-safe).
                    if ([string]$guardVm.State -ne 'Saved') { $why = "the teardown left the VM Saved, but it is $($guardVm.State) now" }
                    else {
                        $changed = $null
                        $cimWhy = ''
                        $vmGuid = [guid]::Empty
                        if ([guid]::TryParse([string]$m.VMId, [ref]$vmGuid)) {
                            try {
                                $cs = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_ComputerSystem' -Filter "Name = '$($vmGuid.ToString('D').ToUpperInvariant())'" -ErrorAction Stop)
                                if ($cs.Count -eq 1) { $changed = $cs[0].TimeOfLastStateChange }
                            }
                            catch {
                                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                                $cimWhy = " ($($_.Exception.Message))"
                            }
                        }
                        if ($changed -isnot [datetime]) { $why = "the VM's last state change could not be read$cimWhy" }
                        elseif ($changed.ToUniversalTime() -gt ([datetime]$m.StampedAt).ToUniversalTime().AddSeconds(5)) {
                            $why = "the VM's last state change ($($changed.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))Z) is later than the teardown that parked it (it was started or saved since)"
                        }
                    }
                }
                elseif ([string]$guardVm.State -ne 'Running') { $why = "the VM is $($guardVm.State), not Running" }
                elseif ($guardVm.Uptime -isnot [timespan] -or $guardVm.Uptime.TotalSeconds -lt ($age - 5)) {
                    $why = "the VM's uptime is shorter than the $([int]$age) s since the teardown restore (it was restored or started since)"
                }
            }
            if ($why) {
                Write-Verbose "'$VMName': the clean marker is not used ($why); restoring '$CheckpointName'."
            }
            else {
                $markerFresh = $true
                $vm = $guardVm
            }
        }
        if ($markerFresh) {
            Write-Verbose "'$VMName' was left verified-clean at '$CheckpointName' by this process — skipping the redundant open-revert."
            $revertSkipped = $true
            $sinceTeardown = [math]::Round($age, 1)
        }
        else {
            # Speed-up PR 2 (D4): the restore helper turns the VM off first (HyperVRevertMode TurnOffFirst) and starts it
            # again; a checkpoint that landed Off is cold even though the helper started it (V-4).
            $restore = Restore-Win32ToolkitTestVMCheckpoint -VMName $VMName -CheckpointName $CheckpointName
            $revertMode = if ($restore -and $restore.Mode) { [string]$restore.Mode } else { $null }
            $landedOff = ($restore -and [string]$restore.Landed -eq 'Off')
        }
    }
    # From here the VM is in use — it can no longer be presumed clean, whatever happens to this run.
    $script:HyperVCleanMarker = $null

    # After a restore (or with -SkipRevert) the VM is read once more; a used marker already read it.
    if ($null -eq $vm) { $vm = Get-VM -Name $VMName -ErrorAction Stop }
    $warm = -not $landedOff
    if ($vm.State -eq 'Saved') {
        # A Standard checkpoint restored onto a VM that was off lands Saved: starting it resumes the checkpoint's memory
        # state (expected, speed-up PR 2; also a marker-skip or -SkipRevert open that finds the VM saved).
        Write-Verbose "'$VMName' was Saved after restoring '$CheckpointName': resumed."
        $null = Start-VM -Name $VMName -ErrorAction Stop
    }
    elseif ($vm.State -ne 'Running') {
        # A Standard (memory-state) checkpoint restores a RUNNING guest; landing here means the checkpoint
        # was taken powered-off or as a Production checkpoint — every run is paying a full boot.
        Write-Warning "VM '$VMName' was not Running after restoring '$CheckpointName' — the checkpoint is not a warm memory-state one, so every run pays a full boot. Re-take it with the VM running at a logged-in desktop (Standard checkpoint type) to restore warm-revert speed."
        Start-VM -Name $VMName -ErrorAction Stop
        $warm = $false
    }
    if ($null -ne $Info) {
        $Info['RevertSkipped']        = $revertSkipped
        $Info['SecondsSinceTeardown'] = $sinceTeardown
        $Info['VM']                   = $vm
        $Info['VMId']                 = if ($null -ne $vm -and $null -ne $vm.Id) { [string]$vm.Id } else { '' }
        $Info['Warm']                 = $warm
        $Info['RevertMode']           = $revertMode
    }

    # Warm revert returns a running, logged-in guest; -SkipPrep because the golden image already set the
    # execution policy. The desktop check runs BEFORE the session is created: its recovery path REBOOTS
    # the guest, which would kill a session opened earlier — the returned session must postdate any reboot.
    if ($EnsureDesktop) {
        Wait-Win32ToolkitVMReady -VMName $VMName -Credential $Credential -SkipPrep | Out-Null
        if (-not (Confirm-Win32ToolkitGuestDesktop -VMName $VMName -Credential $Credential)) {
            Write-Warning 'Could not reach an interactive desktop even after a recovery reboot. Is guest AutoLogon configured (Set-Win32ToolkitGuestAutoLogon)? The PSADT GUI may not render — use -Unattended (the Intune-parity run needs no operator GUI), or re-checkpoint a logged-in desktop.'
        }
    }

    # -ReturnSession: the connection that proves PowerShell Direct IS the run's session (the old shape
    # proved readiness with a throwaway ad-hoc connection, then built another session — 1-3 s wasted).
    return (Wait-Win32ToolkitVMReady -VMName $VMName -Credential $Credential -SkipPrep -ReturnSession)
}
