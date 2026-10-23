<#
    R5 + R6/R7/R8 + R9 — event-driven guest waits (ceilings unchanged).

      (a) R5: the scheduled-task phase runner keys completion on a TASK-INFO TRANSITION vs a pre-start
          stamp — 'Ready' is ambiguous (not-yet-started == finished) and Start-ScheduledTask launches
          async, so a naive fast check-first would declare the install phase done while the installer is
          still launching (uninstall racing install). A fast-finishing task is detected with ZERO sleeps
          (the old code slept a blind 3 s per phase).
      (b) R6/R7/R8: the generated capture script — MSI-only msiexec-quiescence finalize capped at 30 s
          (exe keeps the fixed 30 s: late file drops have no rescan backstop); the registry late-writer
          budget stays 90 s but polls the Uninstall hives at 5 s and ALWAYS ends in a full-hive rescan
          (App Paths/Classes-only writers); the Sandbox settle probe applies to machine scope only,
          capped at the old 60 s; snapshot accumulators use List[object].
      (c) R9: Wait-Win32ToolkitVMReady -ReturnSession returns the proving session (no throwaway
          connection); the desktop check runs BEFORE the session is created (its recovery path reboots);
          the boot-vs-session failure diagnostic survives.
      (d) F9: the Gate-2 retries leave no record in $Error once the guest is ready, and a non-terminating
          refusal none in a caller's -ErrorVariable either; only the retry loop's own records go (a caller's
          earlier error of the same text stays). The helper runs inside a module, as in production; a
          timeout keeps the last error.

    Run:  pwsh -File Tests\GuestWaitTuning.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# ══ (a) R5 — scheduled-task transition signal ══════════════════════════════════════════════════════
Write-Host '[a] task poll: transition-keyed completion (no Ready-state race, no blind 3 s)' -ForegroundColor Cyan
. (Join-Path $repo 'Private\Invoke-Win32ToolkitGuestScheduledTask.ps1')

# Execute the guest scriptblock locally; all ScheduledTask cmdlets are shadow-driven sequences.
# $script:timeoutOverride (minutes, may be fractional) replaces the guest timeout so a ceiling case runs
# in milliseconds: the guest's parameter is untyped, the host's [int] TimeoutMinutes is bypassed.
$script:timeoutOverride = $null
function Invoke-Command { [CmdletBinding()] param($Session, [scriptblock]$ScriptBlock, $ArgumentList, [Parameter(ValueFromRemainingArguments)]$Rest)
    $t = if ($null -ne $script:timeoutOverride) { $script:timeoutOverride } else { $ArgumentList[2] }
    & $ScriptBlock $ArgumentList[0] $ArgumentList[1] $t
}
function Unregister-ScheduledTask { param([Parameter(ValueFromRemainingArguments)]$Rest) $script:taskLog += 'unregister' }
function New-ScheduledTaskAction { param([Parameter(ValueFromRemainingArguments)]$Rest) 'action' }
# Records the principal arguments: the task must run as SYSTEM (the only context since GAP1-01).
function New-ScheduledTaskPrincipal { param([Parameter(ValueFromRemainingArguments)]$Rest) $script:principalArgs = @($Rest) -join ' '; 'principal' }
function Register-ScheduledTask { param([Parameter(ValueFromRemainingArguments)]$Rest) 'task' }
function Start-ScheduledTask { param([Parameter(ValueFromRemainingArguments)]$Rest) }
# Stopping the task makes it leave 'Running' (as the real scheduler does).
function Stop-ScheduledTask { param([Parameter(ValueFromRemainingArguments)]$Rest) $script:taskLog += 'stop'; $script:stateSeq = @('Ready'); $script:stateCalls = 0 }
# $script:realSleepMs > 0 lets real time pass per poll (the monotonic ceiling case).
$script:realSleepMs = 0
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $script:sleeps += $Seconds; if ($script:realSleepMs -gt 0) { [System.Threading.Thread]::Sleep($script:realSleepMs) } }
function Get-ScheduledTask { param([Parameter(ValueFromRemainingArguments)]$Rest)
    $i = [Math]::Min($script:stateCalls, $script:stateSeq.Count - 1); $script:stateCalls++
    [pscustomobject]@{ State = $script:stateSeq[$i] }
}
function Get-ScheduledTaskInfo { param([Parameter(ValueFromRemainingArguments)]$Rest)
    $i = [Math]::Min($script:infoCalls, $script:infoSeq.Count - 1); $script:infoCalls++
    $script:infoSeq[$i]
}
$never = [pscustomobject]@{ LastRunTime = [datetime]'1999-11-30'; LastTaskResult = 267011 }  # SCHED_S_TASK_HAS_NOT_RUN
$done0 = [pscustomobject]@{ LastRunTime = (Get-Date); LastTaskResult = 0 }
function Reset-TaskShadows { $script:sleeps = @(); $script:stateCalls = 0; $script:infoCalls = 0; $script:taskLog = @(); $script:timeoutOverride = $null; $script:realSleepMs = 0 }

