<#
    Test campaign F1: a leftover Windows Sandbox client window no longer blocks the next run.

    Windows Sandbox 0.8 can leave its client window (WindowsSandboxRemoteSession / WindowsSandboxClient)
    open on 'The remote environment is shutting down' after the guest is gone. The single-instance wait
    counted that window as a running sandbox, waited 90 s and the chained test gave no verdict.

      [1] Get-Win32ToolkitSandboxEnvironment parses 'wsb list --raw' (Invoke-Win32ToolkitWsbList shadowed):
          an empty WindowsSandboxEnvironments list -> Count 0; anything unexpected -> $null (unknown)
      [2] Invoke-Win32ToolkitWsbList: runs only 'list --raw'; the real wsb.exe when it is installed
          (read-only), $null when it is not
      [3] Wait-Win32ToolkitSandboxFree (fake clock): closes client windows only after wsb has reported no
          sandbox for the grace period and only the SAME client windows of this session are left; never while
          wsb lists a sandbox, never with another sandbox process left, never without wsb (process check as
          before); a window that appears during the grace (a sandbox that is starting) restarts it; another
          session's window (another user's sandbox) is never closed; wsb is asked again right before the
          close; a window that survives the close keeps the wait going; one failed wsb answer is tolerated (R1 #2)
          and restarts the grace, a good answer resets the count, two failed answers in a row fall back to the
          process check
      [4] Close-Win32ToolkitSandboxClient: CloseMainWindow first, Kill only what is still running after the
          wait, only client-window processes of this session (never WindowsSandboxServer), never throws
      [5] Source checks (and wsb.exe is stopped alone, never with its process tree)
      [6] No error noise: the real Test-Win32ToolkitSandboxRunning and the wait's own process lookup leave
          nothing in $Error or a caller's -ErrorVariable
      [7] -OwnRun (installer-identity PR 2 follow-up F10, an unattended test's own sandbox): only this session's
          sandbox processes count as still open; without wsb.exe no wait; the same close rule; its own three lines
          and a neutral line at the timeout; one failed wsb answer during it no longer skips the close (R1 #2),
          neither at the first answer (the pre-check right after the sandbox shut down); two in a row there -> no wait
      [8] R1 #2 end to end (the real parser, a fake 'wsb list --raw'): a non-JSON or truncated answer is a failed
          answer, never "no sandbox"; one is tolerated, two in a row fall back to the process check

    No sandbox is started, stopped or closed.

    Run:  pwsh -File Tests\SandboxStaleClient.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Get-Date, Start-Sleep and Get-Process are shadowed: a fake clock and fake processes')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows and case helpers')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Invoke-Win32ToolkitWsbList.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitSandboxEnvironment.ps1')
. (Join-Path $repo 'Private\Close-Win32ToolkitSandboxClient.ps1')
. (Join-Path $repo 'Private\Wait-Win32ToolkitSandboxFree.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitSandboxRunning.ps1')
$script:mySession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId

# --- [2] first: the real runner, before anything is shadowed -------------------------------------------
Write-Host '[2] Invoke-Win32ToolkitWsbList: only "list --raw"; the real wsb.exe when installed' -ForegroundColor Cyan
$runnerFile = Join-Path $repo 'Private\Invoke-Win32ToolkitWsbList.ps1'
$runnerAst = [System.Management.Automation.Language.Parser]::ParseFile($runnerFile, [ref]$null, [ref]$null)
$adds = @($runnerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Add' -and $n.Expression.Extent.Text -eq '$psi.ArgumentList' }, $true) |
        ForEach-Object { $_.Arguments[0].Extent.Text })
if (($adds -join ' ') -eq "'list' '--raw'") { Ok "the only arguments are 'list' '--raw' (read-only: nothing is started or stopped)" } else { Bad "arguments: $($adds -join ' ')" }
# On a timeout only wsb.exe is stopped: Kill($true) would take its tree, and a cold 'wsb list' starts WindowsSandboxServer.
$kills = @($runnerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Kill' }, $true))
if ($kills.Count -eq 1 -and @($kills[0].Arguments | Where-Object { $_ }).Count -eq 0 -and $kills[0].Expression.Extent.Text -eq '$proc') { Ok 'a timed-out wsb list is stopped with $proc.Kill() (wsb.exe alone, never its process tree)' } else { Bad "kill calls: $(@($kills | ForEach-Object { $_.Extent.Text }) -join ' | ')" }
$wsbExe = Get-Command -Name 'wsb.exe' -CommandType Application -ErrorAction Ignore | Select-Object -First 1
if ($wsbExe) {
    $real = Invoke-Win32ToolkitWsbList
    if ($real -and $real.ExitCode -eq 0) {
        if ($real.Output -match 'WindowsSandboxEnvironments') { Ok 'wsb.exe is installed: exit 0 and the WindowsSandboxEnvironments JSON' } else { Bad "real wsb output: $($real.Output)" }
        $realEnv = Get-Win32ToolkitSandboxEnvironment
        if ($realEnv -and $realEnv.Count -ge 0) { Ok "Get-Win32ToolkitSandboxEnvironment reads it (Count $($realEnv.Count))" } else { Bad 'real environment not parsed' }
    } else {
        # A host whose Windows Sandbox is disabled or broken: the runner still answered (no throw); nothing to parse.
        Write-Host "  SKIP: wsb.exe is installed but 'wsb list' did not succeed on this host ($(if ($real) { "exit $($real.ExitCode)" } else { 'no result' }))" -ForegroundColor DarkGray
    }
} else {
    if ($null -eq (Invoke-Win32ToolkitWsbList)) { Ok 'wsb.exe is not installed -> $null (the process check decides)' } else { Bad 'no wsb.exe but a result' }
}

# --- [1] parser ---------------------------------------------------------------------------------------
Write-Host '[1] Get-Win32ToolkitSandboxEnvironment: wsb list --raw parsing' -ForegroundColor Cyan
$script:wsbResult = $null
function Invoke-Win32ToolkitWsbList { $script:wsbResult }
function Wsb([int]$Code, [string]$Out) { $script:wsbResult = [pscustomobject]@{ ExitCode = $Code; Output = $Out; ErrorOutput = '' } }
$cases = [ordered]@{
    'empty list'                 = @{ Code = 0; Out = "{`r`n  `"WindowsSandboxEnvironments`": []`r`n}"; Want = 0 }
    'one environment (object)'   = @{ Code = 0; Out = '{"WindowsSandboxEnvironments":[{"Id":"4f0c2a3e-0000-0000-0000-000000000001","Status":"Running"}]}'; Want = 1 }
    'two environments (strings)' = @{ Code = 0; Out = '{"WindowsSandboxEnvironments":["a","b"]}'; Want = 2 }
    'text around the JSON'       = @{ Code = 0; Out = "note: preview`r`n{`"WindowsSandboxEnvironments`":[]}`r`n"; Want = 0 }
    'exit code 1'                = @{ Code = 1; Out = '{"WindowsSandboxEnvironments":[]}'; Want = $null }
    'not JSON'                   = @{ Code = 0; Out = 'No running sandboxes.'; Want = $null }
    'broken JSON'                = @{ Code = 0; Out = '{"WindowsSandboxEnvironments":[}'; Want = $null }
    'other object'               = @{ Code = 0; Out = '{"Sandboxes":[]}'; Want = $null }
    'null list'                  = @{ Code = 0; Out = '{"WindowsSandboxEnvironments":null}'; Want = $null }
    'top-level array'            = @{ Code = 0; Out = '[]'; Want = $null }
    'empty output'               = @{ Code = 0; Out = ''; Want = $null }
}
foreach ($name in $cases.Keys) {
    $c = $cases[$name]
    Wsb $c.Code $c.Out
    $got = Get-Win32ToolkitSandboxEnvironment
    $gotText = if ($null -eq $got) { 'null' } else { "Count $($got.Count)" }
    $wantText = if ($null -eq $c.Want) { 'null' } else { "Count $($c.Want)" }
    if ($gotText -eq $wantText) { Ok "${name}: $gotText" } else { Bad "${name}: got $gotText, expected $wantText" }
}
$script:wsbResult = $null
if ($null -eq (Get-Win32ToolkitSandboxEnvironment)) { Ok 'wsb missing / timed out (runner $null) -> null' } else { Bad 'runner null not null' }

# --- [6] no error noise (real Get-Process, real clock; nothing is closed) -------------------------------------
Write-Host '[6] No NoProcessFoundForGivenName noise in $Error or -ErrorVariable' -ForegroundColor Cyan
$Error.Clear(); $ev = @()
$null = Test-Win32ToolkitSandboxRunning -ErrorVariable ev
if ($Error.Count -eq 0 -and @($ev).Count -eq 0) { Ok 'Test-Win32ToolkitSandboxRunning (real Get-Process) adds nothing to $Error or -ErrorVariable' } else { Bad "running check: Error=$($Error.Count) ev=$(@($ev).Count) $($Error | Select-Object -First 1)" }
# The wait's own lookup of the client windows: one poll that reaches it (wsb empty), then free.
$script:runningAnswers = [System.Collections.Generic.Queue[bool]]::new(); foreach ($b in $true, $true, $false) { $script:runningAnswers.Enqueue($b) }
function Test-Win32ToolkitSandboxRunning { if ($script:runningAnswers.Count) { $script:runningAnswers.Dequeue() } else { $false } }
$script:envAsked = 0
function Get-Win32ToolkitSandboxEnvironment { $script:envAsked++; [pscustomobject]@{ Count = 0 } }
$Error.Clear(); $ev = @()
$freeNow = Wait-Win32ToolkitSandboxFree -TimeoutSeconds 10 -PollSeconds 1 -ErrorVariable ev 6>$null
if ($freeNow -eq $true -and $script:envAsked -ge 1 -and $Error.Count -eq 0 -and @($ev).Count -eq 0) { Ok "Wait-Win32ToolkitSandboxFree's client-window lookup (real Get-Process) adds nothing to `$Error or -ErrorVariable" }
else { Bad "wait lookup: free=$freeNow asked=$($script:envAsked) Error=$($Error.Count) ev=$(@($ev).Count) $($Error | Select-Object -First 1)" }

# --- shared fakes: a clock, processes, wsb answers ------------------------------------------------------
$script:now = [datetime]'2026-10-20T22:00:00'
$script:sleeps = 0
function Get-Date { $script:now }
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $script:sleeps++; $script:now = $script:now.AddSeconds([Math]::Max(1, $Seconds)); if ($script:onTick) { & $script:onTick } }
$script:onTick = $null
# A fake process: this session and 10 minutes old unless told otherwise (a leftover window is minutes old).
function New-FakeProcess([string]$Name, [int]$Id, [switch]$ExitsOnClose, [switch]$KillThrows, [switch]$SurvivesKill, $SessionId = $script:mySession, $StartTime = $script:now.AddMinutes(-10), [switch]$StartTimeThrows) {
    $p = [pscustomobject]@{ ProcessName = $Name; Id = $Id; HasExited = $false; Closed = 0; Killed = 0; ExitsOnClose = [bool]$ExitsOnClose; KillThrows = [bool]$KillThrows; SurvivesKill = [bool]$SurvivesKill; SessionId = $SessionId }
    if ($StartTimeThrows) { $p | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw 'Access is denied' } }
    else { $p | Add-Member -MemberType NoteProperty -Name StartTime -Value ([datetime]$StartTime) }
    $p | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $this.Closed++; if ($this.ExitsOnClose) { $this.HasExited = $true }; $true }
    $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { $this.Killed++; if ($this.KillThrows) { throw 'Access is denied' }; if (-not $this.SurvivesKill) { $this.HasExited = $true } }
    $p
}
$script:procs = @()
function Get-Process { param([string[]]$Name, $ErrorAction) @($script:procs | Where-Object { -not $_.HasExited -and ($null -eq $Name -or $Name -contains $_.ProcessName) }) }
function Test-Win32ToolkitSandboxRunning { @(Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession').Count -gt 0 }

# --- [4] Close-Win32ToolkitSandboxClient (real, with fakes) ---------------------------------------------
Write-Host '[4] Close-Win32ToolkitSandboxClient: close the window, stop only what is left, only client windows' -ForegroundColor Cyan
$polite = New-FakeProcess 'WindowsSandboxRemoteSession' 11 -ExitsOnClose
$stuck = New-FakeProcess 'WindowsSandboxClient' 12
$server = New-FakeProcess 'WindowsSandboxServer' 13
$other = New-FakeProcess 'notepad' 14
$t0 = $script:now
Close-Win32ToolkitSandboxClient -Process @($polite, $stuck, $server, $other) -WaitSeconds 10
if ($polite.Closed -eq 1 -and $polite.Killed -eq 0 -and $polite.HasExited) { Ok 'a window that closes on CloseMainWindow is not stopped' } else { Bad "polite: closed=$($polite.Closed) killed=$($polite.Killed)" }
if ($stuck.Closed -eq 1 -and $stuck.Killed -eq 1 -and ($script:now - $t0).TotalSeconds -ge 10) { Ok 'a window still open after -WaitSeconds 10 is stopped (Kill on the same process object)' } else { Bad "stuck: closed=$($stuck.Closed) killed=$($stuck.Killed) waited=$(($script:now - $t0).TotalSeconds)" }
if ($server.Closed -eq 0 -and $server.Killed -eq 0 -and $other.Closed -eq 0 -and $other.Killed -eq 0) { Ok 'WindowsSandboxServer and any other process passed in are never touched' } else { Bad 'a non-client process was touched' }
$deny = New-FakeProcess 'WindowsSandboxRemoteSession' 15 -KillThrows
$w = @(); $threw = $null
try { Close-Win32ToolkitSandboxClient -Process @($deny) -WaitSeconds 2 -WarningVariable w -ErrorAction Stop 3>$null } catch { $threw = $_ }
if (-not $threw -and $deny.Killed -eq 1 -and @($w).Count -eq 1 -and "$($w[0])" -match 'Could not stop the leftover Windows Sandbox window \(WindowsSandboxRemoteSession, process 15\)') { Ok 'a process that cannot be stopped -> one warning, no throw' } else { Bad "deny: threw=$threw warnings=$($w -join ' | ')" }
$t0 = $script:now
Close-Win32ToolkitSandboxClient -Process @()
if (($script:now - $t0).TotalSeconds -eq 0) { Ok 'nothing to close -> no wait' } else { Bad 'waited with nothing to close' }
$foreign = New-FakeProcess 'WindowsSandboxRemoteSession' 16 -SessionId ($script:mySession + 1)
$noSession = New-FakeProcess 'WindowsSandboxClient' 17 -SessionId $null
$t0 = $script:now
Close-Win32ToolkitSandboxClient -Process @($foreign, $noSession) -WaitSeconds 10
if ($foreign.Closed -eq 0 -and $foreign.Killed -eq 0 -and $noSession.Closed -eq 0 -and $noSession.Killed -eq 0 -and ($script:now - $t0).TotalSeconds -eq 0) { Ok "another session's window (another user's sandbox) or one without a session is never closed or stopped" }
else { Bad "foreign: closed=$($foreign.Closed) killed=$($foreign.Killed) nosession=$($noSession.Closed)/$($noSession.Killed)" }

# --- [3] Wait-Win32ToolkitSandboxFree --------------------------------------------------------------------
Write-Host '[3] Wait-Win32ToolkitSandboxFree: wsb decides a leftover client window' -ForegroundColor Cyan
$script:closeCalls = [System.Collections.Generic.List[object]]::new()
function Close-Win32ToolkitSandboxClient { param([object[]]$Process, [int]$WaitSeconds) $script:closeCalls.Add([pscustomobject]@{ Process = @($Process); WaitSeconds = $WaitSeconds; At = $script:now }); foreach ($p in $Process) { if (-not $p.SurvivesKill) { $p.HasExited = $true } } }
$script:wsbAsked = 0
$script:wsbAnswer = { [pscustomobject]@{ Count = 0 } }
function Get-Win32ToolkitSandboxEnvironment { $script:wsbAsked++; & $script:wsbAnswer }
function Start-Wait([object[]]$Procs, [scriptblock]$Answer, [int]$Timeout = 90, [scriptblock]$OnTick, [switch]$OwnRun) {
    $script:procs = @($Procs); $script:wsbAnswer = $Answer; $script:wsbAsked = 0; $script:closeCalls.Clear(); $script:onTick = $OnTick
    $script:start = $script:now
    $out = @(Wait-Win32ToolkitSandboxFree -TimeoutSeconds $Timeout -OwnRun:$OwnRun 6>&1)
    $script:onTick = $null
    [pscustomobject]@{
        Result  = @($out | Where-Object { $_ -is [bool] }) | Select-Object -Last 1
        Info    = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
        Elapsed = ($script:now - $script:start).TotalSeconds
    }
}
$empty = { [pscustomobject]@{ Count = 0 } }
$one = { [pscustomobject]@{ Count = 1 } }
$unknown = { $null }

# (a) the F1 case: the guest is gone (wsb empty), only the client window is left
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 21
$r = Start-Wait @($client) $empty
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $script:closeCalls[0].Process.Count -eq 1 -and $script:closeCalls[0].Process[0].Id -eq 21 -and $script:closeCalls[0].WaitSeconds -eq 10 -and $closeAt -ge 20 -and $closeAt -le 26) {
    Ok "wsb empty + only the client window -> closed after the 20 s grace ($closeAt s), reported free"
} else { Bad "F1: result=$($r.Result) closes=$($script:closeCalls.Count) at=$closeAt" }
$msg = @($r.Info | Where-Object { $_ -like 'Windows Sandbox reports no running sandbox*' })
if ($msg.Count -eq 1 -and $msg[0] -ceq 'Windows Sandbox reports no running sandbox, but its window (WindowsSandboxRemoteSession) is still open after 20 s: closing it.') { Ok 'one clear line says why the window is closed' } else { Bad "message: $($r.Info -join ' | ')" }

# (b) wsb lists a running sandbox (a watched one): never closed, the wait ends at the timeout
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 22
$r = Start-Wait @($client) $one
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0 -and -not $client.HasExited -and $r.Elapsed -ge 90) { Ok 'wsb lists a sandbox -> nothing is closed; $false at the 90 s timeout' } else { Bad "running: result=$($r.Result) closes=$($script:closeCalls.Count)" }

