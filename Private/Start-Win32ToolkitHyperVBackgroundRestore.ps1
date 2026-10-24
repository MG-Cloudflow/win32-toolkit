function Start-Win32ToolkitHyperVBackgroundRestore {
    <#
    .SYNOPSIS
        Starts a restore of the test VM's checkpoint in a background thread job; $true when the job was started.
    .DESCRIPTION
        Hyper-V speed-up PR 4 (D13, D14, A1, A5, V-15). Used for an asynchronous teardown (Kind Teardown,
        HyperVAsyncTeardown, only under an owner: Get-Win32ToolkitAsyncTeardownOwner) and for the capture pre-warm (Kind
        Prewarm, HyperVCapturePrewarm). The caller holds the VM's lease (Enter-Win32ToolkitHyperVLease) and hands it to
        the job record: it is released when the job is joined (Wait-Win32ToolkitHyperVTeardown), never here.

        In this session first (V-15): the checkpoint is read (Get-VMCheckpoint) and, for TurnOffFirst, its precondition
        (Get-Win32ToolkitCheckpointAutoSetting reads $false); a failed precondition prints the advisory here (once per
        process and checkpoint, Write-Win32ToolkitCheckpointAdvisory) and the mode becomes Legacy. Then a thread job runs
        the text of Restore-Win32ToolkitTestVMCheckpoint ONLY, with the resolved -Mode and -SkipPrecondition (and -NoStart
        when given): the job reads no setting and calls no module function. It emits only the helper's result object,
        with CompletedAt (UTC) added after the helper returned. The job is recorded in $script:HyperVPendingRestore
        (Job, VMName, CheckpointName, Lease, Kind, Parked, StartedAt, Mode); a restore still pending from an earlier call
        is joined first.

        $false (nothing started; the caller restores synchronously, as before): no Start-ThreadJob, the helper's text is
        not available, the checkpoint cannot be read, or the job could not be started. Never throws.
    .PARAMETER VMName
        The test VM.
    .PARAMETER CheckpointName
        The checkpoint to restore.
    .PARAMETER Mode
        TurnOffFirst or Legacy; omitted: the HyperVRevertMode setting (absent, blank or anything but Legacy =
        TurnOffFirst).
    .PARAMETER Lease
        The VM lease the caller holds; the job record keeps it and the join releases it (Kind Teardown) or keeps it for
        Wait-Win32ToolkitHyperVTeardown -Prewarm (Kind Prewarm).
    .PARAMETER Kind
        Teardown or Prewarm.
    .PARAMETER NoStart
        Leave the VM as the restore landed it (Saved parking, HyperVTeardownPark).
    .PARAMETER Info
        Optional hashtable filled with Mode (the mode the job runs) when the job was started.
    .OUTPUTS
        Exactly one [bool].
    .EXAMPLE
        $started = Start-Win32ToolkitHyperVBackgroundRestore -VMName $vm -CheckpointName 'clean-base' -Lease $lease -Kind Teardown
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'internal helper: the caller already decided to restore the VM it holds the lease of')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CheckpointName,

        [ValidateSet('TurnOffFirst', 'Legacy')]
        [string]$Mode,

        [AllowNull()]
        [object]$Lease,

        [Parameter(Mandatory)]
        [ValidateSet('Teardown', 'Prewarm')]
        [string]$Kind,

        [switch]$NoStart,

        [hashtable]$Info
    )

    $vmText = ConvertTo-Win32ToolkitSafeText -Text $VMName -MaxLength 64
    $cpText = ConvertTo-Win32ToolkitSafeText -Text $CheckpointName -MaxLength 64
    try {
        if (-not (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)) {
            Write-Verbose "Background restore of '$vmText': Start-ThreadJob is not available; restoring in the foreground."
            return $false
        }
        $restoreText = [string]${function:Restore-Win32ToolkitTestVMCheckpoint}
        if ([string]::IsNullOrWhiteSpace($restoreText)) {
            Write-Verbose "Background restore of '$vmText': the restore helper is not available; restoring in the foreground."
            return $false
        }

        # One background restore at a time in this process: an earlier one is joined first.
        $pending = $script:HyperVPendingRestore
        if ($null -ne $pending) { $null = Wait-Win32ToolkitHyperVTeardown -VMName ([string]$pending['VMName']) }

        if (-not $PSBoundParameters.ContainsKey('Mode')) {
            $raw = ''
            try { $raw = ([string](Get-Win32ToolkitConfigValue -Name 'HyperVRevertMode' -Default '')).Trim() }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "HyperVRevertMode could not be read ($($_.Exception.Message)); TurnOffFirst is used."
                $raw = ''
            }
            $Mode = if ($raw -eq 'Legacy') { 'Legacy' } else { 'TurnOffFirst' }
            if ($raw -and $raw -ne 'Legacy' -and $raw -ne 'TurnOffFirst') {
                Write-Verbose "HyperVRevertMode '$(ConvertTo-Win32ToolkitSafeText -Text $raw -MaxLength 32)' is neither TurnOffFirst nor Legacy; TurnOffFirst is used."
            }
        }

        # The checkpoint and, for TurnOffFirst, its precondition: here, where the advisory remembers what it printed (V-15).
        $cps = @(Get-VMCheckpoint -VMName $VMName -Name $CheckpointName -ErrorAction Stop | Where-Object { $null -ne $_ })
        if ($cps.Count -ne 1) {
            Write-Verbose "Background restore of '$vmText': $($cps.Count) checkpoint(s) named '$cpText'; restoring in the foreground."
            return $false
        }
        if ($Mode -eq 'TurnOffFirst') {
            $auto = Get-Win32ToolkitCheckpointAutoSetting -CheckpointId ([string]$cps[0].Id)
            if (-not ($auto -is [bool] -and -not $auto)) {
                $Mode = 'Legacy'
                $slow = 'Until then every restore keeps the slower path that saves the running VM first.'
                # The texts of Restore-Win32ToolkitTestVMCheckpoint, word for word (one advisory per checkpoint and process).
                $msg = if ($auto -eq $true) {
                    "The test VM's checkpoint '$cpText' was taken with automatic checkpoints on. Turn them off (Set-VM -Name '$vmText' -AutomaticCheckpointsEnabled `$false) and re-take the checkpoint (docs/hyperv-vm.md). $slow"
                }
                else {
                    "The automatic-checkpoint setting of the test VM's checkpoint '$cpText' could not be read, so the restore keeps the slower path that saves the running VM first. Check it (docs/hyperv-vm.md, Make Hyper-V tests faster), or set HyperVRevertMode to Legacy."
                }
                $null = Write-Win32ToolkitCheckpointAdvisory -Kind AutoCheckpoints -Key "$($cps[0].VMId)|$($cps[0].Id)" -Message $msg
            }
        }

        # The job: the helper's own text and nothing else of the module; its result object only, stamped when it returned.
        $jobScript = {
            param([string]$HelperText, [string]$JobVMName, [string]$JobCheckpointName, [string]$JobMode, [bool]$JobNoStart)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            $VerbosePreference = 'Continue'
            $helper = [scriptblock]::Create($HelperText)
            $r = & $helper -VMName $JobVMName -CheckpointName $JobCheckpointName -Mode $JobMode -SkipPrecondition -NoStart:$JobNoStart
            $r | Add-Member -NotePropertyName CompletedAt -NotePropertyValue ([datetime]::UtcNow) -Force
            $r
        }
        $job = Start-ThreadJob -ScriptBlock $jobScript -ArgumentList $restoreText, $VMName, $CheckpointName, $Mode, ([bool]$NoStart)
        $script:HyperVPendingRestore = @{
            Job = $job; VMName = $VMName; CheckpointName = $CheckpointName; Lease = $Lease; Kind = $Kind
            Parked = $(if ($NoStart) { 'Saved' } else { 'Running' }); StartedAt = Get-Date; Mode = $Mode
        }
        if ($null -ne $Info) { $Info['Mode'] = $Mode }
        Write-Verbose "Background restore of '$vmText' to '$cpText' started ($Kind, $Mode$(if ($NoStart) { ', left Saved' }))."
        return $true
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Background restore of '$vmText' could not be started ($($_.Exception.Message)); restoring in the foreground."
        return $false
    }
}
