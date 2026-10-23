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

# ── (m) Hyper-V speed-up PR 1: -Info for the run's record; the output stays exactly the session (C-12) ──────────────
Write-Host '[m] New-Win32ToolkitHyperVSession -Info (RevertSkipped, SecondsSinceTeardown, VM, VMId, Warm); Remove- -Info (Restored)' -ForegroundColor Cyan
$sessionDouble = [pscustomobject]@{ Kind = 'session-double' }
${function:Wait-Win32ToolkitVMReady_Saved} = ${function:Wait-Win32ToolkitVMReady}
function Wait-Win32ToolkitVMReady { param($VMName, $Credential, [switch]$SkipPrep, [switch]$ReturnSession) if ($ReturnSession) { $sessionDouble } else { $true } }
$openM = {
    param([hashtable]$Info)
    $o = @(New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -Info $Info 3>$null)
    [pscustomobject]@{ Out = $o; Exact = ($o.Count -eq 1 -and [object]::ReferenceEquals($o[0], $sessionDouble)) }
}
# a restore
Reset-State
$im = @{}
$rm = & $openM $im
if ($rm.Exact -and $script:restores -eq 1 -and $im['RevertSkipped'] -eq $false -and $null -eq $im['SecondsSinceTeardown'] -and $im['Warm'] -eq $true -and $im['VM'] -and $im['VM'].State -eq 'Running' -and $im.ContainsKey('VMId')) {
    Ok 'a restore: RevertSkipped $false, SecondsSinceTeardown $null, Warm $true, the VM object; exactly the session returned'
} else { Bad "restore: exact=$($rm.Exact) restores=$($script:restores) info=$($im | ConvertTo-Json -Compress -Depth 2)" }
# a marker skip (the marker the teardown stamps, 30 s old)
Reset-State
$script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = $script:vmId; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddSeconds(-30) }
$im = @{}
$rm = & $openM $im
if ($rm.Exact -and $script:restores -eq 0 -and $im['RevertSkipped'] -eq $true -and $im['SecondsSinceTeardown'] -ge 29 -and $im['SecondsSinceTeardown'] -le 40 -and $im['Warm'] -eq $true) {
    Ok "a marker skip: no restore, RevertSkipped `$true, SecondsSinceTeardown $($im['SecondsSinceTeardown']) (the marker's age)"
} else { Bad "skip: exact=$($rm.Exact) restores=$($script:restores) info=$($im | ConvertTo-Json -Compress -Depth 2)" }
# the cold fallback
Reset-State
$script:vmState = 'Off'
$im = @{}
$rm = & $openM $im
if ($rm.Exact -and $script:started -eq 1 -and $im['Warm'] -eq $false -and $im['RevertSkipped'] -eq $false) { Ok 'the cold fallback (VM not Running after the restore, started): Warm $false' } else { Bad "cold: exact=$($rm.Exact) started=$($script:started) info=$($im | ConvertTo-Json -Compress -Depth 2)" }
# -SkipRevert: nothing restored
Reset-State
$im = @{}
$o = @(New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -SkipRevert -Info $im)
if ($o.Count -eq 1 -and $script:restores -eq 0 -and $im['RevertSkipped'] -eq $true) { Ok '-SkipRevert: RevertSkipped $true (no restore)' } else { Bad "skiprevert: count=$($o.Count) info=$($im | ConvertTo-Json -Compress -Depth 2)" }
# without -Info: unchanged
Reset-State
$o = @(New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base')
if ($o.Count -eq 1 -and [object]::ReferenceEquals($o[0], $sessionDouble)) { Ok 'without -Info: exactly the session, as before' } else { Bad "no info: count=$($o.Count)" }
# the teardown
Reset-State
$tm = @{}
$o = @(Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Info $tm)
if ($o.Count -eq 0 -and $tm['Restored'] -eq $true -and $tm['RevertMode'] -ceq 'Legacy') { Ok 'Remove- -Info after a restore: Restored $true, RevertMode Legacy; it emits nothing' } else { Bad "teardown: count=$($o.Count) info=$($tm | ConvertTo-Json -Compress)" }
Reset-State
$script:restoreFail = $true
$tm = @{}
$o = @(Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Info $tm 3>$null)
if ($o.Count -eq 0 -and $tm['Restored'] -eq $false -and $null -eq $tm['RevertMode']) { Ok 'a failed teardown restore: Restored $false, RevertMode $null' } else { Bad "failed teardown: count=$($o.Count) info=$($tm | ConvertTo-Json -Compress)" }
$tm = @{}
$null = Remove-Win32ToolkitHyperVSession -Session 'fake' -Info $tm
if ($tm['Restored'] -eq $false) { Ok 'no -Revert: Restored $false' } else { Bad "no revert: $($tm | ConvertTo-Json -Compress)" }
${function:Wait-Win32ToolkitVMReady} = ${function:Wait-Win32ToolkitVMReady_Saved}
Remove-Item Function:\Wait-Win32ToolkitVMReady_Saved
Reset-State

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
