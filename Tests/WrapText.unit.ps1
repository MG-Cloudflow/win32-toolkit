<#
    Tests Get-Win32ToolkitWrappedText, which caps the health table's Detail column so a long status
    line wraps within its own column instead of squeezing the label columns.

    Run:  pwsh -File Tests\WrapText.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitWrappedText.ps1')

Write-Host "`n[1] short text is returned unchanged (no newlines)" -ForegroundColor Cyan
$r = Get-Win32ToolkitWrappedText -Text 'available' -MaxWidth 50
if ($r -eq 'available') { Ok 'short text unchanged' } else { Bad "changed short text: '$r'" }

Write-Host "`n[2] the long Hyper-V message wraps to lines no wider than MaxWidth" -ForegroundColor Cyan
$long = "host session is not elevated (PowerShell Direct needs an Administrator); VM 'win32tk-golden' not found"
$w = Get-Win32ToolkitWrappedText -Text $long -MaxWidth 50
$lines = $w -split "`n"
if ($lines.Count -gt 1) { Ok "wrapped into $($lines.Count) lines" } else { Bad 'did not wrap' }
$tooWide = @($lines | Where-Object { $_.Length -gt 50 })
if ($tooWide.Count -eq 0) { Ok 'every line is <= 50 chars' } else { Bad "line(s) exceed 50: $($tooWide -join ' | ')" }
if (($w -replace "`n", ' ') -eq $long) { Ok 'no words lost or altered (only spaces became breaks)' } else { Bad 'content changed by wrapping' }

Write-Host "`n[3] a single over-long word is hard-broken (never exceeds MaxWidth)" -ForegroundColor Cyan
$word = 'x' * 130
$hw = Get-Win32ToolkitWrappedText -Text $word -MaxWidth 40
$maxLine = ($hw -split "`n" | Measure-Object -Property Length -Maximum).Maximum
if ($maxLine -le 40) { Ok "hard-broken to <= 40 (longest line $maxLine)" } else { Bad "a line is $maxLine chars" }

Write-Host "`n[4] empty / null input never throws" -ForegroundColor Cyan
$e = $null
try { Get-Win32ToolkitWrappedText -Text '' | Out-Null; Get-Win32ToolkitWrappedText -Text $null | Out-Null } catch { $e = $_ }
if (-not $e) { Ok 'empty and null handled' } else { Bad "threw: $($e.Exception.Message)" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All WrapText tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail WrapText test(s) FAILED." -ForegroundColor Red; exit 1 }
