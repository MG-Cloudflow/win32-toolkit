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
    #>
    [CmdletBinding()]
    param(
        $Session,
        [string]$VMName,
        [string]$CheckpointName = 'clean-base',
        [switch]$Revert,

        # Filled for the caller (speed-up PR 1): Restored, RevertMode.
        [hashtable]$Info
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
            $restore = Restore-Win32ToolkitTestVMCheckpoint -VMName $VMName -CheckpointName $CheckpointName
            if ($null -ne $Info) {
                $Info['Restored'] = $true
                $Info['RevertMode'] = if ($restore -and $restore.Mode) { [string]$restore.Mode } else { $null }
            }
            # The marker carries the VM's Id (speed-up PR 1, D25): the next open uses it only for this very VM. When
            # the Id cannot be read there is no marker (one extra restore next time); the restore itself succeeded.
            $vmId = $null
            try { $vmId = [string](Get-VM -Name $VMName -ErrorAction Stop).Id }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $vmId = $null
            }
            if ($vmId) {
                $script:HyperVCleanMarker = @{ VMName = $VMName; VMId = $vmId; CheckpointName = $CheckpointName; StampedAt = Get-Date }
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
