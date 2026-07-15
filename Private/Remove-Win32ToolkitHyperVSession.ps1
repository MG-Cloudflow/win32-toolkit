function Remove-Win32ToolkitHyperVSession {
    <#
    .SYNOPSIS
        Closes the PowerShell Direct session and (optionally) reverts the VM to its clean checkpoint.
    .DESCRIPTION
        The Hyper-V backend's teardown. Always removes the PSSession. With -Revert (the default for a
        finished run) it restores the warm checkpoint so the VM is left clean and ready for the next run
        — the untrusted, reused VM never accumulates state from a test.
    .PARAMETER Session
        The PSSession to close (may be $null if the run failed before it opened).
    .PARAMETER VMName
        The VM to revert (required with -Revert).
    .PARAMETER CheckpointName
        The checkpoint to restore (default 'clean-base').
    .PARAMETER Revert
        Restore the clean checkpoint after closing the session.
    #>
    [CmdletBinding()]
    param(
        $Session,
        [string]$VMName,
        [string]$CheckpointName = 'clean-base',
        [switch]$Revert
    )

    if ($Session) { Remove-PSSession -Session $Session -ErrorAction SilentlyContinue }
    if ($Revert -and $VMName) {
        # The old -ErrorAction SilentlyContinue swallowed a FAILED revert — and a failure here must never
        # let the next run believe the VM is clean. Stamp the process-local clean marker STRICTLY after a
        # successful restore (New-Win32ToolkitHyperVSession consumes it to skip its then-redundant
        # open-revert); on failure clear it and warn, so the next run reverts before starting.
        try {
            Restore-VMCheckpoint -VMName $VMName -Name $CheckpointName -Confirm:$false -ErrorAction Stop
            $script:HyperVCleanMarker = @{ VMName = $VMName; CheckpointName = $CheckpointName; StampedAt = Get-Date }
        }
        catch {
            $script:HyperVCleanMarker = $null
            Write-Warning "Teardown revert of '$VMName' to '$CheckpointName' FAILED: $($_.Exception.Message) — the VM may hold state from the last run; the next run will revert it before starting."
        }
    }
}