# (c) no wsb (missing, failed, unexpected output): two failed answers in a row, then the process check alone, as before
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 23
$r = Start-Wait @($client) $unknown
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0 -and $script:wsbAsked -eq 2 -and $r.Elapsed -ge 90) { Ok 'wsb unknown -> asked twice (two failed answers in a row), then the process check only (no close), $false at the timeout' } else { Bad "unknown: result=$($r.Result) closes=$($script:closeCalls.Count) asked=$($script:wsbAsked)" }
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 25
$script:exitAt = $script:sleeps + 3
$r = Start-Wait @($client) $unknown -OnTick { if ($script:sleeps -ge $script:exitAt) { $client.HasExited = $true } }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 0) { Ok 'wsb unknown and the window closes on its own -> $true (unchanged behaviour)' } else { Bad "unknown + exit: $($r.Result)" }

# (d) wsb empty but another Windows Sandbox process is left: wait as before, close nothing
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 26
$legacy = New-FakeProcess 'WindowsSandbox' 27
$r = Start-Wait @($client, $legacy) $empty
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0) { Ok 'wsb empty but WindowsSandbox.exe still runs -> nothing closed, $false at the timeout' } else { Bad "legacy: result=$($r.Result) closes=$($script:closeCalls.Count)" }

# (e) the client window goes away inside the grace period: free, nothing closed
$client = New-FakeProcess 'WindowsSandboxClient' 28
$script:exitAt = $script:sleeps + 4
$r = Start-Wait @($client) $empty -OnTick { if ($script:sleeps -ge $script:exitAt) { $client.HasExited = $true } }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 0 -and $r.Elapsed -lt 20) { Ok 'the window closes on its own within the grace -> $true, nothing closed' } else { Bad "self-close: result=$($r.Result) closes=$($script:closeCalls.Count)" }

