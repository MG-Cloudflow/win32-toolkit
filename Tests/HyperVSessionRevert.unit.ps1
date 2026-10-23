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
# Speed-up PR 1 (D25): the VM's Id and uptime feed the clean-marker guard; by default the same VM, up for a day.
$script:vmGetThrows = $false
function Get-VM { param($Name, [Parameter(ValueFromRemainingArguments)]$Rest) if ($script:vmGetThrows) { throw 'Get-VM failed' }; [pscustomobject]@{ State = $script:vmState; Id = $script:vmId; Uptime = $script:vmUptime } }
$script:vmState = 'Running'
$script:vmId = [guid]'0e5f9e66-1111-2222-3333-444455556666'
$script:vmUptime = [timespan]::FromDays(1)
$script:started = 0
function Start-VM { param([Parameter(ValueFromRemainingArguments)]$Rest) $script:started++ }
function Wait-Win32ToolkitVMReady { param([Parameter(ValueFromRemainingArguments)]$Rest) $true }
function New-PSSession { param([Parameter(ValueFromRemainingArguments)]$Rest) 'fake-session' }
function Remove-PSSession { param([Parameter(ValueFromRemainingArguments)]$Rest) }
function Confirm-Win32ToolkitGuestDesktop { param([Parameter(ValueFromRemainingArguments)]$Rest) $true }
# C-5/C-9 (speed-up PR 1): the real Clear-Win32ToolkitHyperVStateCache now clears the stored checkpoint answers; the
# developer's real HKCU must never be touched.
$script:probeClears = 0
function Clear-Win32ToolkitParityProbeCache { $script:probeClears++ }
function Remove-ItemProperty { throw 'real HKCU must not be touched' }

$cred = New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
function Reset-State { $script:restores = 0; $script:restoreFail = $false; $script:HyperVCleanMarker = $null; $script:started = 0; $script:vmState = 'Running'
    $script:vmId = [guid]'0e5f9e66-1111-2222-3333-444455556666'; $script:vmUptime = [timespan]::FromDays(1); $script:vmGetThrows = $false }

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

