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
    .PARAMETER Info
        Optional hashtable the open fills for the caller's record and caches (Hyper-V speed-up PR 1):
        RevertSkipped ($true when no checkpoint was restored: the clean marker was used, or -SkipRevert),
        SecondsSinceTeardown (the marker's age when it was used, else $null), VM (the Get-VM object read after
        the restore), VMId (its Id, or '') and Warm ($false when the VM was not Running after the restore and
        had to be started). The output is unchanged: exactly the session.
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

        # Filled for the caller (speed-up PR 1): RevertSkipped, SecondsSinceTeardown, VM, VMId, Warm.
        [hashtable]$Info
    )

    # Nothing is restored with -SkipRevert; a used clean marker also skips the restore (below).
    $revertSkipped = [bool]$SkipRevert
    $sinceTeardown = $null
    if (-not $SkipRevert) {
        # Skip the open-revert only when THIS process verified a teardown revert of the SAME VM+checkpoint
        # moments ago (Remove-Win32ToolkitHyperVSession stamps $script:HyperVCleanMarker strictly AFTER a
        # successful restore; every VM-management cmdlet clears it). Back-to-back runs in one pipeline
        # otherwise revert twice with zero use in between. Fail-safe by construction: no marker, any
        # mismatch, or age > 10 min ⇒ revert exactly as before. The marker is deliberately PROCESS-LOCAL —
        # VM Notes have untested survive/erase semantics across a Standard-checkpoint restore, and
        # uptime/state checks detect nothing (a memory-state revert leaves the VM continuously Running).
        $m = $script:HyperVCleanMarker
        $markerFresh = $m -and ($m.VMName -eq $VMName) -and ($m.CheckpointName -eq $CheckpointName) -and
                       (((Get-Date) - $m.StampedAt).TotalMinutes -lt 10)
        if ($markerFresh) {
            Write-Verbose "'$VMName' was left verified-clean at '$CheckpointName' by this process — skipping the redundant open-revert."
            $revertSkipped = $true
            $sinceTeardown = [math]::Round(((Get-Date) - $m.StampedAt).TotalSeconds, 1)
        }
        else {
            Restore-VMCheckpoint -VMName $VMName -Name $CheckpointName -Confirm:$false -ErrorAction Stop
        }
    }
    # From here the VM is in use — it can no longer be presumed clean, whatever happens to this run.
    $script:HyperVCleanMarker = $null

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $warm = $true
    if ($vm.State -ne 'Running') {
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
