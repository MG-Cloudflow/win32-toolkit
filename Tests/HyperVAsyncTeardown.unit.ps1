<#
    Hyper-V speed-up PR 4 (D13, A1, A-14, V-1, V-2, V-15, V-16): the asynchronous teardown.

      [a] HyperVAsyncTeardown Off (the default; also any value but On): the teardown restores before the run returns,
          then the lease is released (call order); no background job.
      [b] On, but no owner (a direct Test-Win32ToolkitProject call), or a stale owner record whose command is not on the
          call stack (V-2): synchronous, no job.
      [c] On + an owner + an unattended run: the run returns while the background restore still runs (a job double that
          waits on a gate), exactly one [bool]; Timing.TeardownSeconds $null, RevertMode the job's mode; the session is
          closed and the VM's lease is still held (by the job record).
      [d] The next Enter-Win32ToolkitHyperVLease of the VM joins the restore first: it is not nested in the job's lease,
          and its PreviousGeneration is the job lease's generation (A-2: the marker counts).
     [d2] A PROJECT lease (TestProjectLease, the lane runner) joins a pending restore too, before the project's lock
          file is opened (the restore holds its VM's lease: project before VM, V-18).
      [e] The clean marker is stamped by THIS session at the join (VM Id, checkpoint, the job lease's epoch and
          generation, Parked Running), never by the job: the job script has no HyperVCleanMarker text; the job's
          warnings are relayed. StampedAt = the job's CompletedAt (when the restore returned), not the join time: pinned
          with a join 2 s after the job ended.
      [f] A failed job (it throws, or returns more than the result): one FAILED warning, no marker, the lease released.
      [g] An interactive phase list: synchronous even when On (a watched run is never async).
      [h] No Start-ThreadJob: synchronous.
      [j] The job script in a clean runspace (V-15: no module, module autoloading off, Hyper-V cmdlet doubles defined
          there): TurnOffFirst landing Saved / Running / Off, Legacy, -NoStart and the A-9 path run without a
          CommandNotFoundException and emit exactly one result object; the precondition is read in THIS session (a
          checkpoint that reads True, or cannot be read, prints the advisory once, the same text as
          Restore-Win32ToolkitTestVMCheckpoint, and the job gets -Mode Legacy -SkipPrecondition).
      [o] C-12 output shapes (V-1): every Wait-Win32ToolkitHyperVTeardown parameter set emits nothing although the job
          returns its result object; Start-Win32ToolkitHyperVBackgroundRestore emits exactly one [bool]; -ReleaseOwner
          $null and a token that is not the live one do nothing. Start- joins a restore still pending (of another VM)
          before it records the new one: no orphaned job, its lease released.
      [p] (P4-2) Saved parking: the job gets -NoStart under HyperVTeardownPark Saved (never under Legacy, A-15); the join
          stamps Parked Saved only when the VM is Saved then.
      [pw] (P4-3) The capture pre-warm: Off (absent, Off, anything but On) = nothing; On + HyperV = the VM's lease held and a
          background restore (Kind Prewarm); the capture's own lease joins it and its open skips the restore on the marker;
          -Prewarm releases the hold; Sandbox, HyperVDepsCheckpoint On, no thread jobs, a held pre-warm, a job that cannot
          start = nothing held; a busy VM = the lease error is thrown. The pre-warm never parks the VM (no -NoStart, even
          under HyperVTeardownPark Saved: the capture follows).
      [w] Get-Win32ToolkitAsyncTeardownOwner: no record, a live one, a stale one.
      [s] Static: the two owners (Show-Win32Toolkit, Invoke-Win32Toolkit) register right before their try with the
          null-safe pattern and join as the last statement of their finally (after the reset/restore lines); New-,
          Complete-Win32ToolkitManualApp and Invoke-Win32ToolkitFinalize are no owners (V-16). File hygiene of the new
          helpers.

    No Hyper-V: every Hyper-V cmdlet is a double, every background job runs a double script (never the restore helper
    against a real VM), lock files go to a temp folder (the lease's hidden -LockRoot), HKCU is shadowed. The suite
    asserts at the end that the Hyper-V module was never imported.

    Run:  pwsh -File Tests\HyperVAsyncTeardown.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: no PSScriptAnalyzer warning in the suites).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows keep the real command names')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'test shadows mirror the Hyper-V cmdlets'' -Confirm parameter')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'test shadows take a fake credential')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '', Justification = 'test shadows take a fake credential')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Start-Process (vmconnect) and Get-Command (no thread jobs) are shadowed on purpose')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\Restore-Win32ToolkitTestVMCheckpoint.ps1')
. (Join-Path $repo 'Private\Write-Win32ToolkitCheckpointAdvisory.ps1')
. (Join-Path $repo 'Private\Start-Win32ToolkitHyperVBackgroundRestore.ps1')
. (Join-Path $repo 'Private\Wait-Win32ToolkitHyperVTeardown.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAsyncTeardownOwner.ps1')
. (Join-Path $repo 'Private\Enter-Win32ToolkitHyperVLease.ps1')
. (Join-Path $repo 'Private\Exit-Win32ToolkitHyperVLease.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitHyperVRun.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitHyperVTeardownPark.ps1')   # P4-2: the real park decision (HKCU in memory)
. (Join-Path $repo 'Private\Start-Win32ToolkitHyperVPrewarm.ps1')        # P4-3: the capture pre-warm
Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue

# -- shadows ----------------------------------------------------------------------------------------------------------
$script:cfg = @{}
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
# The provider's record helpers, inert.
function Get-Win32ToolkitHyperVLane { param($VMName, $CheckpointName, $VM) }
function Get-Win32ToolkitZipContentHash { param($ZipPath) }
function Get-Win32ToolkitCheckpointAttestation { param($Session, $VMName, $CheckpointName, $VMId, $CheckpointId, $CreationTimeUtcTicks, [switch]$AllowLive, [switch]$AllowStore, $SignedInAnswer) }
function Test-Win32ToolkitVMConnectOpen { param($VMName, $VMId) $false }
# The checkpoint's automatic-checkpoint setting: $false (the fast path) unless a case says otherwise.
$script:auto = $false
function Get-Win32ToolkitCheckpointAutoSetting { param($CheckpointId) $script:auto }

# Hyper-V doubles of THIS session (the join reads Get-VM; Start- reads Get-VMCheckpoint). Never a real cmdlet.
$vmId = '0e5f9e66-1111-2222-3333-444455556666'
$cpId = '29613cba-d62f-4998-a421-df2e124a2b4f'
$script:vmState = 'Running'
$script:hvLog = [System.Collections.Generic.List[string]]::new()
function Get-VM { param($Name, $ErrorAction) [pscustomobject]@{ Name = $Name; Id = [guid]$script:vmIdNow; State = $script:vmState; Uptime = [timespan]::FromHours(1); AutomaticCheckpointsEnabled = $false } }
$script:vmIdNow = $vmId
$script:cpCount = 1
function Get-VMCheckpoint { param($VMName, $Name, $ErrorAction) for ($i = 0; $i -lt $script:cpCount; $i++) { [pscustomobject]@{ Name = $Name; Id = [guid]$cpId; VMId = [guid]$vmId; VMName = $VMName } } }
function Restore-VMCheckpoint { param($VMName, $Name, $Confirm, $ErrorAction) $script:hvLog.Add('restore') }
function Stop-VM { param($Name, [switch]$TurnOff, [switch]$Force, $Confirm, $ErrorAction) $script:hvLog.Add('stop') }
function Start-VM { param($Name, $Confirm, $ErrorAction) $script:hvLog.Add('start') }
function Set-VM { param($Name, $AutomaticCheckpointsEnabled, $Confirm, $ErrorAction) $script:hvLog.Add('set-vm') }

# Background jobs: Start-ThreadJob records what it was given and runs a DOUBLE script in a real thread job (so
# Receive-Job, the job states and the relayed streams are real); the restore helper never runs here. jobMode: ok, fail,
# extra (two objects). gate: a ManualResetEventSlim the double waits on. CaptureOnly: nothing is started.
$realStj = Get-Command -Name Start-ThreadJob -CommandType Cmdlet | Select-Object -First 1
$script:jobCalls = [System.Collections.Generic.List[object]]::new()
$script:jobMode = 'ok'; $script:gate = $null; $script:jobLanded = 'Saved'; $script:captureOnly = $false
# What the last job double returned as CompletedAt (UTC), written from the job's thread.
$script:jobSync = [hashtable]::Synchronized(@{})
function Start-ThreadJob {
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList)
    $script:jobCalls.Add([pscustomobject]@{ ScriptBlock = $ScriptBlock; ArgumentList = $ArgumentList })
    if ($script:captureOnly) { return [pscustomobject]@{ State = 'NotStarted'; Id = -1 } }
    $double = {
        param([string]$JobMode, $Gate, [string]$Landed, [bool]$NoStart, $Sync)
        if ($null -ne $Gate) { $null = $Gate.Wait(60000) }
        Write-Warning 'job warning (double)'
        if ($JobMode -eq 'fail') { throw 'simulated restore failure' }
        $r = [pscustomobject]@{ Mode = 'TurnOffFirst'; Landed = $Landed; TurnOffSeconds = 0.1; RestoreSeconds = 0.2; StartSeconds = $null; Started = -not $NoStart }
        $at = [datetime]::UtcNow
        $r.PSObject.Properties.Add([psnoteproperty]::new('CompletedAt', $at))
        if ($null -ne $Sync) { $Sync['CompletedAt'] = $at }
        $r
        if ($JobMode -eq 'extra') { 'an extra object' }
    }
    & $realStj -ScriptBlock $double -ArgumentList $script:jobMode, $script:gate, $script:jobLanded, ([bool]$ArgumentList[4]), $script:jobSync
}

