function Remove-Win32ToolkitHyperVSession {
    <#
    .SYNOPSIS
        Closes the PowerShell Direct session and (optionally) reverts the VM to its clean checkpoint.
    .DESCRIPTION
        The Hyper-V backend's teardown. Always removes the PSSession. With -Revert (the default for a
        finished run) it restores the warm checkpoint so the VM is left clean and ready for the next run
        — the untrusted, reused VM never accumulates state from a test. The restore goes through
        Restore-Win32ToolkitTestVMCheckpoint (speed-up PR 2: by default turn off, restore, start).
    .PARAMETER Session
        The PSSession to close (may be $null if the run failed before it opened).
    .PARAMETER VMName
        The VM to revert (required with -Revert).
    .PARAMETER CheckpointName
        The checkpoint to restore (default 'clean-base').
    .PARAMETER Revert
        Restore the clean checkpoint after closing the session.
    .PARAMETER Info
        Optional hashtable the teardown fills for the caller's record (Hyper-V speed-up PR 1): Restored ($true
        when the checkpoint was restored) and RevertMode (after a restore the mode it used, TurnOffFirst or Legacy;
        else $null). Nothing is written to the output.
    .PARAMETER Lease
        The VM lease the caller holds (Enter-Win32ToolkitHyperVLease, speed-up PR 3). The clean marker carries its
        epoch and generation (A-2), so the next open uses it only while no other process held the VM in between.
        Without -Lease the restore still runs but no marker is kept (the next run restores again).
    .PARAMETER AllowPark
        The caller's run was unattended (speed-up PR 4, D9): with HKCU HyperVTeardownPark = Saved (and HyperVRevertMode
        TurnOffFirst, Test-Win32ToolkitHyperVTeardownPark) the restore leaves the VM as it landed (-NoStart), and a VM
        that is Saved afterwards gets the marker's Parked = Saved, so the next open only starts it.
    #>
    [CmdletBinding()]
    param(
        $Session,
        [string]$VMName,
        [string]$CheckpointName = 'clean-base',
        [switch]$Revert,

        # Filled for the caller (speed-up PR 1): Restored, RevertMode.
        [hashtable]$Info,

        # The VM lease the caller holds (speed-up PR 3, A-2): stamped into the clean marker.
        [object]$Lease,

        # An unattended run (speed-up PR 4, D9): the VM may be parked Saved (HyperVTeardownPark).
        [switch]$AllowPark
    )

    if ($null -ne $Info) { $Info['Restored'] = $false; $Info['RevertMode'] = $null }
    if ($Session) { Remove-PSSession -Session $Session -ErrorAction SilentlyContinue }
    if ($Revert -and $VMName) {
        # The old -ErrorAction SilentlyContinue swallowed a FAILED revert — and a failure here must never
        # let the next run believe the VM is clean. Stamp the process-local clean marker STRICTLY after a
        # successful restore (New-Win32ToolkitHyperVSession consumes it to skip its then-redundant
        # open-revert); on failure clear it and warn, so the next run reverts before starting.
        # Speed-up PR 2 (D4): the restore helper turns the VM off, restores and starts it again (HyperVRevertMode); it
        # throws when any of these steps fails, so the marker is stamped only after the whole sequence succeeded.
        try {
            # Speed-up PR 4 (D9, A-15): an unattended run's VM may be parked Saved (HyperVTeardownPark; TurnOffFirst only):
            # the restore then leaves it as it landed, and the next open in this process only starts it.
            $noStart = $false
            if ($AllowPark) { $noStart = Test-Win32ToolkitHyperVTeardownPark }
            $restoreArgs = @{ VMName = $VMName; CheckpointName = $CheckpointName }
            if ($noStart) { $restoreArgs['NoStart'] = $true }
            $restore = Restore-Win32ToolkitTestVMCheckpoint @restoreArgs
            if ($null -ne $Info) {
                $Info['Restored'] = $true
                $Info['RevertMode'] = if ($restore -and $restore.Mode) { [string]$restore.Mode } else { $null }
            }
            # The marker carries the VM's Id (speed-up PR 1, D25): the next open uses it only for this very VM. When
            # the Id cannot be read there is no marker (one extra restore next time); the restore itself succeeded.
            $vmId = $null
            $vmState = ''
            try {
                $vmNow = Get-VM -Name $VMName -ErrorAction Stop
                $vmId = [string]$vmNow.Id
                $vmState = [string]$vmNow.State
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $vmId = $null
            }
            # Parked (speed-up PR 4): Saved only when parking was asked for and the VM is Saved now; the next open then
            # checks that its last state change is not later than this stamp (V-17).
            $parked = if ($noStart -and $vmState -eq 'Saved') { 'Saved' } else { 'Running' }
            # Speed-up PR 3 (A-2): the marker also carries the lease it was stamped under; without a lease there is none.
            if ($null -eq $Lease) {
                $script:HyperVCleanMarker = $null
                Write-Verbose "Teardown of '$VMName': no VM lease is held, so no clean marker is kept (the next run restores the checkpoint again)."
            }
            elseif ($vmId) {
                $script:HyperVCleanMarker = @{ VMName = $VMName; VMId = $vmId; CheckpointName = $CheckpointName; StampedAt = Get-Date
                    LeaseEpoch = [string]$Lease.Epoch; LeaseGeneration = ($Lease.Generation -as [long]); Parked = $parked }
            }
            else {
                $script:HyperVCleanMarker = $null
                Write-Verbose "Teardown of '$VMName': the VM's Id could not be read, so no clean marker is kept (the next run restores the checkpoint again)."
            }
        }
        catch {
            $script:HyperVCleanMarker = $null
            Write-Warning "Teardown revert of '$VMName' to '$CheckpointName' FAILED: $($_.Exception.Message) — the VM may hold state from the last run; the next run will revert it before starting."
        }
    }
}