# a1: THE RACE — 'Ready' sampled before the scheduler even started the task must NOT complete the phase.
#     info sequence: pre-stamp(never) -> poll1(never, still launching) -> poll2(done) -> rc read(done)
Reset-TaskShadows
$script:infoSeq  = @($never, $never, $done0, $done0)
$script:stateSeq = @('Ready', 'Ready', 'Ready')
$rc = Invoke-Win32ToolkitGuestScheduledTask -Session 'fake' -Command 'noop' -Label 'race'
if ($rc -eq 0) { Ok 'phase completes with the real exit code' } else { Bad "rc=$rc" }
if (@($script:sleeps).Count -ge 1) { Ok "did NOT trust the pre-launch 'Ready' sample (waited for the task-info transition)" } else { Bad 'completed on the ambiguous Ready state — the uninstall-races-install bug' }
if ($script:principalArgs -match 'NT AUTHORITY\\SYSTEM' -and $script:principalArgs -match 'ServiceAccount' -and $script:principalArgs -match 'Highest' -and $script:principalArgs -notmatch 'Interactive') { Ok 'the task runs as NT AUTHORITY\SYSTEM (ServiceAccount, Highest)' } else { Bad "principal: $($script:principalArgs)" }

# a2: fast-finishing task -> detected on the FIRST poll with zero sleeps (old code always slept 3 s).
Reset-TaskShadows
$script:infoSeq  = @($never, $done0, $done0)
$script:stateSeq = @('Ready', 'Ready')
$rc = Invoke-Win32ToolkitGuestScheduledTask -Session 'fake' -Command 'noop' -Label 'fast'
if ($rc -eq 0 -and @($script:sleeps).Count -eq 0) { Ok 'fast task: zero sleeps (the blind 3 s/phase floor is gone)' } else { Bad "rc=$rc sleeps=$(@($script:sleeps).Count)" }

# a3: long-running task -> polls while Running, completes after.
Reset-TaskShadows
$script:infoSeq  = @($never, $done0, $done0, $done0, $done0)   # LastRunTime updates when the run STARTS
$script:stateSeq = @('Running', 'Running', 'Ready')
$rc = Invoke-Win32ToolkitGuestScheduledTask -Session 'fake' -Command 'noop' -Label 'long'
if ($rc -eq 0 -and @($script:sleeps).Count -eq 2) { Ok 'running task: kept polling until it actually finished' } else { Bad "rc=$rc sleeps=$(@($script:sleeps).Count)" }

# a4: the guest wall clock JUMPS after a checkpoint revert (checkpoint time, then +4.4 days once the
#     Hyper-V time sync catches up). A wall-clock deadline expired at once and reported the still-Running
#     phase as done (267009) — the deadlines must be monotonic (test campaign H1-F1).
$script:dateCalls = 0
$cpTime = [datetime]'2026-10-16T08:00:00'
function Get-Date { param([Parameter(ValueFromRemainingArguments)]$Rest) $script:dateCalls++; if ($script:dateCalls -le 1) { $cpTime } else { $cpTime.AddDays(4.4) } }
Reset-TaskShadows
$script:infoSeq  = @($never, $done0, $done0, $done0, $done0, $done0, $done0, $done0)
$script:stateSeq = @('Running', 'Running', 'Running', 'Running', 'Running', 'Ready')
$rc = Invoke-Win32ToolkitGuestScheduledTask -Session 'fake' -Command 'noop' -Label 'clock-jump'
if ($rc -eq 0 -and @($script:sleeps).Count -eq 5) { Ok 'guest clock jumps +4.4 days mid-phase: kept polling until the task finished (rc 0, 5 polls)' } else { Bad "rc=$rc sleeps=$(@($script:sleeps).Count) — a wall-clock deadline ended the wait early" }
if ($script:taskLog -notcontains 'stop') { Ok 'a finished task is never stopped' } else { Bad "log: $($script:taskLog -join ' > ')" }
Remove-Item Function:\Get-Date