# The VM lease: the real Enter/Exit with lock files in a temp folder (never %ProgramData%), one attempt, the VM Id given.
$BASE = Join-Path ([System.IO.Path]::GetTempPath()) ('w32async_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $BASE -Force
$ROOT = Join-Path $BASE 'locks'
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Owner.Value
$trust = if ($me -in 'S-1-5-32-544', 'S-1-5-18') { @{} } else { @{ TrustedOwnerSid = @($me) } }
$realEnter = ${function:Enter-Win32ToolkitHyperVLease}
function Enter-Win32ToolkitHyperVLease {
    param($VMName, $VMId, $ProjectPath, $Purpose, [scriptblock]$OpenStream)
    $a = @{ Purpose = $Purpose; LockRoot = $ROOT; WaitSeconds = 0 } + $trust
    if ($ProjectPath) { $a['ProjectPath'] = $ProjectPath } else { $a['VMName'] = $VMName; $a['VMId'] = $vmId }
    if ($OpenStream) { $a['OpenStream'] = $OpenStream }
    & $realEnter @a
}
$lockFile = Join-Path $ROOT "hyperv-$vmId.lock"
# $true when another process could take the lease now (the file is not held).
function Test-Free { try { $fs = [System.IO.FileStream]::new($lockFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read); $fs.Dispose(); $true } catch { $false } }

# The provider's session helpers and guest work, logged.
$script:log = [System.Collections.Generic.List[string]]::new()
function New-Win32ToolkitHyperVSession {
    param($VMName, $Credential, $CheckpointName, [switch]$SkipRevert, [switch]$EnsureDesktop, [hashtable]$Info, $Lease)
    $script:log.Add('open')
    $script:HyperVCleanMarker = $null
    if ($null -ne $Info) { $Info['RevertSkipped'] = $false; $Info['Warm'] = $true; $Info['VM'] = $null }
    'SESS'
}
function Copy-Win32ToolkitProjectToGuest { param($Session, $ProjectPath, $GuestPath, [switch]$ReadOnly, $PrebuiltZip) }
function Copy-Win32ToolkitResultsFromGuest { param($Session, $GuestPath, $Destination, $GuestRoot) }
function Invoke-Win32ToolkitGuestPhase { param($Session, $Command, $Label) $script:log.Add("phase:$Label"); 0 }
function Remove-Win32ToolkitHyperVSession {
    param($Session, $VMName, $CheckpointName, [switch]$Revert, [hashtable]$Info, $Lease, [switch]$AllowPark)
    $script:log.Add("teardown:session=${Session}:revert=$($Revert.IsPresent)")
    if ($Revert -and $null -ne $Info) { $Info['Restored'] = $true; $Info['RevertMode'] = 'Legacy' }
}
function Start-Process { param($FilePath, $ArgumentList, $ErrorAction) $script:log.Add('vmconnect') }
$cred = [pscredential]::new('w32admin', (New-Object System.Security.SecureString))
$proj = Join-Path $BASE 'proj'
$null = New-Item -ItemType Directory -Path $proj -Force
# One provider run; the owner (when -Owner) is this very function, so it is on the call stack.
function Invoke-AsOwner {
    param([object[]]$Phases = @(@{ Label = 'Install'; Command = '0' }), [switch]$Owner)
    if ($Owner) { $script:W32TAsyncTeardownOwner = @{ Token = [guid]::NewGuid(); Command = 'Invoke-AsOwner' } }
    $script:log.Clear(); $script:jobCalls.Clear()
    $ri = @{}
    $v = @(Invoke-Win32ToolkitHyperVRun -ProjectPath $proj -Phase $Phases -VMName 'vmA' -CheckpointName 'clean-base' -Credential $cred -RunInfo $ri -Verbose 4>&1 3>$null 6>$null)
    $o = @($v | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] })
    [pscustomobject]@{ Out = $o; Timing = $ri['Timing']; Log = ($script:log -join ' > '); Verbose = @($v | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
        One = ($o.Count -eq 1 -and $o[0] -is [bool]) }
}
function Reset-Case {
    $script:cfg = @{}; $script:W32TAsyncTeardownOwner = $null; $script:HyperVCleanMarker = $null; $script:jobMode = 'ok'; $script:gate = $null
    $script:jobLanded = 'Saved'; $script:captureOnly = $false; $script:auto = $false; $script:vmState = 'Running'; $script:cpCount = 1; $script:vmIdNow = $vmId
    if ($null -ne $script:HyperVPendingRestore) { $null = Wait-Win32ToolkitHyperVTeardown -VMName ([string]$script:HyperVPendingRestore['VMName']) 3>$null }
    $script:jobSync.Clear()
}

# -- [a] Off ----------------------------------------------------------------------------------------------------------
Write-Host '[a] HyperVAsyncTeardown Off (or anything but On): the teardown restores before the run returns' -ForegroundColor Cyan
foreach ($v in @($null, 'Off', 'on ', 'Yes')) {
    Reset-Case
    if ($null -ne $v) { $script:cfg['HyperVAsyncTeardown'] = $v }
    $x = Invoke-AsOwner -Owner
    # 'on ' is On after the trim (anything but On is Off; the compare ignores case and surrounding blanks).
    $wantAsync = $v -eq 'on '
    if ($wantAsync) {
        $ok = $x.One -and $script:jobCalls.Count -eq 1 -and $x.Log -eq 'open > phase:Install > teardown:session=SESS:revert=False'
        $null = Wait-Win32ToolkitHyperVTeardown -VMName 'vmA' 3>$null
        if ($ok) { Ok "'on ' (trimmed, any case) counts as On: the background restore" } else { Bad "'on ': log=$($x.Log) jobs=$($script:jobCalls.Count)" }
        continue
    }
    if ($x.One -and $x.Out[0] -and $script:jobCalls.Count -eq 0 -and $x.Log -eq 'open > phase:Install > teardown:session=SESS:revert=True' -and $x.Timing['TeardownSeconds'] -is [double] -and (Test-Free)) {
        Ok "HyperVAsyncTeardown $(if ($null -eq $v) { 'absent' } else { "'$v'" }): synchronous restore, the lease released, TeardownSeconds measured, no job"
    } else { Bad "value ${v}: log=$($x.Log) jobs=$($script:jobCalls.Count) td=$($x.Timing['TeardownSeconds']) free=$(Test-Free)" }
}

# -- [b] no owner / stale owner ----------------------------------------------------------------------------------------
Write-Host '[b] On without an owner, or with a stale owner record: synchronous' -ForegroundColor Cyan
Reset-Case; $script:cfg['HyperVAsyncTeardown'] = 'On'
$x = Invoke-AsOwner
if ($x.One -and $script:jobCalls.Count -eq 0 -and $x.Log -eq 'open > phase:Install > teardown:session=SESS:revert=True' -and (Test-Free) -and @($x.Verbose | Where-Object { $_ -like '*no TUI session or Invoke-Win32Toolkit run will wait*' }).Count -eq 1) {
    Ok 'On, no owner (a direct test): synchronous, one verbose line, the lease released'
} else { Bad "no owner: log=$($x.Log) jobs=$($script:jobCalls.Count) verbose=$($x.Verbose -join ' | ')" }
Reset-Case; $script:cfg['HyperVAsyncTeardown'] = 'On'
$script:W32TAsyncTeardownOwner = @{ Token = [guid]::NewGuid(); Command = 'Show-Win32Toolkit' }   # its finally never ran: not on the stack
$x = Invoke-AsOwner
if ($x.One -and $script:jobCalls.Count -eq 0 -and $x.Log -like '*teardown:session=SESS:revert=True' -and @($x.Verbose | Where-Object { $_ -like "*owner 'Show-Win32Toolkit' is not running any more*" }).Count -ge 1) {
    Ok 'a stale owner record (Show-Win32Toolkit, not on the call stack): synchronous (V-2)'
} else { Bad "stale owner: log=$($x.Log) jobs=$($script:jobCalls.Count) verbose=$($x.Verbose -join ' | ')" }

