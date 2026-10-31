<#
    Tests\Run-All.ps1 itself: the parallel runner, its serial-only phase, -Serial and the output contract.

    Runs Run-All in a CHILD pwsh against the fixture suites in Tests\Fixtures\RunAll\ (never the real suites):

      mixed\  RA-Alpha / RA-Bravo  pass; they meet in a rendezvous folder ($env:W32T_RA_RENDEZVOUS, this
                                   suite's own temp folder), which only works if they run AT THE SAME TIME
              RA-Charlie           fails (exit 1) and writes one stderr line
              RA-Delta             skips itself (exit 3)
              RA-Echo              env-gated (W32T_LIVE_RUNALL_FIXTURE, never set): skipped without running
              RA-Foxtrot / RA-Golf serial-only (the W32T-RUN-SERIAL comment line)
              nested\RA-Hotel      in a sub-folder: never discovered
      green\  RA-Kilo pass, RA-Lima gated, RA-Mike serial-only
      edge\   RA-India             hangs with a child that holds its output (killed by -SuiteTimeoutMinutes)
              RA-Juliet            leaves a child behind that holds its output; prompts once (Read-Host)
              RA-November          6,000 lines of output (printed in chunks) and one non-ASCII line
      hang\   RA-Papa hangs, RA-Quebec passes at once

      [1] parallel run of mixed\: exit 1; 'Total 7: 4 passed, 1 failed, 2 skipped' is the last line; the summary
          (sorted by name) and the wall-clock line; gate SKIP without running; exit 3 -> SKIP; no recursion;
          Alpha and Bravo ran side by side; every suite's output is ONE contiguous block between its RUN line
          and its status line (the FAIL block in full, stderr included); the serial-only suites start after
          every parallel suite ended, one after the other, and print after every parallel block
      [1b] -ThrottleLimit 1 on mixed\: the header says throttle 1, the same totals, and the four parallel-batch
          suites never overlap in time (the limit itself is honoured, not only "at least 2")
      [2] green\: exit 0, 'Total 3: 2 passed, 0 failed, 1 skipped'
      [3] -Serial on mixed\: the same totals and exit code; no two suites ever overlap in time
      [4] -ThrottleLimit outside 1..32, -SuiteTimeoutMinutes below 0 and a missing -Path are refused (non-zero exit)
      [5] edge\ with -SuiteTimeoutMinutes 0.25: India is a FAIL whose block ends with the TIMEOUT line, and its child
          died with it; Run-All moved on 10 s after Juliet exited although Juliet's child (holding its output) still
          ran, and Juliet's Read-Host got end of input at once; November's 6,000 lines are one block, in order, and
          its non-ASCII line reads back intact (when the console code page has the letter)
      [6] a stop (Ctrl+C) during hang\ (Run-All in a PowerShell instance of this process, then Stop()):
          'INTERRUPTED: still running: RA-Papa.hang.ps1', the logs kept (KEPT:, Papa's output in its log), Papa's
          process killed, no summary

    The fixture runs keep their duration history in this suite's own temp folder ($env:W32T_RUNALL_HISTORY), never
    in the shared %TEMP%\w32t-runall-durations.json. Every fixture writes only to stdout/stderr (and marker files in
    that folder); nothing in the repository changes. A fixture's process is recorded as '<pid> <start time>' and
    checked or stopped only while that very process runs (a bare PID can be reused by another process).

    Run:  pwsh -File Tests\RunAllParallel.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$runAll = Join-Path $PSScriptRoot 'Run-All.ps1'
$fx     = Join-Path $PSScriptRoot 'Fixtures\RunAll'
$pwsh   = (Get-Process -Id $PID).Path
Remove-Item Env:\W32T_LIVE_RUNALL_FIXTURE -ErrorAction SilentlyContinue   # the gate stays closed
Remove-Item Env:\W32T_KEEP_TEST_OUTPUT -ErrorAction SilentlyContinue      # the child cleans up its logs

$rv = Join-Path ([System.IO.Path]::GetTempPath()) ('w32ra_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $rv -Force | Out-Null
$env:W32T_RUNALL_HISTORY = Join-Path $rv 'durations.json'                 # never the shared history file

# Runs Run-All in a child pwsh (stdin closed; stdout and stderr copied as bytes); returns its exit code, its output
# lines (Lines: stdout, then stderr; Out: stdout only) and the seconds until the process exited. -AfterExit runs as
# soon as the process has exited, before the rest of its output is awaited (a child that a fixture left behind can
# hold that output open).
function Invoke-RunAll([string[]]$Arguments, [string]$Rendezvous, [scriptblock]$AfterExit) {
    $prev = $env:W32T_RA_RENDEZVOUS
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $rv "runall-$id.out"
    $errFile = Join-Path $rv "runall-$id.err"
    $p = $null; $o = $null; $e = $null; $code = $null; $secs = $null
    try {
        if ($Rendezvous) { $env:W32T_RA_RENDEZVOUS = $Rendezvous } else { Remove-Item Env:\W32T_RA_RENDEZVOUS -ErrorAction SilentlyContinue }
        $o = [System.IO.FileStream]::new($outFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $e = [System.IO.FileStream]::new($errFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $psi = [System.Diagnostics.ProcessStartInfo]::new($pwsh)
        foreach ($a in @('-NoProfile', '-File', $runAll) + @($Arguments)) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $copies = [System.Threading.Tasks.Task[]]@($p.StandardOutput.BaseStream.CopyToAsync($o), $p.StandardError.BaseStream.CopyToAsync($e))
        if (-not $p.WaitForExit(300000)) { $p.Kill($true); [void]$p.WaitForExit(10000); Bad "Run-All $($Arguments -join ' ') did not end within 5 min (killed)" }
        $secs = $sw.Elapsed.TotalSeconds
        if ($AfterExit) { & $AfterExit }
        try { [void][System.Threading.Tasks.Task]::WaitAll($copies, 15000) } catch { $null = $_ }
        if ($p.HasExited) { $code = $p.ExitCode }
    }
    finally {
        if ($p) { try { if (-not $p.HasExited) { $p.Kill($true) } } catch { $null = $_ }; $p.Dispose() }
        if ($o) { $o.Dispose() }
        if ($e) { $e.Dispose() }
        if ($null -ne $prev) { $env:W32T_RA_RENDEZVOUS = $prev } else { Remove-Item Env:\W32T_RA_RENDEZVOUS -ErrorAction SilentlyContinue }
    }
    # Run-All writes in the console's code page (it never changes it): read back in the same one.
    $enc = [Console]::OutputEncoding
    $out = @([System.IO.File]::ReadAllLines($outFile, $enc))
    $err = @([System.IO.File]::ReadAllLines($errFile, $enc))
    [pscustomobject]@{ Code = $code; Lines = [string[]]($out + $err); Out = [string[]]$out; Seconds = $secs }
}

# A fixture's process recorded as '<pid> <start time, FILETIME UTC>' in the rendezvous folder: returned only while
# that very process runs (same PID AND same start time).
function Read-Record([string]$Name) { $f = Join-Path $rv $Name; if (Test-Path -LiteralPath $f) { "$(Get-Content -LiteralPath $f -Raw)".Trim() } }
function Get-RecordedProcess([string]$Record) {
    $m = [regex]::Match("$Record", '^\s*(\d+)\s+(\d+)\s*$')
    if (-not $m.Success) { return $null }
    $p = Get-Process -Id ([int]$m.Groups[1].Value) -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    try { if ($p.StartTime.ToFileTimeUtc() -eq [long]$m.Groups[2].Value) { return $p } } catch { $null = $_ }
    return $null
}
function Wait-RecordedProcessGone([string]$Record, [int]$Seconds = 10) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ((Get-RecordedProcess $Record) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
    -not (Get-RecordedProcess $Record)
}

# Fixture marks 'RA|<tag>|<what>|<utc ticks>' -> @{ <tag> = @{ <what> = ticks } }.
function Get-FixtureMark([string[]]$Lines) {
    $m = @{}
    foreach ($l in $Lines) {
        $p = $l -split '\|'
        if ($p.Count -eq 4 -and $p[0] -eq 'RA' -and $p[3] -match '^\d+$') {
            if (-not $m.ContainsKey($p[1])) { $m[$p[1]] = @{} }
            $m[$p[1]][$p[2]] = [long]$p[3]
        }
    }
    $m
}

# The START..END windows of the given fixture tags, by start time, and the pairs that overlap.
function Get-Overlap([string[]]$Lines, [string[]]$Tags) {
    $mk = Get-FixtureMark $Lines
    $windows = @($Tags | ForEach-Object { if ($mk[$_] -and $mk[$_].ContainsKey('START') -and $mk[$_].ContainsKey('END')) { [pscustomobject]@{ Tag = $_; Start = $mk[$_]['START']; End = $mk[$_]['END'] } } } | Sort-Object Start)
    $overlap = @(for ($i = 1; $i -lt $windows.Count; $i++) { if ($windows[$i].Start -lt $windows[$i - 1].End) { "$($windows[$i - 1].Tag)/$($windows[$i].Tag)" } })
    [pscustomobject]@{ Windows = $windows; Overlap = $overlap }
}

# The block of a suite: the line indexes of its RUN line and of its status line.
function Get-Block([string[]]$Lines, [string]$Name) {
    $start = [array]::IndexOf($Lines, "RUN   $Name")
    $end = -1
    if ($start -ge 0) {
        for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match ('^(PASS|FAIL|SKIP)  ' + [regex]::Escape($Name) + '  \(exit ')) { $end = $i; break }
        }
    }
    [pscustomobject]@{ Start = $start; End = $end }
}
function Get-BlockContent([string[]]$Lines, [string]$Name) {
    $b = Get-Block $Lines $Name
    if ($b.Start -ge 0 -and $b.End -gt $b.Start) { @($Lines[$b.Start..$b.End]) } else { @() }
}

# Every fixture output line carries 'RA|<tag>|': each suite's lines lie inside its own block (RUN line .. status
# line), no other suite's line and no other RUN/status line is inside it. $Tags: suite name -> tag.
function Test-Block([string[]]$Lines, [hashtable]$Tags, [string]$Label) {
    $problems = [System.Collections.Generic.List[string]]::new()
    $owner = @{}
    foreach ($name in $Tags.Keys) {
        $b = Get-Block $Lines $name
        if ($b.Start -lt 0 -or $b.End -lt 0) { $problems.Add("$name has no RUN ... status block"); continue }
        for ($i = $b.Start + 1; $i -lt $b.End; $i++) {
            $owner[$i] = $Tags[$name]
            if ($Lines[$i] -like 'RUN   *' -or $Lines[$i] -match '^(PASS|FAIL|SKIP)  \S+  \(') { $problems.Add("${name}: another RUN/status line inside its block: '$($Lines[$i])'") }
        }
    }
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $own = [regex]::Match($Lines[$i], 'RA\|(\w+)\|')
        if (-not $own.Success -or -not (@($Tags.Values) -contains $own.Groups[1].Value)) { continue }
        if ($owner[$i] -ne $own.Groups[1].Value) { $problems.Add("line $i '$($Lines[$i])' is outside the block of $($own.Groups[1].Value)") }
    }
    if ($problems.Count -eq 0) { Ok "${Label}: every suite's output is one contiguous block (RUN line .. status line), never interleaved" }
    else { Bad "${Label}: $($problems.Count) block problem(s): $(@($problems | Select-Object -First 5) -join ' | ')" }
}

function Test-RunTotal($Run, [string]$Total, [int]$Code, [string]$Label) {
    if ($Run.Code -eq $Code) { Ok "${Label}: exit code $Code" } else { Bad "${Label}: exit code $($Run.Code), expected $Code" }
    $nonEmpty = @($Run.Out | Where-Object { $_.Trim() })   # stdout (with -Serial a suite's stderr is not part of it)
    if ($nonEmpty.Count -and $nonEmpty[-1] -ceq $Total) { Ok "${Label}: the last line is '$Total'" } else { Bad "${Label}: last line '$(if ($nonEmpty.Count) { $nonEmpty[-1] })', expected '$Total'" }
    if (@($Run.Lines | Where-Object { $_ -ceq '================ SUMMARY ================' }).Count -eq 1) { Ok "${Label}: one SUMMARY header" } else { Bad "${Label}: SUMMARY header missing or repeated" }
}

$expectMixed = [ordered]@{
    'RA-Alpha.pass.ps1' = 'PASS'; 'RA-Bravo.pass.ps1' = 'PASS'; 'RA-Charlie.fail.ps1' = 'FAIL'; 'RA-Delta.selfskip.ps1' = 'SKIP'
    'RA-Echo.gated.ps1' = 'SKIP'; 'RA-Foxtrot.serial.ps1' = 'PASS'; 'RA-Golf.serial.ps1' = 'PASS'
}
$ran = @{ 'RA-Alpha.pass.ps1' = 'Alpha'; 'RA-Bravo.pass.ps1' = 'Bravo'; 'RA-Charlie.fail.ps1' = 'Charlie'; 'RA-Delta.selfskip.ps1' = 'Delta'
          'RA-Foxtrot.serial.ps1' = 'Foxtrot'; 'RA-Golf.serial.ps1' = 'Golf' }

try {
    # == [1] parallel ==================================================================================
    Write-Host '[1] parallel run of Fixtures\RunAll\mixed (-ThrottleLimit 4)' -ForegroundColor Cyan
    $r = Invoke-RunAll @('-Path', (Join-Path $fx 'mixed'), '-ThrottleLimit', '4') $rv
    $L = $r.Lines
    Test-RunTotal $r 'Total 7: 4 passed, 1 failed, 2 skipped' 1 'parallel'

    $sumAt = [array]::IndexOf($L, '================ SUMMARY ================')
    $summary = @(if ($sumAt -ge 0) { $L[($sumAt + 1)..($L.Count - 1)] | Where-Object { $_ -match '^  (PASS|FAIL|SKIP) +\S' } })
    $wantSummary = @($expectMixed.Keys | ForEach-Object { '  {0,-5} {1}' -f $expectMixed[$_], $_ })
    if (($summary -join "`n") -ceq ($wantSummary -join "`n")) { Ok "summary: the 7 suites, by name, '  <STATUS> <name>'" } else { Bad "summary: $($summary -join ' | ')" }
    $wall = @($L | Where-Object { $_ -match '^Wall clock \d+([.,]\d)? s \(parallel, throttle 4\); slowest: ' })
    $wallAt = if ($wall.Count) { [array]::IndexOf($L, $wall[0]) } else { -1 }
    if ($wall.Count -eq 1 -and $wallAt -gt $sumAt) { Ok "wall-clock line after the summary: '$($wall[0].Substring(0, [Math]::Min(48, $wall[0].Length)))...'" } else { Bad "wall-clock line: $($wall -join ' | ')" }

    # Gate, self-skip, no recursion.
    if ($L -contains 'SKIP  RA-Echo.gated.ps1  (gated by $env:W32T_LIVE_RUNALL_FIXTURE)') { Ok 'the gated suite is reported SKIP (gated by $env:W32T_LIVE_RUNALL_FIXTURE)' } else { Bad 'no gate SKIP line' }
    if (-not ($L -contains 'RUN   RA-Echo.gated.ps1') -and -not ($L -contains 'RA|Echo|RAN')) { Ok 'the gated suite never ran' } else { Bad 'the gated suite ran' }
    if ($L -contains 'SKIP  RA-Delta.selfskip.ps1  (exit 3)') { Ok 'exit 3 -> SKIP  RA-Delta.selfskip.ps1  (exit 3)' } else { Bad 'no exit-3 SKIP line' }
    if (-not @($L | Where-Object { $_ -like 'RA|Hotel|*' -or $_ -like '*RA-Hotel*' }).Count) { Ok 'a sub-folder suite is never discovered' } else { Bad 'nested\RA-Hotel ran' }

    # Ran side by side.
    $mk = Get-FixtureMark $L
    if ($mk['Alpha'] -and $mk['Bravo'] -and $mk['Alpha'].ContainsKey('PEER') -and $mk['Bravo'].ContainsKey('PEER')) { Ok 'Alpha and Bravo met in the rendezvous: they ran at the same time' }
    else { Bad "rendezvous: Alpha=$(@($mk['Alpha'].Keys) -join ',') Bravo=$(@($mk['Bravo'].Keys) -join ',')" }

    # One contiguous block per suite; the FAIL block in full, with its stderr part.
    Test-Block $L $ran 'parallel'
    $cBlock = Get-BlockContent $L 'RA-Charlie.fail.ps1'
    $needC = @('RA|Charlie|LINE 1', 'RA|Charlie|LINE 5', '  FAIL: RA|Charlie|the fixture failure line', '--- stderr ---', 'RA|Charlie|STDERR', 'FAIL  RA-Charlie.fail.ps1  (exit 1)')
    if (@($needC | Where-Object { $cBlock -notcontains $_ }).Count -eq 0 -and [array]::IndexOf($cBlock, '--- stderr ---') -lt [array]::IndexOf($cBlock, 'RA|Charlie|STDERR')) { Ok 'the FAIL block is printed in full, its stderr line under ''--- stderr ---''' } else { Bad "FAIL block: $($cBlock -join ' | ')" }

    # Serial-only phase.
    if (($L -contains '  serial-only: RA-Foxtrot.serial.ps1 (Run-All self-test fixture (serial-only suites run alone, after the parallel batch))') -and
        ($L -contains '  serial-only: RA-Golf.serial.ps1 (Run-All self-test fixture (serial-only suites run alone, after the parallel batch))')) { Ok 'the run announces both serial-only suites with their reason' } else { Bad 'serial-only announcement missing' }
    $parallelEnds = @('Alpha', 'Bravo', 'Charlie', 'Delta' | ForEach-Object { if ($mk[$_]) { $mk[$_]['END'] } })
    $lastParallelEnd = ($parallelEnds | Measure-Object -Maximum).Maximum
    if ($parallelEnds.Count -eq 4 -and $mk['Foxtrot'] -and $mk['Golf'] -and $mk['Foxtrot']['START'] -ge $lastParallelEnd -and $mk['Golf']['START'] -ge $mk['Foxtrot']['END']) {
        Ok 'serial-only suites started after every parallel suite ended, one after the other (Foxtrot, then Golf)'
    } else { Bad "serial timing: parallel ends=$($parallelEnds -join ',') Foxtrot=$($mk['Foxtrot'] | ConvertTo-Json -Compress) Golf=$($mk['Golf'] | ConvertTo-Json -Compress)" }
    $lastParallelBlock = (@('RA-Alpha.pass.ps1', 'RA-Bravo.pass.ps1', 'RA-Charlie.fail.ps1', 'RA-Delta.selfskip.ps1' | ForEach-Object { (Get-Block $L $_).End }) | Measure-Object -Maximum).Maximum
    if ((Get-Block $L 'RA-Foxtrot.serial.ps1').Start -gt $lastParallelBlock -and (Get-Block $L 'RA-Golf.serial.ps1').Start -gt (Get-Block $L 'RA-Foxtrot.serial.ps1').End) { Ok 'serial-only blocks print after every parallel block' } else { Bad 'serial-only blocks printed before a parallel block' }

    # == [1b] -ThrottleLimit 1 ===========================================================================
    Write-Host '[1b] -ThrottleLimit 1 on Fixtures\RunAll\mixed: the limit itself is honoured' -ForegroundColor Cyan
    $t1 = Invoke-RunAll @('-Path', (Join-Path $fx 'mixed'), '-ThrottleLimit', '1') $null
    Test-RunTotal $t1 'Total 7: 4 passed, 1 failed, 2 skipped' 1 'throttle 1'
    if (@($t1.Lines | Where-Object { $_ -like 'Run-All: 4 suite(s) in parallel (throttle 1), then 2 serial-only suite(s)*' }).Count -eq 1) { Ok "header: '4 suite(s) in parallel (throttle 1)'" } else { Bad "header: $(@($t1.Lines | Where-Object { $_ -like 'Run-All:*' }) -join ' | ')" }
    $o1 = Get-Overlap $t1.Lines @('Alpha', 'Bravo', 'Charlie', 'Delta')
    if ($o1.Windows.Count -eq 4 -and $o1.Overlap.Count -eq 0) { Ok "the 4 parallel-batch suites ran one at a time ($(@($o1.Windows.Tag) -join ', '))" } else { Bad "throttle 1 windows: $($o1.Windows.Count), overlapping: $($o1.Overlap -join ' ')" }

    # == [2] all green ==================================================================================
    Write-Host '[2] Fixtures\RunAll\green: nothing fails -> exit 0' -ForegroundColor Cyan
    $g = Invoke-RunAll @('-Path', (Join-Path $fx 'green'), '-ThrottleLimit', '2') $null
    Test-RunTotal $g 'Total 3: 2 passed, 0 failed, 1 skipped' 0 'green'

    # == [3] -Serial =====================================================================================
    Write-Host '[3] -Serial on Fixtures\RunAll\mixed: same totals, one suite at a time' -ForegroundColor Cyan
    $s = Invoke-RunAll @('-Path', (Join-Path $fx 'mixed'), '-Serial') $null
    Test-RunTotal $s 'Total 7: 4 passed, 1 failed, 2 skipped' 1 'serial'
    if (@($s.Lines | Where-Object { $_ -match '^Wall clock \d+([.,]\d)? s \(serial\); slowest: ' }).Count -eq 1) { Ok 'serial wall-clock line' } else { Bad 'serial wall-clock line missing' }
    $os = Get-Overlap $s.Lines @($ran.Values)
    if ($os.Windows.Count -eq 6 -and $os.Overlap.Count -eq 0) { Ok "the 6 suites ran one at a time ($(@($os.Windows.Tag) -join ', '))" } else { Bad "serial windows: $($os.Windows.Count), overlapping: $($os.Overlap -join ' ')" }
    if (@($s.Lines | Where-Object { $_ -like 'RA|*|SOLO|*' }).Count -eq 2) { Ok 'without a rendezvous folder the peers ran alone (SOLO)' } else { Bad 'SOLO marks missing' }

    # == [4] parameter validation ==========================================================================
    Write-Host '[4] -ThrottleLimit, -SuiteTimeoutMinutes and -Path are validated' -ForegroundColor Cyan
    foreach ($t in '0', '33') {
        $v = Invoke-RunAll @('-Path', (Join-Path $fx 'green'), '-ThrottleLimit', $t) $null
        if ($v.Code -ne 0 -and ($v.Lines -join ' ') -match 'ThrottleLimit' -and -not @($v.Lines | Where-Object { $_ -like 'RUN *' }).Count) { Ok "-ThrottleLimit $t is refused before any suite runs" } else { Bad "-ThrottleLimit $t -> exit $($v.Code): $($v.Lines -join ' | ')" }
    }
    $v = Invoke-RunAll @('-Path', (Join-Path $fx 'green'), '-SuiteTimeoutMinutes', '-1') $null
    if ($v.Code -ne 0 -and ($v.Lines -join ' ') -match 'SuiteTimeoutMinutes' -and -not @($v.Lines | Where-Object { $_ -like 'RUN *' }).Count) { Ok '-SuiteTimeoutMinutes -1 is refused before any suite runs' } else { Bad "-SuiteTimeoutMinutes -1 -> exit $($v.Code): $($v.Lines -join ' | ')" }
    $v = Invoke-RunAll @('-Path', (Join-Path $fx ('missing_' + [guid]::NewGuid().ToString('N').Substring(0, 6)))) $null
    if ($v.Code -ne 0 -and ($v.Lines -join ' ') -match 'is not a folder') { Ok 'a missing -Path is refused' } else { Bad "missing -Path -> exit $($v.Code): $($v.Lines -join ' | ')" }

    # == [5] time limit, leftover child, stdin, big log =====================================================
    Write-Host '[5] Fixtures\RunAll\edge (-SuiteTimeoutMinutes 0.25): time limit, a leftover child, stdin, a big log' -ForegroundColor Cyan
    $edgeRv = Join-Path $rv 'edge'
    New-Item -ItemType Directory -Path $edgeRv -Force | Out-Null
    $script:julietKidAlive = $null
    $ed = Invoke-RunAll @('-Path', (Join-Path $fx 'edge'), '-ThrottleLimit', '3', '-SuiteTimeoutMinutes', '0.25') $edgeRv {
        # Run-All has exited: Juliet's child must still run (Run-All did not wait for it). Then stop it, so this
        # suite's own capture of Run-All's output (which the child also holds) ends.
        $kid = Get-RecordedProcess (Read-Record 'edge\Juliet.kid')
        $script:julietKidAlive = [bool]$kid
        if ($kid) { Stop-Process -InputObject $kid -Force -ErrorAction SilentlyContinue }
    }
    $E = $ed.Lines
    Test-RunTotal $ed 'Total 3: 2 passed, 1 failed, 0 skipped' 1 'edge'
    if (@($E | Where-Object { $_ -like 'Run-All: 3 suite(s) in parallel (throttle 3), then 0 serial-only suite(s); time limit 0.25 min per suite' }).Count -eq 1) { Ok "header: 'time limit 0.25 min per suite'" } else { Bad "header: $(@($E | Where-Object { $_ -like 'Run-All:*' }) -join ' | ')" }
    Test-Block $E @{ 'RA-India.timeout.ps1' = 'India'; 'RA-Juliet.orphan.ps1' = 'Juliet'; 'RA-November.bigout.ps1' = 'November' } 'edge'

    $iBlock = Get-BlockContent $E 'RA-India.timeout.ps1'
    if ($iBlock.Count -ge 3 -and $iBlock[-2] -ceq 'Run-All: TIMEOUT after 0.25 min (process tree killed)' -and $iBlock[-1] -match '^FAIL  RA-India\.timeout\.ps1  \(exit -?\d+\)$' -and @($iBlock | Where-Object { $_ -like 'RA|India|START|*' }).Count -eq 1) {
        Ok "the timed-out suite is a FAIL; its block keeps its output and ends with the TIMEOUT line ('$($iBlock[-1])')"
    } else { Bad "India block: $($iBlock -join ' | ')" }
    $indiaKid = Read-Record 'edge\India.kid'
    if ($indiaKid -match '^\d+ \d+$' -and (Wait-RecordedProcessGone $indiaKid)) { Ok 'the timed-out suite''s child died with it (process tree killed)' } else { Bad "India's child: record '$indiaKid', still running: $([bool](Get-RecordedProcess $indiaKid))" }

    $jBlock = Get-BlockContent $E 'RA-Juliet.orphan.ps1'
    if ($jBlock.Count -and $jBlock[-1] -ceq 'PASS  RA-Juliet.orphan.ps1  (exit 0)' -and @($jBlock | Where-Object { $_ -match 'RA\|Juliet\|STDIN (EOF|ERROR)' }).Count -eq 1) { Ok "a prompt gets end of input at once (stdin closed): '$(@($jBlock | Where-Object { $_ -match 'RA\|Juliet\|STDIN' }) -join '')'" } else { Bad "Juliet block: $($jBlock -join ' | ')" }
    $jSecs = [regex]::Match(($E -join "`n"), 'RA-Juliet\.orphan\.ps1 (\d+(?:[.,]\d)?) s')
    $jSecsValue = if ($jSecs.Success) { [double]($jSecs.Groups[1].Value -replace ',', '.') } else { -1 }
    if ($script:julietKidAlive -eq $true -and $jSecsValue -ge 9 -and $jSecsValue -lt 90) { Ok "a leftover child holding the output delays the result by the 10 s cap only (Juliet: $jSecsValue s; its 180 s child still ran when Run-All ended)" } else { Bad "leftover child: alive when Run-All ended=$($script:julietKidAlive), Juliet took $jSecsValue s" }

    $nb = Get-Block $E 'RA-November.bigout.ps1'
    $nLines = @(if ($nb.Start -ge 0 -and $nb.End -gt $nb.Start) { $E[($nb.Start + 1)..($nb.End - 1)] | Where-Object { $_ -like 'RA|November|LINE *' } })
    $inOrder = $nLines.Count -eq 6000
    if ($inOrder) { for ($i = 0; $i -lt 6000; $i++) { if ($nLines[$i] -cne "RA|November|LINE $($i + 1)") { $inOrder = $false; break } } }
    if ($inOrder -and $E[$nb.End] -ceq 'PASS  RA-November.bigout.ps1  (exit 0)') { Ok 'a 6,000-line log prints as one block, every line once and in order' } else { Bad "November: $($nLines.Count) LINE lines in its block, in order: $inOrder" }
    $glyph = 'RA|November|GLYPH ' + [char]0x00E9
    $enc = [Console]::OutputEncoding
    if ($enc.GetString($enc.GetBytes($glyph)) -cne $glyph) { Write-Host "  SKIP: the console code page ($($enc.CodePage)) has no U+00E9: the non-ASCII check does not apply" -ForegroundColor DarkYellow }
    elseif (@($E[$nb.Start..$nb.End] | Where-Object { $_ -ceq $glyph }).Count -eq 1) { Ok "a non-ASCII letter reads back intact (console code page $($enc.CodePage), unchanged by Run-All)" }
    else { Bad "glyph line: $(@($E | Where-Object { $_ -like 'RA|November|GLYPH*' }) -join ' | ')" }
    if ([Console]::OutputEncoding.CodePage -eq $enc.CodePage) { Ok "the console code page is still $($enc.CodePage) after the run" } else { Bad "the console code page changed to $([Console]::OutputEncoding.CodePage)" }

    # == [6] stop (Ctrl+C) =====================================================================================
    Write-Host '[6] a stop (Ctrl+C) during Fixtures\RunAll\hang: the running suite is named, killed, its log kept' -ForegroundColor Cyan
    $hangRv = Join-Path $rv 'hang'
    New-Item -ItemType Directory -Path $hangRv -Force | Out-Null
    $prevRv = $env:W32T_RA_RENDEZVOUS
    $env:W32T_RA_RENDEZVOUS = $hangRv
    $ps = [powershell]::Create()
    $info = [System.Collections.Generic.List[string]]::new()
    $kept = $null
    try {
        [void]$ps.AddCommand($runAll).AddParameter('Path', (Join-Path $fx 'hang')).AddParameter('ThrottleLimit', 2).AddParameter('SuiteTimeoutMinutes', 0)
        [void]$ps.BeginInvoke()
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        do {
            Start-Sleep -Milliseconds 250
            foreach ($rec in $ps.Streams.Information.ReadAll()) { $info.Add("$($rec.MessageData)") }
        } until (((Read-Record 'hang\Papa.self') -and $info.Contains('PASS  RA-Quebec.pass.ps1  (exit 0)')) -or [DateTime]::UtcNow -gt $deadline)
        $ps.Stop()
        foreach ($rec in $ps.Streams.Information.ReadAll()) { $info.Add("$($rec.MessageData)") }
        $papa = Read-Record 'hang\Papa.self'
        if ($info.Contains('INTERRUPTED: still running: RA-Papa.hang.ps1')) { Ok "a stop names the suite still running: 'INTERRUPTED: still running: RA-Papa.hang.ps1'" } else { Bad "no INTERRUPTED line: $(@($info | Where-Object { $_ }) -join ' | ')" }
        $keptLine = @($info | Where-Object { $_ -like 'KEPT: *' })
        if ($keptLine.Count -eq 1) { $kept = $keptLine[0].Substring(6) }
        $papaLog = if ($kept) { Join-Path $kept 'RA-Papa.hang.ps1.log' } else { $null }
        if ($kept -and (Test-Path -LiteralPath $papaLog) -and @(Get-Content -LiteralPath $papaLog | Where-Object { $_ -like 'RA|Papa|START|*' }).Count -eq 1) { Ok 'the logs are kept without W32T_KEEP_TEST_OUTPUT (KEPT:), the running suite''s output in its log' } else { Bad "KEPT: $($keptLine -join ' | ')" }
        if ($papa -match '^\d+ \d+$' -and (Wait-RecordedProcessGone $papa)) { Ok 'the running suite''s process was killed' } else { Bad "Papa: record '$papa', still running: $([bool](Get-RecordedProcess $papa))" }
        if (-not $info.Contains('================ SUMMARY ================')) { Ok 'no summary after a stop' } else { Bad 'a summary was printed after the stop' }
    }
    finally {
        $ps.Dispose()
        if ($null -ne $prevRv) { $env:W32T_RA_RENDEZVOUS = $prevRv } else { Remove-Item Env:\W32T_RA_RENDEZVOUS -ErrorAction SilentlyContinue }
        if ($kept -and (Split-Path -Leaf $kept) -like 'w32t-runall-*') { Remove-Item -LiteralPath $kept -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
finally {
    # Every fixture process still running (same PID and start time) is stopped; nothing else is touched.
    foreach ($f in @(Get-ChildItem -LiteralPath $rv -Recurse -File -Include '*.kid', '*.self' -ErrorAction SilentlyContinue)) {
        $left = Get-RecordedProcess (Get-Content -LiteralPath $f.FullName -Raw)
        if ($left) { Stop-Process -InputObject $left -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $rv -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All RunAllParallel tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail RunAllParallel test(s) FAILED." -ForegroundColor Red; exit 1 }
