<#
    R14 — Test-Win32ToolkitHyperVReady memoizes its verdict (60 s TTL) and invalidates correctly.

      A single pipeline start probes backend readiness 3-5 times; each probe costs a module scan + Get-VM.
      The verdict cannot change mid-pipeline except via the VM-management cmdlets — which now clear the
      cache (Clear-Win32ToolkitHyperVStateCache). -Force bypasses; TTL bounds staleness from actions
      outside this process.

    Run:  pwsh -File Tests\HyperVReadyCache.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Test-Win32ToolkitHyperVReady.ps1')
. (Join-Path $repo 'Private\Clear-Win32ToolkitHyperVStateCache.ps1')

# ── shadows: count the expensive probes ────────────────────────────────────────────────────────────
$script:probes = 0
function Test-Win32ToolkitElevated { $true }
function Get-Module { param([switch]$ListAvailable, $Name, [Parameter(ValueFromRemainingArguments)]$Rest) $script:probes++; [pscustomobject]@{ Name = 'Hyper-V' } }
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Get-VM { param([Parameter(ValueFromRemainingArguments)]$Rest) [pscustomobject]@{ Name = 'win32tk-golden' } }
function Get-VMCheckpoint { param([Parameter(ValueFromRemainingArguments)]$Rest) [pscustomobject]@{ Name = 'clean-base' } }
function Get-Win32ToolkitGuestCredential { New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }

$script:HyperVReadyCache = $null

Write-Host '[a] repeated calls inside the TTL probe ONCE' -ForegroundColor Cyan
$r1 = @(Test-Win32ToolkitHyperVReady)
$r2 = @(Test-Win32ToolkitHyperVReady)
$r3 = @(Test-Win32ToolkitHyperVReady)
if ($r1.Count -eq 0 -and $r2.Count -eq 0 -and $r3.Count -eq 0) { Ok 'verdict consistent (ready)' } else { Bad "verdicts: $($r1.Count)/$($r2.Count)/$($r3.Count)" }
if ($script:probes -eq 1) { Ok "3 calls -> 1 real probe (cached)" } else { Bad "probes=$($script:probes)" }

Write-Host '[b] -Force bypasses the cache' -ForegroundColor Cyan
$null = @(Test-Win32ToolkitHyperVReady -Force)
if ($script:probes -eq 2) { Ok '-Force re-probed' } else { Bad "probes=$($script:probes)" }

Write-Host '[c] Clear-Win32ToolkitHyperVStateCache invalidates' -ForegroundColor Cyan
Clear-Win32ToolkitHyperVStateCache
$null = @(Test-Win32ToolkitHyperVReady)
if ($script:probes -eq 3) { Ok 'cleared cache -> re-probed' } else { Bad "probes=$($script:probes)" }

Write-Host '[d] TTL expiry re-probes' -ForegroundColor Cyan
$script:HyperVReadyCache = @{ Reasons = @(); At = (Get-Date).AddSeconds(-61) }
$null = @(Test-Win32ToolkitHyperVReady)
if ($script:probes -eq 4) { Ok 'stale cache (>60 s) -> re-probed' } else { Bad "probes=$($script:probes)" }

Write-Host '[e] a NOT-ready verdict is also cached faithfully' -ForegroundColor Cyan
function Get-Win32ToolkitGuestCredential { $null }   # now missing
Clear-Win32ToolkitHyperVStateCache
$r = @(Test-Win32ToolkitHyperVReady)
$rCached = @(Test-Win32ToolkitHyperVReady)
if ($r.Count -eq 1 -and $r[0] -match 'credential' -and $rCached.Count -eq 1) { Ok 'missing-credential reason returned and cached' } else { Bad "reasons: [$($r -join ';')] cached: [$($rCached -join ';')]" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