$stSrcA = Get-Content -LiteralPath (Join-Path $repo 'Private\Invoke-Win32ToolkitGuestScheduledTask.ps1') -Raw
$guestBlock = [regex]::Match($stSrcA, '(?s)-ScriptBlock \{(.*)\} -ArgumentList').Groups[1].Value
if ($guestBlock -and $guestBlock -notmatch 'Get-Date' -and $guestBlock -match '\[System\.Diagnostics\.Stopwatch\]::StartNew\(\)') { Ok 'the guest scriptblock times out on a Stopwatch, never on (Get-Date)' } else { Bad 'the guest scriptblock still reads the wall clock (or lost its Stopwatch)' }

# a5: still Running at the ceiling -> the task is STOPPED before it is unregistered and the phase reports
#     267009 (SCHED_S_TASK_RUNNING), never the post-stop LastTaskResult (0x41306).
Reset-TaskShadows
$script:timeoutOverride = 0.0005   # 30 ms
$script:realSleepMs = 10
$stopped = [pscustomobject]@{ LastRunTime = (Get-Date); LastTaskResult = 0x41306 }
$script:infoSeq  = @($never, $done0, $stopped)
$script:stateSeq = @('Running')
$rc = Invoke-Win32ToolkitGuestScheduledTask -Session 'fake' -Command 'noop' -Label 'timeout'
if ($rc -eq 267009) { Ok 'ceiling reached while Running -> rc 267009' } else { Bad "rc=$rc" }
$si = [array]::IndexOf(@($script:taskLog), 'stop'); $ui = [array]::LastIndexOf(@($script:taskLog), 'unregister')
if ($si -ge 0 -and $ui -gt $si) { Ok 'Stop-ScheduledTask runs before the task is unregistered (a timed-out phase cannot run into the next one)' } else { Bad "log: $($script:taskLog -join ' > ')" }

# a6: never started (no transition, never seen Running) -> 267011 and nothing to stop.
Reset-TaskShadows
$script:timeoutOverride = 0.0005
$script:realSleepMs = 10
$script:infoSeq  = @($never)
$script:stateSeq = @('Ready')
$rc = Invoke-Win32ToolkitGuestScheduledTask -Session 'fake' -Command 'noop' -Label 'never'
if ($rc -eq 267011 -and $script:taskLog -notcontains 'stop') { Ok 'never started -> rc 267011, no stop' } else { Bad "rc=$rc log=$($script:taskLog -join ' > ')" }
Reset-TaskShadows