# -- [c] async ----------------------------------------------------------------------------------------------------------
Write-Host '[c] On + owner + unattended: the run returns while the restore runs; the job record holds the lease' -ForegroundColor Cyan
Reset-Case; $script:cfg['HyperVAsyncTeardown'] = 'On'
$script:gate = [System.Threading.ManualResetEventSlim]::new($false)
$x = Invoke-AsOwner -Owner
$pending = $script:HyperVPendingRestore
$jobState = if ($pending) { [string]$pending['Job'].State } else { '' }
if ($x.One -and $x.Out[0] -and $x.Log -eq 'open > phase:Install > teardown:session=SESS:revert=False' -and $script:jobCalls.Count -eq 1 -and $jobState -in 'NotStarted', 'Running') {
    Ok 'the run returned exactly one [bool] $true while the background restore is still running; the session was closed without a restore'
} else { Bad "async: out=$(@($x.Out | ForEach-Object { "$($_.GetType().Name):$_" }) -join ', ') log=$($x.Log) jobs=$($script:jobCalls.Count) state=$jobState" }
if ($x.Timing.ContainsKey('TeardownSeconds') -and $null -eq $x.Timing['TeardownSeconds'] -and $x.Timing['RevertMode'] -ceq 'TurnOffFirst') { Ok 'Timing: TeardownSeconds $null, RevertMode TurnOffFirst (the mode the job runs)' } else { Bad "timing: $($x.Timing | ConvertTo-Json -Compress -Depth 3)" }
$jobLease = if ($pending) { $pending['Lease'] } else { $null }
if ($pending -and $pending['Kind'] -eq 'Teardown' -and $pending['VMName'] -eq 'vmA' -and $pending['CheckpointName'] -eq 'clean-base' -and $jobLease -and -not $jobLease.Released -and -not (Test-Free) -and $null -eq $script:HyperVCleanMarker) {
    Ok 'the job record holds the run''s lease (not released, the lock file busy for other processes); no marker yet'
} else { Bad "record: kind=$($pending['Kind']) released=$($jobLease.Released) free=$(Test-Free) marker=$($null -ne $script:HyperVCleanMarker)" }
$jobSb = if ($script:jobCalls.Count) { [string]$script:jobCalls[0].ScriptBlock } else { '' }
$jobArgs = if ($script:jobCalls.Count) { @($script:jobCalls[0].ArgumentList) } else { @() }
if ($jobSb -match 'SkipPrecondition' -and $jobArgs.Count -eq 5 -and $jobArgs[1] -eq 'vmA' -and $jobArgs[2] -eq 'clean-base' -and $jobArgs[3] -ceq 'TurnOffFirst' -and $jobArgs[4] -eq $false -and
    [string]$jobArgs[0] -ceq [string]${function:Restore-Win32ToolkitTestVMCheckpoint}) {
    Ok 'the job gets the text of Restore-Win32ToolkitTestVMCheckpoint only, the resolved mode, -SkipPrecondition, no -NoStart'
} else { Bad "job args: $($jobArgs.Count) $($jobArgs[1]) $($jobArgs[2]) $($jobArgs[3]) $($jobArgs[4])" }

# -- [d] + [e] the next lease joins first; this session stamps the marker -------------------------------------------------
Write-Host '[d] the next Enter-Win32ToolkitHyperVLease of the VM joins the restore first; [e] this session stamps the marker' -ForegroundColor Cyan
$jobGen = $jobLease.Generation; $jobEpoch = $jobLease.Epoch
# Opens the gate 700 ms from now, from another thread (a real thread job: Start-ThreadJob is shadowed here).
$opener = & $realStj -ScriptBlock { param($g) Start-Sleep -Milliseconds 700; $null = $g.Set() } -ArgumentList $script:gate
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$got = @(Enter-Win32ToolkitHyperVLease -VMName 'vmA' -Purpose 'test run' 3>&1)
$elapsed = $watch.Elapsed.TotalMilliseconds
$null = Receive-Job -Job $opener -Wait -AutoRemoveJob
$warn = @($got | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
$next = @($got | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
$m = $script:HyperVCleanMarker
if ($next.Count -eq 1 -and $next[0].Nested -eq $false -and $next[0].PreviousGeneration -eq $jobGen -and $next[0].Generation -eq $jobGen + 1 -and $next[0].Epoch -eq $jobEpoch -and $elapsed -ge 500 -and
    $null -eq $script:HyperVPendingRestore -and $jobLease.Released) {
    Ok "the new lease waited for the job ($([int]$elapsed) ms), is not nested and follows the job lease's generation $jobGen (A-2)"
} else { Bad "next lease: count=$($next.Count) nested=$($next[0].Nested) prev=$($next[0].PreviousGeneration) gen=$($next[0].Generation) jobGen=$jobGen elapsed=$elapsed pending=$($null -ne $script:HyperVPendingRestore)" }
$doneAt = $script:jobSync['CompletedAt']
if ($m -and $m.VMName -eq 'vmA' -and $m.VMId -eq $vmId -and $m.CheckpointName -eq 'clean-base' -and $m.LeaseEpoch -eq $jobEpoch -and $m.LeaseGeneration -eq $jobGen -and $m.Parked -ceq 'Running' -and
    $m.StampedAt -is [datetime] -and $doneAt -is [datetime] -and $m.StampedAt -eq $doneAt.ToLocalTime()) {
    Ok 'the marker: VM Id, checkpoint, the job lease''s epoch and generation, Parked Running, StampedAt = the job''s CompletedAt'
} else { Bad "marker: $($m | ConvertTo-Json -Compress) completedAt=$doneAt" }
if (@($warn | Where-Object { $_ -eq 'job warning (double)' }).Count -eq 1) { Ok 'the job''s warning is relayed at the join' } else { Bad "warnings: $($warn -join ' | ')" }
if ($jobSb -notmatch 'HyperVCleanMarker' -and [string]$jobArgs[0] -notmatch 'HyperVCleanMarker' -and
    $jobSb -notmatch 'Write-Win32ToolkitCheckpointAdvisory|Get-Win32ToolkitCheckpointAutoSetting|Get-Win32ToolkitConfigValue') {
    Ok 'the job script (and the helper text it runs) never touches the marker; the job script calls no advisory, precondition or config helper'
} else { Bad 'the job script names the marker or a module helper' }
$null = Exit-Win32ToolkitHyperVLease -Lease $next[0]
$script:gate.Dispose()

# [e] StampedAt is the time the restore returned, not the time of the join: the job ends, 2 s pass, then the join.
Write-Host '[e] the marker''s StampedAt is the job''s CompletedAt, not the (later) join time' -ForegroundColor Cyan
Reset-Case; $script:cfg['HyperVAsyncTeardown'] = 'On'
$script:gate = [System.Threading.ManualResetEventSlim]::new($false)
$x = Invoke-AsOwner -Owner
$pe = $script:HyperVPendingRestore
$null = $script:gate.Set()
$ended = if ($pe) { @(Wait-Job -Job $pe['Job'] -Timeout 30).Count -eq 1 } else { $false }
Start-Sleep -Milliseconds 2000
$joinAt = Get-Date
$null = Wait-Win32ToolkitHyperVTeardown -VMName 'vmA' 3>$null
$m = $script:HyperVCleanMarker
$doneAt = $script:jobSync['CompletedAt']
if ($x.One -and $ended -and $m -and $doneAt -is [datetime] -and $m.StampedAt -eq $doneAt.ToLocalTime() -and $m.StampedAt -lt $joinAt.AddSeconds(-1)) {
    Ok "joined $([math]::Round(($joinAt - $m.StampedAt).TotalSeconds, 1)) s after the restore returned: StampedAt = CompletedAt, earlier than the join (a TUI-idle VM gets the 10-minute window from the restore, not from the join)"
} else { Bad "stamp: ended=$ended stamped=$($m.StampedAt.ToString('o')) completed=$(if ($doneAt) { $doneAt.ToLocalTime().ToString('o') }) join=$($joinAt.ToString('o'))" }
$script:gate.Dispose()

# [d2] A project lease joins a pending restore (of any VM) BEFORE the project's lock file is opened: the restore holds
# its VM's lease, and waiting for a project while holding a VM would invert the lock order (project before VM, V-18).
Write-Host '[d2] Enter-Win32ToolkitHyperVLease -ProjectPath joins a pending restore before it takes the project''s lock' -ForegroundColor Cyan
Reset-Case; $script:cfg['HyperVAsyncTeardown'] = 'On'
$script:gate = [System.Threading.ManualResetEventSlim]::new($false)
$x = Invoke-AsOwner -Owner
$pd = $script:HyperVPendingRestore
$jl = if ($pd) { $pd['Lease'] } else { $null }
$script:atOpen = $null
# The lock file's open (the lease's hidden -OpenStream; the same no-follow open as the default) records the state first.
$probeOpen = {
    param($p)
    $script:atOpen = [pscustomobject]@{ Pending = ($null -ne $script:HyperVPendingRestore); Released = [bool]$jl.Released; Free = (Test-Free); Marker = ($null -ne $script:HyperVCleanMarker) }
    $openError = 0
    $h = [W32TLeaseFileV2]::TryOpenLock($p, [int][System.IO.FileShare]::Read, [ref]$openError)
    if ($null -eq $h) { return [int]$openError }
    [System.IO.FileStream]::new($h, [System.IO.FileAccess]::ReadWrite)
}
$opener = & $realStj -ScriptBlock { param($g) Start-Sleep -Milliseconds 700; $null = $g.Set() } -ArgumentList $script:gate
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$pl = @(Enter-Win32ToolkitHyperVLease -ProjectPath $proj -Purpose 'test' -OpenStream $probeOpen 3>$null)
$elapsed = $watch.Elapsed.TotalMilliseconds
$null = Receive-Job -Job $opener -Wait -AutoRemoveJob
$a = $script:atOpen
if ($x.One -and $jl -and $pl.Count -eq 1 -and $pl[0].Kind -eq 'Project' -and $a -and -not $a.Pending -and $a.Released -and $a.Free -and $a.Marker -and $elapsed -ge 500 -and $null -eq $script:HyperVPendingRestore) {
    Ok "the project lease waited for the restore ($([int]$elapsed) ms); when its lock file was opened the restore was joined: no pending record, the job's VM lease released (free), the marker stamped"
} else { Bad "project join: lease=$($pl.Count)/$($pl[0].Kind) atOpen=$($a | ConvertTo-Json -Compress) elapsed=$([int]$elapsed) pending=$($null -ne $script:HyperVPendingRestore)" }
foreach ($l in $pl) { $null = Exit-Win32ToolkitHyperVLease -Lease $l }
$script:gate.Dispose()

# -- [f] a failed job ---------------------------------------------------------------------------------------------------
Write-Host '[f] a failed background restore: one FAILED warning, no marker, the lease released' -ForegroundColor Cyan
foreach ($mode in 'fail', 'extra') {
    Reset-Case; $script:cfg['HyperVAsyncTeardown'] = 'On'; $script:jobMode = $mode
    $x = Invoke-AsOwner -Owner
    $lz = $script:HyperVPendingRestore['Lease']
    $script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = $vmId; CheckpointName = 'clean-base'; StampedAt = Get-Date }   # a marker left from before must go
    $wv = $null
    $o = @(Wait-Win32ToolkitHyperVTeardown -VMName 'vmA' -WarningVariable wv 3>$null)
    $failed = @($wv | Where-Object { "$_" -like "The background restore of 'vmA' to 'clean-base' FAILED: *the next run restores it before starting." })
    if ($x.One -and $o.Count -eq 0 -and $failed.Count -eq 1 -and $null -eq $script:HyperVCleanMarker -and $lz.Released -and (Test-Free) -and $null -eq $script:HyperVPendingRestore) {
        Ok "job $(if ($mode -eq 'fail') { 'throws' } else { 'returns two objects' }): the FAILED warning, no marker, the lease released, nothing emitted"
    } else { Bad "${mode}: out=$($o.Count) warnings=$(@($wv) -join ' | ') marker=$($null -ne $script:HyperVCleanMarker) released=$($lz.Released) free=$(Test-Free)" }
}

# -- [g] watched run ----------------------------------------------------------------------------------------------------
Write-Host '[g] an interactive (watched) phase list: synchronous even when On and owned' -ForegroundColor Cyan
Reset-Case; $script:cfg['HyperVAsyncTeardown'] = 'On'
$x = Invoke-AsOwner -Owner -Phases @(@{ Label = 'Install'; Command = '0'; Interactive = $true })
if ($x.One -and $script:jobCalls.Count -eq 0 -and $x.Log -eq 'open > vmconnect > phase:Install > teardown:session=SESS:revert=True' -and (Test-Free)) { Ok 'watched: the teardown restores before the run returns, no job' } else { Bad "watched: log=$($x.Log) jobs=$($script:jobCalls.Count)" }

# -- [h] no ThreadJob ---------------------------------------------------------------------------------------------------
Write-Host '[h] no Start-ThreadJob: synchronous' -ForegroundColor Cyan
Reset-Case; $script:cfg['HyperVAsyncTeardown'] = 'On'
function Get-Command { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [string[]]$CommandType)
    if (@($Name) -contains 'Start-ThreadJob') { return $null }
    Microsoft.PowerShell.Core\Get-Command @PSBoundParameters }