# (f) a sandbox appears during the grace: the grace starts again once wsb is empty again
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 29
$script:flip = 0
$r = Start-Wait @($client) { $script:flip++; if ($script:flip -ge 5 -and $script:flip -le 7) { [pscustomobject]@{ Count = 1 } } else { [pscustomobject]@{ Count = 0 } } }
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $closeAt -ge 36) { Ok "a sandbox listed during the grace resets it (closed at $closeAt s, not at 20 s)" } else { Bad "flip: result=$($r.Result) at=$closeAt" }

# (g) free at once: no wsb call, no sleep
$script:sleeps = 0
$r = Start-Wait @() $empty
if ($r.Result -eq $true -and $script:wsbAsked -eq 0 -and $script:sleeps -eq 0) { Ok 'no sandbox process -> $true at once (wsb not asked)' } else { Bad "free: asked=$($script:wsbAsked) sleeps=$($script:sleeps)" }

# (h) the swap: the stale window goes away at 18 s and a NEW sandbox starts (its window shows ~8 s before wsb lists
#     it). The grace is tied to the windows it saw, so the new one is never closed (it was closed at 22 s before).
$stale = New-FakeProcess 'WindowsSandboxRemoteSession' 21
$script:swap = $null
$r = Start-Wait @($stale) { if ($script:swap -and ($script:now - $script:start).TotalSeconds -ge 26) { & $one } else { & $empty } } -OnTick {
    if (-not $script:swap -and ($script:now - $script:start).TotalSeconds -ge 18) {
        $stale.HasExited = $true
        $script:swap = New-FakeProcess 'WindowsSandboxRemoteSession' 22 -StartTime $script:now
        $script:procs = @($script:procs) + $script:swap
    }
}
if ($script:closeCalls.Count -eq 0 -and $r.Result -eq $false -and -not $script:swap.HasExited -and $script:swap.Closed -eq 0) { Ok 'a new sandbox window that replaces the stale one during the grace is never closed (wsb lists it from 26 s); $false at the timeout' }
else { Bad "swap: closes=$($script:closeCalls.Count) at=$(@($script:closeCalls | ForEach-Object { ($_.At - $script:start).TotalSeconds }) -join ',') ids=$(@($script:closeCalls | ForEach-Object { $_.Process.Id }) -join ',') result=$($r.Result)" }