# ── (l) Hyper-V speed-up PR 1 (D25): the marker is used only while the VM is still the one the teardown left clean ───
Write-Host '[l] clean-marker guard: same VM Id, Running, uptime >= the marker''s age (5 s slack); a teardown without an Id keeps no marker' -ForegroundColor Cyan
$openL = {
    $v = @(New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -Verbose 4>&1 3>$null | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
    @($v | Where-Object { $_ -like '*clean marker is not used*' })
}
$stampL = { param([int]$AgeSeconds) $script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = [string]$script:vmId; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddSeconds(-$AgeSeconds) } }
# all good: skip
Reset-State; & $stampL 60; $script:vmUptime = [timespan]::FromSeconds(90)
$whyL = @(& $openL)
if ($script:restores -eq 0 -and $whyL.Count -eq 0) { Ok 'same Id, Running, uptime 90 s >= marker age 60 s -> the open skips its restore' } else { Bad "good: restores=$($script:restores) why=$($whyL -join ' | ')" }
# uptime within the 5 s slack: still a skip
Reset-State; & $stampL 60; $script:vmUptime = [timespan]::FromSeconds(57)
$null = & $openL
if ($script:restores -eq 0) { Ok 'uptime 57 s against a 60 s marker (within the 5 s slack) -> skip' } else { Bad "slack: restores=$($script:restores)" }
foreach ($case in @(
        @{ Tag = 'another VM Id (the VM was replaced)'; Set = { $script:vmId = [guid]::NewGuid() }; Want = 'VM Id' }
        @{ Tag = 'uptime 10 s < marker age 60 s (restored or started since)'; Set = { $script:vmUptime = [timespan]::FromSeconds(10) }; Want = 'uptime' }
        @{ Tag = 'the VM is Off'; Set = { $script:vmState = 'Off' }; Want = 'not Running' }
        @{ Tag = 'the VM is Saved'; Set = { $script:vmState = 'Saved' }; Want = 'not Running' }
        @{ Tag = 'no uptime reported'; Set = { $script:vmUptime = $null }; Want = 'uptime' }
        @{ Tag = 'Get-VM fails at the open'; Set = { $script:vmGetThrows = $true }; Want = 'could not be read' })) {
    Reset-State; & $stampL 60
    & $case.Set
    $whyL = @()
    $threwL = $null
    try { $whyL = @(& $openL) } catch { $threwL = $_ }
    # A failing Get-VM also fails the open's own Get-VM after the restore (unchanged): only the restore is asserted then.
    $restoredL = $script:restores -eq 1
    $namedL = $whyL.Count -eq 1 -and $whyL[0] -like "*$($case.Want)*"
    if ($restoredL -and ($namedL -or ($case.Want -eq 'could not be read' -and $threwL))) { Ok "$($case.Tag) -> restore$(if ($namedL) { ', the verbose line names it' })" } else { Bad "$($case.Tag): restores=$($script:restores) why=$($whyL -join ' | ') threw=$threwL" }
}
# a marker of the old shape (no VMId) is never used
Reset-State
$script:HyperVCleanMarker = @{ VMName = 'vmA'; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddSeconds(-30) }
$null = & $openL
if ($script:restores -eq 1) { Ok 'a marker without VMId -> restore (fail-safe)' } else { Bad "no VMId: restores=$($script:restores)" }
# the teardown stamps the VM Id; without one it keeps no marker and does not warn
Reset-State
Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert
if ($script:HyperVCleanMarker -and $script:HyperVCleanMarker.VMId -eq [string]$script:vmId -and $script:HyperVCleanMarker.CheckpointName -eq 'clean-base') { Ok 'the teardown stamps VMName, VMId, CheckpointName, StampedAt' } else { Bad "stamp: $($script:HyperVCleanMarker | ConvertTo-Json -Compress)" }
Reset-State
$script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = 'x'; CheckpointName = 'clean-base'; StampedAt = Get-Date }
$script:vmGetThrows = $true
$wl = @()
Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -WarningVariable wl 3>$null
if ($script:restores -eq 1 -and $null -eq $script:HyperVCleanMarker -and @($wl).Count -eq 0) { Ok 'Get-VM fails after the teardown restore -> no marker, no warning (the restore still counts as done)' } else { Bad "teardown get-vm: restores=$($script:restores) marker=$($null -ne $script:HyperVCleanMarker) warnings=$(@($wl).Count)" }
Reset-State

# ── (d2) Hyper-V speed-up PR 1 (A-6): Clear-Win32ToolkitHyperVStateCache -MarkerOnly ──────────────────────────────────
Write-Host '[d2] Clear-Win32ToolkitHyperVStateCache -MarkerOnly clears the marker only; without it every cache goes' -ForegroundColor Cyan
$script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = 'x'; CheckpointName = 'clean-base'; StampedAt = Get-Date }
$script:HyperVReadyCache  = @{ Reasons = @(); At = Get-Date }
Clear-Win32ToolkitHyperVStateCache -MarkerOnly
if ($null -eq $script:HyperVCleanMarker -and $null -ne $script:HyperVReadyCache) { Ok '-MarkerOnly: the marker goes, the readiness memo stays' } else { Bad "marker-only: marker=$($null -ne $script:HyperVCleanMarker) ready=$($null -ne $script:HyperVReadyCache)" }
$script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = 'x'; CheckpointName = 'clean-base'; StampedAt = Get-Date }
$script:probeClears = 0
Clear-Win32ToolkitHyperVStateCache -MarkerOnly
$probeAfterMarkerOnly = $script:probeClears
$script:HyperVReadyCache  = @{ Reasons = @(); At = Get-Date }
Clear-Win32ToolkitHyperVStateCache
if ($null -eq $script:HyperVCleanMarker -and $null -eq $script:HyperVReadyCache) { Ok 'without -MarkerOnly: the marker and the readiness memo go' } else { Bad 'full clear left a cache' }
if ($probeAfterMarkerOnly -eq 0 -and $script:probeClears -eq 1) { Ok 'the stored checkpoint answers are cleared by a full clear only (Clear-Win32ToolkitParityProbeCache once)' } else { Bad "probe clears: after -MarkerOnly $probeAfterMarkerOnly, after full $($script:probeClears)" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
