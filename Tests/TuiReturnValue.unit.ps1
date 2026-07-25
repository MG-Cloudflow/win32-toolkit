<#
    Regression test for the settings->main-menu crash:
        "Cannot process argument transformation on parameter 'BasePath'. Cannot convert value to
         type System.String."

    CAUSE: PwshSpectreConsole 2.6.3 changed Write-SpectreRule / Format-SpectreTable / Format-SpectrePanel
    to RETURN their renderable to the pipeline (they used to render only). The TUI screens whose RETURN
    VALUE is captured by the caller ($base = Show-Win32ToolkitSettings ...; $base = Show-Win32ToolkitFirstRun)
    therefore leaked those objects into $base, making it an array; the next Show-Win32ToolkitHealth
    -BasePath $base then failed to bind the [string] parameter. The fix pipes those renders through
    Out-SpectreHost (render + return nothing).

    This test SHADOWS the Spectre cmdlets to LEAK exactly as 2.6.3 does, then asserts each captured screen
    returns a single clean string. With the fix (| Out-SpectreHost) the leak is consumed; without it, the
    shadow's leaked object would pollute the return and these assertions fail.

    Run:  pwsh -File Tests\TuiReturnValue.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitWrappedText.ps1')
. (Join-Path $repo 'Private\Show-Win32ToolkitHealth.ps1')
. (Join-Path $repo 'Private\Show-Win32ToolkitSettings.ps1')
. (Join-Path $repo 'Private\Show-Win32ToolkitFirstRun.ps1')

# ── Spectre shadows that LEAK like 2.6.3 (return a renderable), plus a consuming Out-SpectreHost ────
function Write-SpectreRule    { param([Parameter(ValueFromRemainingArguments)]$a) '[leaked-rule-string]' }
function Format-SpectrePanel  { param([Parameter(ValueFromRemainingArguments)]$a) [pscustomobject]@{ Leaked = 'panel' } }
function Format-SpectreTable  { param([Parameter(ValueFromPipeline)]$InputObject, [Parameter(ValueFromRemainingArguments)]$a) end { [pscustomobject]@{ Leaked = 'table' } } }
function Out-SpectreHost      { param([Parameter(ValueFromPipeline)]$InputObject) process { } }   # render + return NOTHING
function Write-SpectreHost    { param([Parameter(ValueFromRemainingArguments)]$a) }
function Get-SpectreEscapedText { param($Text) $Text }
function Read-SpectreText     { param([Parameter(ValueFromRemainingArguments)]$a) 'C:\Win32Apps' }

# Config + prereqs used while the settings screen renders.
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Get-Win32ToolkitBasePath { param([Parameter(ValueFromRemainingArguments)]$a) 'C:\Win32Apps' }
function Test-Win32ToolkitPrerequisites {
    param([Parameter(ValueFromRemainingArguments)]$a)
    @(
        [pscustomobject]@{ Name = 'PowerShell 7.2+'; Ok = $true;  Detail = '7.6.3';                                                                        Fixable = $false; Purpose = 'core' }
        [pscustomobject]@{ Name = 'Hyper-V backend'; Ok = $false; Detail = "host session is not elevated (PowerShell Direct needs an Administrator); VM 'win32tk-golden' not found"; Fixable = $false; Purpose = 'Hyper-V testing' }
    )
}

# Settings menu: pick 'recheck' once (exercises the captured Show-Win32ToolkitHealth), then 'back'.
$script:selCalls = 0
function Read-SpectreSelection {
    param([Parameter(ValueFromRemainingArguments)]$a)
    $script:selCalls++
    if ($script:selCalls -eq 1) { [pscustomobject]@{ Key = 'recheck' } } else { [pscustomobject]@{ Key = 'back' } }
}

Write-Host "`n[1] Show-Win32ToolkitSettings returns ONE clean string (not an array) despite leaky renders" -ForegroundColor Cyan
$script:selCalls = 0
$err = $null; $r = $null
try { $r = Show-Win32ToolkitSettings -BasePath 'C:\Win32Apps' } catch { $err = $_.Exception.Message }
if (-not $err) { Ok 'settings screen ran' } else { Bad "threw: $err" }
if (@($r).Count -eq 1) { Ok 'returns exactly ONE object (no leaked renderables)' } else { Bad "returned $(@($r).Count) objects: $(@($r) | ForEach-Object { $_.GetType().Name })" }
if ($r -is [string] -and $r -eq 'C:\Win32Apps') { Ok "returns the BasePath string ('$r')" } else { Bad "return is not the BasePath string: '$r'" }

Write-Host "`n[2] the returned value binds to a [string] parameter (the exact failing call)" -ForegroundColor Cyan
function Take-String { param([string]$BasePath) $BasePath }
$e2 = $null
try { $bound = Take-String -BasePath $r } catch { $e2 = $_.Exception.Message }
if (-not $e2) { Ok "binds to [string] BasePath -> '$bound'" } else { Bad "still fails to bind: $e2" }

Write-Host "`n[3] Show-Win32ToolkitFirstRun returns ONE clean string (panel leak consumed)" -ForegroundColor Cyan
$err3 = $null; $fr = $null
try { $fr = Show-Win32ToolkitFirstRun } catch { $err3 = $_.Exception.Message }
if (-not $err3) { Ok 'first-run screen ran' } else { Bad "threw: $err3" }
if (@($fr).Count -eq 1 -and $fr -is [string]) { Ok "returns one string ('$fr')" } else { Bad "returned $(@($fr).Count) object(s): $(@($fr) | ForEach-Object { $_.GetType().Name })" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TuiReturnValue tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TuiReturnValue test(s) FAILED." -ForegroundColor Red; exit 1 }
