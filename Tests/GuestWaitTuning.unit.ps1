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

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
