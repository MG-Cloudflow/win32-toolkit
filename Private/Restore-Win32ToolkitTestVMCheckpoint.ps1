function Restore-Win32ToolkitTestVMCheckpoint {
    <#
    .SYNOPSIS
        Restores the test VM's checkpoint; by default it turns the VM off first, so Hyper-V does not save its memory.
    .DESCRIPTION
        Hyper-V speed-up PR 2 (D4, D5, B1, A-9). Every restore of the Hyper-V test VM goes through this helper: the session
        open and the teardown of a run (New-/Remove-Win32ToolkitHyperVSession, which the Intune-parity pre-check uses too)
        and Reset-Win32ToolkitTestVM.

        Restoring a checkpoint of a running VM makes Hyper-V save the VM's memory to disk first, only to discard it (about
        30 s for an 8 GB VM on a nested host, twice per run). Two modes, from -Mode or else the HKCU value
        HyperVRevertMode (absent, blank or any value but Legacy = TurnOffFirst; a value that is neither prints one verbose
        line):
          * TurnOffFirst (default): a Running or Paused VM is turned off (Stop-VM -TurnOff: the guest stops at once and its
            memory is never written to the host disk; an Off or Saved VM is left as it is), the checkpoint is restored (a
            Standard checkpoint lands the VM Saved) and the VM is started, which resumes the checkpoint's memory state.
            A VM that lands Off gets the cold-checkpoint warning before it is started. With -NoStart the VM is left as it
            landed.
            Precondition: the checkpoint itself was taken with automatic checkpoints off
            (Get-Win32ToolkitCheckpointAutoSetting reads $false). With them on, Hyper-V may add an "Automatic Checkpoint"
            when the VM starts, and a checkpoint brings its setting back with every restore. When the checkpoint reads
            $true, cannot be read, or the name matches no single checkpoint, the Legacy restore runs instead and one
            warning per process and checkpoint says so (Write-Win32ToolkitCheckpointAdvisory). If the VM nevertheless
            reads AutomaticCheckpointsEnabled $true after the restore, they are turned off on the VM (never on the
            checkpoint) before it starts, with one warning (A-9): the fast path never starts the VM with them on.
          * Legacy: the restore as before this change (one Restore-VMCheckpoint; Hyper-V saves a running VM first).
            Starting a VM that did not land Running is left to the caller.
        Every step is timed; one verbose line per step.

        Speed-up PR 3: first, a VM in the middle of a state change (Starting, Stopping, Saving, Pausing, Resuming,
        Reset, FastSaving or any *Critical state: an orphaned background restore, another tool) is waited for, every
        2 seconds for up to 120 seconds; then the restore goes on and the cmdlets report whatever is still wrong. The
        callers hold the VM's lease (Enter-Win32ToolkitHyperVLease), which keeps out other win32-toolkit processes.

        Speed-up PR 4 (V-15): Start-Win32ToolkitHyperVBackgroundRestore runs this function's own text in a background
        thread job that has none of the module's other functions. It resolves the mode and the precondition first (in
        the caller's session, where the advisory and its once-per-process memory live) and calls this with -Mode and
        -SkipPrecondition: then no module function is called here (only Hyper-V cmdlets, Start-Sleep and the
        stopwatch), and the A-9 notice is a constant warning.
    .PARAMETER VMName
        The test VM.
    .PARAMETER CheckpointName
        The checkpoint to restore.
    .PARAMETER Mode
        TurnOffFirst or Legacy. Omitted: the HyperVRevertMode setting.
    .PARAMETER NoStart
        TurnOffFirst only: do not start the VM after the restore.
    .PARAMETER SkipPrecondition
        The caller already resolved -Mode (required with this switch) and the checkpoint's precondition: the
        precondition is not read here, no advisory is printed, and no module function is called (speed-up PR 4, V-15).
    .OUTPUTS
        Exactly one object: Mode (the mode that ran: Legacy also when the precondition failed), Landed (the VM state read
        right after the restore and before any start by this helper: a VM that landed Off reads Off even after this
        helper started it; $null when Legacy could not read it), TurnOffSeconds, RestoreSeconds, StartSeconds ($null for
        a step that did not run) and Started ($true when this helper started the VM). Throws the Hyper-V cmdlet's error
        (not a W32T error) when the checkpoint, the VM, the turn-off, the restore, the setting change or the start fails.
    .EXAMPLE
        $r = Restore-Win32ToolkitTestVMCheckpoint -VMName 'win32tk-golden' -CheckpointName 'clean-base'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CheckpointName,

        [ValidateSet('TurnOffFirst', 'Legacy')]
        [string]$Mode,

        [switch]$NoStart,

        [switch]$SkipPrecondition
    )

    if ($SkipPrecondition) {
        # A background job (speed-up PR 4, V-15): the caller resolved the mode; nothing of the module is available here,
        # so the names are neutralised inline as ConvertTo-Win32ToolkitSafeText does (control/format characters, U+2028/9).
        if (-not $PSBoundParameters.ContainsKey('Mode')) { throw '-SkipPrecondition needs -Mode: the caller resolves the mode and the precondition.' }
        $unsafe = '[\p{Cc}\p{Cf}' + [char]0x2028 + [char]0x2029 + ']'
        $vmText = ($VMName -replace $unsafe, '?').Trim()
        if ($vmText.Length -gt 64) { $vmText = $vmText.Substring(0, 61) + '...' }
        $cpText = ($CheckpointName -replace $unsafe, '?').Trim()
        if ($cpText.Length -gt 64) { $cpText = $cpText.Substring(0, 61) + '...' }
    }
    else {
        $vmText = ConvertTo-Win32ToolkitSafeText -Text $VMName -MaxLength 64
        $cpText = ConvertTo-Win32ToolkitSafeText -Text $CheckpointName -MaxLength 64
    }

    if (-not $PSBoundParameters.ContainsKey('Mode')) {
        $raw = ''
        try { $raw = ([string](Get-Win32ToolkitConfigValue -Name 'HyperVRevertMode' -Default '')).Trim() }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "HyperVRevertMode could not be read ($($_.Exception.Message)); TurnOffFirst is used."
            $raw = ''
        }
        if ($raw -eq 'Legacy') { $Mode = 'Legacy' }
        else {
            $Mode = 'TurnOffFirst'
            if ($raw -and $raw -ne 'TurnOffFirst') {
                Write-Verbose "HyperVRevertMode '$(ConvertTo-Win32ToolkitSafeText -Text $raw -MaxLength 32)' is neither TurnOffFirst nor Legacy; TurnOffFirst is used."
            }
        }
    }

    $result = [ordered]@{ Mode = $Mode; Landed = $null; TurnOffSeconds = $null; RestoreSeconds = $null; StartSeconds = $null; Started = $false }
    $advKey = "$VMName|$CheckpointName"

    # Speed-up PR 3: never start on a VM in the middle of a state change (an orphaned background restore, another tool's
    # save or start): wait while it is transitional, every 2 s for up to 120 s, then go on and let the cmdlets report.
    # Fail-open: a VM that cannot be read here is left to the steps below.
    $transitional = @('Starting', 'Stopping', 'Saving', 'Pausing', 'Resuming', 'Reset', 'FastSaving')
    $settle = [System.Diagnostics.Stopwatch]::StartNew()
    $polls = 0
    while ($true) {
        $state = $null
        try { $state = [string](Get-VM -Name $VMName -ErrorAction Stop).State }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "'$vmText': the VM state could not be read before the restore ($($_.Exception.Message))."
            break
        }
        if (-not ($state -in $transitional -or $state -like '*Critical')) { break }
        if ($polls -ge 60 -or $settle.Elapsed.TotalSeconds -ge 120) {
            Write-Verbose "'$vmText' is still $state after $([math]::Round($settle.Elapsed.TotalSeconds)) s; restoring anyway."
            break
        }
        if ($polls -eq 0) { Write-Verbose "'$vmText' is $state; waiting for it to settle before the restore..." }
        $polls++
        Start-Sleep -Seconds 2
    }

    if ($Mode -eq 'TurnOffFirst' -and -not $SkipPrecondition) {
        # The precondition is read on the target checkpoint itself (its own setting comes back with the restore).
        $cps = @(Get-VMCheckpoint -VMName $VMName -Name $CheckpointName -ErrorAction Stop | Where-Object { $null -ne $_ })
        $auto = $null
        if ($cps.Count -eq 1) {
            $advKey = "$($cps[0].VMId)|$($cps[0].Id)"
            $auto = Get-Win32ToolkitCheckpointAutoSetting -CheckpointId ([string]$cps[0].Id)
        }
        if (-not ($auto -is [bool] -and -not $auto)) {
            $result.Mode = 'Legacy'
            $slow = 'Until then every restore keeps the slower path that saves the running VM first.'
            $msg = if ($auto -eq $true) {
                "The test VM's checkpoint '$cpText' was taken with automatic checkpoints on. Turn them off (Set-VM -Name '$vmText' -AutomaticCheckpointsEnabled `$false) and re-take the checkpoint (docs/hyperv-vm.md). $slow"
            }
            else {
                "The automatic-checkpoint setting of the test VM's checkpoint '$cpText' could not be read, so the restore keeps the slower path that saves the running VM first. Check it (docs/hyperv-vm.md, Make Hyper-V tests faster), or set HyperVRevertMode to Legacy."
            }
            $null = Write-Win32ToolkitCheckpointAdvisory -Kind AutoCheckpoints -Key $advKey -Message $msg
        }
    }

    if ($result.Mode -eq 'Legacy') {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Restore-VMCheckpoint -VMName $VMName -Name $CheckpointName -Confirm:$false -ErrorAction Stop
        $result.RestoreSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
        try { $result.Landed = [string](Get-VM -Name $VMName -ErrorAction Stop).State }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "'$vmText': the VM state after the restore could not be read ($($_.Exception.Message))."
        }
        Write-Verbose "'$vmText': restored '$cpText' (Legacy) in $($result.RestoreSeconds) s; the VM landed $($result.Landed)."
        return [pscustomobject]$result
    }

    # TurnOffFirst: turn off, restore, start.
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $before = [string]$vm.State
    if ($before -eq 'Running' -or $before -eq 'Paused') {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Stop-VM -Name $VMName -TurnOff -Force -Confirm:$false -ErrorAction Stop
        $result.TurnOffSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
        Write-Verbose "'$vmText': turned off ($before) in $($result.TurnOffSeconds) s."
    }
    else {
        Write-Verbose "'$vmText' is $before`: nothing to turn off before the restore."
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Restore-VMCheckpoint -VMName $VMName -Name $CheckpointName -Confirm:$false -ErrorAction Stop
    $result.RestoreSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
    $after = Get-VM -Name $VMName -ErrorAction Stop
    $result.Landed = [string]$after.State
    Write-Verbose "'$vmText': restored '$cpText' (TurnOffFirst) in $($result.RestoreSeconds) s; the VM landed $($result.Landed)."

    # Not expected (the checkpoint reads off): never start the VM with automatic checkpoints on (A-9).
    if ($after.AutomaticCheckpointsEnabled -eq $true) {
        $null = Set-VM -Name $VMName -AutomaticCheckpointsEnabled $false -Confirm:$false -ErrorAction Stop
        $a9 = "The test VM '$vmText' had automatic checkpoints on after restoring '$cpText', although the checkpoint was taken with them off. They were turned off on the VM before it was started."
        # In a background job (-SkipPrecondition) the advisory's once-per-process memory is not available: a plain
        # warning, relayed by Receive-Job when the caller joins the job.
        if ($SkipPrecondition) { Write-Warning $a9 }
        else { $null = Write-Win32ToolkitCheckpointAdvisory -Kind AutoCheckpoints -Key $advKey -Message $a9 }
    }

    if (-not $NoStart) {
        if ($result.Landed -eq 'Saved' -or $result.Landed -eq 'Off') {
            if ($result.Landed -eq 'Off') {
                # A Standard (memory-state) checkpoint restores a Saved VM; Off means it was taken powered off or as a
                # Production checkpoint (the warning of New-Win32ToolkitHyperVSession, kept word for word).
                Write-Warning "VM '$vmText' was not Running after restoring '$cpText' $([char]0x2014) the checkpoint is not a warm memory-state one, so every run pays a full boot. Re-take it with the VM running at a logged-in desktop (Standard checkpoint type) to restore warm-revert speed."
            }
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $null = Start-VM -Name $VMName -Confirm:$false -ErrorAction Stop
            $result.StartSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
            $result.Started = $true
            Write-Verbose "'$vmText': started ($(if ($result.Landed -eq 'Saved') { 'resumed from Saved' } else { 'cold boot from Off' })) in $($result.StartSeconds) s."
        }
    }

    return [pscustomobject]$result
}
