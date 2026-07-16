# SparseConfig.unit.ps1 — F1: New-Win32ToolkitSparseConfig emits a SPARSE, valid, correctly-typed
# PSADT config.psd1 from an org template. Guards the superimpose contract: omit-unset-keys, bare-hex
# FluentAccentColor, quote-escaped strings, $env tokens preserved, DialogStyle/LanguageOverride.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'Private\New-Win32ToolkitSparseConfig.ps1')

$fail = 0
function Ok  { param($m) Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad { param($m) Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

function Import-Sparse { param([string]$text)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('sparse_' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.psd1')
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($true)))
    try { Import-PowerShellDataFile -LiteralPath $tmp } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n[1] Full template — all keys, correct typing" -ForegroundColor Cyan
$t1 = [pscustomobject]@{
    CompanyName='Acme IT'; LogPath='$envWinDir\Logs\Software'
    DialogStyle='Classic'; FluentAccentColor='0xFF0078D7'; LanguageOverride='nl'
}
$c1 = New-Win32ToolkitSparseConfig -Template $t1
$p1 = Import-Sparse $c1
if ($p1.Toolkit.CompanyName -eq 'Acme IT') { Ok 'CompanyName' } else { Bad "CompanyName=[$($p1.Toolkit.CompanyName)]" }
if ($p1.Toolkit.LogPath -eq '$envWinDir\Logs\Software') { Ok 'LogPath preserves $env token verbatim' } else { Bad "LogPath=[$($p1.Toolkit.LogPath)]" }
if ($p1.UI.DialogStyle -eq 'Classic') { Ok 'DialogStyle=Classic' } else { Bad "DialogStyle=[$($p1.UI.DialogStyle)]" }
# Bare hex must parse as an integer, exactly as PSADT's own 0xFF0078D7 default does.
if ($p1.UI.FluentAccentColor -is [int] -and $p1.UI.FluentAccentColor -eq 0xFF0078D7) { Ok 'FluentAccentColor bare hex -> Int32' } else { Bad "accent=[$($p1.UI.FluentAccentColor)] type=[$($p1.UI.FluentAccentColor.GetType().Name)]" }
if ($p1.UI.LanguageOverride -eq 'nl') { Ok 'LanguageOverride' } else { Bad "lang=[$($p1.UI.LanguageOverride)]" }

Write-Host "`n[2] Sparse — unset keys are OMITTED (cannot blank a default)" -ForegroundColor Cyan
$t2 = [pscustomobject]@{ CompanyName='Bare Co'; LogPath=''; DialogStyle='Fluent'; FluentAccentColor=''; LanguageOverride='' }
$c2 = New-Win32ToolkitSparseConfig -Template $t2
$p2 = Import-Sparse $c2
if (-not $p2.Toolkit.ContainsKey('LogPath')) { Ok 'empty LogPath omitted' } else { Bad 'empty LogPath emitted' }
if (-not $p2.UI.ContainsKey('FluentAccentColor')) { Ok 'empty accent omitted' } else { Bad 'empty accent emitted' }
if (-not $p2.UI.ContainsKey('LanguageOverride')) { Ok 'empty language omitted' } else { Bad 'empty language emitted' }
if ($c2 -notmatch "''" ) { Ok 'no empty-string literals in output' } else { Bad 'output contains empty-string literals' }

Write-Host "`n[3] Old-schema template (missing new fields) degrades cleanly" -ForegroundColor Cyan
$t3 = [pscustomobject]@{ CompanyName='Legacy Co'; LogPath='C:\Logs' }  # no DialogStyle/accent/language
$c3 = New-Win32ToolkitSparseConfig -Template $t3
$p3 = Import-Sparse $c3
if ($p3.UI.DialogStyle -eq 'Fluent') { Ok 'missing DialogStyle -> defaults to Fluent' } else { Bad "DialogStyle=[$($p3.UI.DialogStyle)]" }
if ($p3.Toolkit.CompanyName -eq 'Legacy Co') { Ok 'CompanyName present' } else { Bad 'CompanyName missing' }

Write-Host "`n[4] Injection safety — apostrophes doubled, output still parses" -ForegroundColor Cyan
$t4 = [pscustomobject]@{ CompanyName="O'Brien's IT"; LogPath="C:\Logs\O'Neil"; DialogStyle='Fluent' }
$c4 = New-Win32ToolkitSparseConfig -Template $t4
$p4 = Import-Sparse $c4
if ($p4.Toolkit.CompanyName -eq "O'Brien's IT") { Ok "CompanyName apostrophes round-trip" } else { Bad "company=[$($p4.Toolkit.CompanyName)]" }
if ($p4.Toolkit.LogPath -eq "C:\Logs\O'Neil") { Ok 'LogPath apostrophes round-trip' } else { Bad "logpath=[$($p4.Toolkit.LogPath)]" }

Write-Host "`n[5] Invalid DialogStyle falls back to Fluent (never emits garbage)" -ForegroundColor Cyan
$t5 = [pscustomobject]@{ CompanyName='X'; DialogStyle='Neon' }
$p5 = Import-Sparse (New-Win32ToolkitSparseConfig -Template $t5)
if ($p5.UI.DialogStyle -eq 'Fluent') { Ok "invalid style -> Fluent" } else { Bad "style=[$($p5.UI.DialogStyle)]" }

Write-Host ""
if ($fail -eq 0) { Write-Host "SparseConfig unit test PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILURE(S)" -ForegroundColor Red; exit 1 }
