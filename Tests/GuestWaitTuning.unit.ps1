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
function Invoke-Command { [CmdletBinding()] param($Session, [scriptblock]$ScriptBlock, $ArgumentList, [Parameter(ValueFromRemainingArguments)]$Rest) & $ScriptBlock @ArgumentList }
function Unregister-ScheduledTask { param([Parameter(ValueFromRemainingArguments)]$Rest) }
function New-ScheduledTaskAction { param([Parameter(ValueFromRemainingArguments)]$Rest) 'action' }
function New-ScheduledTaskPrincipal { param([Parameter(ValueFromRemainingArguments)]$Rest) 'principal' }
function Register-ScheduledTask { param([Parameter(ValueFromRemainingArguments)]$Rest) 'task' }
function Start-ScheduledTask { param([Parameter(ValueFromRemainingArguments)]$Rest) }
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $script:sleeps += $Seconds }
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
function Reset-TaskShadows { $script:sleeps = @(); $script:stateCalls = 0; $script:infoCalls = 0 }

# a1: THE RACE — 'Ready' sampled before the scheduler even started the task must NOT complete the phase.
#     info sequence: pre-stamp(never) -> poll1(never, still launching) -> poll2(done) -> rc read(done)
Reset-TaskShadows
$script:infoSeq  = @($never, $never, $done0, $done0)
$script:stateSeq = @('Ready', 'Ready', 'Ready')
$rc = Invoke-Win32ToolkitGuestScheduledTask -Session 'fake' -Command 'noop' -Label 'race'
if ($rc -eq 0) { Ok 'phase completes with the real exit code' } else { Bad "rc=$rc" }
if (@($script:sleeps).Count -ge 1) { Ok "did NOT trust the pre-launch 'Ready' sample (waited for the task-info transition)" } else { Bad 'completed on the ambiguous Ready state — the uninstall-races-install bug' }

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

# ══ (b) R6/R7/R8 — the generated capture script's waits ════════════════════════════════════════════
Write-Host '[b] generated capture script: MSI quiescence, 90 s registry budget + final full rescan, machine-scope settle probe' -ForegroundColor Cyan
$ntdRaw = Get-Content -LiteralPath (Join-Path $repo 'Private\New-TargetedDocumentation.ps1') -Raw
$hs = [regex]::Match($ntdRaw, "(?s)\`$documentationScript = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $hs) { Bad 'could not extract the guest here-string'; exit 1 }

# R6: MSI-gated finalize with the 30 s ceiling; exe keeps fixed 30.
if ($hs -match '\$isMsi = \[bool\]\(Get-ChildItem -Path .C:\\PSADT\\Files. -Filter .\*\.msi.') { Ok 'finalize gate: installer type detected in-guest (no new host deps)' } else { Bad 'no in-guest MSI detection' }
if ($hs -match 'AddSeconds\(30\)' -and $hs -match 'Get-Process -Name msiexec') { Ok 'MSI: msiexec-quiescence poll capped at the old 30 s' } else { Bad 'quiescence poll missing/uncapped' }
if ($hs -match '(?s)else \{\s*Write-Host "Please wait 30 seconds\.\.\."') { Ok 'non-MSI: fixed 30 s kept (late file drops have no rescan backstop)' } else { Bad 'exe path lost its fixed wait' }

# R7: 90 s budget, 5 s Uninstall-hive probe, mandatory final full rescan.
if ($hs -match 'AddSeconds\(90\)') { Ok 'registry late-writer budget stays 90 s (ceiling unchanged)' } else { Bad '90 s budget missing' }
if ($hs -match 'Start-Sleep -Seconds 5' -and $hs -match 'CurrentVersion\\\\Uninstall') { Ok 'polls ONLY the Uninstall hives at 5 s (cheap probe)' } else { Bad 'probe wrong' }
if ($hs -match 'Post-installation registry \(final\)') { Ok 'ALWAYS ends in a full-hive rescan + diff (App Paths/Classes-only writers still caught)' } else { Bad 'final full rescan missing' }
if ($hs -notmatch 'retry \$retryCount/\$maxRetries') { Ok 'the 3x30 s blind countdown loop is gone' } else { Bad 'old retry countdown still present' }

# R8: settle probe machine-scope only, 60 s cap; user/unknown keep the fixed 60 s.
if ($hs -match "(?s)if \(\`$installerScope -eq 'machine'\) \{.*?AddSeconds\(60\)") { Ok 'machine scope: readiness probe capped at the old 60 s' } else { Bad 'settle probe missing/ungated' }
if ($hs -match '(?s)else \{\s*Write-Host "Please wait 60 seconds\.\.\."') { Ok 'user/unknown scope: fixed 60 s kept (WDAG first-logon churn lands in the scanned profile)' } else { Bad 'user-scope fixed settle lost' }
if ($hs -match 'Abs\(\$count - \$prevCount\)') { Ok 'probe includes the profile-churn stability condition' } else { Bad 'churn condition missing' }

# List[object] accumulators + the raw template still parses (5.1 safety).
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
$cred = New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))

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
