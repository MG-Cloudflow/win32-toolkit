<#
    Local test runner for win32-toolkit.

    The suites in this folder are HAND-ROLLED .ps1 scripts (NOT Pester): each one
    dot-sources the helpers it needs, asserts, and calls `exit 1` on failure.
    This runner discovers them, launches each in its OWN child pwsh so a crash or a
    stray `exit` in one suite can't take down the run, collects the exit codes, and
    prints a PASS/FAIL summary. It exits non-zero if ANY suite failed.

    Selection (not hard-coded - discovered from the top-level *.ps1 of -Path, default this folder):
      * every *.unit.ps1 and the offline *.integration.ps1 / *.smoke.ps1 suites run.
      * Run-All.ps1 (this file) is excluded; sub-folders (Tests\Fixtures) are never searched.
      * env-gated LIVE suites (e.g. HyperV.integration.ps1, guarded by
        `-not $env:W32T_LIVE_HYPERV`) are SKIPPED unless their gate variable is set.
        The gate is detected by reading each file, so no suite name is hard-coded.
      * a suite that cannot run on this machine (e.g. it needs a real PSAppDeployToolkit and
        none is installed) exits 3 and is reported as SKIP - never as PASS. With
        $env:W32T_REQUIRE_PSADT set, such suites fail (exit 1) instead of skipping (CI).

    Parallel by default: up to -ThrottleLimit suites run at once (default: logical CPUs - 2, at
    least 1), each in its own pwsh with stdin closed (a suite that prompts by mistake reads end of
    input instead of waiting). Each suite's stdout and stderr go to temp files, printed as ONE block
    when the suite ends (RUN line, its stdout, a '--- stderr ---' part when it wrote any, the
    PASS/FAIL/SKIP line), so the output of suites running side by side never interleaves. The
    summary is sorted by suite name.
      * -SuiteTimeoutMinutes (default 30, 0 = no limit): a suite still running after that long has
        its process tree killed and is a FAIL, its block ending with
        'Run-All: TIMEOUT after <N> min (process tree killed)'. A process a suite leaves behind that
        still holds the suite's output delays its result by 10 s at most.
      * Ctrl+C (any stop): the suites without a result are named ('INTERRUPTED: still running: ...'),
        their process trees are killed, and the per-suite logs are kept ('KEPT: <folder>').
      * A suite that must not run next to others carries ONE comment line (detected like the gate):
            # W32T-RUN-SERIAL: <reason>
        Those suites run one at a time AFTER the parallel batch. Prefer making a suite independent
        (unique temp names, shadows) over marking it serial.
      * -Serial runs every suite one after another with its output streamed live (the runner
        before parallelism, unchanged: no time limit).
      * $env:W32T_KEEP_TEST_OUTPUT set: the per-suite logs are kept and their folder printed (KEPT:).
      * The longest suites start first, by the durations of earlier runs on this machine, kept in
        %TEMP%\w32t-runall-durations.json ($env:W32T_RUNALL_HISTORY names another file; scheduling only).
    Text: the suites inherit this console and write in its code page, and their logs are read back
    in the same one. Run-All never changes the code page: it belongs to every process on the
    console (a second Run-All included). A character the code page lacks prints as its best-fit
    replacement, as in any redirected output; switch your console to UTF-8 first if you need it.
    Every suite of a parallel run must also tolerate a SECOND Run-All on the same machine at the
    same time (e.g. the 4.1.8 and 4.2 legs side by side): no fixed temp names, no writes into the
    repository, no registry writes, no machine-wide installs.

    Suite exit codes: 0 = PASS, 3 = SKIP, anything else = FAIL.

    Run:  pwsh -File Tests\Run-All.ps1 [-ThrottleLimit <1-32>] [-SuiteTimeoutMinutes <0-1440>] [-Serial] [-Path <folder>]
