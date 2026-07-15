<#
    R2 — single-revert-per-run via the process-local clean marker (fail-safe matrix).

      Every Hyper-V run used to restore the checkpoint TWICE: at session open and again at teardown,
      back-to-back with the next run's open-restore. The fix: Remove-Win32ToolkitHyperVSession stamps
      $script:HyperVCleanMarker strictly AFTER a successful teardown revert; New-Win32ToolkitHyperVSession
      skips its open-revert ONLY when the marker matches the same VM+checkpoint and is < 10 min old.
      Fail-safe: no marker / mismatch / stale / failed teardown ⇒ revert exactly as before.

    All Hyper-V cmdlets are shadowed; nothing touches a real VM.

    Run:  pwsh -File Tests\HyperVSessionRevert.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\New-Win32ToolkitHyperVSession.ps1')
. (Join-Path $repo 'Private\Remove-Win32ToolkitHyperVSession.ps1')
. (Join-Path $repo 'Private\Clear-Win32ToolkitHyperVStateCache.ps1')

# ── shadows ──────────────────────────────────────────────────────────────────────────────────────
$script:restores   = 0
$script:restoreFail = $false
function Restore-VMCheckpoint { param($VMName, $Name, $Confirm, [Parameter(ValueFromRemainingArguments)]$Rest)
    $script:restores++
    if ($script:restoreFail) { throw 'simulated restore failure' }
}
function Get-VM { param($Name, [Parameter(ValueFromRemainingArguments)]$Rest) [pscustomobject]@{ State = $script:vmState } }
$script:vmState = 'Running'
$script:started = 0
function Start-VM { param([Parameter(ValueFromRemainingArguments)]$Rest) $script:started++ }
function Wait-Win32ToolkitVMReady { param([Parameter(ValueFromRemainingArguments)]$Rest) $true }
function New-PSSession { param([Parameter(ValueFromRemainingArguments)]$Rest) 'fake-session' }
function Remove-PSSession { param([Parameter(ValueFromRemainingArguments)]$Rest) }
function Confirm-Win32ToolkitGuestDesktop { param([Parameter(ValueFromRemainingArguments)]$Rest) $true }

$cred = New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
function Reset-State { $script:restores = 0; $script:restoreFail = $false; $script:HyperVCleanMarker = $null; $script:started = 0; $script:vmState = 'Running' }

# ── (a) baseline: no marker ⇒ open reverts ─────────────────────────────────────────────────────────
Write-Host '[a] no marker -> the open-revert runs (unchanged default)' -ForegroundColor Cyan
Reset-State
$null = New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base'
if ($script:restores -eq 1) { Ok 'open restored once with no marker' } else { Bad "restores=$($script:restores)" }
if ($null -eq $script:HyperVCleanMarker) { Ok 'marker stays clear once the VM is in use' } else { Bad 'marker set at open' }

# ── (b) full run pair: teardown stamps; next open skips ───────────────────────────────────────────
Write-Host '[b] teardown stamps the marker -> the NEXT open skips its revert (1 restore per pair)' -ForegroundColor Cyan
Reset-State
Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert
if ($script:restores -eq 1) { Ok 'teardown reverted' } else { Bad "teardown restores=$($script:restores)" }
if ($script:HyperVCleanMarker -and $script:HyperVCleanMarker.VMName -eq 'vmA') { Ok 'marker stamped after a VERIFIED teardown revert' } else { Bad 'no marker after successful teardown' }
$null = New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base'
if ($script:restores -eq 1) { Ok 'open SKIPPED the redundant revert (still 1 restore total)' } else { Bad "restores=$($script:restores) after open" }
if ($null -eq $script:HyperVCleanMarker) { Ok 'marker consumed/cleared the moment the run starts' } else { Bad 'marker survived into the run' }

# ── (c) fail-safe: mismatch / stale / failed teardown all force a revert ───────────────────────────
Write-Host '[c] mismatched VM or checkpoint -> revert' -ForegroundColor Cyan
Reset-State
$script:HyperVCleanMarker = @{ VMName = 'OTHER'; CheckpointName = 'clean-base'; StampedAt = Get-Date }
$null = New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base'
if ($script:restores -eq 1) { Ok 'different VM name -> reverted' } else { Bad "restores=$($script:restores)" }
Reset-State
$script:HyperVCleanMarker = @{ VMName = 'vmA'; CheckpointName = 'other-cp'; StampedAt = Get-Date }
$null = New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base'
if ($script:restores -eq 1) { Ok 'different checkpoint -> reverted' } else { Bad "restores=$($script:restores)" }

Write-Host '[c2] stale marker (>10 min) -> revert' -ForegroundColor Cyan
Reset-State
$script:HyperVCleanMarker = @{ VMName = 'vmA'; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddMinutes(-11) }
$null = New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base'
if ($script:restores -eq 1) { Ok 'stale marker -> reverted (TTL enforced)' } else { Bad "restores=$($script:restores)" }

Write-Host '[c3] FAILED teardown revert -> marker cleared + warning; next open reverts' -ForegroundColor Cyan
Reset-State
$script:HyperVCleanMarker = @{ VMName = 'vmA'; CheckpointName = 'clean-base'; StampedAt = Get-Date }  # pretend a prior stamp exists
$script:restoreFail = $true
$warnings = @()
Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -WarningVariable warnings 3>$null
if ($null -eq $script:HyperVCleanMarker) { Ok 'failed teardown NEVER leaves a marker' } else { Bad 'marker survived a failed revert' }
if (@($warnings).Count -ge 1 -and "$warnings" -match 'FAILED') { Ok 'failed revert is WARNED (was silently swallowed before)' } else { Bad "no warning on failed revert: '$warnings'" }
$script:restoreFail = $false
$script:restores = 0
$null = New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base'
if ($script:restores -eq 1) { Ok 'next open reverts (fail-safe held)' } else { Bad "restores=$($script:restores)" }

# ── (d) -SkipRevert still honored; Clear helper wipes the marker ───────────────────────────────────
Write-Host '[d] -SkipRevert + Clear-Win32ToolkitHyperVStateCache' -ForegroundColor Cyan
Reset-State
$null = New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -SkipRevert
if ($script:restores -eq 0) { Ok '-SkipRevert performs no restore (unchanged)' } else { Bad "restores=$($script:restores)" }
$script:HyperVCleanMarker = @{ VMName = 'vmA'; CheckpointName = 'clean-base'; StampedAt = Get-Date }
$script:HyperVReadyCache  = @{ Reasons = @(); At = Get-Date }
Clear-Win32ToolkitHyperVStateCache
if ($null -eq $script:HyperVCleanMarker -and $null -eq $script:HyperVReadyCache) { Ok 'Clear helper wipes both caches' } else { Bad 'caches survived Clear' }

# ── (e) non-Running after restore -> Start-VM + a warning about the cold checkpoint ────────────────
Write-Host '[e] checkpoint restores a non-running VM -> boot + warn (every run pays a boot)' -ForegroundColor Cyan
Reset-State
$script:vmState = 'Off'
$warnings = @()
$null = New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -WarningVariable warnings 3>$null
if ($script:started -eq 1) { Ok 'Start-VM fired for the cold checkpoint' } else { Bad "started=$($script:started)" }
if ("$warnings" -match 'memory-state') { Ok 'operator warned the checkpoint is not warm' } else { Bad "no cold-checkpoint warning: '$warnings'" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
