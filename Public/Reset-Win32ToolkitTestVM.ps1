function Reset-Win32ToolkitTestVM {
    <#
    .SYNOPSIS
        Puts the Hyper-V test VM back to its clean checkpoint.
    .DESCRIPTION
        Reset-Win32ToolkitTestVM puts the Hyper-V test VM back to its clean-base checkpoint: a
        saved state of the VM at a clean, signed-in desktop. Every change since that checkpoint is
        lost. By default the command turns the VM off, restores the checkpoint and starts the VM
        again.

        Tests already do this by themselves. Use the command after you worked in the VM yourself,
        or before you change its processors or memory. In the menu: Settings > Hyper-V test VM >
        Reset the VM to its clean checkpoint.

        The command prints nothing when it works. A checkpoint taken with automatic checkpoints on
        gets a slower restore and one warning. With the HyperVRevertMode setting Legacy, every
        reset uses the slower restore. After the slower restore, a VM that was off can stay in the
        Saved state: start it with Start-VM.

        It stops with an error when the VM or the checkpoint does not exist. While another
        PowerShell window uses the VM, the command waits. After 60 minutes by default, it stops
        with the error W32T.HyperVLeaseTimeout and changes nothing.
    .PARAMETER Name
        The VM to reset. Default: the VM in the W32T_HYPERV_VM environment variable if it is set,
        else your saved test VM (win32tk-golden unless you chose another name).
    .PARAMETER CheckpointName
        The checkpoint to restore. Default: the name in the W32T_HYPERV_CHECKPOINT environment
        variable if it is set, else your saved checkpoint name (clean-base unless you chose another
        name).
    .EXAMPLE
        Reset-Win32ToolkitTestVM

        This puts your test VM back to its clean-base checkpoint. It prints nothing when it works.
    .EXAMPLE
        Reset-Win32ToolkitTestVM -WhatIf

        This shows which VM and which checkpoint the command would use, and changes nothing.
    .OUTPUTS
        None. When the reset works, the command prints nothing.
    .NOTES
        Needs: PowerShell 7 run as administrator. Time: about 30 to 70 seconds, depending on your
        PC. Only one PowerShell window at a time can use the test VM.
    .LINK
        https://win32toolkit.com/reference/Reset-Win32ToolkitTestVM/
    .LINK
        https://win32toolkit.com/hyperv-vm-care/
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
