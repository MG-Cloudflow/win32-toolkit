<#
    R4 — Hyper-V result copy-out is ONE zip, with per-file failure isolation and loud errors.

      The old loop did one Copy-Item -FromSession round trip PER FILE with -ErrorAction SilentlyContinue —
      slow (0.5-2 s x N) and blind (a missing log vanished silently). The new shape zips in-guest
      (per-file try/catch so one locked file loses only itself), transfers once, extracts host-side with
      a count check, warns per skipped file, and refuses entries that resolve outside the project root.

      Test campaign F2 (e, f): Sandbox\Logs\Runs\ holds the host's own copy of earlier runs' logs: the guest
      never sends it back and the host never extracts an entry there (a read-only host copy stays untouched).

      Shadows: Invoke-Command executes the given scriptblock LOCALLY (so the real guest code runs against
      a local fixture tree), Copy-Item strips -FromSession / -ToSession. Nothing touches a VM.

      (h) re-verification 2026-10-21 (A1/A2/A3 hv#1): the full Hyper-V round trip — the real copy-in
      (Copy-Win32ToolkitProjectToGuest) then the real copy-back — keeps a file the guest never rewrites at its
      exact UTC write time, run after run; the copy-in's Times map wins over the zip's stamp. The guest's
      C:\Windows\Temp is redirected to a temp folder.

    Run:  pwsh -File Tests\CopyOutBatch.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Copy-Win32ToolkitResultsFromGuest.ps1')
. (Join-Path $repo 'Private\New-Win32ToolkitProjectZip.ps1')         # C-9: the copy-in (h) builds its zip
. (Join-Path $repo 'Private\Copy-Win32ToolkitProjectToGuest.ps1')    # the copy-in half of the round trip (h)

# ── shadows ──────────────────────────────────────────────────────────────────────────────────────
# (h) plays the guest's C:\Windows\Temp (the copy-in zip lands there); $null = not redirected.
$script:guestTemp = $null
function ConvertTo-FakeGuestTemp([object]$Value) {
    if ($script:guestTemp -and $Value -is [string] -and $Value.StartsWith('C:\Windows\Temp\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return (Join-Path $script:guestTemp (Split-Path -Leaf $Value))
    }
    return , $Value
}
# Run the "guest" scriptblock locally with its arguments (the fixture tree plays the guest filesystem).
function Invoke-Command {
    [CmdletBinding()]
    param($Session, [scriptblock]$ScriptBlock, $ArgumentList, [Parameter(ValueFromRemainingArguments)]$Rest)
    if ($script:fakeGuestResult -and "$ScriptBlock" -match 'ZipFile') {
        return $script:fakeGuestResult   # zip-slip case: hand back a crafted result instead of running
    }
    if ($script:guestTemp) {
        $mapped = @(foreach ($a in $ArgumentList) { , (ConvertTo-FakeGuestTemp $a) })
        return (& $ScriptBlock @mapped)
    }
    & $ScriptBlock @ArgumentList
}
# Strip -FromSession / -ToSession and do a plain local copy.
function Copy-Item {
    [CmdletBinding()]
    param($FromSession, $ToSession, $Path, $Destination, [switch]$Force, [Parameter(ValueFromRemainingArguments)]$Rest)
    if ($ToSession) { $Destination = ConvertTo-FakeGuestTemp $Destination }
    Microsoft.PowerShell.Management\Copy-Item -Path $Path -Destination $Destination -Force
}

# Every temp folder/zip is registered here and removed at the end, pass or fail (test campaign 2026-10-21, H7-F12).
$script:tmp = [System.Collections.Generic.List[string]]::new()
function New-TempDir { $p = Join-Path ([System.IO.Path]::GetTempPath()) ('cob_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $script:tmp.Add($p); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }
$script:fakeGuestResult = $null

try {
    # ── (a) faithful relative paths, nested folders, count verified ────────────────────────────────────
    Write-Host '[a] nested results land at the same relative paths under the project' -ForegroundColor Cyan
    $guestRoot = New-TempDir     # plays C:\PSADT in the guest
    $dest      = New-TempDir     # plays the host project
    New-Item -ItemType Directory -Path (Join-Path $guestRoot 'Documentation') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $guestRoot 'Sandbox\Logs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $guestRoot 'Documentation\InstallationChanges_20260716_010101.json') '{"ok":1}'
    Set-Content -LiteralPath (Join-Path $guestRoot 'Sandbox\Logs\Install.log') 'log A'
    Set-Content -LiteralPath (Join-Path $guestRoot 'Sandbox\Logs\AppIcon_Captured.png') 'png-bytes'

    $globs = @((Join-Path $guestRoot 'Documentation\InstallationChanges_*.json'), (Join-Path $guestRoot 'Sandbox\Logs\*'))
    Copy-Win32ToolkitResultsFromGuest -Session 'fake' -GuestPath $globs -Destination $dest -GuestRoot $guestRoot 3>$null

    $expect = @('Documentation\InstallationChanges_20260716_010101.json', 'Sandbox\Logs\Install.log', 'Sandbox\Logs\AppIcon_Captured.png')
    $missing = @($expect | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dest $_)) })
    if ($missing.Count -eq 0) { Ok 'all files extracted at their exact relative paths' } else { Bad "missing after copy-out: $($missing -join ', ')" }
    $content = Get-Content -LiteralPath (Join-Path $dest 'Sandbox\Logs\Install.log') -Raw
    if ($content.Trim() -eq 'log A') { Ok 'file content intact through the zip' } else { Bad 'content mangled' }
    Remove-Item $guestRoot, $dest -Recurse -Force -ErrorAction SilentlyContinue

    # ── (b) one locked file loses only itself — and is REPORTED ────────────────────────────────────────
    Write-Host '[b] a locked guest file is skipped with a WARNING; the rest still copy' -ForegroundColor Cyan
    $guestRoot = New-TempDir
    $dest      = New-TempDir
    New-Item -ItemType Directory -Path (Join-Path $guestRoot 'Sandbox\Logs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $guestRoot 'Sandbox\Logs\good.log') 'fine'
    $lockedPath = Join-Path $guestRoot 'Sandbox\Logs\locked.log'
    Set-Content -LiteralPath $lockedPath 'locked'
    $fs = [System.IO.File]::Open($lockedPath, 'Open', 'Read', 'None')   # exclusive: CreateEntryFromFile will fail
    try {
        $warnings = @()
        Copy-Win32ToolkitResultsFromGuest -Session 'fake' -GuestPath @((Join-Path $guestRoot 'Sandbox\Logs\*')) `
            -Destination $dest -GuestRoot $guestRoot -WarningVariable warnings 3>$null
        if (Test-Path -LiteralPath (Join-Path $dest 'Sandbox\Logs\good.log')) { Ok 'unaffected file still copied' } else { Bad 'good file lost with the locked one' }
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'Sandbox\Logs\locked.log'))) { Ok 'locked file skipped (not half-written)' } else { Bad 'locked file appeared' }
        if ("$warnings" -match 'locked\.log') { Ok 'the skipped file is NAMED in a warning (was silent before)' } else { Bad "no warning naming the file: '$warnings'" }
    }
    finally { $fs.Dispose() }
    Remove-Item $guestRoot, $dest -Recurse -Force -ErrorAction SilentlyContinue

    # ── (c) zero matches -> clean no-op ────────────────────────────────────────────────────────────────
    Write-Host '[c] zero matching guest files -> no-op, no zip, no error' -ForegroundColor Cyan
    $guestRoot = New-TempDir
    $dest      = New-TempDir
    Copy-Win32ToolkitResultsFromGuest -Session 'fake' -GuestPath @((Join-Path $guestRoot 'Documentation\*.json')) -Destination $dest -GuestRoot $guestRoot 3>$null
    if (@(Get-ChildItem -Path $dest -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) { Ok 'nothing extracted, nothing thrown' } else { Bad 'files appeared from nowhere' }
    Remove-Item $guestRoot, $dest -Recurse -Force -ErrorAction SilentlyContinue

    # ── (d) zip-slip: an entry resolving outside the project is refused ────────────────────────────────
    Write-Host '[d]-[f] a crafted ../ entry cannot escape the project root; Sandbox\Logs\Runs\ stays on the host (the guest skips it, the host refuses it)' -ForegroundColor Cyan
    $dest    = New-TempDir
    $evilZip = Join-Path ([System.IO.Path]::GetTempPath()) ('cob_evil_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
    $script:tmp.Add($evilZip)
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    $za = [System.IO.Compression.ZipFile]::Open($evilZip, 'Create')
    try {
        $entry = $za.CreateEntry('../escaped.txt')
        $sw = New-Object System.IO.StreamWriter($entry.Open()); $sw.Write('pwned'); $sw.Dispose()
        $entry2 = $za.CreateEntry('Sandbox/Logs/fine.log')
        $sw2 = New-Object System.IO.StreamWriter($entry2.Open()); $sw2.Write('ok'); $sw2.Dispose()
    }
    finally { $za.Dispose() }
    $script:fakeGuestResult = @{ Zip = $evilZip; Count = 2; Failed = @() }
    $warnings = @()
    Copy-Win32ToolkitResultsFromGuest -Session 'fake' -GuestPath @('C:\PSADT\Sandbox\Logs\*') -Destination $dest -GuestRoot 'C:\PSADT' -WarningVariable warnings 3>$null
    $script:fakeGuestResult = $null
    $escaped = Join-Path (Split-Path $dest -Parent) 'escaped.txt'
    if (-not (Test-Path -LiteralPath $escaped)) { Ok 'traversal entry did NOT escape the project root' } else { Bad 'zip-slip escaped!'; Remove-Item $escaped -Force }
    if (Test-Path -LiteralPath (Join-Path $dest 'Sandbox\Logs\fine.log')) { Ok 'legitimate entry still extracted' } else { Bad 'legit entry lost' }
    if ("$warnings" -match 'outside the project') { Ok 'the refused entry is warned about' } else { Bad "no traversal warning: '$warnings'" }
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue

    # ── (e) test campaign F2: the host's run logs (Sandbox\Logs\Runs\) are never sent back nor overwritten ──
    $guestRoot = New-TempDir
    $dest      = New-TempDir
    New-Item -ItemType Directory -Path (Join-Path $guestRoot 'Sandbox\Logs\Runs\20261020-221500_Update_msi') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $guestRoot 'Sandbox\Logs\Runs\20261020-221500_Update_msi\UpdateAssertions.log') 'guest copy of an old run'
    Set-Content -LiteralPath (Join-Path $guestRoot 'Sandbox\Logs\UpdateAssertions.log') 'this run'
    Set-Content -LiteralPath (Join-Path $guestRoot 'Sandbox\Logs\RunsNotes.txt') 'a sibling whose name starts with Runs'
    $hostRun = Join-Path $dest 'Sandbox\Logs\Runs\20261020-221500_Update_msi\UpdateAssertions.log'
    New-Item -ItemType Directory -Path (Split-Path -Parent $hostRun) -Force | Out-Null
    Set-Content -LiteralPath $hostRun 'host evidence'
    (Get-Item -LiteralPath $hostRun).IsReadOnly = $true   # extracting over it would throw out of the copy-back
    $warnings = @(); $threw = $null
    try { Copy-Win32ToolkitResultsFromGuest -Session 'fake' -GuestPath @((Join-Path $guestRoot 'Sandbox\Logs\*')) -Destination $dest -GuestRoot $guestRoot -WarningVariable warnings 3>$null } catch { $threw = $_ }
    if (-not $threw -and (Get-Content -LiteralPath (Join-Path $dest 'Sandbox\Logs\UpdateAssertions.log') -Raw).Trim() -eq 'this run' -and (Test-Path -LiteralPath (Join-Path $dest 'Sandbox\Logs\RunsNotes.txt'))) { Ok "this run's logs come back (also a sibling named Runs*)" } else { Bad "current logs: threw=$($threw.Exception.Message)" }
    if ((Get-Content -LiteralPath $hostRun -Raw).Trim() -eq 'host evidence') { Ok 'the host copy in Sandbox\Logs\Runs\ is untouched (the guest never sends it)' } else { Bad 'the host run log was overwritten' }
    if (@($warnings).Count -eq 0) { Ok 'no warning (no count mismatch: the guest zipped only results)' } else { Bad "warnings: $($warnings -join ' | ')" }
    (Get-Item -LiteralPath $hostRun).IsReadOnly = $false
    Remove-Item $guestRoot, $dest -Recurse -Force -ErrorAction SilentlyContinue

    # ── (f) a guest that sends a Runs\ entry anyway: refused on the host, with a warning ──────────────────
    $dest    = New-TempDir
    $evilZip = Join-Path ([System.IO.Path]::GetTempPath()) ('cob_runs_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
    $script:tmp.Add($evilZip)
    $za = [System.IO.Compression.ZipFile]::Open($evilZip, 'Create')
    try {
        foreach ($name in 'Sandbox/Logs/Runs/20261020-221500_Update_msi/UpdateAssertions.log', 'Sandbox/Logs/UpdateAssertions.log') {
            $entry = $za.CreateEntry($name)
            $sw = New-Object System.IO.StreamWriter($entry.Open()); $sw.Write('from the guest'); $sw.Dispose()
        }
    }
    finally { $za.Dispose() }
    $script:fakeGuestResult = @{ Zip = $evilZip; Count = 2; Failed = @() }
    $warnings = @()
    Copy-Win32ToolkitResultsFromGuest -Session 'fake' -GuestPath @('C:\PSADT\Sandbox\Logs\*') -Destination $dest -GuestRoot 'C:\PSADT' -WarningVariable warnings 3>$null
    $script:fakeGuestResult = $null
    if (-not (Test-Path -LiteralPath (Join-Path $dest 'Sandbox\Logs\Runs')) -and (Test-Path -LiteralPath (Join-Path $dest 'Sandbox\Logs\UpdateAssertions.log'))) { Ok 'the Runs\ entry is not extracted; the result is' } else { Bad 'a Runs entry was extracted' }
    if ("$warnings" -match 'inside Sandbox\\Logs\\Runs') { Ok 'the refused entry is warned about' } else { Bad "no Runs warning: '$warnings'" }
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $evilZip -Force -ErrorAction SilentlyContinue

    # ── (g) the guest's exact UTC write time survives the zip (test campaign 2026-10-21, H7-F4; TODO F-15) ──
    Write-Host '[g] copied-back files keep the guest''s exact UTC LastWriteTime (not the zip''s local DOS time)' -ForegroundColor Cyan
    $guestRoot = New-TempDir; $dest = New-TempDir
    New-Item -ItemType Directory -Path (Join-Path $guestRoot 'Sandbox\Logs') -Force | Out-Null
    $gf = Join-Path $guestRoot 'Sandbox\Logs\App_Install.log'
    Set-Content -LiteralPath $gf 'log'
    $exact = [datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc).AddTicks(1234567)   # odd seconds + sub-seconds: a DOS stamp cannot hold it
    [System.IO.File]::SetLastWriteTimeUtc($gf, $exact)
    Copy-Win32ToolkitResultsFromGuest -Session 'fake' -GuestPath @((Join-Path $guestRoot 'Sandbox\Logs\*')) -Destination $dest -GuestRoot $guestRoot 3>$null
    $got = [System.IO.File]::GetLastWriteTimeUtc((Join-Path $dest 'Sandbox\Logs\App_Install.log'))
    if ($got -eq $exact) { Ok "exact UTC write time restored ($($exact.ToString('o')))" } else { Bad "write time $($got.ToString('o')) != $($exact.ToString('o'))" }
    Remove-Item $guestRoot, $dest -Recurse -Force -ErrorAction SilentlyContinue
    # A guest value that is not a valid tick count is ignored (bounded, best effort): the zip's own time stays.
    $guestRoot = New-TempDir; $dest = New-TempDir
    $tzip = Join-Path ([System.IO.Path]::GetTempPath()) ('cob_t_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.zip')
    $script:tmp.Add($tzip)
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    $za = [System.IO.Compression.ZipFile]::Open($tzip, 'Create')
    try { $e1 = $za.CreateEntry('Sandbox/Logs/a.log'); $sw = [System.IO.StreamWriter]::new($e1.Open()); $sw.Write('a'); $sw.Dispose()
          $e2 = $za.CreateEntry('Sandbox/Logs/b.log'); $sw = [System.IO.StreamWriter]::new($e2.Open()); $sw.Write('b'); $sw.Dispose() }
    finally { $za.Dispose() }
    $script:fakeGuestResult = @{ Zip = $tzip; Count = 2; Failed = @(); Times = @{ 'Sandbox/Logs/a.log' = $exact.Ticks; 'Sandbox/Logs/b.log' = 'not-ticks; Remove-Item C:\' } }
    Copy-Win32ToolkitResultsFromGuest -Session 'fake' -GuestPath @('C:\PSADT\Sandbox\Logs\*') -Destination $dest -GuestRoot 'C:\PSADT' 3>$null
    $script:fakeGuestResult = $null
    $ga = [System.IO.File]::GetLastWriteTimeUtc((Join-Path $dest 'Sandbox\Logs\a.log')); $gb = Join-Path $dest 'Sandbox\Logs\b.log'
    if ($ga -eq $exact -and (Test-Path -LiteralPath $gb) -and [System.IO.File]::GetLastWriteTimeUtc($gb) -ne $exact) { Ok 'the Times map wins over the zip stamp; a non-numeric value is ignored (file still extracted)' } else { Bad "a=$($ga.ToString('o')) b exists=$(Test-Path -LiteralPath $gb)" }
    Remove-Item $guestRoot, $dest -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $tzip -Force -ErrorAction SilentlyContinue

    # ── (h) the whole round trip: copy-in then copy-back, twice (re-verification 2026-10-21, A1/A2/A3 hv#1) ──
    # A top-level Sandbox\Logs file of an earlier run goes in with the project and comes back with the results
    # glob although the guest never rewrote it. The copy-in used to leave the zip's local DOS stamp on it (the
    # guest runs UTC: +offset), and the exact copy-back then carried that shift to the host, once per run.
    Write-Host '[h] round trip: a file the guest never rewrites keeps its exact UTC write time through copy-in and copy-back, run after run' -ForegroundColor Cyan
    $proj = New-TempDir; $guestRoot = New-TempDir; $gTemp = New-TempDir; $script:guestTemp = $gTemp
    New-Item -ItemType Directory -Path (Join-Path $proj 'Sandbox\Logs'), (Join-Path $proj 'Files') -Force | Out-Null
    $icon = Join-Path $proj 'Sandbox\Logs\AppIcon_Captured.png'
    [System.IO.File]::WriteAllBytes($icon, [byte[]](1..64))
    $exactIn = [datetime]::new(2026, 10, 21, 11, 13, 41, [System.DateTimeKind]::Utc).AddTicks(6143251)   # odd seconds + sub-seconds
    [System.IO.File]::SetLastWriteTimeUtc($icon, $exactIn)
    Set-Content -LiteralPath (Join-Path $proj 'Files\setup.exe') 'x'
    $hashIn = (Get-FileHash -LiteralPath $icon -Algorithm SHA256).Hash
    $guestDest = Join-Path $guestRoot 'PSADT'
    $inGuest = @(); $onHost = @(); $runLogOk = $true
    for ($run = 1; $run -le 2; $run++) {
        Copy-Win32ToolkitProjectToGuest -Session 'fake' -ProjectPath $proj -GuestPath $guestDest
        $inGuest += [System.IO.File]::GetLastWriteTimeUtc((Join-Path $guestDest 'Sandbox\Logs\AppIcon_Captured.png'))
        $runLog = Join-Path $guestDest 'Sandbox\Logs\Run.log'            # this run's own log, written in the guest
        Set-Content -LiteralPath $runLog "run $run"
        $runLogUtc = [System.IO.File]::GetLastWriteTimeUtc($runLog)
        Copy-Win32ToolkitResultsFromGuest -Session 'fake' -GuestPath @((Join-Path $guestDest 'Sandbox\Logs\*')) -Destination $proj -GuestRoot $guestDest 3>$null
        $onHost += [System.IO.File]::GetLastWriteTimeUtc($icon)
        if ([System.IO.File]::GetLastWriteTimeUtc((Join-Path $proj 'Sandbox\Logs\Run.log')) -ne $runLogUtc) { $runLogOk = $false }
    }
    if (@($inGuest | Where-Object { $_ -ne $exactIn }).Count -eq 0) { Ok "copy-in: the guest copy carries the host's exact UTC time on both runs ($($exactIn.ToString('o')))" } else { Bad "guest times: $(@($inGuest | ForEach-Object { $_.ToString('o') }) -join ', ') (want $($exactIn.ToString('o')))" }
    if (@($onHost | Where-Object { $_ -ne $exactIn }).Count -eq 0 -and (Get-FileHash -LiteralPath $icon -Algorithm SHA256).Hash -eq $hashIn) { Ok 'copy-back: the untouched file is unchanged on the host after two runs (no drift)' } else { Bad "host times: $(@($onHost | ForEach-Object { $_.ToString('o') }) -join ', ') (want $($exactIn.ToString('o')))" }
    if ($runLogOk) { Ok "a file the guest wrote still comes back with the guest's exact write time" } else { Bad 'Run.log write time changed on the way back' }

    # A wrong zip stamp (a prebuilt zip, as the thread job builds it) is overridden by the copy-in Times map; an
    # entry with no host file keeps the zip's stamp (best effort).
    $wrong = [DateTimeOffset]::new(1999, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $pzip = Join-Path ([System.IO.Path]::GetTempPath()) ('cob_pre_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.zip')
    $script:tmp.Add($pzip)
    $za = [System.IO.Compression.ZipFile]::Open($pzip, 'Create')
    try {
        $null = $za.CreateEntry('Sandbox/Logs/')
        foreach ($n in 'Sandbox/Logs/AppIcon_Captured.png', 'Sandbox/Logs/orphan.log') {
            $e = $za.CreateEntry($n); $e.LastWriteTime = $wrong
            $s = $e.Open(); try { $s.Write([byte[]](1..4), 0, 4) } finally { $s.Dispose() }
        }
    }
    finally { $za.Dispose() }
    Copy-Win32ToolkitProjectToGuest -Session 'fake' -ProjectPath $proj -GuestPath $guestDest -PrebuiltZip $pzip
    $gi = [System.IO.File]::GetLastWriteTimeUtc((Join-Path $guestDest 'Sandbox\Logs\AppIcon_Captured.png'))
    $go = [System.IO.File]::GetLastWriteTime((Join-Path $guestDest 'Sandbox\Logs\orphan.log'))
    if ($gi -eq $exactIn -and $go.Year -eq 1999 -and -not (Test-Path -LiteralPath $pzip)) { Ok 'the Times map wins over a wrong zip stamp; an entry with no host file keeps the zip stamp; the prebuilt zip is consumed' } else { Bad "icon=$($gi.ToString('o')) orphan=$($go.ToString('o')) zip left=$(Test-Path -LiteralPath $pzip)" }
    $script:guestTemp = $null
    if (@(Get-ChildItem -LiteralPath $gTemp -Force -ErrorAction SilentlyContinue).Count -eq 0) { Ok "no copy-in zip is left in the guest's temp folder" } else { Bad 'a copy-in zip was left in the guest temp folder' }
}
finally { foreach ($tp in $script:tmp) { Remove-Item -LiteralPath $tp -Recurse -Force -ErrorAction SilentlyContinue } }

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