# (i) a stale window plus a NEW window (a sandbox starting at 10 s, listed by wsb from 16 s): nothing is closed
$stale = New-FakeProcess 'WindowsSandboxRemoteSession' 31
$script:newWin = $null
$r = Start-Wait @($stale) { if ($script:newWin -and ($script:now - $script:start).TotalSeconds -ge 16) { & $one } else { & $empty } } -OnTick {
    if (-not $script:newWin -and ($script:now - $script:start).TotalSeconds -ge 10) {
        $script:newWin = New-FakeProcess 'WindowsSandboxClient' 32 -StartTime $script:now
        $script:procs = @($script:procs) + $script:newWin
    }
}
if ($script:closeCalls.Count -eq 0 -and $r.Result -eq $false -and -not $stale.HasExited -and -not $script:newWin.HasExited) { Ok 'a stale window plus a starting sandbox (listed by wsb later) -> nothing closed, $false at the timeout' }
else { Bad "stale+new: closes=$($script:closeCalls.Count) result=$($r.Result)" }
#     the same, but the second window is stale too (wsb never lists anything): the grace restarts when it appears,
#     both are closed together only once that second window has been there for the whole grace
$stale = New-FakeProcess 'WindowsSandboxRemoteSession' 33
$script:newWin = $null
$r = Start-Wait @($stale) $empty -OnTick {
    if (-not $script:newWin -and ($script:now - $script:start).TotalSeconds -ge 10) {
        $script:newWin = New-FakeProcess 'WindowsSandboxClient' 34 -StartTime $script:now
        $script:procs = @($script:procs) + $script:newWin
    }
}
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $closeAt -ge 30 -and (@($script:closeCalls[0].Process.Id | Sort-Object) -join ',') -eq '33,34') { Ok "a second window restarts the grace: both closed together at $closeAt s (not at 22 s)" }
else { Bad "stale+stale: closes=$($script:closeCalls.Count) at=$closeAt result=$($r.Result)" }