try { $x = Invoke-AsOwner -Owner }
finally { Remove-Item Function:\Get-Command }
if ($x.One -and $script:jobCalls.Count -eq 0 -and $x.Log -eq 'open > phase:Install > teardown:session=SESS:revert=False > teardown:session=:revert=True' -and $x.Timing['TeardownSeconds'] -is [double] -and (Test-Free) -and $null -eq $script:HyperVPendingRestore) {
    Ok 'no thread jobs: Start- returns $false, the session closed, then the synchronous restore and the release'
} else { Bad "no threadjob: log=$($x.Log) jobs=$($script:jobCalls.Count) free=$(Test-Free)" }

# -- [j] the job script in a clean runspace ------------------------------------------------------------------------------
Write-Host '[j] the job script runs in a clean runspace (no module, autoloading off): every branch, one result object' -ForegroundColor Cyan
Reset-Case
$script:captureOnly = $true
$lj = Enter-Win32ToolkitHyperVLease -VMName 'vmA' -Purpose 'capture'
$null = Start-Win32ToolkitHyperVBackgroundRestore -VMName 'vmA' -CheckpointName 'clean-base' -Mode TurnOffFirst -Lease $lj -Kind Teardown
$script:HyperVPendingRestore = $null
$null = Exit-Win32ToolkitHyperVLease -Lease $lj
$script:captureOnly = $false
$jsText = [string]$script:jobCalls[-1].ScriptBlock
$helperText = [string]$script:jobCalls[-1].ArgumentList[0]
$hvDoubles = @'
$PSModuleAutoLoadingPreference = 'None'
$global:hv = [System.Collections.Generic.List[string]]::new()
function Get-VM { param($Name, $ErrorAction) $global:hv.Add('get-vm'); [pscustomobject]@{ Name = $Name; State = $global:state; AutomaticCheckpointsEnabled = $global:autoOnVm } }
function Stop-VM { param($Name, [switch]$TurnOff, [switch]$Force, $Confirm, $ErrorAction) $global:hv.Add('stop'); $global:state = 'Off' }
function Restore-VMCheckpoint { param($VMName, $Name, $Confirm, $ErrorAction) $global:hv.Add('restore'); $global:state = $global:landed; if ($global:autoAfter) { $global:autoOnVm = $true } }
function Start-VM { param($Name, $Confirm, $ErrorAction) $global:hv.Add('start'); $global:state = 'Running' }
function Set-VM { param($Name, $AutomaticCheckpointsEnabled, $Confirm, $ErrorAction) $global:hv.Add('set-vm'); $global:autoOnVm = $false }
'@
$runJob = {
    param([string]$Mode, [bool]$NoStart, [string]$Landed, [bool]$AutoAfter = $false)
    $ps = [powershell]::Create()
    try {
        $null = $ps.AddScript($hvDoubles).AddScript("`$global:state = 'Running'; `$global:landed = '$Landed'; `$global:autoOnVm = `$false; `$global:autoAfter = `$$AutoAfter")
        $null = $ps.Invoke(); $ps.Commands.Clear()
        $null = $ps.AddScript($jsText).AddArgument($helperText).AddArgument('vmA').AddArgument('clean-base').AddArgument($Mode).AddArgument($NoStart)
        $out = @($ps.Invoke())
        $ps.Commands.Clear()
        $hv = @($ps.AddScript('$global:hv').Invoke())
        [pscustomobject]@{ Out = $out; Errors = @($ps.Streams.Error | ForEach-Object { "$_" }); Warnings = @($ps.Streams.Warning | ForEach-Object { "$_" }); Hv = ($hv -join ' > ') }
    }
    catch { [pscustomobject]@{ Out = @(); Errors = @("$($_.Exception.Message)"); Warnings = @(); Hv = '' } }
    finally { $ps.Dispose() }
}
foreach ($case in @(
        @{ Tag = 'TurnOffFirst, landed Saved'; Mode = 'TurnOffFirst'; NoStart = $false; Landed = 'Saved'; Hv = 'get-vm > get-vm > stop > restore > get-vm > start'; Started = $true; Warn = 0 }
        @{ Tag = 'TurnOffFirst, landed Running'; Mode = 'TurnOffFirst'; NoStart = $false; Landed = 'Running'; Hv = 'get-vm > get-vm > stop > restore > get-vm'; Started = $false; Warn = 0 }
        @{ Tag = 'TurnOffFirst, landed Off (the cold warning)'; Mode = 'TurnOffFirst'; NoStart = $false; Landed = 'Off'; Hv = 'get-vm > get-vm > stop > restore > get-vm > start'; Started = $true; Warn = 1 }
        @{ Tag = 'Legacy'; Mode = 'Legacy'; NoStart = $false; Landed = 'Running'; Hv = 'get-vm > restore > get-vm'; Started = $false; Warn = 0 }
        @{ Tag = 'TurnOffFirst -NoStart (left Saved)'; Mode = 'TurnOffFirst'; NoStart = $true; Landed = 'Saved'; Hv = 'get-vm > get-vm > stop > restore > get-vm'; Started = $false; Warn = 0 }
        @{ Tag = 'the A-9 path (automatic checkpoints on after the restore)'; Mode = 'TurnOffFirst'; NoStart = $false; Landed = 'Saved'; AutoAfter = $true; Hv = 'get-vm > get-vm > stop > restore > get-vm > set-vm > start'; Started = $true; Warn = 1 })) {
    $r = & $runJob $case.Mode $case.NoStart $case.Landed ([bool]$case.AutoAfter)
    $res = if ($r.Out.Count -eq 1) { $r.Out[0] } else { $null }
    if ($r.Errors.Count -eq 0 -and $r.Out.Count -eq 1 -and $res.Mode -ceq $case.Mode -and $res.Landed -eq $case.Landed -and $res.Started -eq $case.Started -and $res.CompletedAt -is [datetime] -and
        $r.Hv -eq $case.Hv -and $r.Warnings.Count -eq $case.Warn) {
        Ok "$($case.Tag): no error, exactly one result object (CompletedAt set), $($r.Hv)"
    } else { Bad "$($case.Tag): errors=$($r.Errors -join ' | ') out=$($r.Out.Count) hv=$($r.Hv) warnings=$($r.Warnings -join ' | ') res=$($res | ConvertTo-Json -Compress)" }
}
$r = & $runJob 'TurnOffFirst' $false 'Saved' $true
if (@($r.Warnings | Where-Object { $_ -like "The test VM 'vmA' had automatic checkpoints on after restoring 'clean-base'*They were turned off on the VM before it was started." }).Count -eq 1) { Ok 'the A-9 notice is a constant warning in the job (relayed at the join)' } else { Bad "a-9 warning: $($r.Warnings -join ' | ')" }

