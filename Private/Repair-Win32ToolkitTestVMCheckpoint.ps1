function Repair-Win32ToolkitTestVMCheckpoint {
    <#
    .SYNOPSIS
        Configures guest AutoLogon and re-takes the warm clean-base checkpoint at a logged-in desktop —
        including from the half-provisioned states an interrupted New-Win32ToolkitTestVM leaves behind.
    .DESCRIPTION
        HOST-ONLY; may prompt (TUI/console use). Provisioning persists the guest credential and takes
        'clean-base' only at its very END (New-Win32ToolkitTestVM), so aborting it — e.g. closing the
        console during the manual-prep pause — leaves the VM existing but the backend unusable: no
        checkpoint to revert to and no stored credential to reach the guest. This is the repair path for
        exactly that, so it must not REQUIRE the pieces it repairs:

          1. Credential: use -Credential, else the stored one, else PROMPT (type-it-twice) for the
             credential the golden image was built with. A freshly typed credential is persisted ONLY
             after PowerShell Direct proves it against the guest (step 3) — a typo is never stored.
          2. Checkpoint: revert to it when it exists (the classic login-screen fix); when it is MISSING,
             just ensure the VM is powered on so PowerShell Direct can reach it.
          3. Wait-Win32ToolkitVMReady — heartbeat + PowerShell Direct + guest prep (same gates every
             other checkpoint-taking flow runs).
          4. Set-Win32ToolkitGuestAutoLogon, then Confirm-Win32ToolkitGuestDesktop (reboots into
             AutoLogon if the guest sits at a login screen).
          5. Drop ALL old checkpoints and freeze a STANDARD checkpoint at the logged-in desktop, with Hyper-V
             automatic checkpoints off (also turned off before a start from Off in step 2); clear the
             readiness cache and re-affirm the config identity keys.

        Steps 2-5 hold the test VM's machine-wide lease (Enter-Win32ToolkitHyperVLease, speed-up PR 3): while another
        process uses the VM the repair waits, then stops with W32T.HyperVLeaseTimeout before changing anything.
    .PARAMETER Name
        VM name (default: the session's test VM: W32T_HYPERV_VM, else the stored HyperVVMName, else 'win32tk-golden').
    .PARAMETER CheckpointName
        Checkpoint to (re)create (default: W32T_HYPERV_CHECKPOINT, else the stored HyperVCheckpoint, else 'clean-base').
    .PARAMETER Credential
        Guest local-admin credential. Default: the stored credential; if none is stored (or it was saved
        by a different Windows user — DPAPI), an interactive prompt asks for the one baked into the image.
    .OUTPUTS
        [bool] — $true when the checkpoint was re-taken at a desktop; $false when no desktop could be
        reached (log in once in the VM window, then re-run).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Name = ((Get-Win32ToolkitHyperVTarget).VMName),
        [string]$CheckpointName = ((Get-Win32ToolkitHyperVTarget).CheckpointName),
        [pscredential]$Credential
    )

    # Only the VM itself is mandatory — without one there is nothing to repair.
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) {
        throw "Test VM '$Name' does not exist — provision it first (New-Win32ToolkitTestVM / the TUI's Hyper-V test VM screen)."
    }

    # 1. Resolve the credential. Persisting a hand-typed one is DEFERRED until PowerShell Direct has
    #    accepted it, so the store can never end up holding a password the guest does not have.
    $persistCredential = $false
    if (-not $Credential) {
        $Credential = Get-Win32ToolkitGuestCredential
        if (-not $Credential) {
            Write-Host 'No guest credential is stored — an interrupted provision (or one saved by a different Windows user) causes this.' -ForegroundColor Yellow
            $Credential = Get-Win32ToolkitGuestCredentialInteractive -Message "Enter the SAME guest admin credential VM '$Name' was built with — it is verified against the guest before being saved."
            $persistCredential = $true
        }
    }

    # One process at a time on the VM (speed-up PR 3, D10): steps 2-5 hold the VM's lease, taken after the credential step
    # (a prompt never holds the VM); the nested Reset takes it again without waiting.
    $lease = Enter-Win32ToolkitHyperVLease -VMName $Name -VMId ([string]$vm.Id) -Purpose 'checkpoint repair'
    try {
        # 2. Revert when the checkpoint exists; when it is missing (the other half of a broken provision),
        #    there is nothing to revert to — just make sure the VM is running. Start-VM also resumes a
        #    Saved/Paused VM.
        if (Get-VMCheckpoint -VMName $Name -Name $CheckpointName -ErrorAction SilentlyContinue) {
            Reset-Win32ToolkitTestVM -Name $Name -CheckpointName $CheckpointName
        }
        elseif ($vm.State -ne 'Running') {
            Write-Host "No '$CheckpointName' checkpoint to revert to — booting the VM instead..." -ForegroundColor Yellow
            Clear-Win32ToolkitHyperVStateCache
            # Automatic checkpoints off before a start from Off (speed-up PR 1, D5; the only start that takes an automatic
            # checkpoint). A Saved or Paused VM is only resumed here: the re-take below sets the value anyway (V-19).
            if ($vm.State -eq 'Off') { $null = Set-VM -Name $Name -AutomaticCheckpointsEnabled $false -ErrorAction Stop }
            else { Write-Verbose "VM '$Name' is $($vm.State): automatic checkpoints are turned off when the checkpoint is re-taken." }
            Start-VM -Name $Name -ErrorAction Stop
        }

        # 3. Same readiness gates every checkpoint-taking flow runs (heartbeat, PS Direct proves the
        #    credential, guest prep). A wrong typed password surfaces here as a gate timeout — and is
        #    therefore never persisted below.
        Wait-Win32ToolkitVMReady -VMName $Name -Credential $Credential | Out-Null
        if ($persistCredential) {
            Set-Win32ToolkitGuestCredential -Credential $Credential
            Clear-Win32ToolkitHyperVStateCache
            Write-Host '✓ Guest credential verified over PowerShell Direct and saved.' -ForegroundColor Green
        }

        # 4. AutoLogon + a real desktop (Confirm reboots into AutoLogon if the guest is at a login screen).
        Set-Win32ToolkitGuestAutoLogon -VMName $Name -Credential $Credential
        if (-not (Confirm-Win32ToolkitGuestDesktop -VMName $Name -Credential $Credential)) {
            return $false
        }

        # 5. Freeze the logged-in desktop as the new clean base and make the readiness banner see it.
        Get-VMCheckpoint -VMName $Name -ErrorAction SilentlyContinue | Remove-VMCheckpoint -ErrorAction SilentlyContinue
        $null = Set-VM -Name $Name -CheckpointType Standard -AutomaticCheckpointsEnabled $false
        # A failed checkpoint stops here (speed-up PR 2, V-Fe11): no success line and no settings for a VM without one.
        Checkpoint-VM -VMName $Name -SnapshotName $CheckpointName -ErrorAction Stop
        Clear-Win32ToolkitHyperVStateCache
        # Not for the VM this session pins with W32T_HYPERV_VM (speed-up PR 3, A-10): the pin never repoints the defaults.
        $pin = Get-Win32ToolkitHyperVTarget -NoThrow
        if ($pin.Pinned -and -not $pin.Problem -and $pin.VMName -eq $Name) {
            Write-Host "VM '$(ConvertTo-Win32ToolkitSafeText -Text $Name -MaxLength 64)' is pinned by W32T_HYPERV_VM for this session only: its name and checkpoint were not saved as your defaults." -ForegroundColor Yellow
        }
        else {
            Set-Win32ToolkitConfigValue -Name 'HyperVVMName'     -Value $Name
            Set-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Value $CheckpointName
        }
        Write-Host "✓ '$CheckpointName' checkpoint re-taken at a logged-in desktop." -ForegroundColor Green
        return $true
    }
    finally { $null = Exit-Win32ToolkitHyperVLease -Lease $lease }
}