# (j) another session's window: wsb (this user) cannot vouch for it -> nothing is closed, the old outcome ($false)
$foreign = New-FakeProcess 'WindowsSandboxRemoteSession' 41 -SessionId ($script:mySession + 1)
$r = Start-Wait @($foreign) $empty
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0 -and -not $foreign.HasExited) { Ok "another session's window (another user's sandbox) -> nothing closed, `$false at the timeout" } else { Bad "foreign: result=$($r.Result) closes=$($script:closeCalls.Count)" }
$mine = New-FakeProcess 'WindowsSandboxRemoteSession' 42
$foreign = New-FakeProcess 'WindowsSandboxClient' 43 -SessionId ($script:mySession + 1)
$r = Start-Wait @($mine, $foreign) $empty
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0) { Ok "a window here plus one in another session -> nothing closed (not even this session's)" } else { Bad "mixed sessions: result=$($r.Result) closes=$($script:closeCalls.Count)" }

# (k) wsb is asked again right before the close: a sandbox listed at that moment restarts the grace
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 51
$script:lastAskAt = $null; $script:denied = $false
$r = Start-Wait @($client) {
    if ($script:lastAskAt -eq $script:now -and -not $script:denied) { $script:denied = $true; & $one }
    else { $script:lastAskAt = $script:now; & $empty }
}
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($script:denied -and $r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $closeAt -ge 40) { Ok "the second wsb answer right before the close lists a sandbox -> not closed then; closed after a new grace ($closeAt s)" }
else { Bad "recheck: denied=$($script:denied) closes=$($script:closeCalls.Count) at=$closeAt" }

# (l) a window that survives the close: no 'closed' line, no $true; the wait goes on and ends $false at the timeout
$tough = New-FakeProcess 'WindowsSandboxRemoteSession' 61 -SurvivesKill
$r = Start-Wait @($tough) $empty
if ($r.Result -eq $false -and $script:closeCalls.Count -ge 1 -and @($r.Info | Where-Object { $_ -like '*Previous sandbox closed*' }).Count -eq 0 -and $r.Elapsed -ge 90) { Ok "a window that cannot be closed -> never reported closed; `$false at the timeout ($($script:closeCalls.Count) attempt(s))" }
else { Bad "survivor: result=$($r.Result) closes=$($script:closeCalls.Count) info=$($r.Info -join ' | ')" }

# (m) a window whose start time cannot be read is not provably old: never closed
$opaque = New-FakeProcess 'WindowsSandboxRemoteSession' 71 -StartTimeThrows
$r = Start-Wait @($opaque) $empty
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0) { Ok 'a window whose start time cannot be read -> never closed' } else { Bad "opaque: result=$($r.Result) closes=$($script:closeCalls.Count)" }

# (n) one failed wsb answer is tolerated (R1 #2: one transient non-JSON answer while a sandbox shut down): the next poll
#     asks again, and a failed answer is never "no sandbox": the grace starts at the first good answer after it.
#     Before: one failed answer turned wsb off for the rest of the wait (no close, $false at the timeout).
$at = { ($script:now - $script:start).TotalSeconds }
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 91
$r = Start-Wait @($client) { if ((& $at) -eq 2) { $null } else { & $empty } }
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $script:closeCalls[0].Process[0].Id -eq 91 -and $closeAt -ge 24 -and $closeAt -le 30) { Ok "one failed wsb answer, then good ones -> still closed, 20 s after the first good answer ($closeAt s)" }
else { Bad "one failure: result=$($r.Result) closes=$($script:closeCalls.Count) at=$closeAt asked=$($script:wsbAsked)" }
#     a failed answer during the grace restarts it: the window is closed only once good answers say "no sandbox" for 20 s
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 92
$r = Start-Wait @($client) { if ((& $at) -eq 12) { $null } else { & $empty } }
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $closeAt -ge 34) { Ok "a failed answer at 12 s restarts the grace: closed at $closeAt s (not at 22 s)" }
else { Bad "failure in the grace: result=$($r.Result) closes=$($script:closeCalls.Count) at=$closeAt" }
#     a failed answer right before the close: not closed then; the next good answers start a new grace
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 93
$script:lastAskAt = $null; $script:denied = $false
$r = Start-Wait @($client) {
    if ($script:lastAskAt -eq $script:now -and -not $script:denied) { $script:denied = $true; $null }
    else { $script:lastAskAt = $script:now; & $empty }
}
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($script:denied -and $r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $closeAt -ge 44) { Ok "the check right before the close fails once -> not closed then; closed after a new grace ($closeAt s)" }
else { Bad "recheck failure: denied=$($script:denied) result=$($r.Result) closes=$($script:closeCalls.Count) at=$closeAt" }
#     a good answer resets the count: failed, good, failed, then good -> never two in a row, still closed
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 94
$r = Start-Wait @($client) { if ((& $at) -in 2, 6) { $null } else { & $empty } }
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $closeAt -ge 28) { Ok "failed / good / failed / good -> not two in a row: closed at $closeAt s" }
else { Bad "alternating: result=$($r.Result) closes=$($script:closeCalls.Count) at=$closeAt asked=$($script:wsbAsked)" }

