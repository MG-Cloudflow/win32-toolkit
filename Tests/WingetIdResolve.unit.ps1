<#
    Regression test for issue #60: winget packaging failed with "Package ID '<id>' not found in winget"
    for EVERY package on a non-English system.

    CAUSE: the -Id fast path verified existence by scraping the English word "Found" from `winget show`.
    winget TRANSLATES that verb on non-English PowerShell (German prints "Gefunden"), so the check was
    always false and packaging never started, even though winget had found the package (exit code 0).

    Resolve-Win32ToolkitWingetId now decides existence by EXIT CODE and reads Name/Version from the
    column-parsed search table (locale-independent). This test shadows winget to return GERMAN output
    with exit 0 (Stefan's exact situation) and asserts the id resolves instead of erroring.

    Run:  pwsh -File Tests\WingetIdResolve.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Resolve-Win32ToolkitWingetId.ps1')

# ── shadows: a fake winget whose EXIT CODE we control and whose OUTPUT is localized, plus a controlled
#    Search-WingetApps (so the real one never shells out) ─────────────────────────────────────────────
$script:wingetExit = 0
$script:showOutput = ''
$script:searchRows = @()
function winget {
    param([Parameter(ValueFromRemainingArguments)]$a)
    $global:LASTEXITCODE = $script:wingetExit   # simulate the native exit code
    if ($script:showOutput) { $script:showOutput }
}
function Search-WingetApps { param($SearchTerm) $script:searchRows }

Write-Host "`n[1] GERMAN winget output + exit 0 resolves (the issue #60 regression)" -ForegroundColor Cyan
$script:wingetExit = 0
$script:showOutput = "Gefunden Postman [Postman.Postman]`nVersion: 11.2.3`nHerausgeber: Postman, Inc."
$script:searchRows = @([pscustomobject]@{ Name = 'Postman'; Id = 'Postman.Postman'; Version = '11.2.3'; Source = 'winget' })
$err = $null; $r = $null
try { $r = Resolve-Win32ToolkitWingetId -Id 'Postman.Postman' } catch { $err = $_.Exception.Message }
if (-not $err) { Ok 'no error on German winget output' } else { Bad "threw: $err" }
if ($r) { Ok 'resolves to a package (not $null) despite German "Gefunden"' } else { Bad 'returned $null on a package that exists (the bug)' }
if ($r -and $r.Name -eq 'Postman')  { Ok "Name from the search table ('Postman'), not the raw Id" } else { Bad "Name was '$($r.Name)'" }
if ($r -and $r.Version -eq '11.2.3') { Ok "Version from the search table ('11.2.3'), not 'Unknown'" } else { Bad "Version was '$($r.Version)'" }

Write-Host "`n[2] a genuinely unknown Id (winget exits non-zero) returns `$null" -ForegroundColor Cyan
$script:wingetExit = -1978335189   # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
$script:searchRows = @()
$r2 = Resolve-Win32ToolkitWingetId -Id 'No.Such.Package'
if ($null -eq $r2) { Ok 'unknown id -> $null (caller emits the "not found" error)' } else { Bad "expected `$null, got $($r2 | ConvertTo-Json -Compress)" }

Write-Host "`n[3] exists (exit 0) but the search returns nothing: graceful fallback" -ForegroundColor Cyan
$script:wingetExit = 0
$script:showOutput = 'Gefunden Foo.Bar [Foo.Bar]'
$script:searchRows = @()
$r3 = Resolve-Win32ToolkitWingetId -Id 'Foo.Bar'
if ($r3 -and $r3.Id -eq 'Foo.Bar') { Ok 'still resolves (does not block packaging)' } else { Bad 'blocked when the package exists' }
if ($r3 -and $r3.Name -eq 'Foo.Bar' -and $r3.Version -eq 'Unknown') { Ok "falls back to Id + 'Unknown' when the table has no row" } else { Bad "fallback was Name='$($r3.Name)' Version='$($r3.Version)'" }

Write-Host "`n[4] ENGLISH winget still works (no regression)" -ForegroundColor Cyan
$script:wingetExit = 0
$script:showOutput = "Found Notepad++ [Notepad++.Notepad++]`nVersion: 8.6.9"
$script:searchRows = @([pscustomobject]@{ Name = 'Notepad++'; Id = 'Notepad++.Notepad++'; Version = '8.6.9'; Source = 'winget' })
$r4 = Resolve-Win32ToolkitWingetId -Id 'Notepad++.Notepad++'
if ($r4 -and $r4.Name -eq 'Notepad++' -and $r4.Version -eq '8.6.9') { Ok 'English output resolves correctly' } else { Bad "English case: Name='$($r4.Name)' Version='$($r4.Version)'" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All WingetIdResolve tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail WingetIdResolve test(s) FAILED." -ForegroundColor Red; exit 1 }
