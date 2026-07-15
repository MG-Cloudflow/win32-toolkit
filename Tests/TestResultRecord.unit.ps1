<#
    Unit tests for the shared TestResults.json contract:
      Add-Win32ToolkitTestResult  — appends one outcome entry (JSON ARRAY, BOM-less UTF-8, newest-last).
      Get-Win32ToolkitTestResult  — reads it back (@() when absent/empty/corrupt).

    Nothing hits the network or the real filesystem outside a fresh temp project.

    Run:  pwsh -File Tests\TestResultRecord.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Add-Win32ToolkitTestResult.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitTestResult.ps1')

function New-Proj {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32tr_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    $p
}

$made = @()

# ── One entry: must still serialise as a JSON ARRAY, and be BOM-less ──────────────────────────────
Write-Host '[1] A single entry serialises as a JSON ARRAY (not a bare object)' -ForegroundColor Cyan
$proj = New-Proj; $made += $proj
$resultsPath = Join-Path $proj 'Documentation\TestResults.json'

$e1 = Add-Win32ToolkitTestResult -ProjectPath $proj -Scenario 'InstallUninstall' -Backend 'Sandbox' `
        -Verdict 'Passed' -Mode 'Unattended' `
        -Assertions @(@{ Name = 'Installed'; Result = 'PASS' }, @{ Name = 'TattooWritten'; Result = 'PASS' }) `
        -Notes 'first run' 3>$null

if (Test-Path -LiteralPath $resultsPath) { Ok 'TestResults.json created' } else { Bad 'file not created' }

# Documentation folder was auto-created
if (Test-Path -LiteralPath (Join-Path $proj 'Documentation')) { Ok 'Documentation folder auto-created' } else { Bad 'no Documentation folder' }

# BOM-less: first three bytes must NOT be EF BB BF
$bytes = [System.IO.File]::ReadAllBytes($resultsPath)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Bad 'file has a UTF-8 BOM (should be BOM-less)'
} else { Ok 'file is BOM-less (no EF BB BF prefix)' }

# Raw text starts with '[' -> array
$raw = Get-Content -LiteralPath $resultsPath -Raw -Encoding UTF8
if ($raw.TrimStart().StartsWith('[')) { Ok 'raw JSON starts with [ (array form)' } else { Bad "raw JSON is not an array: $($raw.Substring(0,[Math]::Min(20,$raw.Length)))" }

# On-disk array even with ONE entry (PowerShell unwraps a 1-element array on ConvertFrom-Json,
# so the durable check is the raw JSON text above; here we confirm exactly one entry parses out).
$parsed = $raw | ConvertFrom-Json
if (@($parsed).Count -eq 1) {
    Ok 'one-entry file parses back to exactly one entry'
} else { Bad "expected 1 entry, got $(@($parsed).Count)" }

# TimestampUtc is stored ISO-8601 (checked on the returned entry / raw text — ConvertFrom-Json
# would coerce it to a [datetime] and lose the original string form).
$ts = $e1.TimestampUtc
$dt = [datetime]::MinValue
if ($ts -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' -and [datetime]::TryParse($ts, [ref]$dt)) {
    Ok "TimestampUtc is ISO-8601 ($ts)"
} else { Bad "TimestampUtc not ISO-8601: $ts" }
if ($raw -match '"TimestampUtc":\s*"\d{4}-\d{2}-\d{2}T') { Ok 'raw JSON stores TimestampUtc in ISO-8601 form' } else { Bad 'raw JSON TimestampUtc not ISO-8601' }

# Returned entry echoes the write
if ($e1.Scenario -eq 'InstallUninstall' -and $e1.Backend -eq 'Sandbox' -and $e1.Verdict -eq 'Passed') {
    Ok 'the written entry is returned'
} else { Bad 'returned entry mismatch' }

# ── Second entry: appended newest-last, both present in order ──────────────────────────────────────
Write-Host '[2] A second entry appends newest-last; order preserved' -ForegroundColor Cyan
$e2 = Add-Win32ToolkitTestResult -ProjectPath $proj -Scenario 'Update' -Backend 'HyperV' `
        -Verdict 'Failed' -Mode 'Interactive' `
        -Assertions @(@{ Name = 'Updated'; Result = 'FAIL' }) `
        -Notes 'second run' 3>$null