# ══ (b) R6/R7/R8 — the generated capture script's waits ════════════════════════════════════════════
Write-Host '[b] generated capture script: MSI quiescence, 90 s registry budget + final full rescan, machine-scope settle probe' -ForegroundColor Cyan
$ntdRaw = Get-Content -LiteralPath (Join-Path $repo 'Private\New-TargetedDocumentation.ps1') -Raw
$hs = [regex]::Match($ntdRaw, "(?s)\`$documentationScript = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $hs) { Bad 'could not extract the guest here-string'; exit 1 }

# R6 was REVERTED by adversarial review: late FILE drops (MSI async EXE custom actions, NSIS/Inno
# spawns) have no rescan backstop, so the finalize wait stays a fixed 30 s for EVERY installer type.
if ($hs -notmatch 'Get-Process -Name msiexec' -and $hs -match 'Please wait 30 seconds') { Ok 'finalize: fixed 30 s for ALL installer types (early exit deliberately reverted)' } else { Bad 'an early-exit finalize crept back in' }
if ($hs -match 'file-side rescan') { Ok 'the do-not-shorten rationale is documented in the guest template' } else { Bad 'revert rationale missing' }

# R7: 90 s budget, 5 s Uninstall-hive probe, mandatory final full rescan.
if ($hs -match 'retryClock\.Elapsed\.TotalSeconds -gt 90') { Ok 'registry late-writer budget stays 90 s (ceiling unchanged; monotonic clock)' } else { Bad '90 s budget missing' }
if ($hs -match 'Start-Sleep -Seconds 5' -and $hs -match 'CurrentVersion\\\\Uninstall') { Ok 'polls ONLY the Uninstall hives at 5 s (cheap probe)' } else { Bad 'probe wrong' }
if ($hs -match 'Post-installation registry \(final\)') { Ok 'ALWAYS ends in a full-hive rescan + diff (App Paths/Classes-only writers still caught)' } else { Bad 'final full rescan missing' }
if ($hs -notmatch 'retry \$retryCount/\$maxRetries') { Ok 'the 3x30 s blind countdown loop is gone' } else { Bad 'old retry countdown still present' }

# R8: settle probe machine-scope only, 60 s cap; user/unknown keep the fixed 60 s.
if ($hs -match "(?s)if \(\`$installerScope -eq 'machine'\) \{.*?settleClock\.Elapsed\.TotalSeconds -gt 60") { Ok 'machine scope: readiness probe capped at the old 60 s' } else { Bad 'settle probe missing/ungated' }
if ($hs -match '(?s)else \{\s*Write-Host "Please wait 60 seconds\.\.\."') { Ok 'user/unknown scope: fixed 60 s kept (WDAG first-logon churn lands in the scanned profile)' } else { Bad 'user-scope fixed settle lost' }
if ($hs -match 'Abs\(\$count - \$prevCount\)') { Ok 'probe includes the profile-churn stability condition' } else { Bad 'churn condition missing' }
# The capture log records the settle wait that really happened (H7-F7): measured under Sandbox, none under Hyper-V.
if ($hs -notmatch 'initialization wait started \(60 seconds\)' -and $hs -notmatch 'initialization completed successfully' -and
    $hs -match 'settle wait completed after \$settleSeconds s' -and $hs -match 'Hyper-V backend: guest readiness already gated by the host') { Ok 'capture log: measured Sandbox settle time; Hyper-V logs that there is no settle wait' } else { Bad 'capture log still claims a fixed 60 s Sandbox wait' }

# List[object] accumulators + the raw template still parses (5.1 safety).
# Guest waits never time out on the wall clock (a Hyper-V guest clock jumps after a checkpoint revert, H1).
if ($hs -notmatch '\(Get-Date\)\.AddSeconds' -and $hs -notmatch '\(\(Get-Date\) -gt') { Ok 'capture waits use a Stopwatch, never a wall-clock deadline' } else { Bad 'a wall-clock deadline is left in the capture template' }
if (([regex]::Matches($hs, 'New-Object System\.Collections\.Generic\.List\[object\]')).Count -ge 2) { Ok 'snapshot accumulators use List[object] (quadratic += gone)' } else { Bad 'List fix missing' }
$errsHS = $null
[System.Management.Automation.Language.Parser]::ParseInput($hs, [ref]$null, [ref]$errsHS) | Out-Null
if (-not ($errsHS -and $errsHS.Count)) { Ok 'raw guest template parses cleanly' } else { Bad "template parse: $($errsHS[0].Message)" }

# ══ (c) R9 — Gate 2 returns the session ════════════════════════════════════════════════════════════
Write-Host '[c] Wait-Win32ToolkitVMReady -ReturnSession + session ordering' -ForegroundColor Cyan
. (Join-Path $repo 'Private\Wait-Win32ToolkitVMReady.ps1')
. (Join-Path $repo 'Private\New-Win32ToolkitHyperVSession.ps1')

$script:calls = @()
function Get-VMIntegrationService { param([Parameter(ValueFromRemainingArguments)]$Rest) [pscustomobject]@{ PrimaryStatusDescription = $script:hb } }
$script:hb = 'OK'
function Invoke-Command { [CmdletBinding()] param($VMName, $Credential, [scriptblock]$ScriptBlock, [Parameter(ValueFromRemainingArguments)]$Rest) $script:calls += 'adhoc'; $true }
function New-PSSession { param([Parameter(ValueFromRemainingArguments)]$Rest) $script:calls += 'newpssession'; if ($script:sessThrow) { throw 'no session' }; [pscustomobject]@{ Id = 42; Name = 'run-session' } }
$script:sessThrow = $false
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
function Restore-VMCheckpoint { param([Parameter(ValueFromRemainingArguments)]$Rest) }
function Get-VM { param([Parameter(ValueFromRemainingArguments)]$Rest) [pscustomobject]@{ State = 'Running' } }
function Confirm-Win32ToolkitGuestDesktop { param([Parameter(ValueFromRemainingArguments)]$Rest) $script:calls += 'confirm'; $true }
$cred = New-Object System.Management.Automation.PSCredential('u', (New-Object System.Security.SecureString))

$script:calls = @()
$s = Wait-Win32ToolkitVMReady -VMName 'vm' -Credential $cred -SkipPrep -ReturnSession
if ($s.Name -eq 'run-session') { Ok '-ReturnSession returns the proving session' } else { Bad "got: $s" }
if ($script:calls -notcontains 'adhoc') { Ok 'no throwaway ad-hoc connection in -ReturnSession mode' } else { Bad 'still probing with a discarded connection' }
if ((Wait-Win32ToolkitVMReady -VMName 'vm' -Credential $cred -SkipPrep) -eq $true) { Ok 'bool mode unchanged ($true)' } else { Bad 'bool mode broken' }

# The run path: exactly ONE session created, and with -EnsureDesktop the desktop check PRECEDES it
# (its recovery reboots the guest — a session created earlier would die).
$script:calls = @()
$sess = New-Win32ToolkitHyperVSession -VMName 'vm' -Credential $cred -CheckpointName 'clean-base' 3>$null
if ($sess.Name -eq 'run-session' -and @($script:calls | Where-Object { $_ -eq 'newpssession' }).Count -eq 1) { Ok 'session open: exactly one connection built' } else { Bad "calls: $($script:calls -join ' > ')" }
$script:calls = @()
$null = New-Win32ToolkitHyperVSession -VMName 'vm' -Credential $cred -CheckpointName 'clean-base' -EnsureDesktop 3>$null
$ci = [array]::IndexOf($script:calls, 'confirm'); $ni = [array]::LastIndexOf($script:calls, 'newpssession')
if ($ci -ge 0 -and $ni -gt $ci) { Ok 'desktop check (possible reboot) runs BEFORE the returned session is created' } else { Bad "order: $($script:calls -join ' > ')" }

# Failure diagnostics survive the merge.
$script:sessThrow = $true
$script:hb = 'OK'
$msg = $null
try { $null = Wait-Win32ToolkitVMReady -VMName 'vm' -Credential $cred -SkipPrep -ReturnSession -PSDirectTimeoutSec 0.05 } catch { $msg = $_.Exception.Message }
if ($msg -match 'admin session') { Ok 'heartbeat OK + no session -> the AutoLogon diagnostic' } else { Bad "msg: $msg" }
$script:hb = 'LostCommunication'
try { $null = Wait-Win32ToolkitVMReady -VMName 'vm' -Credential $cred -SkipPrep -ReturnSession -PSDirectTimeoutSec 0.05 } catch { $msg = $_.Exception.Message }
if ($msg -match 'may not have booted') { Ok 'dead heartbeat -> the boot diagnostic (preserved from Gate 1)' } else { Bad "msg: $msg" }

# ══ (d) F9 — Gate 2 retries leave no error records once the guest is ready ═════════════════════════
Write-Host '[d] Wait-Win32ToolkitVMReady (module-hosted): retry errors leave $Error / -ErrorVariable once ready; a timeout keeps the last' -ForegroundColor Cyan
# Installer-identity PR 2 follow-up F9 (live P4-ff-hv #3: ErrorVariableCount 6, GlobalErrorCount 2 on a passing run).
# The helper runs INSIDE a module, as in production (win32-toolkit.psm1 dot-sources Private\): there the plain $Error
# is the module's own, empty list, so only a trim of $global:Error works (spec B1). A dot-sourced copy (as in [c])
# would see the global list as $Error and pass with the wrong code. The doubles the module sees must be global.
Remove-Item Function:\Wait-Win32ToolkitVMReady
$waitMod = New-Module -Name W32tWaitProbe -ScriptBlock { param($f) . $f; Export-ModuleMember -Function Wait-Win32ToolkitVMReady } -ArgumentList (Join-Path $repo 'Private\Wait-Win32ToolkitVMReady.ps1') | Import-Module -PassThru
if ((Get-Command Wait-Win32ToolkitVMReady).ModuleName -eq 'W32tWaitProbe') { Ok 'the helper under test runs as a module function' } else { Bad "Wait-Win32ToolkitVMReady comes from '$((Get-Command Wait-Win32ToolkitVMReady).ModuleName)'" }
# 'write' = a non-terminating cmdlet error (the live PSSessionOpenFailed), 'terminate' = an error raised as
# terminating whatever -ErrorAction says. The first $script:dFail calls fail; later ones succeed.
$script:dCalls = 0
$script:dFail = 2
$script:dKind = 'write'
function global:New-PSSession {
    [CmdletBinding()] param($VMName, [pscredential]$Credential)
    $null = $VMName, $Credential
    $script:dCalls++
    if ($script:dCalls -le $script:dFail) {
        if ($script:dKind -eq 'terminate') {
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('A remote session might have ended.'), 'PSSessionStateBroken', [System.Management.Automation.ErrorCategory]::OpenError, $null))
        }
        Write-Error -Message 'The credential is invalid.' -ErrorId 'PSSessionOpenFailed' -Category OpenError
        return
    }
    [pscustomobject]@{ Id = 7; Name = 'd-session' }
}
function global:Invoke-Command {
    [CmdletBinding()] param($VMName, [pscredential]$Credential, [scriptblock]$ScriptBlock)
    $null = $VMName, $Credential, $ScriptBlock
    $script:dCalls++
    if ($script:dCalls -le $script:dFail) {
        Write-Error -Message 'The credential is invalid.' -ErrorId 'PSSessionOpenFailed' -Category OpenError
        return
    }
    $true
}
function global:Start-Sleep { param([int]$Seconds) $null = $Seconds }
function global:Get-VMIntegrationService { param($VMName, $Name, $ErrorAction) $null = $VMName, $Name, $ErrorAction; [pscustomobject]@{ PrimaryStatusDescription = 'OK' } }
# The caller: an advanced function asked for -ErrorVariable, as automation wraps Test-Win32ToolkitProject.
function Invoke-WaitProbe {
    [CmdletBinding()] param([pscredential]$Credential, [switch]$ReturnSession, [double]$PSDirectTimeoutSec = 900)
    Wait-Win32ToolkitVMReady -VMName 'vm' -Credential $Credential -SkipPrep -ReturnSession:$ReturnSession -PSDirectTimeoutSec $PSDirectTimeoutSec -Verbose
}
function Split-ProbeOutput { param($Out) @{ Value = @($Out | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }); Verbose = @($Out | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message } | Where-Object { $_ -like 'PowerShell Direct is not ready yet*' }) } }