# The precondition is read in THIS session: True or unreadable -> the advisory once (the helper's own text), mode Legacy.
foreach ($autoCase in @(@{ Tag = 'reads True'; Auto = $true }, @{ Tag = 'cannot be read'; Auto = $null })) {
    Reset-Case
    $script:auto = $autoCase.Auto
    # The helper's own advisory text for this checkpoint (THIS session's doubles; nothing real is restored).
    $script:HyperVAdvised = @{}
    $wHelper = $null
    $null = Restore-Win32ToolkitTestVMCheckpoint -VMName 'vmA' -CheckpointName 'clean-base' -Mode TurnOffFirst -WarningVariable wHelper 3>$null
    $script:HyperVAdvised = @{}
    $script:captureOnly = $true
    $lj = Enter-Win32ToolkitHyperVLease -VMName 'vmA' -Purpose 'capture'
    $w1 = $null; $w2 = $null
    $s1 = @(Start-Win32ToolkitHyperVBackgroundRestore -VMName 'vmA' -CheckpointName 'clean-base' -Lease $lj -Kind Teardown -WarningVariable w1 3>$null)
    $a1 = @($script:jobCalls[-1].ArgumentList)
    $script:HyperVPendingRestore = $null
    $s2 = @(Start-Win32ToolkitHyperVBackgroundRestore -VMName 'vmA' -CheckpointName 'clean-base' -Lease $lj -Kind Teardown -WarningVariable w2 3>$null)
    $script:HyperVPendingRestore = $null
    $null = Exit-Win32ToolkitHyperVLease -Lease $lj
    $script:captureOnly = $false
    if ($s1.Count -eq 1 -and $s1[0] -eq $true -and $s2.Count -eq 1 -and $s2[0] -eq $true -and $a1[3] -ceq 'Legacy' -and @($w1).Count -eq 1 -and @($w2).Count -eq 0 -and @($wHelper).Count -eq 1 -and "$($w1[0])" -ceq "$($wHelper[0])") {
        Ok "the checkpoint's setting $($autoCase.Tag): the advisory once in this session (the helper's own text), the job gets -Mode Legacy"
    } else { Bad "$($autoCase.Tag): started=$($s1 -join ',')/$($s2 -join ',') mode=$($a1[3]) warnings=$(@($w1).Count)/$(@($w2).Count) same=$("$($w1[0])" -ceq "$($wHelper[0])")" }
}
$script:HyperVAdvised = @{}
$script:hvLog.Clear()

