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
    .PARAMETER ProjectPath
        The PSADT project under test (host path). Copied to C:\PSADT in the guest.
    .PARAMETER Phase
        Ordered phases to run, each an object with: Label, Command (a 5.1-safe guest command string),
        and optional IgnoreExit ([bool], default $false).
    .PARAMETER Output
        Project-relative globs to copy back from the guest after the phases (default the capture JSON +
        Sandbox\Logs).
    .PARAMETER BaselineProjectPath
        Update baseline-project mode: a second project copied read-only-in-effect to C:\PSADTOld.
    .PARAMETER VMName / Credential / CheckpointName
        Resolved from config / the stored guest credential when omitted.
    .OUTPUTS
        [bool] — $true if the run completed (individual phase failures are warned, not fatal, matching
        the Sandbox fire-and-forget semantics; callers judge results from the copied-back outputs).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$ProjectPath,
        [Parameter(Mandatory)] [object[]]$Phase,
        [string[]]$Output = @('Documentation\InstallationChanges_*.json', 'Documentation\Targeted_Documentation_Log_*.txt', 'Sandbox\Logs\*'),
        [string]$BaselineProjectPath,
        [string]$VMName,
        [pscredential]$Credential,
        [string]$CheckpointName = 'clean-base'
    )

    if (-not $VMName)     { $VMName = Get-Win32ToolkitConfigValue -Name 'HyperVVMName' -Default 'win32tk-golden' }
    if (-not $CheckpointName) { $CheckpointName = Get-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Default 'clean-base' }
    if (-not $Credential) { $Credential = Get-Win32ToolkitGuestCredential }
    if (-not $Credential) {
        throw "No Hyper-V guest credential is configured. Run New-Win32ToolkitTestVM first (it stores the credential), or pass -Credential."
    }

    $session = $null
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
    # in the copy helper, exactly as before.
    $zipJobs = @{}
    $canThreadJob = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
    if ($canThreadJob) {
        $zipBuilder = {
            param($src, $dst)
            Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
            [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $dst, [System.IO.Compression.CompressionLevel]::NoCompression, $false)
            $dst
        }
        $projZipPath = Join-Path ([System.IO.Path]::GetTempPath()) ('w32proj_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
        $zipJobs['project'] = @{ Job = (Start-ThreadJob -ScriptBlock $zipBuilder -ArgumentList $ProjectPath, $projZipPath); Path = $projZipPath }
        if ($BaselineProjectPath) {
            $baseZipPath = Join-Path ([System.IO.Path]::GetTempPath()) ('w32proj_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
            $zipJobs['baseline'] = @{ Job = (Start-ThreadJob -ScriptBlock $zipBuilder -ArgumentList $BaselineProjectPath, $baseZipPath); Path = $baseZipPath }
        }
    }
    # Joins a prebuild job and returns its zip path — or $null (build-inline fallback) on any job error.
    $joinZip = {
        param($key)
        if (-not $zipJobs.ContainsKey($key)) { return $null }
        try {
            $null = Receive-Job -Job $zipJobs[$key].Job -Wait -ErrorAction Stop
            return $zipJobs[$key].Path
        }
        catch {
            Write-Verbose "Zip prebuild '$key' failed ($($_.Exception.Message)) — building inline."
            Remove-Item -LiteralPath $zipJobs[$key].Path -Force -ErrorAction SilentlyContinue
            return $null
        }
    }

    try {
        # Interactive phases need a logged-in desktop, so ask the session to ensure/recover one.
        $needsDesktop = @($Phase | Where-Object { $_.Interactive }).Count -gt 0

        Write-Verbose "Reverting '$VMName' to '$effectiveCheckpoint' and connecting over PowerShell Direct..."
        $session = New-Win32ToolkitHyperVSession -VMName $VMName -Credential $Credential -CheckpointName $effectiveCheckpoint -EnsureDesktop:$needsDesktop

        Write-Verbose "Copying project into the guest (C:\PSADT)..."
        Copy-Win32ToolkitProjectToGuest -Session $session -ProjectPath $ProjectPath -GuestPath 'C:\PSADT' -PrebuiltZip (& $joinZip 'project')
        if ($BaselineProjectPath) {
            # -ReadOnly reproduces the Sandbox <ReadOnly>true</ReadOnly> mount, so the baseline's own PSADT
            # run can't write into C:\PSADTOld on Hyper-V while the same run fails under Sandbox.
            Write-Verbose 'Copying the update baseline into the guest (C:\PSADTOld, read-only)...'
            Copy-Win32ToolkitProjectToGuest -Session $session -ProjectPath $BaselineProjectPath -GuestPath 'C:\PSADTOld' -ReadOnly -PrebuiltZip (& $joinZip 'baseline')
        }

        # Deps are baked into the restored image: remove the in-guest installer script so the CAPTURE
        # script (which installs deps in-script, not as a tagged phase) skips them too.
        if ($skipDepPhases) {
            Invoke-Command -Session $session -ScriptBlock {
                param($p) Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            } -ArgumentList 'C:\PSADT\Sandbox\InstallDependencies.ps1' -ErrorAction SilentlyContinue
        }

        # If any phase is interactive, open the VM console so the operator can watch the PSADT GUI.
        if ($needsDesktop) {
            Write-Verbose 'Opening the VM console (vmconnect) for interactive GUI testing...'
            Start-Process -FilePath 'vmconnect.exe' -ArgumentList 'localhost', $VMName -ErrorAction SilentlyContinue
        }

        foreach ($ph in $Phase) {
            if ($ph.Pause) {
                Read-Host "  $($ph.Label) — press Enter to continue"
                continue
            }
            if ($ph.DepPhase -and $skipDepPhases) {
                Write-Verbose "  Skipping '$($ph.Label)' — dependencies are pre-installed in the checkpoint."
                continue
            }
            # Every phase runs as SYSTEM (the Intune context). For an interactive phase PSADT's own deploy
            # mode renders its GUI in the logged-on user's session (a real desktop is ensured above).
            $exit = Invoke-Win32ToolkitGuestPhase -Session $session -Command $ph.Command -Label $ph.Label
            if (-not $ph.IgnoreExit -and $exit -ne 0) {
                Write-Warning "Guest phase '$($ph.Label)' exited with code $exit."
            }
            # A SUCCESSFUL dep install is the moment to freeze the deps checkpoint (opt-in feature): the
            # image now equals clean-base + this exact dependency set. Only one clean-base+deps-* is kept.
            # A failure here is non-fatal — the run continues exactly as without the feature.
            if ($ph.DepPhase -and $createDepsCheckpoint -and $exit -eq 0) {
                try {
                    Get-VMCheckpoint -VMName $VMName -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like 'clean-base+deps-*' } |
                        Remove-VMCheckpoint -ErrorAction SilentlyContinue
                    Set-VM -Name $VMName -CheckpointType Standard -ErrorAction Stop
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
        $guestGlobs = $Output | ForEach-Object { Join-Path 'C:\PSADT' $_ }
        Copy-Win32ToolkitResultsFromGuest -Session $session -GuestPath $guestGlobs -Destination $ProjectPath -GuestRoot 'C:\PSADT'

        return $true
    }
    catch {
        Write-Warning "Hyper-V run failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        # Revert to the EFFECTIVE checkpoint: with the deps feature that leaves the VM clean-with-deps
        # (still never holding app/test state), and the R2 marker then matches the next run of the same
        # project for the single-revert skip.
        Remove-Win32ToolkitHyperVSession -Session $session -VMName $VMName -CheckpointName $effectiveCheckpoint -Revert
        # INTERACTIVE runs leave a vmconnect window attached to the reverted-but-running guest — the
        # operator can keep poking it after the teardown, invisibly dirtying the VM within the marker's
        # TTL. Never presume clean after an interactive run; unattended runs (no console, no operator)
        # keep the single-revert skip.
        if ($needsDesktop) { $script:HyperVCleanMarker = $null }
        # Any unconsumed prebuild zips (job failed, run threw before the join) are cleaned here.
        foreach ($k in $zipJobs.Keys) {
            if ($zipJobs[$k].Job) { Remove-Job -Job $zipJobs[$k].Job -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $zipJobs[$k].Path -Force -ErrorAction SilentlyContinue
        }
        # Restore the caller's preference (the teardown Restore-VMCheckpoint above stays silenced), so this
        # never leaks to a later Publish/Azure-upload bar. Runs on both the return and the catch paths.
        $ProgressPreference = $prevProgress
    }
}