# d1: -ReturnSession, two refusals (Write-Error) then a session.
$script:dCalls = 0; $script:dFail = 2; $script:dKind = 'write'
$Error.Clear()
$ev = $null
$d1 = Split-ProbeOutput (Invoke-WaitProbe -Credential $cred -ReturnSession -ErrorVariable ev 4>&1)
if ($d1.Value.Count -eq 1 -and $d1.Value[0].Name -eq 'd-session' -and $script:dCalls -eq 3) { Ok '-ReturnSession: two refusals, then the session on the third attempt is returned' } else { Bad "d1: value=$($d1.Value | ForEach-Object { "$_" }) calls=$($script:dCalls)" }
if ($Error.Count -eq 0 -and @($ev).Count -eq 0) { Ok '-ReturnSession: no record left in $Error or the caller''s -ErrorVariable' } else { Bad "d1: `$Error=$($Error.Count) ev=$(@($ev).Count): $(@($Error | ForEach-Object { "$_" }) -join ' | ')" }
if ($d1.Verbose.Count -eq 2 -and $d1.Verbose[0] -match '\(attempt 1 at \d\d:\d\d:\d\d\.\d{3}Z\); retrying in 1 s\.$' -and $d1.Verbose[1] -match '\(attempt 2 at \d\d:\d\d:\d\d\.\d{3}Z\); retrying in 2 s\.$') { Ok 'each refusal is a verbose line with its UTC time (attempt 1, attempt 2)' } else { Bad "d1 verbose: $($d1.Verbose -join ' | ')" }

