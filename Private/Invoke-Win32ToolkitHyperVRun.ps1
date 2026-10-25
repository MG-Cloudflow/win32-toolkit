function Invoke-Win32ToolkitHyperVRun {
    <#
    .SYNOPSIS
        Runs a test/capture against the Hyper-V backend: reset -> copy in -> run phases -> copy out.
    .DESCRIPTION
        The Hyper-V counterpart of launching a .wsb. It reverts the VM to its warm checkpoint, opens a
        PowerShell Direct session, copies the project to C:\PSADT (and an optional baseline to
        C:\PSADTOld), runs each phase synchronously with the guest's Windows PowerShell 5.1, copies the
        requested outputs back UNDER the host project (so the existing host-side waiters/consumers work
        unchanged), and always closes the session + reverts the VM. Returns $true on completion.

        This is the 'HyperV' branch of the test-backend seam; the flows call it instead of building a
        .wsb. See knowledge-base/designs/hyperv-backend-plan.md.

        Before it touches the VM it takes the VM's machine-wide lease (Enter-Win32ToolkitHyperVLease, speed-up PR 3,
        D10): while another PowerShell process uses the VM this run waits, up to HyperVLeaseWaitMinutes, and then throws
        W32T.HyperVLeaseTimeout without restoring anything. The lease is held until the teardown restore is done.

        Asynchronous teardown (speed-up PR 4, D13, A-14; HKCU HyperVAsyncTeardown, default Off): when it is On, the run is
        unattended (no interactive phase) and an owner is running (Show-Win32Toolkit or Invoke-Win32Toolkit:
        Get-Win32ToolkitAsyncTeardownOwner), the teardown closes the session and starts the checkpoint restore in a
        background thread job (Start-Win32ToolkitHyperVBackgroundRestore), which keeps the lease, and returns at once.
        The next use of the VM in this process (its lease), or the owner's end, waits for it. Otherwise (Off, no owner, a
        watched run, no thread jobs, a job that could not start) the teardown restores before returning, as before.
    .PARAMETER ProjectPath
        The PSADT project under test (host path). Copied to C:\PSADT in the guest.
    .PARAMETER Phase
        Ordered phases to run, each an object with: Label, Command (a 5.1-safe guest command string),
        and optional IgnoreExit ([bool], default $false) and SuccessExitCodes ([int[]], default @(0): a
        warning is printed only for an exit code outside them). A DepPhase that fails skips every later
        phase except those with Always = $true (log collection); so does a phase with StopRunOnFailure = $true that
        exits outside its success codes (installer-identity PR 3b: the phases of a sibling capture). An Intune-parity phase may name the
        likely cause of exit code 1460 (the guest runner stopped the package at its limit: 25 minutes, or
        the phase's optional RunnerTimeoutMinutes, an int 1-235 the caller also passes to the runner as
        -TimeoutMinutes; the phase's own backstop is then RunnerTimeoutMinutes + 5) with the optional key
        ParityHint, a constant set by the caller: 'Dialog41' (a PSADT 4.1 dialog waiting for the user
        signed in to the VM), 'Dialog' (a PSADT dialog, or an installer that did not finish) or
        'Uninstaller' (the uninstaller or a child process it waits for; it also explains exit code 69113:
        the package stopped the app's EXE uninstaller at the device's 30-minute limit). The warning then
        adds that cause and what to do; without the key, or with another value, it names the exit code
        only. A phase with PriorRemoval = $true (installer-identity PR 3: a package with Enforce prior-install rules,
        whose remove-prior step may run the prior's uninstaller for up to 30 minutes) adds that to the 1460 text. A phase
        with ExitMeaning (a hashtable [int] code -> text, host constants: the remove-prior codes of a package with
        prior-install rules) names what such a code means in its warning and in its ParityExitNote sentence.
    .PARAMETER Output
        Project-relative globs to copy back from the guest after the phases (default the capture JSON +
        Sandbox\Logs).
    .PARAMETER ResultDestination
        Where the Output globs are copied back to (default ProjectPath). A sibling capture points it at its quarantine
        folder (installer-identity PR 3b, spec 2.14.5), never at the project.
    .PARAMETER ResultAllowedEntry / ResultMaxEntryBytes / ResultMaxTotalBytes
        Passed to Copy-Win32ToolkitResultsFromGuest as -AllowedEntry / -MaxEntryBytes / -MaxTotalBytes (only when
        given): the copy-back allow-list (a regex on the entry names) and size caps of a quarantine.
    .PARAMETER BaselineProjectPath
        Update baseline-project mode: a second project copied read-only-in-effect to C:\PSADTOld.
    .PARAMETER VMName / Credential / CheckpointName
        Resolved when omitted: VMName and CheckpointName by Get-Win32ToolkitHyperVTarget (W32T_HYPERV_VM /
        W32T_HYPERV_CHECKPOINT for this session, else HyperVVMName / HyperVCheckpoint, else 'win32tk-golden' /
        'clean-base' - the checkpoint the test VM commands maintain), the credential from the stored guest credential.
    .PARAMETER ParityExitNote
        Optional list the run adds one sentence to for each Intune-parity phase (a phase with a ParityHint) that
        exited with a code outside its SuccessExitCodes, for the Notes of the test's TestResults.json record:
        the phase label, the exit code and, for 1460 (the test's own limit for the phase was reached), for
        69113 with ParityHint 'Uninstaller' (the app's own uninstaller was still running at the device's
        30-minute limit and was stopped) and for a code the phase's ExitMeaning names, what it means; any other
        code is named only. A phase that did not
        finish (267009 / 267011) did not exit and adds nothing. Host constants and the exit code only.
    .PARAMETER RunInfo
        Optional hashtable the run fills with Timing (seconds per step: open, copy-in, each phase that ran,
        teardown, total; whether the open skipped its restore; the copy-in zip's content hash) and Lane (the VM
        and checkpoint it used) for the caller's TestResults.json record (Hyper-V speed-up PR 1, D12). Best
        effort: a measurement that fails leaves its value $null. The [bool] output is unchanged. An asynchronous
        teardown (PR 4) leaves TeardownSeconds $null; RevertMode is then the mode the background restore runs.
    .OUTPUTS
        [bool] — $true if the run completed (individual phase failures are warned, not fatal, matching
        the Sandbox fire-and-forget semantics; callers judge results from the copied-back outputs).
        $false when a step threw, or when a phase did not finish (stopped at its timeout: 267009, or
        never started: 267011): the remaining phases are then skipped, the logs are still copied back
        (never an install capture) and the VM is still reverted. A W32T error (a lease timeout) is thrown, never
        turned into $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$ProjectPath,
        [Parameter(Mandatory)] [object[]]$Phase,
        [string[]]$Output = @('Documentation\InstallationChanges_*.json', 'Documentation\Targeted_Documentation_Log_*.txt', 'Sandbox\Logs\*'),
        # Installer-identity PR 3b (a sibling capture's quarantine): where the outputs land, and the copy-back checks.
        [string]$ResultDestination,
        [string]$ResultAllowedEntry,
        [long]$ResultMaxEntryBytes = 0,
        [long]$ResultMaxTotalBytes = 0,
        [string]$BaselineProjectPath,
        [string]$VMName,
        [pscredential]$Credential,
        # No default: an omitted name is the configured HyperVCheckpoint (default 'clean-base') below, the
        # checkpoint New-/Set-Win32ToolkitTestVM* maintain (installer-identity PR 2, L18).
        [string]$CheckpointName,
        # Filled for the caller's test record (installer-identity PR 2 follow-up R6 #3): one sentence per Intune-parity
        # phase that exited outside its success codes, so a 69113 and a 1460 are told apart in TestResults.json.
        [System.Collections.Generic.List[string]]$ParityExitNote,
        # Filled for the caller's test record (Hyper-V speed-up PR 1, D12): Timing and Lane.
        [hashtable]$RunInfo
    )

    # The session's test VM and checkpoint (speed-up PR 3, D11): W32T_HYPERV_VM / W32T_HYPERV_CHECKPOINT, else the registry,
    # else the defaults; an invalid pin throws W32T.HyperVTargetNotReady before anything starts.
    if (-not $VMName -or -not $CheckpointName) {
        $target = Get-Win32ToolkitHyperVTarget
        if (-not $VMName)         { $VMName = $target.VMName }
        if (-not $CheckpointName) { $CheckpointName = $target.CheckpointName }
    }
    if (-not $Credential) { $Credential = Get-Win32ToolkitGuestCredential }
    if (-not $Credential) {
        throw "No Hyper-V guest credential is configured. Run New-Win32ToolkitTestVM first (it stores the credential), or pass -Credential."
    }

    # Host measurements for the caller's record (speed-up PR 1, D12). Bookkeeping only: every block that fills them
    # is fail-open (a missing helper or a Hyper-V read error never changes the run's result, warnings or teardown).
    $runWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timing = @{
        TotalSeconds = $null; OpenSeconds = $null; OpenRevertSkipped = $null; SecondsSinceTeardown = $null
        CopyInSeconds = $null; CopyInSha256 = $null; Phases = [System.Collections.Generic.List[object]]::new()
        TeardownSeconds = $null; RevertMode = $null; PrecheckSeconds = $null; PrecheckFromCache = $null
    }
    $lane = $null
    $openInfo = @{}
    $teardownWatch = $null

    $session = $null
    # The machine-wide lease of the VM (speed-up PR 3, D10): $null until taken; without it nothing is restored below.
    $lease = $null
    # Speed-up PR 4 (D13): read once at the start of the try (never in the finally); Off until then.
    $asyncTeardown = $false
    # Suppress HOST progress bars for the whole run. Copy-Item -To/-FromSession (the project copy in/out)
    # and the Hyper-V checkpoint cmdlets paint out-of-band, absolute-cursor progress regions that tear the
    # Spectre.Console TUI this runs under. The copy/session helpers below don't set their own
    # $ProgressPreference, so they inherit this via dynamic scoping — no per-helper edits needed. Restored
    # in finally so the intentional Azure-upload bar on the (later) publish path is unaffected.
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    # ── Deps checkpoint (opt-in: HyperVDepsCheckpoint=On) ─────────────────────────────────────────────
    # When the project stages dependencies, a 'clean-base+deps-<key>' checkpoint lets every later run
    # skip the per-run dependency install entirely: restore THAT instead of clean-base and drop the
    # tagged dep phase. The key hashes the staged set + every payload byte + the parent checkpoint's
    # identity, so any change simply never matches and falls back to clean-base + a live install (which
    # then re-creates the checkpoint). VM maintenance deletes all checkpoints — the fallback is routine.
    $effectiveCheckpoint  = $CheckpointName
    $skipDepPhases        = $false
    $createDepsCheckpoint = $false
    $depsCpName           = $null
    $depsFeatureOn        = $false
    try { $depsFeatureOn = ((Get-Win32ToolkitConfigValue -Name 'HyperVDepsCheckpoint' -Default 'Off') -eq 'On') } catch { $depsFeatureOn = $false }
    if ($depsFeatureOn) {
        $depsCpName = Get-Win32ToolkitDepsCheckpointName -ProjectPath $ProjectPath -VMName $VMName -ParentCheckpointName $CheckpointName
        if ($depsCpName) {
            if (Get-VMCheckpoint -VMName $VMName -Name $depsCpName -ErrorAction SilentlyContinue) {
                $effectiveCheckpoint = $depsCpName
                $skipDepPhases       = $true
                Write-Host "✓ Using checkpoint '$depsCpName' — this project's dependencies are pre-installed in the image." -ForegroundColor Green
            }
            elseif (-not $BaselineProjectPath) {
                $createDepsCheckpoint = $true
            }
            else {
                # NEVER create the checkpoint during a baseline (Update) run: the read-only C:\PSADTOld
                # copy-in happens BEFORE the dep phase, so the frozen image would contain an
                # icacls-locked folder that later baseline copy-ins can neither delete nor overwrite —
                # poisoning every subsequent Update run of the project (the key hashes deps, not the
                # baseline, so it would never rotate). USING an existing checkpoint is fine: it was
                # frozen without a baseline, and this run's C:\PSADTOld is erased by the teardown revert.
                Write-Verbose 'Deps checkpoint not created during a baseline run (it would freeze the read-only C:\PSADTOld into the image); an InstallUninstall/capture run will create it.'
            }
        }
    }

    # ── Overlap: build the copy-in zip(s) WHILE the checkpoint reverts ────────────────────────────────
    # The zip needs no session and used to sit serially in every run (5-20 s). Pure .NET work in a
    # thread job; joined (with errors surfaced) right before the transfer. No ThreadJob => build inline
    # in the copy helper, exactly as before. The job has none of this module's functions, so it rebuilds
    # New-Win32ToolkitProjectZip from its text: one builder, the same zip either way (Sandbox\Logs\Runs\
    # stays on the host, test campaign F2).
    # The project job also hashes the zip's content for the record (CopyInSha256, speed-up PR 1 A-3), off the critical
    # path: it emits ONLY that hash (the build's own output, the zip path, is discarded), the baseline job nothing.
    $zipJobs = @{}
    $zipBuilderText = [string]${function:New-Win32ToolkitProjectZip}
    $hashText = [string]${function:Get-Win32ToolkitZipContentHash}
    $canThreadJob = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) -and -not [string]::IsNullOrWhiteSpace($zipBuilderText)
    if ($canThreadJob) {
        $zipBuilder = {
            param($src, $dst, $builderText, $hashText)
            $build = [scriptblock]::Create($builderText)
            $null = & $build -ProjectPath $src -ZipPath $dst
            if ($hashText) { & ([scriptblock]::Create($hashText)) -ZipPath $dst }
        }
        $projZipPath = Join-Path ([System.IO.Path]::GetTempPath()) ('w32proj_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
        $zipJobs['project'] = @{ Job = (Start-ThreadJob -ScriptBlock $zipBuilder -ArgumentList $ProjectPath, $projZipPath, $zipBuilderText, $hashText); Path = $projZipPath }
        if ($BaselineProjectPath) {
            $baseZipPath = Join-Path ([System.IO.Path]::GetTempPath()) ('w32proj_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
            $zipJobs['baseline'] = @{ Job = (Start-ThreadJob -ScriptBlock $zipBuilder -ArgumentList $BaselineProjectPath, $baseZipPath, $zipBuilderText, ''); Path = $baseZipPath }
        }
    }
    # Joins a prebuild job and returns its zip path — or $null (build-inline fallback) on any job error. The job's hash
    # is stored BY REFERENCE in the shared table ($zipJobs[$key].Hash): this scriptblock runs in a child scope, so a
    # variable it assigned would never reach the run.
    $joinZip = {
        param($key)
        if (-not $zipJobs.ContainsKey($key)) { return $null }
        try {
            $out = @(Receive-Job -Job $zipJobs[$key].Job -Wait -ErrorAction Stop)
            $zipJobs[$key].Hash = if ($out.Count -ge 1 -and [string]$out[-1] -cmatch '^[0-9A-F]{64}$') { [string]$out[-1] } else { $null }
            return $zipJobs[$key].Path
        }
        catch {
            Write-Verbose "Zip prebuild '$key' failed ($($_.Exception.Message)) — building inline."
            # The failed job may never have written the zip: only an existing one is removed, so an
            # absent file leaves no PathNotFound record in the caller's -ErrorVariable / $Error.
            if (Test-Path -LiteralPath $zipJobs[$key].Path) { Remove-Item -LiteralPath $zipJobs[$key].Path -Force -ErrorAction SilentlyContinue }
            return $null
        }
    }

    try {
        # One process at a time on this VM (speed-up PR 3, D10, A-1): the lease is taken before the first VM-changing call
        # and inside this try, so the finally still cleans the zip jobs and restores $ProgressPreference. A lease timeout
        # (W32T.HyperVLeaseTimeout) propagates through the catch's C-2 line, and the finally restores nothing without it.
        $lease = Enter-Win32ToolkitHyperVLease -VMName $VMName -Purpose 'test run'
        # The asynchronous teardown switch (speed-up PR 4, D13; HKCU HyperVAsyncTeardown, anything but On = Off): read here,
        # once, fail-safe; the finally only reads this variable.
        try { $asyncTeardown = ([string](Get-Win32ToolkitConfigValue -Name 'HyperVAsyncTeardown' -Default 'Off')).Trim() -eq 'On' }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "HyperVAsyncTeardown could not be read ($($_.Exception.Message)); the teardown restores before the run returns."
            $asyncTeardown = $false
        }

        # Interactive phases need a logged-in desktop, so ask the session to ensure/recover one.
        $needsDesktop = @($Phase | Where-Object { $_.Interactive }).Count -gt 0

        Write-Verbose "Reverting '$VMName' to '$effectiveCheckpoint' and connecting over PowerShell Direct..."
        $openWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $session = New-Win32ToolkitHyperVSession -VMName $VMName -Credential $Credential -CheckpointName $effectiveCheckpoint -EnsureDesktop:$needsDesktop -Info $openInfo -Lease $lease
        # The record's open timing and the VM/checkpoint identity (speed-up PR 1, D12): fail-open.
        try {
            $timing.OpenSeconds = [math]::Round($openWatch.Elapsed.TotalSeconds, 1)
            $timing.OpenRevertSkipped = $openInfo['RevertSkipped']
            $timing.SecondsSinceTeardown = $openInfo['SecondsSinceTeardown']
            $lane = Get-Win32ToolkitHyperVLane -VMName $VMName -CheckpointName $effectiveCheckpoint -VM $openInfo['VM']
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Hyper-V run record: the VM and checkpoint identity could not be read ($($_.Exception.Message))."
            $lane = $null
        }
        # The checkpoint's sign-in and Defender state, once per checkpoint (speed-up PR 1, D34, A-4), and the
        # non-blocking advisories about it (once per process and checkpoint, A-8; one Notes sentence per run). Asked live
        # only for an unattended run whose open restored the checkpoint and landed warm; a watched run reads the stored
        # answer only. The console check runs before the guest is asked (V-10). Fail-open.
        try {
            if ($lane) {
                $allowLive = -not $needsDesktop -and $openInfo['RevertSkipped'] -eq $false -and $openInfo['Warm'] -eq $true
                $allowStore = $allowLive -and -not (Test-Win32ToolkitVMConnectOpen -VMName $VMName -VMId ([string]$lane.VMId))
                $lane['Attestation'] = Get-Win32ToolkitCheckpointAttestation -Session $session -VMName $VMName -CheckpointName $effectiveCheckpoint -VMId ([string]$lane.VMId) `
                    -CheckpointId ([string]$lane.CheckpointId) -CreationTimeUtcTicks ([long]$lane.CheckpointCreationTicks) -AllowLive:$allowLive -AllowStore:$allowStore
                $advKey = "$($lane.VMId)|$($lane.CheckpointId)"
                $cpText = ConvertTo-Win32ToolkitSafeText -Text $effectiveCheckpoint -MaxLength 64
                # A checkpoint taken with automatic checkpoints on brings the setting back with every restore (D5): one
                # readiness advisory (warning only, not a Notes sentence: it changes no test result).
                if ((Get-Win32ToolkitCheckpointAutoSetting -CheckpointId ([string]$lane.CheckpointId)) -eq $true) {
                    $vmText = ConvertTo-Win32ToolkitSafeText -Text $VMName -MaxLength 64
                    $null = Write-Win32ToolkitCheckpointAdvisory -Kind AutoCheckpoints -Key $advKey -Message "The test VM's checkpoint '$cpText' was taken with automatic checkpoints on. Turn them off (Set-VM -Name '$vmText' -AutomaticCheckpointsEnabled `$false) and re-take the checkpoint (docs/hyperv-vm.md)."
                }
                $advice = [System.Collections.Generic.List[object]]::new()
                if ($null -ne $lane.CheckpointAgeDays -and $lane.CheckpointAgeDays -gt 35) {
                    $advice.Add(@('Age', "The test VM's checkpoint '$cpText' is $($lane.CheckpointAgeDays) days old: every run first catches up on Windows and Defender updates. Re-take it (docs/hyperv-vm.md)."))
                }
                $att = $lane['Attestation']
                if ($att) {
                    if ($att.SignedIn -eq $false) {
                        $advice.Add(@('SignedIn', "The test VM's checkpoint '$cpText' restores with nobody signed in: Intune-parity runs then do not show PSADT's dialogs to a user. Re-take it at a signed-in desktop (docs/hyperv-vm.md)."))
                    }
                    if ($att.DefenderRealTime -eq $false) {
                        $advice.Add(@('RealTime', "Defender real-time protection is off in the test VM's checkpoint '$cpText': installs are not scanned as on a device. Turn it on in the VM and re-take the checkpoint."))
                    }
                    if ($att.DefenderExclusionCount -gt 0) {
                        $advice.Add(@('Exclusions', "The test VM's checkpoint '$cpText' has $($att.DefenderExclusionCount) Defender exclusion(s): installs may skip scans that devices do. Remove them and re-take the checkpoint."))
                    }
                    if ($null -eq $att.SignatureAgeDays) {
                        $advice.Add(@('Signatures', "Defender signatures in the test VM's checkpoint '$cpText' were never updated, or their age is unknown. Update them (Update-MpSignature) and re-take the checkpoint."))
                    }
                    elseif ($att.SignatureAgeDays -gt 35) {
                        $advice.Add(@('Signatures', "Defender signatures in the test VM's checkpoint '$cpText' are $($att.SignatureAgeDays) days old. Update them (Update-MpSignature) and re-take the checkpoint."))
                    }
                }
                foreach ($a in $advice) {
                    $null = Write-Win32ToolkitCheckpointAdvisory -Kind $a[0] -Key $advKey -Message $a[1]
                    if ($null -ne $ParityExitNote) { $ParityExitNote.Add($a[1]) }
                }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Hyper-V run record: the checkpoint attestation could not be read ($($_.Exception.Message))."
        }

        Write-Verbose "Copying project into the guest (C:\PSADT)..."
        $copyWatch = [System.Diagnostics.Stopwatch]::StartNew()
        Copy-Win32ToolkitProjectToGuest -Session $session -ProjectPath $ProjectPath -GuestPath 'C:\PSADT' -PrebuiltZip (& $joinZip 'project')
        if ($BaselineProjectPath) {
            # -ReadOnly reproduces the Sandbox <ReadOnly>true</ReadOnly> mount, so the baseline's own PSADT
            # run can't write into C:\PSADTOld on Hyper-V while the same run fails under Sandbox.
            Write-Verbose 'Copying the update baseline into the guest (C:\PSADTOld, read-only)...'
            Copy-Win32ToolkitProjectToGuest -Session $session -ProjectPath $BaselineProjectPath -GuestPath 'C:\PSADTOld' -ReadOnly -PrebuiltZip (& $joinZip 'baseline')
        }
        $timing.CopyInSeconds = [math]::Round($copyWatch.Elapsed.TotalSeconds, 1)
        # Already validated by the join; $null when the prebuild did not run, failed or emitted no hash.
        $timing.CopyInSha256 = if ($zipJobs.ContainsKey('project')) { $zipJobs['project'].Hash } else { $null }

        # Deps are baked into the restored image: remove the in-guest installer script so the CAPTURE
        # script (which installs deps in-script, not as a tagged phase) skips them too.
        if ($skipDepPhases) {
            Invoke-Command -Session $session -ScriptBlock {
                param($p) Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            } -ArgumentList 'C:\PSADT\Sandbox\InstallDependencies.ps1' -ErrorAction SilentlyContinue
        }

        # If any phase is interactive, open the VM console so the operator can watch the PSADT GUI.
        # A console already attached to this VM (an earlier watched run's, which survives the restore) is used as it is:
        # every watched run used to open one more (live row ASSISTED: two consoles on the same VM at the end).
        if ($needsDesktop) {
            if (Test-Win32ToolkitVMConnectOpen -VMName $VMName -VMId $(if ($lane) { [string]$lane.VMId } else { '' })) {
                Write-Host "A console of '$VMName' is already open: watch the run there." -ForegroundColor Gray
            }
            else {
                Write-Verbose 'Opening the VM console (vmconnect) for interactive GUI testing...'
                Start-Process -FilePath 'vmconnect.exe' -ArgumentList 'localhost', $VMName -ErrorAction SilentlyContinue
            }
        }

        # A phase that did not finish (still running at its timeout, or never started) ends the run: the
        # later phases would overlap it or judge a half-done install, so they are skipped.
        $incomplete = $false
        # A failed dependency phase skips every later phase except those marked Always (log collection): the
        # app is not installed when a dependency failed, as on a device (test campaign 2026-10-21, S11-F1).
        $depFailed = $false
        # A failed StopRunOnFailure phase skips the rest the same way (installer-identity PR 3b, spec 2.14.5).
        $stopFailed = $false
        foreach ($ph in $Phase) {
            if ($depFailed -and -not $ph.Always) {
                Write-Verbose "  Skipping '$($ph.Label)' — a declared dependency failed to install."
                continue
            }
            if ($stopFailed -and -not $ph.Always) {
                Write-Verbose "  Skipping '$($ph.Label)' — an earlier phase of this run failed."
                continue
            }
            if ($ph.Pause) {
                # Assigned: Read-Host returns what the operator typed ('' for Enter), which must never join the [bool] output
                # (live rows MSIBUSY and ASSISTED: ('', $true) made '-not $ok' false for an incomplete watched run).
                $null = Read-Host "  $($ph.Label) — press Enter to continue"
                continue
            }
            if ($ph.DepPhase -and $skipDepPhases) {
                Write-Verbose "  Skipping '$($ph.Label)' — dependencies are pre-installed in the checkpoint."
                continue
            }
            # Every phase runs as SYSTEM (the Intune account; bitness and launcher parity come from the
            # Intune-parity runner phases, not from this primitive). For an interactive phase PSADT's own
            # deploy mode renders its GUI in the logged-on user's session (a real desktop is ensured above).
            # The guest runner's limit for this phase: RunnerTimeoutMinutes (a host constant the caller also passes to the
            # runner as -TimeoutMinutes) or the runner's default 25; the phase backstop stays 5 minutes above it (25/30, 35/40).
            $runnerLimit = 25
            $phaseArgs = @{ Session = $session; Command = $ph.Command; Label = $ph.Label }
            $rtm = 0
            if ($null -ne $ph.RunnerTimeoutMinutes) {
                if ([int]::TryParse([string]$ph.RunnerTimeoutMinutes, [ref]$rtm) -and $rtm -ge 1 -and $rtm -le 235) {
                    $runnerLimit = $rtm
                    $phaseArgs['TimeoutMinutes'] = $rtm + 5
                }
                else { Write-Verbose "  Phase '$($ph.Label)': RunnerTimeoutMinutes '$($ph.RunnerTimeoutMinutes)' is not 1-235; the default limits apply." }
            }
            $phaseWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $exit = Invoke-Win32ToolkitGuestPhase @phaseArgs
            # The record keeps the phases that ran (never a Pause or a skipped phase), at most 20.
            if ($timing.Phases.Count -lt 20) { $timing.Phases.Add(@{ Label = [string]$ph.Label; Seconds = [math]::Round($phaseWatch.Elapsed.TotalSeconds, 1) }) }
            # 267009 (SCHED_S_TASK_RUNNING: stopped at its timeout) / 267011 (SCHED_S_TASK_HAS_NOT_RUN) are
            # not exit codes of the phase: it did not finish. Whatever IgnoreExit says, stop here.
            if ($exit -in 267009, 267011) {
                $why = if ($exit -eq 267009) { 'was still running at its timeout and was stopped' } else { 'never started' }
                Write-Warning "Guest phase '$($ph.Label)' did not finish (it $why, code $exit). The remaining phases are skipped so they do not overlap it; this run gives no result."
                $incomplete = $true
                break
            }
            # A phase may declare its success codes (PSADT/Intune: 0, 1707, 3010, 1641); otherwise only 0 is.
            $okExit = if ($ph.SuccessExitCodes) { @($ph.SuccessExitCodes) } else { @(0) }
            if (-not $ph.IgnoreExit -and $okExit -notcontains $exit) {
                # 1460 = the guest runner stopped the package at its $runnerLimit-minute limit (New-Win32ToolkitPackageRunnerScript).
                # The phase names the likely cause with ParityHint, a host constant set by Test-Win32ToolkitProject
                # (never data); the texts are constants here (installer-identity PR 2, L16).
                $hint = ''
                if ($exit -eq 1460) {
                    # A watched run: -TestMode Interactive overrides HyperVTestMode; a non-interactive host still runs
                    # unattended (Get-Win32ToolkitTestMode).
                    $watchedNeeds = ' (Test-Win32ToolkitProject -TestMode Interactive, or Interactive as the Hyper-V run mode under Run a test in the menu, from an interactive console)'
                    switch ([string]$ph.ParityHint) {
                        'Dialog41'    { $hint = ' In an unattended Intune-parity run this usually means a PSADT dialog was waiting for the user signed in to the VM: PSADT 4.1 shows its welcome dialog in Auto mode when a user is signed in and the app has no processes to close. Run the test watched to see and answer it' + $watchedNeeds + ', or list the app''s process in ProcessesToClose; the PSADT log under Sandbox\Logs shows the last dialog it opened.' }
                        'Dialog'      { $hint = ' In an unattended Intune-parity run this often means a PSADT dialog was waiting for the user signed in to the VM (for example because a listed process to close was running), or the installer itself did not finish. Run the test watched to see it' + $watchedNeeds + '; the PSADT log under Sandbox\Logs shows where it stopped.' }
                        'Uninstaller' {
                            if ($runnerLimit -gt 30) {
                                $hint = " The uninstall was still running after $runnerLimit minutes, longer than the device's 30-minute uninstaller limit: a project created with this win32-toolkit version stops an EXE uninstaller after 30 minutes with exit code 69113, so this is a project created before that (re-create it), or a step that limit does not cover, for example an MSI uninstall. The PSADT log under Sandbox\Logs shows the command it was running."
                            }
                            else {
                                $hint = " The uninstaller, or a child process it waits for, was still running at the test runner's $runnerLimit-minute limit; on devices, a project created with this win32-toolkit version stops the uninstaller at 30 minutes (exit code 69113 when the uninstaller itself is still running; a child process still running then is stopped and the uninstaller's own exit code counts). The PSADT log under Sandbox\Logs shows the command it was running."
                            }
                        }
                    }
                }
                # A package with Enforce prior-install rules removes the prior first (installer-identity PR 3, live row TIMEOUT):
                # its uninstaller may run for up to 30 minutes of the limit (on a device it is then stopped with 69108).
                if ($exit -eq 1460 -and $ph.PriorRemoval) {
                    $hint += " This package removes a prior install before it installs: that uninstaller may run for up to 30 minutes (a device then stops it with exit code 69108); the PSADT log under Sandbox\Logs names it."
                }
                # What another code means, when the caller's phase says so (ExitMeaning: host constants per code, e.g. the
                # remove-prior codes 69101-69112 and 1618 of a package with prior-install rules; live rows TIMEOUT, RC2-BLOCK).
                $codeText = ''
                if ($ph.ExitMeaning -is [System.Collections.IDictionary] -and $ph.ExitMeaning.Contains([int]$exit)) { $codeText = [string]$ph.ExitMeaning[[int]$exit] }
                if ($hint) { Write-Warning ("Guest phase '$($ph.Label)' exited with code 1460: the guest runner stopped the package at its $runnerLimit-minute limit." + $hint) }
                elseif ($exit -eq 69113 -and [string]$ph.ParityHint -eq 'Uninstaller') {
                    Write-Warning "Guest phase '$($ph.Label)' exited with code 69113: the package stopped the app's EXE uninstaller at the device's 30-minute limit, as a device would. The detection tattoo stays, so Intune would keep reporting the app as installed. The PSADT log under Sandbox\Logs names the uninstaller."
                }
                elseif ($codeText) { Write-Warning "Guest phase '$($ph.Label)' exited with code ${exit}: $codeText." }
                else { Write-Warning "Guest phase '$($ph.Label)' exited with code $exit." }
                # The test record says how an Intune-parity phase ended (R6 #3): a 69113 (the device's limit, as on a device)
                # and a 1460 (the test's own limit) otherwise look alike outside the PSADT logs. Constant texts.
                if ($null -ne $ParityExitNote -and -not [string]::IsNullOrEmpty([string]$ph.ParityHint)) {
                    $meaning = if ($exit -eq 1460) { ": the test's own $runnerLimit-minute limit for this phase was reached and the package was stopped." }
                               elseif ($exit -eq 69113 -and [string]$ph.ParityHint -eq 'Uninstaller') { ": the app's own uninstaller was still running at the device's 30-minute limit and was stopped." }
                               elseif ($codeText) { ": $codeText." }
                               else { '.' }
                    $ParityExitNote.Add("Intune-parity phase '$($ph.Label)' exited with code $exit$meaning")
                }
                if ($ph.DepPhase) {
                    Write-Warning 'A declared dependency failed to install: the app phases are skipped (Intune would not install the app either).'
                    $depFailed = $true
                }
                elseif ($ph.StopRunOnFailure) {
                    Write-Warning "Guest phase '$($ph.Label)' failed: the later phases of this run are skipped (only log collection runs)."
                    $stopFailed = $true
                }
            }
            # A SUCCESSFUL dep install is the moment to freeze the deps checkpoint (opt-in feature): the
            # image now equals clean-base + this exact dependency set. Only one clean-base+deps-* is kept.
            # A failure here is non-fatal — the run continues exactly as without the feature.
            if ($ph.DepPhase -and $createDepsCheckpoint -and $exit -eq 0) {
                try {
                    Get-VMCheckpoint -VMName $VMName -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like 'clean-base+deps-*' } |
                        Remove-VMCheckpoint -ErrorAction SilentlyContinue
                    # The checkpoint keeps the VM's automatic-checkpoint setting: off, like every checkpoint the toolkit takes (D5).
                    Set-VM -Name $VMName -CheckpointType Standard -AutomaticCheckpointsEnabled $false -ErrorAction Stop
                    Checkpoint-VM -VMName $VMName -SnapshotName $depsCpName -ErrorAction Stop
                    $effectiveCheckpoint  = $depsCpName
                    $createDepsCheckpoint = $false
                    Write-Host "✓ Deps checkpoint '$depsCpName' created — later runs of this project skip the dependency install." -ForegroundColor Green
                }
                catch {
                    Write-Warning "Could not create the deps checkpoint (run continues without it): $($_.Exception.Message)"
                }
            }
        }

        Write-Verbose "Copying results back to the project..."
        $teardownWatch = [System.Diagnostics.Stopwatch]::StartNew()
        # An incomplete run still brings its logs back for inspection, but never an install capture: the
        # capture of a phase that did not finish is not trusted.
        $copyOut = if ($incomplete) { @($Output | Where-Object { $_ -notlike '*InstallationChanges_*' }) } else { @($Output) }
        if ($copyOut.Count -gt 0) {
            $guestGlobs = $copyOut | ForEach-Object { Join-Path 'C:\PSADT' $_ }
            $copyArgs = @{ Session = $session; GuestPath = $guestGlobs; Destination = $(if ($ResultDestination) { $ResultDestination } else { $ProjectPath }); GuestRoot = 'C:\PSADT' }
            if ($ResultAllowedEntry) { $copyArgs['AllowedEntry'] = $ResultAllowedEntry }
            if ($ResultMaxEntryBytes -gt 0) { $copyArgs['MaxEntryBytes'] = $ResultMaxEntryBytes }
            if ($ResultMaxTotalBytes -gt 0) { $copyArgs['MaxTotalBytes'] = $ResultMaxTotalBytes }
            Copy-Win32ToolkitResultsFromGuest @copyArgs
        }

        return (-not $incomplete)
    }
    catch {
        # Fail closed (C-2, speed-up PR 3): a lease timeout or another W32T error is the caller's, never a quiet $false.
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        # The message can carry guest data (a file name, a remote error): no control or bidi character reaches the console.
        Write-Warning ('Hyper-V run failed: ' + ($_.Exception.Message -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', '?'))
        return $false
    }
    finally {
        # Revert to the EFFECTIVE checkpoint: with the deps feature that leaves the VM clean-with-deps
        # (still never holding app/test state), and the R2 marker then matches the next run of the same
        # project for the single-revert skip. Only while this run holds the VM's lease (speed-up PR 3, A-1): without it
        # no session was opened, and the VM may be another process's.
        $tdInfo = @{}
        # Speed-up PR 4: $true once a background restore took the teardown, and the lease, over.
        $handedOver = $false
        try {
            if ($null -ne $lease) {
                # Asynchronous teardown (D13, A-14): only when On, unattended, after an open, and while an owner (Show- or
                # Invoke-Win32Toolkit) is running that joins the restore before it returns. The session is closed now; the
                # restore and the lease go to a background job. Otherwise, or when no job could start: the restore below.
                if ($asyncTeardown -and -not $needsDesktop -and $null -ne $session) {
                    $owner = $null
                    try { $owner = Get-Win32ToolkitAsyncTeardownOwner }
                    catch {
                        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                        $owner = $null
                    }
                    if ($null -ne $owner) {
                        $null = Remove-Win32ToolkitHyperVSession -Session $session
                        $session = $null
                        # Saved parking (speed-up PR 4, D9) applies to the background restore too.
                        $park = Test-Win32ToolkitHyperVTeardownPark
                        $started = Start-Win32ToolkitHyperVBackgroundRestore -VMName $VMName -CheckpointName $effectiveCheckpoint -Lease $lease -Kind Teardown -Info $tdInfo -NoStart:($park -is [bool] -and $park)
                        $handedOver = $started -is [bool] -and $started
                    }
                    else { Write-Verbose 'HyperVAsyncTeardown is On, but no TUI session or Invoke-Win32Toolkit run will wait for a background restore: the teardown restores now.' }
                }
                if (-not $handedOver) {
                    # An unattended run's VM may be parked Saved (speed-up PR 4, D9, HyperVTeardownPark); never a watched run's.
                    $null = Remove-Win32ToolkitHyperVSession -Session $session -VMName $VMName -CheckpointName $effectiveCheckpoint -Revert -Info $tdInfo -Lease $lease -AllowPark:(-not $needsDesktop)
                }
            }
            # INTERACTIVE runs leave a vmconnect window attached to the reverted-but-running guest — the
            # operator can keep poking it after the teardown, invisibly dirtying the VM within the marker's
            # TTL. Never presume clean after an interactive run; unattended runs (no console, no operator)
            # keep the single-revert skip.
            if ($needsDesktop) { $script:HyperVCleanMarker = $null }
        }
        finally {
            # The lease is released after the teardown restore, whatever happened above - unless a background restore holds
            # it now (released when that restore is joined).
            if (-not $handedOver) { $null = Exit-Win32ToolkitHyperVLease -Lease $lease }
        }
        # Any unconsumed prebuild zips (job failed, run threw before the join) are cleaned here. The copy
        # helper normally consumed (deleted) the zip already, so only an existing one is removed: an absent
        # file must leave no PathNotFound record in $Error / a caller's -ErrorVariable (test campaign
        # 2026-10-21), while a real delete failure (a locked file) is still recorded.
        foreach ($k in $zipJobs.Keys) {
            if ($zipJobs[$k].Job) { Remove-Job -Job $zipJobs[$k].Job -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $zipJobs[$k].Path) { Remove-Item -LiteralPath $zipJobs[$k].Path -Force -ErrorAction SilentlyContinue }
        }
        # The record's teardown and total timing, handed to the caller (speed-up PR 1): best effort, never throws.
        try {
            # An asynchronous teardown (speed-up PR 4) is not timed: its restore ends after this record.
            if ($null -ne $teardownWatch -and -not $handedOver) { $timing.TeardownSeconds = [math]::Round($teardownWatch.Elapsed.TotalSeconds, 1) }
            # The mode the teardown restore used (speed-up PR 2), or the background restore runs (PR 4); $null when no
            # teardown restore ran.
            $timing.RevertMode = if ($tdInfo['Restored'] -eq $true) { $tdInfo['RevertMode'] } elseif ($handedOver) { $tdInfo['Mode'] } else { $null }
            $timing.TotalSeconds = [math]::Round($runWatch.Elapsed.TotalSeconds, 1)
            if ($null -ne $RunInfo) {
                $RunInfo['Timing'] = $timing
                $RunInfo['Lane'] = $lane
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Hyper-V run record: the timings could not be handed over ($($_.Exception.Message))."
        }
        # Restore the caller's preference (the teardown restore above stays silenced), so this
        # never leaks to a later Publish/Azure-upload bar. Runs on both the return and the catch paths.
        $ProgressPreference = $prevProgress
    }
}