# (o) two failed wsb answers in a row: the process check alone for the rest of the wait, as before (nothing closed)
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 95
$r = Start-Wait @($client) { if ((& $at) -in 6, 8) { $null } else { & $empty } }
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0 -and -not $client.HasExited -and $script:wsbAsked -eq 4 -and $r.Elapsed -ge 90) { Ok 'good, good, failed, failed -> wsb not asked again (4 answers), nothing closed, $false at the timeout' }
else { Bad "two failures: result=$($r.Result) closes=$($script:closeCalls.Count) asked=$($script:wsbAsked)" }
#     the check right before the close fails, and so does the next poll's answer: two in a row as well
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 96
$script:lastAskAt = $null; $script:denied = $false
$r = Start-Wait @($client) {
    if ($script:denied) { $null }
    elseif ($script:lastAskAt -eq $script:now) { $script:denied = $true; $null }
    else { $script:lastAskAt = $script:now; & $empty }
}
if ($script:denied -and $r.Result -eq $false -and $script:closeCalls.Count -eq 0 -and $script:wsbAsked -eq 13) { Ok 'a failed check right before the close plus a failed answer at the next poll -> two in a row: not asked again (13 answers), nothing closed' }
else { Bad "recheck + next failure: denied=$($script:denied) result=$($r.Result) closes=$($script:closeCalls.Count) asked=$($script:wsbAsked)" }