# d2: bool mode, the same with Invoke-Command.
$script:dCalls = 0; $script:dFail = 2; $script:dKind = 'write'
$Error.Clear()
$ev = $null
$d2 = Split-ProbeOutput (Invoke-WaitProbe -Credential $cred -ErrorVariable ev 4>&1)
if ($d2.Value.Count -eq 1 -and $d2.Value[0] -eq $true -and $script:dCalls -eq 3 -and $Error.Count -eq 0 -and @($ev).Count -eq 0) { Ok 'bool mode: $true after two refusals, no record in $Error or -ErrorVariable' } else { Bad "d2: value=$($d2.Value -join ',') calls=$($script:dCalls) `$Error=$($Error.Count) ev=$(@($ev).Count)" }

# d3: an error raised as terminating whatever -ErrorAction says: caught, then trimmed from the session's list (B1).
# Only the retry loop's OWN records go, matched by exception object: the caller's earlier error, seeded first through the
# same double (same exception type, text, id and category), must stay. So a trim of every record, or one by text, by id
# or by type, fails here (the seed goes too), and a trim of the plain $Error fails with 3 records (the module's $Error is
# a separate, empty list). The caller's -ErrorVariable still holds the retry records (Fd5: the engine adds caught
# terminating errors there; not asserted).
$script:dCalls = 0; $script:dFail = 1; $script:dKind = 'terminate'
$Error.Clear()
try { $null = New-PSSession -VMName 'vm' -Credential $cred } catch { $null = $_ }
$seed = $Error[0]
if ($Error.Count -eq 1 -and $seed -is [System.Management.Automation.ErrorRecord] -and $seed.FullyQualifiedErrorId -like 'PSSessionStateBroken*' -and $seed.Exception.Message -eq 'A remote session might have ended.') { Ok 'a caller error of the same kind, text and id is in $Error before the wait' } else { Bad "d3 seed: `$Error=$($Error.Count) id=$($seed.FullyQualifiedErrorId)" }
$script:dCalls = 0; $script:dFail = 2
$ev = $null
$d3 = Split-ProbeOutput (Invoke-WaitProbe -Credential $cred -ReturnSession -ErrorVariable ev 4>&1)
if ($d3.Value.Count -eq 1 -and $d3.Value[0].Name -eq 'd-session' -and $script:dCalls -eq 3 -and $d3.Verbose.Count -eq 2) { Ok 'terminating refusals: retried, the session is returned' } else { Bad "d3: value=$($d3.Value | ForEach-Object { "$_" }) calls=$($script:dCalls) verbose=$($d3.Verbose.Count)" }
if ($Error.Count -eq 1 -and [object]::ReferenceEquals($Error[0], $seed)) { Ok 'terminating refusals: their records leave $global:Error once the guest is ready; the caller''s earlier record of the same text and id stays' } else { Bad "d3: `$Error=$($Error.Count) seed kept=$($Error.Count -ge 1 -and [object]::ReferenceEquals($Error[$Error.Count - 1], $seed)): $(@($Error | ForEach-Object { "$($_.FullyQualifiedErrorId)" }) -join ' | ')" }

