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
        Restore-VMCheckpoint -VMName $VMName -Name $CheckpointName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
