function Reset-Win32ToolkitTestVM {
    <#
    .SYNOPSIS
        Reverts the Hyper-V test VM to its warm 'clean-base' checkpoint (the between-run reset).
    .DESCRIPTION
        HOST-ONLY. Restoring a STANDARD (memory-state) checkpoint returns the VM directly to the captured
        running, logged-in desktop — no OOBE, logon, or boot — so a test run can go straight to
        PowerShell Direct. Uses the configured VM + checkpoint names by default.

        When the checkpoint was taken with automatic checkpoints off, the VM is turned off first, the checkpoint
        is restored and the VM is started again, so Hyper-V does not save the memory it is about to discard
        (the HyperVRevertMode setting: TurnOffFirst by default, Legacy for the plain restore); the VM is running
        afterwards. A checkpoint taken with automatic checkpoints on gets the plain restore and one warning.
        The plain restore keeps a running VM running, but leaves a VM that was off or saved before the reset in
        the Saved state: Start-VM resumes it.

        The reset holds the test VM's lease, the lock every win32-toolkit process takes before it changes the VM:
        while another PowerShell session uses the VM (a test run, for example) the reset waits for it, up to
        HyperVLeaseWaitMinutes (default 60), and then stops with the error W32T.HyperVLeaseTimeout.
    .PARAMETER Name
        VM name (default: the session's test VM: W32T_HYPERV_VM, else the stored HyperVVMName, else 'win32tk-golden').
    .PARAMETER CheckpointName
        Checkpoint to restore (default: W32T_HYPERV_CHECKPOINT, else the stored HyperVCheckpoint, else 'clean-base').
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Name = ((Get-Win32ToolkitHyperVTarget).VMName),
        [string]$CheckpointName = ((Get-Win32ToolkitHyperVTarget).CheckpointName)
    )

    if ($PSCmdlet.ShouldProcess($Name, "Restore checkpoint '$CheckpointName'")) {
        # One process at a time on the VM (speed-up PR 3, D10): waits while another process holds it, else throws
        # W32T.HyperVLeaseTimeout before anything changes. Nested (no wait) when the caller holds it (Repair).
        $lease = Enter-Win32ToolkitHyperVLease -VMName $Name -Purpose 'reset'
        try {
            # Invalidate the process-local clean marker / readiness cache — this action changes VM state
            # outside the session lifecycle that maintains them (fail-safe: worst case is one extra revert).
            Clear-Win32ToolkitHyperVStateCache
            # Speed-up PR 2 (D4): turn off, restore, start (HyperVRevertMode). Reset emits nothing (C-12): Repair calls it.
            $null = Restore-Win32ToolkitTestVMCheckpoint -VMName $Name -CheckpointName $CheckpointName
        }
        finally { $null = Exit-Win32ToolkitHyperVLease -Lease $lease }
    }
}