# d4: timeout: every attempt refused -> one last attempt with -ErrorAction Stop; its error is kept and named.
$script:dCalls = 0; $script:dFail = [int]::MaxValue; $script:dKind = 'write'
$Error.Clear()
$msg4 = $null
try { $null = Invoke-WaitProbe -Credential $cred -ReturnSession -PSDirectTimeoutSec 0.05 4>$null } catch { $msg4 = $_.Exception.Message }
if ($msg4 -like '*did not become ready*' -and $msg4 -like '*admin session*' -and $msg4.EndsWith(' Last error: The credential is invalid.')) { Ok 'timeout: the message names the last error' } else { Bad "d4 msg: $msg4" }
$kept4 = @($Error | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -like 'PSSessionOpenFailed*' })
if ($kept4.Count -eq 1 -and $Error.Count -eq 2) { Ok 'timeout: $Error keeps exactly the last attempt''s error (plus the thrown one)' } else { Bad "d4: `$Error=$($Error.Count) kept=$($kept4.Count): $(@($Error | ForEach-Object { "$($_.FullyQualifiedErrorId)" }) -join ' | ')" }
$Error.Clear()

# d5: static (B1): the trim works on the session's list.
$vmrSrc = Get-Content -LiteralPath (Join-Path $repo 'Private\Wait-Win32ToolkitVMReady.ps1') -Raw
if ($vmrSrc.Contains('$global:Error.RemoveAt(') -and -not $vmrSrc.Contains('$Error.RemoveAt(')) { Ok 'the trim removes from $global:Error, never from the module''s own $Error' } else { Bad 'Wait-Win32ToolkitVMReady does not trim $global:Error (or trims the plain $Error)' }

