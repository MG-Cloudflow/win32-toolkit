function Reset-Win32ToolkitTestVM {
    <#
    .SYNOPSIS
        Reverts the Hyper-V test VM to its warm 'clean-base' checkpoint (the between-run reset).
    .DESCRIPTION
        HOST-ONLY. Restoring a STANDARD (memory-state) checkpoint returns the VM directly to the captured
        running, logged-in desktop — no OOBE, logon, or boot — so a test run can go straight to
        PowerShell Direct. Uses the configured VM + checkpoint names by default.
    .PARAMETER Name
        VM name (default: the stored HyperVVMName, else 'win32tk-golden').
    .PARAMETER CheckpointName
        Checkpoint to restore (default: the stored HyperVCheckpoint, else 'clean-base').
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Name = (Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden'),
        [string]$CheckpointName = (Get-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Default 'clean-base')
    )

    if ($PSCmdlet.ShouldProcess($Name, "Restore checkpoint '$CheckpointName'")) {
        # Invalidate the process-local clean marker / readiness cache — this action changes VM state
        # outside the session lifecycle that maintains them (fail-safe: worst case is one extra revert).
        Clear-Win32ToolkitHyperVStateCache
        Restore-VMCheckpoint -VMName $Name -Name $CheckpointName -Confirm:$false -ErrorAction Stop
    }
}