# -- [o] output shapes ---------------------------------------------------------------------------------------------------
Write-Host '[o] C-12: Wait-Win32ToolkitHyperVTeardown emits nothing in every parameter set; Start- emits one [bool]' -ForegroundColor Cyan
$startPending = {
    param([string]$Kind = 'Teardown')
    $l = Enter-Win32ToolkitHyperVLease -VMName 'vmA' -Purpose 'shape'
    $s = @(Start-Win32ToolkitHyperVBackgroundRestore -VMName 'vmA' -CheckpointName 'clean-base' -Lease $l -Kind $Kind)
    [pscustomobject]@{ Lease = $l; Started = $s }
}
Reset-Case
$p1 = & $startPending
$o1 = @(Wait-Win32ToolkitHyperVTeardown -VMName 'vmA' 3>$null)
if ($p1.Started.Count -eq 1 -and $p1.Started[0] -is [bool] -and $p1.Started[0] -and $o1.Count -eq 0 -and $script:HyperVCleanMarker -and $p1.Lease.Released) { Ok 'Start- emits exactly one [bool] $true; the -VMName join emits nothing (the job returned its result object), marker kept, lease released' } else { Bad "join shape: start=$($p1.Started -join ',') out=$($o1.Count)" }
$o1b = @(Wait-Win32ToolkitHyperVTeardown -VMName 'vmA' 3>$null)
$o1c = @(Wait-Win32ToolkitHyperVTeardown -VMName 'other-vm' 3>$null)
if ($o1b.Count -eq 0 -and $o1c.Count -eq 0) { Ok 'nothing pending, or another VM: nothing joined, nothing emitted' } else { Bad "idle join: $($o1b.Count)/$($o1c.Count)" }
# Prewarm: the pre-warm's restore is joined, then its hold released.
Reset-Case
$p2 = & $startPending 'Prewarm'
$script:HyperVPrewarmLease = $p2.Lease
$o2 = @(Wait-Win32ToolkitHyperVTeardown -Prewarm 3>$null)
if ($o2.Count -eq 0 -and $null -eq $script:HyperVPendingRestore -and $null -eq $script:HyperVPrewarmLease -and $p2.Lease.Released -and $script:HyperVCleanMarker) { Ok '-Prewarm: the pre-warm restore joined (marker), its hold released, nothing emitted' } else { Bad "prewarm shape: out=$($o2.Count) released=$($p2.Lease.Released)" }
# A Prewarm join through -VMName keeps the hold (the capture runs under it) until -Prewarm.
Reset-Case
$p3 = & $startPending 'Prewarm'
$script:HyperVPrewarmLease = $p3.Lease
$o3 = @(Wait-Win32ToolkitHyperVTeardown -VMName 'vmA' 3>$null)
$keptHold = -not $p3.Lease.Released -and -not (Test-Free)
$o3b = @(Wait-Win32ToolkitHyperVTeardown -Prewarm 3>$null)
if ($o3.Count -eq 0 -and $o3b.Count -eq 0 -and $keptHold -and $p3.Lease.Released -and (Test-Free)) { Ok 'a pre-warm joined by -VMName keeps its lease hold; -Prewarm releases it later' } else { Bad "prewarm hold: kept=$keptHold released=$($p3.Lease.Released)" }
# Owner: the live token joins, releases, clears; $null and another token do nothing.
Reset-Case
$tok = [guid]::NewGuid()
$script:W32TAsyncTeardownOwner = @{ Token = $tok; Command = 'Invoke-AsOwner' }
$p4 = & $startPending
$o4n = @(Wait-Win32ToolkitHyperVTeardown -ReleaseOwner $null 3>$null)
$afterNull = ($null -ne $script:HyperVPendingRestore) -and $script:W32TAsyncTeardownOwner.Token -eq $tok
$vOther = @(Wait-Win32ToolkitHyperVTeardown -ReleaseOwner ([guid]::NewGuid()) -Verbose 4>&1 3>$null)
$afterOther = ($null -ne $script:HyperVPendingRestore) -and $script:W32TAsyncTeardownOwner.Token -eq $tok
$o4 = @(Wait-Win32ToolkitHyperVTeardown -ReleaseOwner $tok 3>$null)
if ($o4n.Count -eq 0 -and $afterNull) { Ok '-ReleaseOwner $null: a complete no-op (no join, the owner kept, nothing emitted, no binding error)' } else { Bad "null owner: out=$($o4n.Count) kept=$afterNull" }
if (@($vOther | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Count -eq 0 -and @($vOther | Where-Object { $_.Message -like '*not the live one*' }).Count -eq 1 -and $afterOther) { Ok 'another token: nothing joined or released, one verbose line, nothing emitted' } else { Bad "other token: $(@($vOther).Count) kept=$afterOther" }
if ($o4.Count -eq 0 -and $null -eq $script:HyperVPendingRestore -and $null -eq $script:W32TAsyncTeardownOwner -and $p4.Lease.Released -and $script:HyperVCleanMarker) { Ok 'the live token: the restore joined (marker), the lease released, the owner cleared, nothing emitted' } else { Bad "owner: out=$($o4.Count) pending=$($null -ne $script:HyperVPendingRestore) owner=$($null -ne $script:W32TAsyncTeardownOwner)" }
# Start- that cannot start emits exactly one [bool] $false and records nothing.
Reset-Case
$script:cpCount = 0
$l5 = Enter-Win32ToolkitHyperVLease -VMName 'vmA' -Purpose 'shape'
$s5 = @(Start-Win32ToolkitHyperVBackgroundRestore -VMName 'vmA' -CheckpointName 'clean-base' -Lease $l5 -Kind Teardown)
$null = Exit-Win32ToolkitHyperVLease -Lease $l5
if ($s5.Count -eq 1 -and $s5[0] -is [bool] -and -not $s5[0] -and $null -eq $script:HyperVPendingRestore) { Ok 'no such checkpoint: exactly one [bool] $false, nothing recorded (the caller restores in the foreground)' } else { Bad "no checkpoint: $($s5 -join ',')" }
# One background restore at a time: a second Start- (here for another VM) joins the pending one before it records its
# own, so the first job is not orphaned with a lease nobody releases.
Reset-Case
$pA = & $startPending
$jobA = $script:HyperVPendingRestore['Job']
$vmIdB = '0e5f9e66-9999-2222-3333-444455556666'
$lB = & $realEnter -VMName 'vmB' -VMId $vmIdB -Purpose 'shape' -LockRoot $ROOT -WaitSeconds 0 @trust
$sB = @(Start-Win32ToolkitHyperVBackgroundRestore -VMName 'vmB' -CheckpointName 'clean-base' -Lease $lB -Kind Teardown 3>$null)
$recB = $script:HyperVPendingRestore
$mA = $script:HyperVCleanMarker
$jobAGone = @(Get-Job -Id $jobA.Id -ErrorAction SilentlyContinue).Count -eq 0
if ($pA.Started.Count -eq 1 -and $pA.Started[0] -and $sB.Count -eq 1 -and $sB[0] -is [bool] -and $sB[0] -and $pA.Lease.Released -and (Test-Free) -and $jobAGone -and
    $mA -and $mA.VMName -eq 'vmA' -and $recB -and $recB['VMName'] -eq 'vmB' -and [object]::ReferenceEquals($recB['Lease'], $lB) -and -not $lB.Released) {
    Ok 'a second background restore (vmB) joins the pending one (vmA) first: vmA''s marker stamped, its job removed, its lease released; then vmB is recorded with its own lease'
} else { Bad "second start: started=$($sB -join ',') aReleased=$($pA.Lease.Released) free=$(Test-Free) jobAGone=$jobAGone marker=$($mA.VMName) rec=$($recB['VMName'])" }
$null = Wait-Win32ToolkitHyperVTeardown -VMName 'vmB' 3>$null
# Without the join (a regression), clean up what it left so the later cases start clean.
if (-not $pA.Lease.Released) { $null = Exit-Win32ToolkitHyperVLease -Lease $pA.Lease; Remove-Job -Job $jobA -Force -ErrorAction SilentlyContinue }
if (-not $lB.Released) { $null = Exit-Win32ToolkitHyperVLease -Lease $lB }

# -- [p] Saved parking in the background restore (P4-2, D9) --------------------------------------------------------------
Write-Host '[p] (P4-2) HyperVTeardownPark Saved: the background restore leaves the VM as it landed; the join stamps Parked Saved only for a Saved VM' -ForegroundColor Cyan
foreach ($case in @(
        @{ Tag = 'Saved, the VM Saved at the join'; Cfg = @{ HyperVTeardownPark = 'Saved' }; State = 'Saved'; NoStart = $true; Parked = 'Saved' }
        @{ Tag = 'Saved, the VM Running at the join'; Cfg = @{ HyperVTeardownPark = 'Saved' }; State = 'Running'; NoStart = $true; Parked = 'Running' }
        @{ Tag = 'Saved + HyperVRevertMode Legacy (A-15)'; Cfg = @{ HyperVTeardownPark = 'Saved'; HyperVRevertMode = 'Legacy' }; State = 'Saved'; NoStart = $false; Parked = 'Running' }
        @{ Tag = 'Running (the default)'; Cfg = @{}; State = 'Saved'; NoStart = $false; Parked = 'Running' })) {
    Reset-Case
    $script:cfg = $case.Cfg.Clone(); $script:cfg['HyperVAsyncTeardown'] = 'On'; $script:vmState = $case.State
    $x = Invoke-AsOwner -Owner
    $args0 = if ($script:jobCalls.Count) { @($script:jobCalls[0].ArgumentList) } else { @() }
    $rec = $script:HyperVPendingRestore
    $null = Wait-Win32ToolkitHyperVTeardown -VMName 'vmA' 3>$null
    $m = $script:HyperVCleanMarker
    if ($x.One -and $args0.Count -eq 5 -and $args0[4] -eq $case.NoStart -and $rec -and $rec['Parked'] -ceq $(if ($case.NoStart) { 'Saved' } else { 'Running' }) -and $m -and $m.Parked -ceq $case.Parked) {
        Ok "$($case.Tag): the job's -NoStart $($case.NoStart), the marker Parked $($case.Parked)"
    } else { Bad "$($case.Tag): nostart=$($args0[4]) rec=$($rec['Parked']) marker=$($m | ConvertTo-Json -Compress)" }
}
$script:vmState = 'Running'
# -- [pw] the capture pre-warm (P4-3, D14, A5, A-13) ---------------------------------------------------------------------
Write-Host '[pw] (P4-3) HyperVCapturePrewarm: Off = nothing; On + HyperV = the lease held and a background restore; the capture''s open skips its restore' -ForegroundColor Cyan
$script:backendPW = 'HyperV'
function Get-Win32ToolkitTestBackend { param($Backend, [switch]$NoPinThrow) $script:pwBackendArgs = "nopin=$($NoPinThrow.IsPresent)"; $script:backendPW }
function Get-Win32ToolkitHyperVTarget { [pscustomobject]@{ VMName = 'vmA'; CheckpointName = 'clean-base'; Pinned = $false } }
$pwState = { [pscustomobject]@{ Hold = $script:HyperVPrewarmLease; Pending = $script:HyperVPendingRestore; Jobs = $script:jobCalls.Count; Free = (Test-Free) } }
# Off (absent, Off, anything but On): nothing.
foreach ($v in @($null, 'Off', 'Yes')) {
    Reset-Case; $script:jobCalls.Clear()
    if ($null -ne $v) { $script:cfg['HyperVCapturePrewarm'] = $v }
    $o = @(Start-Win32ToolkitHyperVPrewarm)
    $s = & $pwState
    if ($o.Count -eq 0 -and $null -eq $s.Hold -and $null -eq $s.Pending -and $s.Jobs -eq 0 -and $s.Free) { Ok "HyperVCapturePrewarm $(if ($null -eq $v) { 'absent' } else { "'$v'" }): no lease, no job" } else { Bad "prewarm ${v}: hold=$($null -ne $s.Hold) jobs=$($s.Jobs)" }
}
# On + HyperV: the lease held, the pre-warm restore pending; then the capture (the real provider and open) joins it and
# skips its own restore on the marker this session stamped; Finalize's -Prewarm releases the hold after the capture.
Reset-Case; $script:jobCalls.Clear(); $script:cfg['HyperVCapturePrewarm'] = ' on '
$o = @(Start-Win32ToolkitHyperVPrewarm)
$s = & $pwState
$args0 = if ($s.Jobs) { @($script:jobCalls[0].ArgumentList) } else { @() }
if ($o.Count -eq 0 -and $s.Hold -and $s.Pending -and $s.Pending['Kind'] -eq 'Prewarm' -and [object]::ReferenceEquals($s.Pending['Lease'], $s.Hold) -and -not $s.Free -and $args0[1] -eq 'vmA' -and $args0[2] -eq 'clean-base' -and $script:pwBackendArgs -eq 'nopin=True') {
    Ok "On + HyperV: the VM's lease is held (purpose 'capture pre-warm'), the pre-warm restore runs in the background; nothing emitted; the backend asked with -NoPinThrow"
} else { Bad "prewarm on: out=$($o.Count) hold=$($null -ne $s.Hold) pending=$($s.Pending['Kind']) free=$($s.Free) args=$($args0[1])/$($args0[2]) backend=$($script:pwBackendArgs)" }
$holdGen = $s.Hold.Generation
${function:New-Win32ToolkitHyperVSession_Shadow} = ${function:New-Win32ToolkitHyperVSession}
. (Join-Path $repo 'Private\New-Win32ToolkitHyperVSession.ps1')
$script:helperRestores = 0
function Restore-Win32ToolkitTestVMCheckpoint { param($VMName, $CheckpointName, $Mode, [switch]$NoStart, [switch]$SkipPrecondition) $script:helperRestores++; [pscustomobject]@{ Mode = 'TurnOffFirst'; Landed = 'Saved'; Started = $true } }
function Wait-Win32ToolkitVMReady { param($VMName, $Credential, [switch]$SkipPrep, [switch]$ReturnSession) if ($ReturnSession) { 'SESS' } else { $true } }
try { $x = Invoke-AsOwner }
finally {
    ${function:New-Win32ToolkitHyperVSession} = ${function:New-Win32ToolkitHyperVSession_Shadow}
    Remove-Item Function:\New-Win32ToolkitHyperVSession_Shadow, Function:\Restore-Win32ToolkitTestVMCheckpoint, Function:\Wait-Win32ToolkitVMReady
    . (Join-Path $repo 'Private\Restore-Win32ToolkitTestVMCheckpoint.ps1')
}
$heldAfterCapture = $null -ne $script:HyperVPrewarmLease -and -not (Test-Free)
if ($x.One -and $x.Out[0] -and $x.Timing['OpenRevertSkipped'] -eq $true -and $script:helperRestores -eq 0 -and $null -eq $script:HyperVPendingRestore -and $heldAfterCapture) {
    Ok "the capture's lease joined the pre-warm (generation $holdGen, nested in the hold) and its open skipped the restore (OpenRevertSkipped `$true); the hold is kept until -Prewarm"
} else { Bad "capture: one=$($x.One) skipped=$($x.Timing['OpenRevertSkipped']) restores=$($script:helperRestores) pending=$($null -ne $script:HyperVPendingRestore) held=$heldAfterCapture verbose=$($x.Verbose -join ' | ')" }
$null = Wait-Win32ToolkitHyperVTeardown -Prewarm 3>$null
if ($null -eq $script:HyperVPrewarmLease -and (Test-Free)) { Ok 'Finalize''s -Prewarm release after the capture: the lease is free' } else { Bad "release: hold=$($null -ne $script:HyperVPrewarmLease) free=$(Test-Free)" }
# No pre-warm when: the backend is Sandbox, HyperVDepsCheckpoint is On, no thread jobs, one is already held, the job cannot start.
foreach ($case in @(
        @{ Tag = 'the backend resolves Sandbox'; Set = { $script:backendPW = 'Sandbox' } }
        @{ Tag = 'HyperVDepsCheckpoint On'; Set = { $script:cfg['HyperVDepsCheckpoint'] = 'On' } }
        @{ Tag = 'no checkpoint (the job cannot start): the lease is released at once'; Set = { $script:cpCount = 0 } })) {
    Reset-Case; $script:jobCalls.Clear(); $script:cfg['HyperVCapturePrewarm'] = 'On'; $script:backendPW = 'HyperV'
    & $case.Set
    $o = @(Start-Win32ToolkitHyperVPrewarm)
    $s = & $pwState
    if ($o.Count -eq 0 -and $null -eq $s.Hold -and $null -eq $s.Pending -and $s.Jobs -eq 0 -and $s.Free) { Ok "$($case.Tag): no pre-warm, no lease held" } else { Bad "$($case.Tag): hold=$($null -ne $s.Hold) pending=$($null -ne $s.Pending) jobs=$($s.Jobs) free=$($s.Free)" }
}
$script:backendPW = 'HyperV'
Reset-Case; $script:jobCalls.Clear(); $script:cfg['HyperVCapturePrewarm'] = 'On'
function Get-Command { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [string[]]$CommandType)
    if (@($Name) -contains 'Start-ThreadJob') { return $null }
    Microsoft.PowerShell.Core\Get-Command @PSBoundParameters }