$all = Get-Win32ToolkitTestResult -ProjectPath $proj
if (@($all).Count -eq 2) { Ok 'two entries present' } else { Bad "expected 2 entries, got $(@($all).Count)" }
if (@($all)[0].Scenario -eq 'InstallUninstall' -and @($all)[1].Scenario -eq 'Update') {
    Ok 'order preserved (oldest first, newest appended)'
} else { Bad 'entry order wrong' }
if (@($all)[1].Backend -eq 'HyperV' -and @($all)[1].Mode -eq 'Interactive' -and @($all)[1].Verdict -eq 'Failed') {
    Ok 'second entry fields round-trip'
} else { Bad 'second entry fields wrong' }

# Assertions round-trip
$a0 = @($all)[0].Assertions
if (@($a0).Count -eq 2 -and @($a0)[0].Name -eq 'Installed' -and @($a0)[0].Result -eq 'PASS' -and @($a0)[1].Name -eq 'TattooWritten') {
    Ok 'assertions round-trip (name + result)'
} else { Bad 'assertions did not round-trip' }

# ── Corrupt existing file: replaced, not thrown on ────────────────────────────────────────────────
Write-Host '[3] A corrupt existing file is replaced (with a warning), not fatal' -ForegroundColor Cyan
$proj2 = New-Proj; $made += $proj2
New-Item -ItemType Directory -Path (Join-Path $proj2 'Documentation') -Force | Out-Null
$corruptPath = Join-Path $proj2 'Documentation\TestResults.json'
Set-Content -LiteralPath $corruptPath -Value '{ this is not : valid json ][' -Encoding UTF8

$threw = $false
$warn = @()
try {
    $e3 = Add-Win32ToolkitTestResult -ProjectPath $proj2 -Scenario 'InstallUninstall' -Backend 'Sandbox' `
            -Verdict 'Inconclusive' -WarningVariable warn 3>$null
} catch { $threw = $true }
if (-not $threw) { Ok 'append over a corrupt file did not throw' } else { Bad 'threw on corrupt file' }

$after = Get-Win32ToolkitTestResult -ProjectPath $proj2
if (@($after).Count -eq 1 -and @($after)[0].Verdict -eq 'Inconclusive') {
    Ok 'corrupt file replaced with a fresh 1-entry array'
} else { Bad "expected fresh 1-entry array, got $(@($after).Count)" }

# ── Reader on a missing file ──────────────────────────────────────────────────────────────────────
Write-Host '[4] Get-Win32ToolkitTestResult returns @() for a missing file' -ForegroundColor Cyan
$proj3 = New-Proj; $made += $proj3
$none = Get-Win32ToolkitTestResult -ProjectPath $proj3
if ($null -ne $none -and @($none).Count -eq 0) { Ok 'missing file -> @()' } else { Bad "missing file did not return @() (count=$(@($none).Count))" }

# Reader on an empty file
Write-Host '[5] Get-Win32ToolkitTestResult returns @() for an empty file' -ForegroundColor Cyan
$proj4 = New-Proj; $made += $proj4
New-Item -ItemType Directory -Path (Join-Path $proj4 'Documentation') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $proj4 'Documentation\TestResults.json') -Value '' -Encoding UTF8
$empty = Get-Win32ToolkitTestResult -ProjectPath $proj4
if ($null -ne $empty -and @($empty).Count -eq 0) { Ok 'empty file -> @()' } else { Bad 'empty file did not return @()' }

# ── cleanup ───────────────────────────────────────────────────────────────────────────────────────
foreach ($m in $made) { Remove-Item -LiteralPath $m -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestResultRecord tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestResultRecord test(s) FAILED." -ForegroundColor Red; exit 1 }