# --- [7] -OwnRun: the returning unattended test's own sandbox (installer-identity PR 2 follow-up F10) --------------------
Write-Host "[7] Wait-Win32ToolkitSandboxFree -OwnRun: the test's own leftover window, this session only, never without wsb" -ForegroundColor Cyan
$ownWait = "Waiting up to 90 s for this test's Windows Sandbox to close..."
$ownClosed = [string][char]0x2713 + " This test's Windows Sandbox closed."
$ownOpen = 'A Windows Sandbox window of this session is still open after 90 s; the next test waits for it to close.'
# Is wsb.exe installed? The -OwnRun pre-check looks only after a failed first answer (installed by default here; the
# real wsb.exe on this host is never asked: Get-Win32ToolkitSandboxEnvironment is shadowed).
$script:wsbInstalled = $true
$script:wsbLookups = 0
function Get-Command {
    param([string[]]$Name, $CommandType, $ErrorAction)
    if ($Name -contains 'wsb.exe') { $script:wsbLookups++; if ($script:wsbInstalled) { [pscustomobject]@{ Name = 'wsb.exe'; Source = 'C:\fake\wsb.exe' } }; return }
    Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
}
# (a) nothing of this sandbox is left: $true at once, silent, wsb not asked
$script:sleeps = 0
$r = Start-Wait @() $empty -OwnRun
if ($r.Result -eq $true -and $r.Info.Count -eq 0 -and $script:wsbAsked -eq 0 -and $script:sleeps -eq 0) { Ok 'no sandbox process -> $true at once, no output, wsb not asked, no sleep' } else { Bad "own free: result=$($r.Result) info=$($r.Info -join ' | ') asked=$($script:wsbAsked) sleeps=$($script:sleeps)" }
# (b) no wsb.exe: nothing can be judged -> $false at once (the next run's wait handles the window), silent, nothing closed (Fd8)
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 81
$script:sleeps = 0; $script:wsbInstalled = $false
$r = Start-Wait @($client) $unknown -OwnRun
$script:wsbInstalled = $true
if ($r.Result -eq $false -and $script:sleeps -eq 0 -and $r.Info.Count -eq 0 -and $script:closeCalls.Count -eq 0 -and $script:wsbAsked -eq 1 -and -not $client.HasExited) { Ok 'wsb.exe not installed -> $false at once: zero sleeps, no output, nothing closed' }
else { Bad "own no wsb: result=$($r.Result) sleeps=$($script:sleeps) info=$($r.Info -join ' | ') closes=$($script:closeCalls.Count) asked=$($script:wsbAsked)" }
# (c) the F10 case: wsb empty, only this session's stale client window -> closed after the 20 s grace, three exact lines
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 82
$r = Start-Wait @($client) $empty -OwnRun
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
$want = @($ownWait, 'Windows Sandbox reports no running sandbox, but its window (WindowsSandboxRemoteSession) is still open after 20 s: closing it.', $ownClosed)
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $script:closeCalls[0].Process[0].Id -eq 82 -and $closeAt -ge 20 -and $closeAt -le 26) { Ok "wsb empty + this test's stale window -> closed after the 20 s grace ($closeAt s), `$true" }
else { Bad "own stale: result=$($r.Result) closes=$($script:closeCalls.Count) at=$closeAt" }
if (($r.Info -join "`n") -ceq ($want -join "`n")) { Ok "exactly: '$ownWait' / the closing line / '$ownClosed'" } else { Bad "own lines: $($r.Info -join ' | ')" }
# (d) wsb lists the sandbox the whole time: nothing closed, $false at 90 s, a neutral last line
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 83
$r = Start-Wait @($client) $one -OwnRun
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0 -and -not $client.HasExited -and $r.Elapsed -ge 90 -and @($r.Info)[-1] -ceq $ownOpen -and $r.Info.Count -eq 2 -and $r.Info[0] -ceq $ownWait) { Ok "wsb lists it -> nothing closed; `$false at 90 s, last line '$ownOpen'" }
else { Bad "own listed: result=$($r.Result) closes=$($script:closeCalls.Count) elapsed=$($r.Elapsed) info=$($r.Info -join ' | ')" }
# (e) only ANOTHER session's window (another user's sandbox): not this test's -> $true at once, silent, wsb not asked (B6)
$foreign = New-FakeProcess 'WindowsSandboxRemoteSession' 84 -SessionId ($script:mySession + 1)
$script:sleeps = 0
$r = Start-Wait @($foreign) $empty -OwnRun
if ($r.Result -eq $true -and $script:sleeps -eq 0 -and $r.Info.Count -eq 0 -and $script:wsbAsked -eq 0 -and $script:closeCalls.Count -eq 0 -and -not $foreign.HasExited) { Ok "another session's window only -> `$true at once: zero sleeps, no output, wsb not asked, nothing closed" }
else { Bad "own + foreign only: result=$($r.Result) sleeps=$($script:sleeps) info=$($r.Info -join ' | ') asked=$($script:wsbAsked)" }
# (f) this test's stale window plus another session's window: the F1 rule closes nothing; $false at 90 s
$mine = New-FakeProcess 'WindowsSandboxRemoteSession' 85
$foreign = New-FakeProcess 'WindowsSandboxClient' 86 -SessionId ($script:mySession + 1)
$r = Start-Wait @($mine, $foreign) $empty -OwnRun
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0 -and -not $mine.HasExited -and -not $foreign.HasExited -and $r.Elapsed -ge 90 -and @($r.Info)[-1] -ceq $ownOpen) { Ok "this test's window plus another session's -> nothing closed (F1 rule), `$false at 90 s" }
else { Bad "own + foreign: result=$($r.Result) closes=$($script:closeCalls.Count) info=$($r.Info -join ' | ')" }
# (g) R1 #2: one failed wsb answer during the own-run wait no longer skips the close (before: the process check alone,
#     nothing closed, $false at 90 s and the still-open line); two in a row still fall back to the process check
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 88
$r = Start-Wait @($client) { if ((& $at) -eq 2) { $null } else { & $empty } } -OwnRun
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $script:closeCalls[0].Process[0].Id -eq 88 -and $closeAt -ge 24 -and ($r.Info -join "`n") -ceq ($want -join "`n")) { Ok "one failed wsb answer during the own-run wait -> still closed ($closeAt s), the same three lines" }
else { Bad "own one failure: result=$($r.Result) closes=$($script:closeCalls.Count) at=$closeAt info=$($r.Info -join ' | ')" }
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 89
$r = Start-Wait @($client) { if ((& $at) -in 2, 4) { $null } else { & $empty } } -OwnRun
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0 -and -not $client.HasExited -and $script:wsbAsked -eq 3 -and $r.Elapsed -ge 90 -and @($r.Info)[-1] -ceq $ownOpen) { Ok "two failed wsb answers in a row during the own-run wait -> process check only, nothing closed, `$false at 90 s, '$ownOpen'" }
else { Bad "own two failures: result=$($r.Result) closes=$($script:closeCalls.Count) asked=$($script:wsbAsked) info=$($r.Info -join ' | ')" }
# (h) R1 #2 at the pre-check: the FIRST answer (asked right after the test's sandbox shut down, when wsb glitches) fails
#     once and wsb.exe is installed -> asked again after one poll, then the same wait and close as (c), 2 s later.
#     Before: $false at once, silent, and the leftover window stayed open.
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 110
$script:sleeps = 0; $script:wsbLookups = 0
$r = Start-Wait @($client) { if ((& $at) -eq 0) { $null } else { & $empty } } -OwnRun
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $script:closeCalls[0].Process[0].Id -eq 110 -and $client.HasExited -and $closeAt -ge 24 -and $closeAt -le 26 -and $script:wsbLookups -eq 1) { Ok "a failed first answer at the pre-check, then the empty list -> asked again after one poll, closed at $closeAt s, `$true" }
else { Bad "own pre-check one failure: result=$($r.Result) closes=$($script:closeCalls.Count) at=$closeAt lookups=$($script:wsbLookups) asked=$($script:wsbAsked) info=$($r.Info -join ' | ')" }
if (($r.Info -join "`n") -ceq ($want -join "`n")) { Ok "the same three lines: '$ownWait' / the closing line / '$ownClosed'" } else { Bad "own pre-check one failure lines: $($r.Info -join ' | ')" }
# (i) two failed answers in a row at the pre-check: $false after that one poll, silent (no "Waiting" line), nothing closed
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 111
$script:sleeps = 0
$r = Start-Wait @($client) { if ((& $at) -le 2) { $null } else { & $empty } } -OwnRun
if ($r.Result -eq $false -and $r.Info.Count -eq 0 -and $script:closeCalls.Count -eq 0 -and -not $client.HasExited -and $script:wsbAsked -eq 2 -and $script:sleeps -eq 1 -and $r.Elapsed -eq 2) { Ok 'two failed answers in a row at the pre-check -> asked twice, $false after one poll (2 s): no output, nothing closed' }
else { Bad "own pre-check two failures: result=$($r.Result) info=$($r.Info -join ' | ') closes=$($script:closeCalls.Count) asked=$($script:wsbAsked) sleeps=$($script:sleeps) elapsed=$($r.Elapsed)" }
# (j) a failed first answer, and the window closes on its own during that poll: $true, silent, wsb not asked again
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 112
$r = Start-Wait @($client) $unknown -OwnRun -OnTick { $client.HasExited = $true }
if ($r.Result -eq $true -and $r.Info.Count -eq 0 -and $script:closeCalls.Count -eq 0 -and $script:wsbAsked -eq 1 -and $r.Elapsed -eq 2) { Ok 'a failed first answer and the sandbox closes within the poll -> $true, no output, wsb asked once' }
else { Bad "own pre-check then closed: result=$($r.Result) info=$($r.Info -join ' | ') closes=$($script:closeCalls.Count) asked=$($script:wsbAsked) elapsed=$($r.Elapsed)" }
Remove-Item -LiteralPath Function:\Get-Command
# Without -OwnRun nothing changed: the start-up wait's lines ([3] covers its rule).
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 87
$r = Start-Wait @($client) $empty
if (@($r.Info | Where-Object { $_ -like "*this test's*" -or $_ -like '*of this session is still open*' }).Count -eq 0 -and @($r.Info)[-1] -ceq ([string][char]0x2713 + ' Previous sandbox closed.')) { Ok "without -OwnRun: the start-up wait's own lines ('Previous sandbox closed.')" }
else { Bad "start-up lines: $($r.Info -join ' | ')" }