Remove-Module -ModuleInfo $waitMod
# Every copy of the doubles goes (the global ones of [d] and the script ones of [c]).
foreach ($dbl in 'New-PSSession', 'Invoke-Command', 'Start-Sleep', 'Get-VMIntegrationService', 'Wait-Win32ToolkitVMReady') {
    while (Test-Path -LiteralPath "Function:\$dbl") { Remove-Item -LiteralPath "Function:\$dbl" }
}

# ══ (c2) Hyper-V speed-up PR 1 (D22): the PowerShell Direct back-off is capped at 2 s after a checkpoint restore ═════
Write-Host '[c2] Wait-Win32ToolkitVMReady: -ReturnSession retries 1, 2, 2, 2 ... s; bool mode keeps 1, 2, 4, 8, 10 s' -ForegroundColor Cyan
. (Join-Path $repo 'Private\Wait-Win32ToolkitVMReady.ps1')
$script:c2Calls = 0
$script:c2Sleeps = [System.Collections.Generic.List[int]]::new()
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $script:c2Sleeps.Add($Seconds) }
function Get-VMIntegrationService { param([Parameter(ValueFromRemainingArguments)]$Rest) [pscustomobject]@{ PrimaryStatusDescription = 'OK' } }
function New-PSSession { param([Parameter(ValueFromRemainingArguments)]$Rest) $script:c2Calls++; if ($script:c2Calls -le 5) { return $null }; [pscustomobject]@{ Id = 3; Name = 'c2-session' } }
function Invoke-Command { param([Parameter(ValueFromRemainingArguments)]$Rest) $script:c2Calls++; if ($script:c2Calls -le 5) { return $null }; $true }
$r = Wait-Win32ToolkitVMReady -VMName 'vm' -Credential $cred -SkipPrep -ReturnSession
if ($r.Name -eq 'c2-session' -and ($script:c2Sleeps -join ',') -eq '1,2,2,2,2') { Ok '-ReturnSession: five refusals -> sleeps 1, 2, 2, 2, 2 s, then the session' } else { Bad "-ReturnSession sleeps: $($script:c2Sleeps -join ',') result=$r" }
$script:c2Calls = 0; $script:c2Sleeps.Clear()
$r = Wait-Win32ToolkitVMReady -VMName 'vm' -Credential $cred -SkipPrep
if ($r -eq $true -and ($script:c2Sleeps -join ',') -eq '1,2,4,8,10') { Ok 'bool mode (provisioning): five refusals -> sleeps 1, 2, 4, 8, 10 s (unchanged)' } else { Bad "bool sleeps: $($script:c2Sleeps -join ',') result=$r" }
foreach ($dbl in 'New-PSSession', 'Invoke-Command', 'Start-Sleep', 'Get-VMIntegrationService', 'Wait-Win32ToolkitVMReady') {
    while (Test-Path -LiteralPath "Function:\$dbl") { Remove-Item -LiteralPath "Function:\$dbl" }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