#>
[CmdletBinding()]
param(
    # How many suites run at once (each in its own pwsh). Ignored with -Serial.
    [ValidateRange(1, 32)]
    [int]$ThrottleLimit = [Math]::Max(1, [Math]::Min(32, [Environment]::ProcessorCount - 2)),

    # Run the suites one after another with live output (no parallelism, no per-suite logs, no time limit).
    [switch]$Serial,

    # The folder whose top-level *.ps1 are the suites (default: this folder). Used by the runner's
    # own self-test (Tests\RunAllParallel.unit.ps1) against Tests\Fixtures\RunAll\*.
    [ValidateNotNullOrEmpty()]
    [string]$Path = $PSScriptRoot,

    # Minutes one suite may run before its process tree is killed (FAIL, TIMEOUT); 0 = no limit. Fractions
    # are allowed (0.5 = 30 s). Ignored with -Serial.
    [ValidateRange(0, 1440)]
    [double]$SuiteTimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'
$clock = [System.Diagnostics.Stopwatch]::StartNew()
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Run-All: -Path '$Path' is not a folder." }
$testsDir = (Resolve-Path -LiteralPath $Path).ProviderPath
$self     = $MyInvocation.MyCommand.Path

# pwsh to re-launch each suite with. Prefer the executable running this script.
$pwsh = (Get-Process -Id $PID).Path
if (-not $pwsh) { $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
if (-not $pwsh) { $pwsh = 'pwsh' }

# The suites inherit this console and write in its code page: their logs are read back in the same one. Never set
# here: the code page belongs to every process on the console.
$logEncoding = try { [Console]::OutputEncoding } catch { [System.Text.UTF8Encoding]::new($false) }

# Detect an env-gate of the form:  if (-not $env:W32T_LIVE_XXX) { ... exit 0 }
# Returns the gate variable name (e.g. 'W32T_LIVE_HYPERV') or $null if ungated.
function Get-SuiteGate {
    param([string]$Text)
    $m = [regex]::Match($Text, '-not\s+\$env:(W32T_LIVE_\w+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Detect the serial marker: a comment line '# W32T-RUN-SERIAL: <reason>'. Returns the reason or $null.
function Get-SuiteSerialReason {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?m)^[ \t]*#[ \t]*W32T-RUN-SERIAL:[ \t]*(\S[^\r\n]*?)[ \t]*\r?$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-SuiteStatus {
    param($Code)
    # 3 = the suite skipped itself (e.g. no PSAppDeployToolkit installed): SKIP, never PASS.
    switch ($Code) { 0 { 'PASS' } 3 { 'SKIP' } default { 'FAIL' } }
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) { 'PASS' { 'Green' } 'SKIP' { 'DarkGray' } default { 'Red' } }
}

# Suite durations of earlier runs on this machine (scheduling only: never affects a result). One small JSON
# in %TEMP% shared by every checkout ($env:W32T_RUNALL_HISTORY names another file, e.g. for the self-test's
# fixture runs); a missing or unreadable file just means "no history".
$historyFile = if ($env:W32T_RUNALL_HISTORY) { $env:W32T_RUNALL_HISTORY } else { Join-Path ([System.IO.Path]::GetTempPath()) 'w32t-runall-durations.json' }
function Read-SuiteDurationHistory {
    $h = @{}
    try {
        if (Test-Path -LiteralPath $historyFile) {
            $raw = Get-Content -LiteralPath $historyFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            foreach ($k in @($raw.Keys)) { $v = $raw[$k] -as [double]; if ($null -ne $v -and $v -ge 0) { $h[[string]$k] = $v } }
        }
    } catch { $h = @{} }
    return $h
}
# Merges this run's durations into the history: written to a unique file, then moved over the old one
# (an atomic replace), so a second Run-All finishing at the same time never leaves a torn file.
function Save-SuiteDurationHistory {
    param([object[]]$Results)
    $tmp = $null
    try {
        $h = Read-SuiteDurationHistory
        foreach ($r in $Results) { if ($r.Seconds -gt 0) { $h[$r.Name] = [Math]::Round([double]$r.Seconds, 1) } }
        $tmp = "$historyFile.$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($tmp, ($h | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tmp, $historyFile, $true)
    } catch {
        Write-Verbose "Suite duration history not saved: $($_.Exception.Message)"
        if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# Prints one finished suite as a single block: RUN line, its whole log, the status line. A log of up to 5,000 lines
# and 1 MB prints line by line (PASS/FAIL lines coloured); a bigger one prints in 64K-character chunks, uncoloured
# (one Write-Host per line takes minutes for a runaway suite).
function Write-SuiteBlock {
    param([pscustomobject]$Result)
    Write-Host ("RUN   {0}" -f $Result.Name) -ForegroundColor Cyan
    if ($Result.Log -and (Test-Path -LiteralPath $Result.Log)) {
        $lines = $null
        if ((Get-Item -LiteralPath $Result.Log).Length -le 1MB) {
            $lines = [System.IO.File]::ReadAllLines($Result.Log, $logEncoding)
            if ($lines.Count -gt 5000) { $lines = $null }
        }
        if ($null -ne $lines) {
            foreach ($line in $lines) {
                if ($line -match '^\s*FAIL\b') { Write-Host $line -ForegroundColor Red }
                elseif ($line -match '^\s*PASS\b') { Write-Host $line -ForegroundColor Green }
                else { Write-Host $line }
            }
        }
        else {
            $reader = [System.IO.StreamReader]::new($Result.Log, $logEncoding, $true)
            try {
                $buf = [char[]]::new(65536)
                $last = [char]10
                while (($n = $reader.Read($buf, 0, $buf.Length)) -gt 0) {
                    Write-Host ([string]::new($buf, 0, $n)) -NoNewline
                    $last = $buf[$n - 1]
                }
                if ($last -ne [char]10) { Write-Host '' }
            }
            finally { $reader.Dispose() }
        }
    }
    Write-Host ("{0}  {1}  (exit {2})" -f $Result.Status, $Result.Name, $Result.ExitCode) -ForegroundColor (Get-StatusColor $Result.Status)
    Write-Host ''
}

$suites = Get-ChildItem -LiteralPath $testsDir -Filter '*.ps1' -File |
    Where-Object { $_.FullName -ne $self -and $_.Name -ne 'Run-All.ps1' } |
    Sort-Object Name

$results = [System.Collections.Generic.List[object]]::new()

if ($Serial) {
    # The sequential runner: one suite after another, output streamed live to this console.
    foreach ($suite in $suites) {
        $gate = Get-SuiteGate -Text (Get-Content -LiteralPath $suite.FullName -Raw)
        if ($gate -and -not (Get-Item -Path ("Env:$gate") -ErrorAction SilentlyContinue)) {
            Write-Host ("SKIP  {0}  (gated by `$env:{1})" -f $suite.Name, $gate) -ForegroundColor DarkGray
            $results.Add([pscustomobject]@{ Name = $suite.Name; Status = 'SKIP'; ExitCode = $null; Seconds = 0 })
            continue
        }

        Write-Host ("RUN   {0}" -f $suite.Name) -ForegroundColor Cyan
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $pwsh -NoProfile -File $suite.FullName
        $code = $LASTEXITCODE
        $status = Get-SuiteStatus $code
        Write-Host ("{0}  {1}  (exit {2})" -f $status, $suite.Name, $code) -ForegroundColor (Get-StatusColor $status)
        Write-Host ''
        $results.Add([pscustomobject]@{ Name = $suite.Name; Status = $status; ExitCode = $code; Seconds = $sw.Elapsed.TotalSeconds })
    }
}
else {
    # Classify: gated (SKIP now), serial-only (after the batch), parallel.
    $parallelSuites = [System.Collections.Generic.List[object]]::new()
    $serialSuites   = [System.Collections.Generic.List[object]]::new()
    foreach ($suite in $suites) {
        $text = Get-Content -LiteralPath $suite.FullName -Raw
        $gate = Get-SuiteGate -Text $text
        if ($gate -and -not (Get-Item -Path ("Env:$gate") -ErrorAction SilentlyContinue)) {
            Write-Host ("SKIP  {0}  (gated by `$env:{1})" -f $suite.Name, $gate) -ForegroundColor DarkGray
            $results.Add([pscustomobject]@{ Name = $suite.Name; Status = 'SKIP'; ExitCode = $null; Seconds = 0 })
            continue
        }
        $reason = Get-SuiteSerialReason -Text $text
        $entry = [pscustomobject]@{ Name = $suite.Name; FullName = $suite.FullName; SerialReason = $reason }
        if ($reason) { $serialSuites.Add($entry) } else { $parallelSuites.Add($entry) }
    }
    # Longest first (by the last recorded durations; a suite never timed counts as longest), so a slow
    # suite never starts at the end of the batch and stretches the wall clock.
    $history = Read-SuiteDurationHistory
    $parallelSuites = @($parallelSuites | Sort-Object -Property @(
            @{ Expression = { if ($history.ContainsKey($_.Name)) { [double]$history[$_.Name] } else { [double]::MaxValue } }; Descending = $true }
            @{ Expression = 'Name'; Descending = $false }))
    $limitText = if ($SuiteTimeoutMinutes -gt 0) { '{0} min per suite' -f $SuiteTimeoutMinutes.ToString([System.Globalization.CultureInfo]::InvariantCulture) } else { 'none' }
    Write-Host ("Run-All: {0} suite(s) in parallel (throttle {1}), then {2} serial-only suite(s); time limit {3}" -f $parallelSuites.Count, $ThrottleLimit, $serialSuites.Count, $limitText) -ForegroundColor Cyan
    foreach ($s in $serialSuites) { Write-Host ("  serial-only: {0} ({1})" -f $s.Name, $s.SerialReason) -ForegroundColor DarkGray }

    # One temp folder per run (two runs side by side never share a log), removed at the end.
    $logDir = Join-Path ([System.IO.Path]::GetTempPath()) ('w32t-runall-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Write-Host ("  logs: {0}" -f $logDir) -ForegroundColor DarkGray
    Write-Host ''
    # The children inherit this folder as their working directory, as with the sequential runner.
    $cwd = (Get-Location -PSProvider FileSystem).ProviderPath
    # The suites a runner started (names), for the INTERRUPTED line. Shared with the parallel runspaces.
    $started = [System.Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()
    # Each running suite blocks two thread-pool threads reading its output (Windows pipes are synchronous): have
    # them from the start instead of the pool adding threads slowly.
    $minWorker = 0; $minIo = 0
    [System.Threading.ThreadPool]::GetMinThreads([ref]$minWorker, [ref]$minIo)
    if ($minWorker -lt 2 * $ThrottleLimit + 4) { [void][System.Threading.ThreadPool]::SetMinThreads(2 * $ThrottleLimit + 4, $minIo) }

    # Runs ONE suite in its own pwsh (stdin closed, stdout + stderr copied as bytes into its log); returns the result.
    # Text, so each parallel runspace can build its own copy (a script block cannot cross runspaces).
    $runSuiteText = {
        param($Suite, $LogDir, $Pwsh, $Cwd, [double]$TimeoutMinutes, $Started)
        $ErrorActionPreference = 'Continue'
        $log    = Join-Path $LogDir ($Suite.Name + '.log')
        $errLog = Join-Path $LogDir ($Suite.Name + '.stderr')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $code = -1; $timedOut = $false; $problem = $null
        $p = $null; $out = $null; $err = $null; $copies = $null
        try {
            $out = [System.IO.FileStream]::new($log, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            $err = [System.IO.FileStream]::new($errLog, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            $psi = [System.Diagnostics.ProcessStartInfo]::new($Pwsh)
            foreach ($a in @('-NoProfile', '-File', $Suite.FullName)) { $psi.ArgumentList.Add($a) }
            $psi.WorkingDirectory       = $Cwd
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardInput  = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            [void]$Started.TryAdd($Suite.Name, $true)
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $copies = [System.Threading.Tasks.Task[]]@(
                $p.StandardOutput.BaseStream.CopyToAsync($out),
                $p.StandardError.BaseStream.CopyToAsync($err))
            $limit = if ($TimeoutMinutes -gt 0) { [TimeSpan]::FromMinutes($TimeoutMinutes) } else { [TimeSpan]::MaxValue }
            # Short waits, so a stop (Ctrl+C) is seen within half a second.
            while (-not $p.WaitForExit(500)) {
                if ($sw.Elapsed -ge $limit) {
                    $timedOut = $true
                    try { $p.Kill($true) } catch { $null = $_ }
                    [void]$p.WaitForExit(10000)
                    break
                }
            }
            # A process the suite left behind can hold its output open: wait for the rest at most 10 s.
            try { [void][System.Threading.Tasks.Task]::WaitAll($copies, 10000) } catch { $null = $_ }
            if ($p.HasExited) { $code = $p.ExitCode }
        }
        catch { $problem = "Run-All: could not run the suite: $($_.Exception.Message)" }
        finally {
            # Also on a stop: kill the suite's process tree, keep what it wrote.
            if ($p) {
                try { if (-not $p.HasExited) { $p.Kill($true) } } catch { $null = $_ }
                if ($copies) { try { [void][System.Threading.Tasks.Task]::WaitAll($copies, 2000) } catch { $null = $_ } }
                $p.Dispose()
            }
            if ($out) { $out.Dispose() }
            if ($err) { $err.Dispose() }
        }
        # The stderr part, the timeout and a launch problem go at the end of the log, in ASCII (the same bytes in
        # every code page the suite may have written in).
        try {
            $fs = [System.IO.FileStream]::new($log, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            try {
                $crlf = [byte[]](13, 10)
                $endsLine = $true
                if ($fs.Length -gt 0) { [void]$fs.Seek(-1, [System.IO.SeekOrigin]::End); $endsLine = $fs.ReadByte() -eq 10 }
                [void]$fs.Seek(0, [System.IO.SeekOrigin]::End)
                if ((Test-Path -LiteralPath $errLog) -and (Get-Item -LiteralPath $errLog).Length -gt 0) {
                    if (-not $endsLine) { $fs.Write($crlf, 0, 2) }
                    $b = [System.Text.Encoding]::ASCII.GetBytes("--- stderr ---`r`n"); $fs.Write($b, 0, $b.Length)
                    $es = [System.IO.FileStream]::new($errLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    try { $es.CopyTo($fs); [void]$es.Seek(-1, [System.IO.SeekOrigin]::End); $endsLine = $es.ReadByte() -eq 10 } finally { $es.Dispose() }
                }
                $notes = @(
                    if ($timedOut) { 'Run-All: TIMEOUT after {0} min (process tree killed)' -f $TimeoutMinutes.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
                    if ($problem) { $problem })
                foreach ($note in $notes) {
                    if (-not $endsLine) { $fs.Write($crlf, 0, 2); $endsLine = $true }
                    $b = [System.Text.Encoding]::ASCII.GetBytes("$note`r`n"); $fs.Write($b, 0, $b.Length)
                }
            }
            finally { $fs.Dispose() }
        }
        catch { $null = $_ }
        Remove-Item -LiteralPath $errLog -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{ Name = $Suite.Name; ExitCode = $code; TimedOut = $timedOut; Log = $log; Seconds = $sw.Elapsed.TotalSeconds }
    }.ToString()

    $completed = $false
    try {
        $collect = {
            param($r)
            $r | Add-Member -NotePropertyName Status -NotePropertyValue $(if ($r.TimedOut) { 'FAIL' } else { Get-SuiteStatus $r.ExitCode })
            Write-SuiteBlock $r
            $results.Add($r)
        }

        if ($parallelSuites.Count -gt 0) {
            $parallelSuites | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
                $run = [scriptblock]::Create($using:runSuiteText)
                & $run $_ $using:logDir $using:pwsh $using:cwd $using:SuiteTimeoutMinutes $using:started
            } | ForEach-Object { & $collect $_ }
        }

        $runSuite = [scriptblock]::Create($runSuiteText)
        foreach ($s in $serialSuites) {
            & $collect (& $runSuite $s $logDir $pwsh $cwd $SuiteTimeoutMinutes $started)
        }
        $completed = $true
    }
    finally {
        if ($completed) {
            if ($env:W32T_KEEP_TEST_OUTPUT) { Write-Host "KEPT: $logDir" -ForegroundColor DarkGray }
            else { Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        else {
            # Stopped (Ctrl+C) or broken: name the suites without a result and keep every log for the post-mortem.
            $done = @{}
            foreach ($r in $results) { $done[$r.Name] = $true }
            $pending = @(@($parallelSuites) + @($serialSuites) | Where-Object { -not $done.ContainsKey($_.Name) })
            $running = @($pending | Where-Object { $started.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
            $waiting = @($pending | Where-Object { -not $started.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
            Write-Host ''
            Write-Host ("INTERRUPTED: still running: {0}" -f $(if ($running.Count) { $running -join ', ' } else { 'none' })) -ForegroundColor Red
            if ($waiting.Count) { Write-Host ("INTERRUPTED: not started: {0}" -f ($waiting -join ', ')) -ForegroundColor DarkGray }
            Write-Host "KEPT: $logDir" -ForegroundColor DarkGray
        }
    }
}

$sorted = @($results | Sort-Object Name)
Save-SuiteDurationHistory -Results $sorted
Write-Host '================ SUMMARY ================' -ForegroundColor White
foreach ($r in $sorted) {
    $color = switch ($r.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Write-Host ("  {0,-5} {1}" -f $r.Status, $r.Name) -ForegroundColor $color
}

$passed  = @($sorted | Where-Object Status -eq 'PASS').Count
$failed  = @($sorted | Where-Object Status -eq 'FAIL').Count
$skipped = @($sorted | Where-Object Status -eq 'SKIP').Count
$mode    = if ($Serial) { 'serial' } else { "parallel, throttle $ThrottleLimit" }
$slowest = @($sorted | Where-Object { $_.Seconds -gt 0 } | Sort-Object Seconds -Descending | Select-Object -First 5 |
    ForEach-Object { '{0} {1:0.0} s' -f $_.Name, $_.Seconds })
Write-Host ''
Write-Host ("Wall clock {0:0.0} s ({1}); slowest: {2}" -f $clock.Elapsed.TotalSeconds, $mode, $(if ($slowest.Count) { $slowest -join ', ' } else { 'none' })) -ForegroundColor DarkGray
Write-Host ("Total {0}: {1} passed, {2} failed, {3} skipped" -f $sorted.Count, $passed, $failed, $skipped) `
    -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })

if ($failed -gt 0) { exit 1 }
exit 0
