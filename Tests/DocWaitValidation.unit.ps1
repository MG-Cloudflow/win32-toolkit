<#
    R10 — the documentation waiter polls at 2 s and refuses a torn (mid-write) capture JSON.

      The guest writes InstallationChanges_*.json over VSMB while the host polls; the old code accepted
      the file on bare Test-Path. At the new faster cadence a partial read becomes likelier — the waiter
      must only proceed once the file parses as complete JSON (a torn capture feeding requirement /
      uninstall generation would corrupt the package quietly).

    Start-Sleep and all downstream processors are shadowed; nothing real runs.

    Run:  pwsh -File Tests\DocWaitValidation.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Wait-ForDocumentationAndProcess.ps1')

# ── shadows ──────────────────────────────────────────────────────────────────────────────────────
$script:sleeps = @()
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $script:sleeps += $Seconds; $script:tick++ ; & $script:onTick }
$script:onTick = { }
$script:tick = 0
function New-IntuneRequirementScript { param($ProjectPath, $JsonFilePath) $true }
function Update-PSADTUninstallLogic  { param($ProjectPath, $JsonFilePath) $true }
function Update-PSADTProcessesToClose { param($ProjectPath, $JsonFilePath) $true }
function Update-PSADTMsixUninstallLogic { param($ProjectPath) $true }
function Get-LatestInstallationCapture { param($ProjectPath) $null }

$tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ('docw_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$json = Join-Path $tmp 'InstallationChanges_20260716_010101.json'

# ── (a) a TORN file is retried until it parses; then processing proceeds ──────────────────────────
Write-Host '[a] partial JSON on disk -> keep polling; complete JSON -> proceed' -ForegroundColor Cyan
Set-Content -LiteralPath $json -Value '{"InstallationInfo": {"ProjectName": "x", '   # torn mid-write
$script:sleeps = @(); $script:tick = 0
$script:onTick = {
    if ($script:tick -eq 3) {
        Set-Content -LiteralPath $json -Value '{"InstallationInfo":{"ProjectName":"x"},"NewFiles":[],"NewRegistryKeys":[]}'
    }
}
$r = Wait-ForDocumentationAndProcess -ProjectPath $tmp -InstallerType 'msi' -ExpectedJsonPath $json 6>$null
if ($r -eq $true) { Ok 'returns $true once the JSON is complete' } else { Bad "returned $r" }
if (@($script:sleeps).Count -ge 3) { Ok "did NOT accept the torn file (polled $(@($script:sleeps).Count) times first)" } else { Bad "accepted too early (sleeps=$(@($script:sleeps).Count))" }

# ── (b) cadence is 2 s; the 30-min ceiling is unchanged ────────────────────────────────────────────
Write-Host '[b] 2 s cadence, 30-min ceiling intact' -ForegroundColor Cyan
$uniq = @($script:sleeps | Select-Object -Unique)
if ($uniq.Count -eq 1 -and $uniq[0] -eq 2) { Ok 'polls every 2 s (was 10 s)' } else { Bad "sleep values: $($script:sleeps -join ',')" }
$src = Get-Content -LiteralPath (Join-Path $repo 'Private\Wait-ForDocumentationAndProcess.ps1') -Raw
if ($src -match '\$maxWaitMinutes\s*=\s*30') { Ok 'the 30-minute ceiling is untouched' } else { Bad 'ceiling changed' }

# ── (c) a valid file that never appears -> $false at the ceiling (no hang) ─────────────────────────
Write-Host '[c] file never appears -> $false (bounded)' -ForegroundColor Cyan
Remove-Item -LiteralPath $json -Force
$script:sleeps = @(); $script:tick = 0; $script:onTick = { }
$r = Wait-ForDocumentationAndProcess -ProjectPath $tmp -InstallerType 'msi' -ExpectedJsonPath $json 6>$null 3>$null
if ($r -eq $false) { Ok 'returns $false when the capture never lands' } else { Bad "returned $r" }
if (@($script:sleeps).Count -eq (30 * 60 / 2)) { Ok 'polled exactly the 30-min budget at 2 s' } else { Bad "polls=$(@($script:sleeps).Count)" }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