try { $o = @(Start-Win32ToolkitHyperVPrewarm) } finally { Remove-Item Function:\Get-Command }
if ($o.Count -eq 0 -and $null -eq $script:HyperVPrewarmLease -and $script:jobCalls.Count -eq 0 -and (Test-Free)) { Ok 'no thread jobs: no pre-warm, no lease' } else { Bad 'no threadjob prewarm' }
Reset-Case; $script:jobCalls.Clear(); $script:cfg['HyperVCapturePrewarm'] = 'On'
$null = Start-Win32ToolkitHyperVPrewarm
$first = $script:HyperVPrewarmLease
$null = Start-Win32ToolkitHyperVPrewarm
if ($script:jobCalls.Count -eq 1 -and [object]::ReferenceEquals($script:HyperVPrewarmLease, $first)) { Ok 'a second call while one is held: nothing more' } else { Bad "second: jobs=$($script:jobCalls.Count)" }
$null = Wait-Win32ToolkitHyperVTeardown -Prewarm 3>$null
# Another process holds the VM: the pre-warm waits like any user of the VM; the lease error is thrown (here at once:
# the test's lease wrapper makes one attempt), nothing held.
Reset-Case; $script:jobCalls.Clear(); $script:cfg['HyperVCapturePrewarm'] = 'On'
$null = [System.IO.Directory]::CreateDirectory($ROOT)
$foreign = [System.IO.FileStream]::new($lockFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
$threw = $null
try { $null = Start-Win32ToolkitHyperVPrewarm } catch { $threw = $_ } finally { $foreign.Dispose() }
if ($threw -and $threw.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and $null -eq $script:HyperVPrewarmLease -and $script:jobCalls.Count -eq 0) { Ok 'a busy VM: W32T.HyperVLeaseTimeout is thrown (C-2), no pre-warm held' } else { Bad "busy: threw=$($threw.FullyQualifiedErrorId) hold=$($null -ne $script:HyperVPrewarmLease)" }
# The pre-warm never parks (spec 7.3; parking is for the end-of-test restore): with HyperVTeardownPark Saved the
# pre-warm's job still starts the VM, and the record is Parked Running, so the capture finds the VM running.
Reset-Case; $script:jobCalls.Clear(); $script:cfg['HyperVCapturePrewarm'] = 'On'; $script:cfg['HyperVTeardownPark'] = 'Saved'
$script:vmState = 'Saved'   # as a parked restore would leave it: only the record decides the marker's Parked
$null = Start-Win32ToolkitHyperVPrewarm
$recPw = $script:HyperVPendingRestore
$argsPw = if ($script:jobCalls.Count) { @($script:jobCalls[0].ArgumentList) } else { @() }
$okPw = $recPw -and $recPw['Kind'] -eq 'Prewarm' -and $recPw['Parked'] -ceq 'Running' -and $argsPw.Count -eq 5 -and $argsPw[4] -eq $false
$null = Wait-Win32ToolkitHyperVTeardown -Prewarm 3>$null
if ($okPw -and $script:HyperVCleanMarker -and $script:HyperVCleanMarker.Parked -ceq 'Running' -and (Test-Free)) { Ok 'HyperVTeardownPark Saved: the pre-warm''s job gets no -NoStart (record and marker Parked Running); the capture finds the VM running' } else { Bad "prewarm park: rec=$($recPw['Parked']) nostart=$($argsPw[4]) marker=$($script:HyperVCleanMarker.Parked)" }
Remove-Item Function:\Get-Win32ToolkitTestBackend, Function:\Get-Win32ToolkitHyperVTarget
# -- [w] Get-Win32ToolkitAsyncTeardownOwner -------------------------------------------------------------------------------
Write-Host '[w] Get-Win32ToolkitAsyncTeardownOwner: none, live, stale' -ForegroundColor Cyan
Reset-Case
$w0 = @(Get-Win32ToolkitAsyncTeardownOwner | Where-Object { $null -ne $_ })
function Show-Win32Toolkit { param([scriptblock]$Body) & $Body }
$liveTok = [guid]::NewGuid()
$script:W32TAsyncTeardownOwner = @{ Token = $liveTok; Command = 'Show-Win32Toolkit' }
$wLive = @(Show-Win32Toolkit { Get-Win32ToolkitAsyncTeardownOwner } | Where-Object { $null -ne $_ })
$wStale = @(Get-Win32ToolkitAsyncTeardownOwner -Verbose 4>&1 | Where-Object { $null -ne $_ })
if ($w0.Count -eq 0 -and $wLive.Count -eq 1 -and $wLive[0].Token -eq $liveTok -and @($wStale | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Count -eq 0 -and @($wStale | Where-Object { $_.Message -like '*not running any more*' }).Count -eq 1 -and $script:W32TAsyncTeardownOwner.Token -eq $liveTok) {
    Ok 'no record -> nothing; Show-Win32Toolkit on the call stack -> the record; not on the stack -> nothing + one verbose line (the record is left as it is)'
} else { Bad "owner: none=$($w0.Count) live=$($wLive.Count) stale=$(@($wStale).Count)" }
Remove-Item Function:\Show-Win32Toolkit
$script:W32TAsyncTeardownOwner = $null

# -- [s] static checks ---------------------------------------------------------------------------------------------------
Write-Host '[s] the two owners register before their try and join last in their finally; New-/Complete-/Finalize are no owners; file hygiene' -ForegroundColor Cyan
$registerText = '$w32tOwner = $null; if (-not (Get-Win32ToolkitAsyncTeardownOwner)) { $w32tOwner = [guid]::NewGuid(); $script:W32TAsyncTeardownOwner = @{ Token = $w32tOwner; Command = ''<NAME>'' } }'
$joinText = '$null = Wait-Win32ToolkitHyperVTeardown -ReleaseOwner $w32tOwner'
foreach ($o in @(@{ Name = 'Show-Win32Toolkit'; First = '$ProgressPreference = $prevProgress' }, @{ Name = 'Invoke-Win32Toolkit'; Before = '$script:OrgTemplate = $null' })) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "Public\$($o.Name).ps1"), [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $o.Name }, $true)
    $stmts = @($fn.Body.EndBlock.Statements)
    $tryIdx = -1
    for ($i = 0; $i -lt $stmts.Count; $i++) { if ($stmts[$i] -is [System.Management.Automation.Language.TryStatementAst] -and $stmts[$i].Finally) { $tryIdx = $i } }
    $regOk = $tryIdx -ge 2 -and ($stmts[$tryIdx - 2].Extent.Text + '; ' + $stmts[$tryIdx - 1].Extent.Text) -ceq ($registerText.Replace('<NAME>', $o.Name))
    $fin = if ($tryIdx -ge 0) { @($stmts[$tryIdx].Finally.Statements) } else { @() }
    $joinOk = $fin.Count -ge 2 -and $fin[-1].Extent.Text -ceq $joinText -and @($fin | Where-Object { $_.Extent.Text -match 'ReleaseOwner' }).Count -eq 1
    $orderOk = if ($o.First) { $fin[0].Extent.Text -ceq $o.First } else { @($fin | ForEach-Object { $_.Extent.Text }).IndexOf($o.Before) -ge 0 -and @($fin | ForEach-Object { $_.Extent.Text }).IndexOf($o.Before) -lt ($fin.Count - 1) }
    if ($regOk -and $joinOk -and $orderOk) { Ok "$($o.Name): the null-safe registration right before its try, the join last in its finally (after the existing reset/restore lines)" } else { Bad "$($o.Name): register=$regOk join=$joinOk order=$orderOk" }
}
# P4-3: Invoke releases the pre-warm in its finally after the org-template reset and before the owner join; Finalize
# releases it once, right after the capture block, outside any try (no owner line, no join there).
$astI = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Public\Invoke-Win32Toolkit.ps1'), [ref]$null, [ref]$null)
$tryI = @($astI.FindAll({ param($x) $x -is [System.Management.Automation.Language.TryStatementAst] -and $x.Finally }, $true)) | Where-Object { $_.Finally.Extent.Text -match 'ReleaseOwner' } | Select-Object -First 1
$finI = if ($tryI) { @($tryI.Finally.Statements | ForEach-Object { $_.Extent.Text }) } else { @() }
$finOk = ($finI -join ' | ') -ceq '$script:OrgTemplate = $null | $null = Wait-Win32ToolkitHyperVTeardown -Prewarm | $null = Wait-Win32ToolkitHyperVTeardown -ReleaseOwner $w32tOwner'
$srcI = [System.IO.File]::ReadAllText((Join-Path $repo 'Public\Invoke-Win32Toolkit.ps1'))
$startIdx = $srcI.IndexOf('$null = Start-Win32ToolkitHyperVPrewarm')
$orderI = $startIdx -gt $srcI.IndexOf('$BasePath = Get-Win32ToolkitBasePath') -and $startIdx -lt $srcI.IndexOf('$script:OrgTemplate = Get-OrgTemplate')
$astF = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Private\Invoke-Win32ToolkitFinalize.ps1'), [ref]$null, [ref]$null)
$relF = @($astF.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Wait-Win32ToolkitHyperVTeardown' }, $true))
$inTryF = $false
if ($relF.Count -eq 1) { $up = $relF[0].Parent; while ($up) { if ($up -is [System.Management.Automation.Language.TryStatementAst]) { $inTryF = $true }; $up = $up.Parent } }
$relFOk = $relF.Count -eq 1 -and $relF[0].Extent.Text -ceq 'Wait-Win32ToolkitHyperVTeardown -Prewarm' -and -not $inTryF
$srcF = [System.IO.File]::ReadAllText((Join-Path $repo 'Private\Invoke-Win32ToolkitFinalize.ps1'))
$posF = $srcF.IndexOf('$null = Wait-Win32ToolkitHyperVTeardown -Prewarm')
$placeF = $posF -gt $srcF.IndexOf("Write-Warning 'Hyper-V documentation capture did not complete") -and $posF -lt $srcF.IndexOf('$jsonProcessed = $false')
if ($finOk -and $orderI -and $relFOk -and $placeF) { Ok 'Invoke: the pre-warm starts after the base folder, before the org template; its finally: reset, -Prewarm release, owner join. Finalize: one -Prewarm release right after the capture block' } else { Bad "prewarm statics: finally=$finOk ($($finI -join ' | ')) order=$orderI finalize=$relFOk place=$placeF" }
foreach ($n in @('Public\New-Win32ToolkitManualApp.ps1', 'Public\Complete-Win32ToolkitManualApp.ps1', 'Private\Invoke-Win32ToolkitFinalize.ps1')) {
    $t = [System.IO.File]::ReadAllText((Join-Path $repo $n))
    if ($t -notmatch 'W32TAsyncTeardownOwner' -and $t -notmatch 'ReleaseOwner' -and $t -notmatch 'Get-Win32ToolkitAsyncTeardownOwner') { Ok "$(Split-Path -Leaf $n): no owner registration, no owner join (V-16)" } else { Bad "$n registers or joins an owner" }
}
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
foreach ($n in 'Start-Win32ToolkitHyperVBackgroundRestore', 'Wait-Win32ToolkitHyperVTeardown', 'Get-Win32ToolkitAsyncTeardownOwner', 'Test-Win32ToolkitHyperVTeardownPark', 'Start-Win32ToolkitHyperVPrewarm') {
    $file = Join-Path $repo "Private\$n.ps1"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
    $catches = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
    $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
    $top = @($ast.EndBlock.Statements)
    $one = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq $n -and -not $ast.ParamBlock
    $help = $null -ne $top[0].GetHelpContent() -and $top[0].GetHelpContent().Synopsis
    $suppress = $n -notlike 'Start-*' -or [System.IO.File]::ReadAllText($file) -match "SuppressMessageAttribute\('PSUseShouldProcessForStateChangingFunctions'"
    if (@($errs).Count -eq 0 -and $badCatch.Count -eq 0 -and $ascii -and $one -and $help -and $suppress) { Ok "${n}: ASCII, one function with help, $($catches.Count) catch(es) with the C-2 line$(if ($n -like 'Start-*') { ', the ShouldProcess suppression' })" } else { Bad "${n}: errors $(@($errs).Count), bad catches $($badCatch.Count), ascii $ascii, one $one, help $([bool]$help), suppress $suppress" }
}

Reset-Case
Remove-Item -LiteralPath $BASE -Recurse -Force -ErrorAction SilentlyContinue
# Safety net: no real Hyper-V cmdlet was reached (it would have imported the Hyper-V module).
if (-not (Microsoft.PowerShell.Core\Get-Module -Name Hyper-V)) { Ok 'the Hyper-V module was never imported (no real Hyper-V cmdlet reached)' } else { Bad 'the Hyper-V module was imported: a real Hyper-V cmdlet was reached' }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All HyperVAsyncTeardown tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail HyperVAsyncTeardown test(s) FAILED." -ForegroundColor Red; exit 1 }
