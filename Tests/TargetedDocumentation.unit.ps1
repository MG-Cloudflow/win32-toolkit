<#
    Unit tests for the backend-aware documentation/capture generator (Phase 4, Step 4.1).
    New-LogCollectorScript / Start-Process / Get-WindowsOptionalFeature are shadowed; nothing launches a
    sandbox or a VM. Verifies the emitted guest script is UTF-8 WITH BOM, parses, bakes the backend, guards
    the Sandbox-only blocks, and that the HyperV path writes no .wsb and never launches.

    Run:  pwsh -File Tests\TargetedDocumentation.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-XmlEncoded.ps1')
. (Join-Path $repo 'Private\New-TargetedDocumentation.ps1')

# Shadows so nothing external runs.
function New-LogCollectorScript { param($ProjectPath) return 'fake-collector' }
function Get-WindowsOptionalFeature { param($Online, $FeatureName, $ErrorAction) return $null }
$script:started = 0
function Start-Process { param($FilePath, $ArgumentList, $ErrorAction, [switch]$PassThru, [switch]$Wait) $script:started++ }

function New-Proj {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32doc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $p 'Files') -Force | Out-Null
    $p
}
$sandGuard = 'if ($backend -eq ''Sandbox'')'
$hvGuard   = 'if ($backend -eq ''HyperV'')'
function GuardCount([string]$text, [string]$needle) { ([regex]::Matches($text, [regex]::Escape($needle))).Count }

# --- Sandbox generation -----------------------------------------------------------------------------
Write-Host '[1] Backend=Sandbox: builds the .wsb; script is BOM+parses+baked+guarded' -ForegroundColor Cyan
$projS = New-Proj
$script:started = 0
$jsonS = New-TargetedDocumentation -ProjectPath $projS -ProjectName 'Test_x64_1.0' -Backend Sandbox -SkipLaunch
$docS  = Join-Path $projS 'SupportFiles\TargetedDocumentationScript.ps1'
$wsbS  = Join-Path $projS 'Test_x64_1.0_TargetedDocumentation.wsb'

$bytes = [System.IO.File]::ReadAllBytes($docS)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$text  = [System.IO.File]::ReadAllText($docS)
$perr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$perr)

if ($hasBom) { Ok 'script written UTF-8 with BOM' } else { Bad 'no UTF-8 BOM on generated script' }
if (-not $perr) { Ok 'generated script parses (5.1-safe syntax)' } else { Bad "parse errors: $($perr[0].Message)" }
if ($text.Contains("`$backend = 'Sandbox'")) { Ok 'backend literal baked = Sandbox' } else { Bad 'backend not baked to Sandbox' }
if ((GuardCount $text $sandGuard) -eq 2) { Ok 'two Sandbox-only guards (init wait + auto-close/Stop-Computer)' } else { Bad "sandbox guards = $(GuardCount $text $sandGuard)" }
if ((GuardCount $text $hvGuard) -eq 1) { Ok 'one HyperV guard (ProgressPreference)' } else { Bad "hyperv guards = $(GuardCount $text $hvGuard)" }
if ($text.Contains('Stop-Computer')) { Ok 'Stop-Computer present (guarded)' } else { Bad 'Stop-Computer missing' }
if (Test-Path -LiteralPath $wsbS) { Ok 'Sandbox: .wsb built' } else { Bad 'Sandbox: .wsb missing' }
if ($jsonS -like '*Documentation\InstallationChanges_*.json') { Ok 'returns expected capture path' } else { Bad "returned: $jsonS" }

# --- HyperV generation ------------------------------------------------------------------------------
Write-Host '[2] Backend=HyperV: NO .wsb, never launches, script baked HyperV' -ForegroundColor Cyan
$projH = New-Proj
$script:started = 0
$jsonH = New-TargetedDocumentation -ProjectPath $projH -ProjectName 'Test_x64_1.0' -Backend HyperV
$docH  = Join-Path $projH 'SupportFiles\TargetedDocumentationScript.ps1'
$wsbH  = Join-Path $projH 'Test_x64_1.0_TargetedDocumentation.wsb'
$textH = [System.IO.File]::ReadAllText($docH)
$perrH = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($textH, [ref]$null, [ref]$perrH)

if ($textH.Contains("`$backend = 'HyperV'")) { Ok 'backend literal baked = HyperV' } else { Bad 'backend not baked to HyperV' }
if (-not $perrH) { Ok 'HyperV script parses' } else { Bad "parse errors: $($perrH[0].Message)" }
if (-not (Test-Path -LiteralPath $wsbH)) { Ok 'HyperV: no .wsb built' } else { Bad 'HyperV: .wsb should NOT exist' }
if ($script:started -eq 0) { Ok 'HyperV: WindowsSandbox.exe never launched' } else { Bad "Start-Process called $script:started time(s)" }
if ($jsonH -like '*Documentation\InstallationChanges_*.json') { Ok 'HyperV returns expected capture path' } else { Bad "returned: $jsonH" }

# best-effort cleanup
Remove-Item -LiteralPath $projS, $projH -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TargetedDocumentation tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TargetedDocumentation test(s) FAILED." -ForegroundColor Red; exit 1 }
