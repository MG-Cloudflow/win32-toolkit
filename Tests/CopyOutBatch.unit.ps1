<#
    R4 — Hyper-V result copy-out is ONE zip, with per-file failure isolation and loud errors.

      The old loop did one Copy-Item -FromSession round trip PER FILE with -ErrorAction SilentlyContinue —
      slow (0.5-2 s x N) and blind (a missing log vanished silently). The new shape zips in-guest
      (per-file try/catch so one locked file loses only itself), transfers once, extracts host-side with
      a count check, warns per skipped file, and refuses entries that resolve outside the project root.

      Shadows: Invoke-Command executes the given scriptblock LOCALLY (so the real guest code runs against
      a local fixture tree), Copy-Item strips -FromSession. Nothing touches a VM.

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

# ── shadows ──────────────────────────────────────────────────────────────────────────────────────
# Run the "guest" scriptblock locally with its arguments (the fixture tree plays the guest filesystem).
function Invoke-Command {
    [CmdletBinding()]
    param($Session, [scriptblock]$ScriptBlock, $ArgumentList, [Parameter(ValueFromRemainingArguments)]$Rest)
    if ($script:fakeGuestResult -and "$ScriptBlock" -match 'ZipFile') {
        return $script:fakeGuestResult   # zip-slip case: hand back a crafted result instead of running
    }
    & $ScriptBlock @ArgumentList
}
# Strip -FromSession and do a plain local copy.
function Copy-Item {
    [CmdletBinding()]
    param($FromSession, $Path, $Destination, [switch]$Force, [Parameter(ValueFromRemainingArguments)]$Rest)
    Microsoft.PowerShell.Management\Copy-Item -Path $Path -Destination $Destination -Force
}

function New-TempDir { $p = Join-Path ([System.IO.Path]::GetTempPath()) ('cob_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }
$script:fakeGuestResult = $null

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
Write-Host '[d] a crafted ../ entry cannot escape the project root' -ForegroundColor Cyan
$dest    = New-TempDir
$evilZip = Join-Path ([System.IO.Path]::GetTempPath()) ('cob_evil_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
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

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