# --- [8] R1 #2 end to end: the real parser between the wait and a fake 'wsb list --raw' -----------------------
Write-Host "[8] Wait-Win32ToolkitSandboxFree + the real parser: an unparseable 'wsb list --raw' is a failed answer, never 'no sandbox'" -ForegroundColor Cyan
. (Join-Path $repo 'Private\Get-Win32ToolkitSandboxEnvironment.ps1')   # the real parser again ([3]/[7] shadowed it)
$script:runnerAsked = 0
$script:runnerOutput = $null
function Invoke-Win32ToolkitWsbList { $script:runnerAsked++; [pscustomobject]@{ ExitCode = 0; Output = (& $script:runnerOutput); ErrorOutput = '' } }
$emptyJson = '{"WindowsSandboxEnvironments":[]}'
$garbled = 'Sandbox environment is shutting down'   # no JSON object (R1: one non-JSON answer, first character S)
function Start-RunnerWait([object[]]$Procs, [scriptblock]$Output) {
    $script:runnerAsked = 0; $script:runnerOutput = $Output
    Start-Wait $Procs { throw 'the shadow is not used here' }
}
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 101
$r = Start-RunnerWait @($client) { if ((& $at) -eq 2) { $garbled } else { $emptyJson } }
$closeAt = if ($script:closeCalls.Count) { ($script:closeCalls[0].At - $script:start).TotalSeconds } else { -1 }
if ($r.Result -eq $true -and $script:closeCalls.Count -eq 1 -and $closeAt -ge 24) { Ok "one non-JSON answer, then the empty list -> closed 20 s after the first good answer ($closeAt s), not at once" }
else { Bad "real parser, one garbled: result=$($r.Result) closes=$($script:closeCalls.Count) at=$closeAt asked=$($script:runnerAsked)" }
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 102
$r = Start-RunnerWait @($client) { $garbled }
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0 -and -not $client.HasExited -and $script:runnerAsked -eq 2) { Ok 'non-JSON answers only -> never taken as "no sandbox": asked twice, nothing closed, $false at the timeout' }
else { Bad "real parser, garbled only: result=$($r.Result) closes=$($script:closeCalls.Count) asked=$($script:runnerAsked)" }
$client = New-FakeProcess 'WindowsSandboxRemoteSession' 103
$r = Start-RunnerWait @($client) { if ((& $at) -in 4, 6) { '{"WindowsSandboxEnvironments":[' } else { $emptyJson } }
if ($r.Result -eq $false -and $script:closeCalls.Count -eq 0 -and $script:runnerAsked -eq 3) { Ok 'good, then two truncated JSON answers in a row -> not asked again (3 answers), nothing closed' }
else { Bad "real parser, truncated: result=$($r.Result) closes=$($script:closeCalls.Count) asked=$($script:runnerAsked)" }

# --- [5] Source checks -------------------------------------------------------------------------------------
Write-Host '[5] Source checks: ASCII new files, C-2 catches, WindowsSandboxServer never targeted' -ForegroundColor Cyan
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
foreach ($f in 'Invoke-Win32ToolkitWsbList', 'Get-Win32ToolkitSandboxEnvironment', 'Close-Win32ToolkitSandboxClient') {
    $file = Join-Path $repo "Private\$f.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
    $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
    $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
    if ($badCatch.Count -eq 0 -and $ascii) { Ok "${f}: ASCII, $($catches.Count) catch clause(s) with the C-2 line" } else { Bad "${f}: ascii=$ascii bad catch at line $($badCatch[0].Extent.StartLineNumber)" }
}
$waitText = [System.IO.File]::ReadAllText((Join-Path $repo 'Private\Wait-Win32ToolkitSandboxFree.ps1'))
$closeText = [System.IO.File]::ReadAllText((Join-Path $repo 'Private\Close-Win32ToolkitSandboxClient.ps1'))
if ($closeText -match "\`$clientNames = @\('WindowsSandboxRemoteSession', 'WindowsSandboxClient'\)" -and $waitText -match "\`$clientNames = @\('WindowsSandboxRemoteSession', 'WindowsSandboxClient'\)" -and
    $waitText -notmatch "'WindowsSandboxServer'" -and $closeText -notmatch "'WindowsSandboxServer'") { Ok 'only WindowsSandboxRemoteSession / WindowsSandboxClient can be closed; WindowsSandboxServer is never named as a target' } else { Bad 'client name list changed' }
# Every process lookup uses -ErrorAction Ignore (SilentlyContinue leaves NoProcessFoundForGivenName records behind).
foreach ($f in 'Wait-Win32ToolkitSandboxFree', 'Test-Win32ToolkitSandboxRunning') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "Private\$f.ps1"), [ref]$null, [ref]$null)
    $gp = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Process' }, $true))
    $notIgnore = @($gp | Where-Object { $_.Extent.Text -notmatch '-ErrorAction Ignore\b' })
    if ($gp.Count -ge 1 -and $notIgnore.Count -eq 0) { Ok "${f}: every Get-Process uses -ErrorAction Ignore ($($gp.Count))" } else { Bad "${f}: $($notIgnore.Count) Get-Process call(s) without -ErrorAction Ignore" }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SandboxStaleClient tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SandboxStaleClient test(s) FAILED." -ForegroundColor Red; exit 1 }
