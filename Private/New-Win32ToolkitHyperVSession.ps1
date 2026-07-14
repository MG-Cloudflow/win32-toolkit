function New-Win32ToolkitHyperVSession {
    <#
    .SYNOPSIS
        Reverts the test VM to its warm checkpoint and opens a PowerShell Direct session to it.
    .DESCRIPTION
        The Hyper-V backend's "initialize" step. Restores the standard (memory-state) checkpoint — which
        returns the guest to a running, logged-in desktop with no boot — waits until PowerShell Direct is
        reachable, and returns an open PSSession for the run. HOST-ONLY (Hyper-V + elevation).
        See knowledge-base/designs/hyperv-backend-plan.md.
    .PARAMETER VMName
        The test VM name.
    .PARAMETER Credential
        The guest local-admin credential (PowerShell Direct).
    .PARAMETER CheckpointName
        The warm checkpoint to revert to (default 'clean-base').
    .PARAMETER SkipRevert
        Connect to the VM as-is without reverting (e.g. when it is already clean).
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
        [switch]$EnsureDesktop
    )

    if (-not $SkipRevert) {
        Restore-VMCheckpoint -VMName $VMName -Name $CheckpointName -Confirm:$false -ErrorAction Stop
    }
    if ((Get-VM -Name $VMName -ErrorAction Stop).State -ne 'Running') {
        Start-VM -Name $VMName -ErrorAction Stop
    }

    # Warm revert returns a running, logged-in guest; -SkipPrep because the golden image already set the
    # execution policy. This still handles the brief window before PowerShell Direct answers.
    Wait-Win32ToolkitVMReady -VMName $VMName -Credential $Credential -SkipPrep | Out-Null

    if ($EnsureDesktop) {
        if (-not (Confirm-Win32ToolkitGuestDesktop -VMName $VMName -Credential $Credential)) {
            Write-Warning 'Could not reach an interactive desktop even after a recovery reboot. Is guest AutoLogon configured (Set-Win32ToolkitGuestAutoLogon)? The PSADT GUI may not render — use -Unattended / Silent, or re-checkpoint a logged-in desktop.'
        }
    }

    return (New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop)
}
