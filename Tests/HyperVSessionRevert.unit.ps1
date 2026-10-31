<#
    R2 — single-revert-per-run via the process-local clean marker (fail-safe matrix).

      Every Hyper-V run used to restore the checkpoint TWICE: at session open and again at teardown,
      back-to-back with the next run's open-restore. The fix: Remove-Win32ToolkitHyperVSession stamps
      $script:HyperVCleanMarker strictly AFTER a successful teardown revert; New-Win32ToolkitHyperVSession
      skips its open-revert ONLY when the marker matches the same VM+checkpoint and is < 10 min old.
      Fail-safe: no marker / mismatch / stale / failed teardown ⇒ revert exactly as before.

    Speed-up PR 2: both helpers restore through Restore-Win32ToolkitTestVMCheckpoint (a double here, see
    HyperVRevertMode.unit for the helper itself). [e] (PR 2): a Saved VM is resumed silently, Off warns, Info.Warm
    follows the helper's Landed (V-4). [j]: the teardown stamps the marker only after the whole helper succeeded.

    Speed-up PR 3 (A-2): the marker is used only under a VM lease (Enter-Win32ToolkitHyperVLease) whose generation
    follows the one the teardown stamped (the sections above pass $L5 to the teardown and $L6 to the open). [n]: the
    generation rule (next outermost, nested, another holder in between, another epoch, no lease, a PR 1 marker).

    Speed-up PR 4 (D9, A-15, V-17): [k] Saved parking: an unattended teardown (-AllowPark) with HyperVTeardownPark Saved and
    TurnOffFirst leaves the VM as it landed and stamps Parked; the next open only starts a parked VM while it is Saved and
    its last state change (WMI, a double here) is not later than the stamp.

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
# C-9 (speed-up PR 2): both session helpers restore through Restore-Win32ToolkitTestVMCheckpoint. The double calls the
# Restore-VMCheckpoint shadow above (so every restore count below stays valid) and RETURNS AN OBJECT, as the real helper
# does (an unassigned call would leak it): Mode $script:helperMode, Landed = the VM state unless $script:helperLanded
# says otherwise, Started $script:helperStarted. $script:helperFail makes it throw (a failed turn-off, restore or start).
$script:helperMode = 'TurnOffFirst'; $script:helperLanded = $null; $script:helperStarted = $false; $script:helperFail = ''; $script:helperCalls = 0
function Restore-Win32ToolkitTestVMCheckpoint { param($VMName, $CheckpointName, $Mode, [switch]$NoStart)
    $script:helperCalls++
    if ($script:helperFail) { throw "simulated $($script:helperFail) failure" }
    $null = Restore-VMCheckpoint -VMName $VMName -Name $CheckpointName -Confirm:$false -ErrorAction Stop
    [pscustomobject]@{ Mode = $script:helperMode; Landed = $(if ($null -ne $script:helperLanded) { $script:helperLanded } else { [string]$script:vmState })
        TurnOffSeconds = $null; RestoreSeconds = 0.1; StartSeconds = $null; Started = $script:helperStarted }
}
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
# Speed-up PR 3 (A-2): the marker counts only under a VM lease. $L5 = the lease a teardown held (generation 5); $L6 = the
# next outermost acquisition of the same file when nobody else took it in between (PreviousGeneration 5).
$L5 = [pscustomobject]@{ Kind = 'VM'; Epoch = 'epoch-a'; Generation = 5; PreviousGeneration = 4; Nested = $false }
$L6 = [pscustomobject]@{ Kind = 'VM'; Epoch = 'epoch-a'; Generation = 6; PreviousGeneration = 5; Nested = $false }
function Reset-State { $script:restores = 0; $script:restoreFail = $false; $script:HyperVCleanMarker = $null; $script:started = 0; $script:vmState = 'Running'
    $script:vmId = [guid]'0e5f9e66-1111-2222-3333-444455556666'; $script:vmUptime = [timespan]::FromDays(1); $script:vmGetThrows = $false
    $script:helperMode = 'TurnOffFirst'; $script:helperLanded = $null; $script:helperStarted = $false; $script:helperFail = ''; $script:helperCalls = 0 }

# ── (a) baseline: no marker ⇒ open reverts ─────────────────────────────────────────────────────────
Write-Host '[a] no marker -> the open-revert runs (unchanged default)' -ForegroundColor Cyan
Reset-State
$null = New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base'
if ($script:restores -eq 1) { Ok 'open restored once with no marker' } else { Bad "restores=$($script:restores)" }
if ($null -eq $script:HyperVCleanMarker) { Ok 'marker stays clear once the VM is in use' } else { Bad 'marker set at open' }

# ── (b) full run pair: teardown stamps; next open skips ───────────────────────────────────────────
Write-Host '[b] teardown stamps the marker -> the NEXT open skips its revert (1 restore per pair)' -ForegroundColor Cyan
Reset-State
Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Lease $L5
if ($script:restores -eq 1) { Ok 'teardown reverted' } else { Bad "teardown restores=$($script:restores)" }
if ($script:HyperVCleanMarker -and $script:HyperVCleanMarker.VMName -eq 'vmA') { Ok 'marker stamped after a VERIFIED teardown revert' } else { Bad 'no marker after successful teardown' }
$null = New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -Lease $L6
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
    $o = @(New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -Info $Info -Lease $L6 3>$null)
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
$script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = $script:vmId; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddSeconds(-30); LeaseEpoch = 'epoch-a'; LeaseGeneration = 5 }
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
# Speed-up PR 2: RevertMode is the mode the restore helper used (the double's TurnOffFirst here; was the constant Legacy).
if ($o.Count -eq 0 -and $tm['Restored'] -eq $true -and $tm['RevertMode'] -ceq $script:helperMode) { Ok "Remove- -Info after a restore: Restored `$true, RevertMode $($script:helperMode) (the helper's); it emits nothing" } else { Bad "teardown: count=$($o.Count) info=$($tm | ConvertTo-Json -Compress)" }
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
    $v = @(New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -Lease $L6 -Verbose 4>&1 3>$null | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
    @($v | Where-Object { $_ -like '*clean marker is not used*' })
}
$stampL = { param([int]$AgeSeconds) $script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = [string]$script:vmId; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddSeconds(-$AgeSeconds); LeaseEpoch = 'epoch-a'; LeaseGeneration = 5 } }
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
$script:HyperVCleanMarker = @{ VMName = 'vmA'; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddSeconds(-30); LeaseEpoch = 'epoch-a'; LeaseGeneration = 5 }
$null = & $openL
if ($script:restores -eq 1) { Ok 'a marker without VMId -> restore (fail-safe)' } else { Bad "no VMId: restores=$($script:restores)" }
# the teardown stamps the VM Id; without one it keeps no marker and does not warn
Reset-State
Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Lease $L5
if ($script:HyperVCleanMarker -and $script:HyperVCleanMarker.VMId -eq [string]$script:vmId -and $script:HyperVCleanMarker.CheckpointName -eq 'clean-base') { Ok 'the teardown stamps VMName, VMId, CheckpointName, StampedAt' } else { Bad "stamp: $($script:HyperVCleanMarker | ConvertTo-Json -Compress)" }
Reset-State
$script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = 'x'; CheckpointName = 'clean-base'; StampedAt = Get-Date }
$script:vmGetThrows = $true
$wl = @()
Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Lease $L5 -WarningVariable wl 3>$null
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

# ── (e) extended, Hyper-V speed-up PR 2 (B1, V-4): Saved is expected; a checkpoint that landed Off is cold ──────────────
Write-Host '[e] (PR 2) the open: a Saved VM is resumed silently, Off still warns; Info.Warm follows the helper''s Landed' -ForegroundColor Cyan
$sessionDouble = [pscustomobject]@{ Kind = 'session-double' }
${function:Wait-Win32ToolkitVMReady_Saved} = ${function:Wait-Win32ToolkitVMReady}
function Wait-Win32ToolkitVMReady { param($VMName, $Credential, [switch]$SkipPrep, [switch]$ReturnSession) if ($ReturnSession) { $sessionDouble } else { $true } }
$openE = {
    $info = @{}
    $wv = $null
    $o = @(New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -Info $info -Lease $L6 -WarningVariable wv 3>$null)
    [pscustomobject]@{ Info = $info; Warnings = @($wv | ForEach-Object { "$_" }); Exact = ($o.Count -eq 1 -and [object]::ReferenceEquals($o[0], $sessionDouble)) }
}
# A Saved VM after the restore (Legacy on a VM that was off, or a helper run with -NoStart): resumed, no warning.
Reset-State; $script:vmState = 'Saved'; $script:helperMode = 'Legacy'
$e = & $openE
if ($e.Exact -and $script:started -eq 1 -and $e.Warnings.Count -eq 0 -and $e.Info['Warm'] -eq $true -and $e.Info['RevertMode'] -ceq 'Legacy') { Ok 'Saved after the restore -> Start-VM (resume) without the cold warning; Warm $true; RevertMode from the helper' } else { Bad "saved: exact=$($e.Exact) started=$($script:started) warnings=$($e.Warnings -join ' | ') info=$($e.Info | ConvertTo-Json -Compress -Depth 1)" }
# Off after the restore: the cold warning (today's text) and a start.
Reset-State; $script:vmState = 'Off'
$e = & $openE
if ($e.Exact -and $script:started -eq 1 -and $e.Warnings.Count -eq 1 -and $e.Warnings[0] -like "VM 'vmA' was not Running after restoring 'clean-base'*memory-state*" -and $e.Info['Warm'] -eq $false) { Ok 'Off after the restore -> the cold warning (unchanged text), Start-VM, Warm $false' } else { Bad "off: started=$($script:started) warnings=$($e.Warnings -join ' | ')" }
# The helper turned the VM off, the checkpoint landed Off and the helper started it (the VM is Running here): still cold.
Reset-State; $script:helperLanded = 'Off'; $script:helperStarted = $true; $script:vmState = 'Running'
$e = & $openE
if ($e.Exact -and $script:started -eq 0 -and $e.Warnings.Count -eq 0 -and $e.Info['Warm'] -eq $false -and $e.Info['RevertMode'] -ceq 'TurnOffFirst') { Ok 'helper Landed Off + Started $true (VM Running at the open''s check) -> Info.Warm $false (V-4); no second warning or start here' } else { Bad "landed off: started=$($script:started) warnings=$($e.Warnings -join ' | ') info=$($e.Info | ConvertTo-Json -Compress -Depth 1)" }
foreach ($landed in 'Saved', 'Running') {
    Reset-State; $script:helperLanded = $landed; $script:helperStarted = ($landed -eq 'Saved'); $script:vmState = 'Running'
    $e = & $openE
    if ($e.Exact -and $e.Info['Warm'] -eq $true -and $e.Warnings.Count -eq 0) { Ok "helper Landed $landed -> Info.Warm `$true" } else { Bad "landed ${landed}: info=$($e.Info | ConvertTo-Json -Compress -Depth 1)" }
}
# A marker-skip open restores nothing: RevertMode $null; a skipped open that finds the VM Saved resumes it silently.
Reset-State
$script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = [string]$script:vmId; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddSeconds(-30); LeaseEpoch = 'epoch-a'; LeaseGeneration = 5 }
$e = & $openE
if ($e.Exact -and $script:helperCalls -eq 0 -and $e.Info['RevertSkipped'] -eq $true -and $null -eq $e.Info['RevertMode']) { Ok 'a marker skip: no helper call, RevertMode $null' } else { Bad "skip: calls=$($script:helperCalls) info=$($e.Info | ConvertTo-Json -Compress -Depth 1)" }
Reset-State; $script:vmState = 'Saved'
$o = @(New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -SkipRevert -WarningVariable wvS 3>$null)
if ($o.Count -eq 1 -and $script:started -eq 1 -and @($wvS).Count -eq 0) { Ok '-SkipRevert onto a Saved VM -> resumed without the cold warning' } else { Bad "skiprevert saved: started=$($script:started) warnings=$(@($wvS).Count)" }

# ── (j) Hyper-V speed-up PR 2: the teardown stamps only after the whole helper succeeded; nothing leaks (C-12) ──────────
Write-Host '[j] (PR 2) teardown: marker only after the whole restore helper succeeded; a failed step -> no marker + warning; no output leaks' -ForegroundColor Cyan
Reset-State
$tj = @{}
$o = @(Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Info $tj -Lease $L5)
if ($o.Count -eq 0 -and $script:helperCalls -eq 1 -and $script:HyperVCleanMarker -and $script:HyperVCleanMarker.VMName -eq 'vmA' -and $tj['Restored'] -eq $true -and $tj['RevertMode'] -ceq 'TurnOffFirst') {
    Ok 'success: one helper call, the marker stamped, Info RevertMode TurnOffFirst; Remove- emits nothing although the helper double returns an object'
} else { Bad "teardown ok: out=$($o.Count) calls=$($script:helperCalls) marker=$($null -ne $script:HyperVCleanMarker) info=$($tj | ConvertTo-Json -Compress)" }
Reset-State; $script:helperMode = 'Legacy'
$tj = @{}
$null = Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Info $tj
if ($tj['RevertMode'] -ceq 'Legacy') { Ok 'a Legacy restore: Info RevertMode Legacy' } else { Bad "legacy mode: $($tj | ConvertTo-Json -Compress)" }
foreach ($step in 'turn-off', 'restore', 'start') {
    Reset-State
    $script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = [string]$script:vmId; CheckpointName = 'clean-base'; StampedAt = Get-Date }   # a prior stamp
    $script:helperFail = $step
    $tj = @{}; $wj = $null
    $o = @(Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Info $tj -WarningVariable wj 3>$null)
    if ($o.Count -eq 0 -and $null -eq $script:HyperVCleanMarker -and @($wj).Count -eq 1 -and "$wj" -match 'FAILED' -and "$wj" -match "simulated $step failure" -and $tj['Restored'] -eq $false -and $null -eq $tj['RevertMode']) {
        Ok "the helper fails at the $step -> no marker, the FAILED warning, Restored `$false, RevertMode `$null"
    } else { Bad "$step fails: out=$($o.Count) marker=$($null -ne $script:HyperVCleanMarker) warnings=$($wj -join ' | ') info=$($tj | ConvertTo-Json -Compress)" }
}
# The open after a failed teardown restores (fail-safe held) and returns exactly the session.
Reset-State
$e = & $openE
if ($e.Exact -and $script:helperCalls -eq 1 -and $script:restores -eq 1) { Ok 'the open: one helper call; New- returns exactly the session double although the helper double returns an object' } else { Bad "open: exact=$($e.Exact) calls=$($script:helperCalls)" }
${function:Wait-Win32ToolkitVMReady} = ${function:Wait-Win32ToolkitVMReady_Saved}
Remove-Item Function:\Wait-Win32ToolkitVMReady_Saved
Reset-State

# ── (n) Hyper-V speed-up PR 3 (A-2): the marker counts only under the lease generation that follows its own ───────────
Write-Host '[n] (PR 3) the marker of a teardown under lease generation N: used with PreviousGeneration N or a nested hold of N; not with N+1, another epoch, or no lease' -ForegroundColor Cyan
$openN = {
    param($Lease)
    $a = @{ VMName = 'vmA'; Credential = $cred; CheckpointName = 'clean-base' }
    if ($null -ne $Lease) { $a['Lease'] = $Lease }
    $v = @(New-Win32ToolkitHyperVSession @a -Verbose 4>&1 3>$null | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
    @($v | Where-Object { $_ -like '*clean marker is not used*' })
}
foreach ($case in @(
        @{ Tag = 'the next outermost lease (PreviousGeneration 5, Generation 6)'; Lease = $L6; Skip = $true; Why = '' }
        @{ Tag = 'a nested hold of generation 5 (lane runner -HoldLease)'; Lease = [pscustomobject]@{ Epoch = 'epoch-a'; Generation = 5; PreviousGeneration = 5; Nested = $true }; Skip = $true; Why = '' }
        @{ Tag = 'another process held the VM in between (PreviousGeneration 6, Generation 7)'; Lease = [pscustomobject]@{ Epoch = 'epoch-a'; Generation = 7; PreviousGeneration = 6; Nested = $false }; Skip = $false; Why = 'another process used the VM since the teardown (the lease generation changed)' }
        @{ Tag = 'another epoch (the lease file was reset)'; Lease = [pscustomobject]@{ Epoch = 'epoch-b'; Generation = 6; PreviousGeneration = 5; Nested = $false }; Skip = $false; Why = 'it was not stamped under the current VM lease' }
        @{ Tag = 'no lease passed'; Lease = $null; Skip = $false; Why = 'no VM lease is held' })) {
    Reset-State
    Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Lease $L5
    $stamped = $script:HyperVCleanMarker
    $script:restores = 0
    $whyN = @(& $openN $case.Lease)
    $wantRestores = if ($case.Skip) { 0 } else { 1 }
    $whyOk = if ($case.Skip) { $whyN.Count -eq 0 } else { $whyN.Count -eq 1 -and $whyN[0] -like "*($($case.Why)); restoring 'clean-base'." }
    if ($stamped.LeaseEpoch -ceq 'epoch-a' -and $stamped.LeaseGeneration -eq 5 -and $script:restores -eq $wantRestores -and $whyOk) {
        Ok "$($case.Tag): $(if ($case.Skip) { 'the marker is used (no restore)' } else { 'restore, the verbose line names why' })"
    } else { Bad "$($case.Tag): stamp=$($stamped | ConvertTo-Json -Compress) restores=$($script:restores) why=$($whyN -join ' | ')" }
}
# A marker of the PR 1 shape (VMId, no lease fields) is never used once leases exist.
Reset-State
$script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = [string]$script:vmId; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddSeconds(-30) }
$whyN = @(& $openN $L6)
if ($script:restores -eq 1 -and $whyN.Count -eq 1 -and $whyN[0] -like '*not stamped under the current VM lease*') { Ok 'a marker without lease fields -> restore (fail-safe)' } else { Bad "no lease fields: restores=$($script:restores) why=$($whyN -join ' | ')" }
# The teardown without a lease restores but keeps no marker (one verbose line).
Reset-State
$tn = @{}
$vn = @(Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Info $tn -Verbose 4>&1 | ForEach-Object { $_.Message })
if ($script:restores -eq 1 -and $tn['Restored'] -eq $true -and $null -eq $script:HyperVCleanMarker -and @($vn | Where-Object { $_ -like '*no VM lease is held, so no clean marker is kept*' }).Count -eq 1) {
    Ok 'a teardown without -Lease: the restore runs (Restored $true), no marker, one verbose line'
} else { Bad "teardown no lease: restores=$($script:restores) marker=$($null -ne $script:HyperVCleanMarker) verbose=$($vn -join ' | ')" }
Reset-State

# ── (k) Hyper-V speed-up PR 4 (D9, A-15, V-17): Saved parking ─────────────────────────────────────────────────────────
Write-Host '[k] (PR 4) an unattended teardown may park the clean VM Saved; the next open only starts it while its last state change is not later than the stamp' -ForegroundColor Cyan
# C-9/C-5: the real park decision with HKCU in memory; WMI (Msvm_ComputerSystem.TimeOfLastStateChange) as a double.
. (Join-Path $repo 'Private\Test-Win32ToolkitHyperVTeardownPark.ps1')
$script:cfgK = @{}
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfgK.ContainsKey($Name)) { $script:cfgK[$Name] } else { $Default } }
$script:vmStateChange = $null; $script:cimThrows = $false; $script:cimCalls = 0; $script:cimFilter = $null
function Get-CimInstance { param($Namespace, $ClassName, $Filter, $ErrorAction)
    $script:cimCalls++; $script:cimFilter = "$Namespace|$ClassName|$Filter"
    if ($script:cimThrows) { throw 'WMI is not available' }
    [pscustomobject]@{ Name = '0E5F9E66-1111-2222-3333-444455556666'; TimeOfLastStateChange = $script:vmStateChange } }
# The helper double records -NoStart; a parked VM is left as it landed (Started $false).
${function:Restore-Win32ToolkitTestVMCheckpoint_Saved} = ${function:Restore-Win32ToolkitTestVMCheckpoint}
$script:noStartSeen = $null
function Restore-Win32ToolkitTestVMCheckpoint { param($VMName, $CheckpointName, $Mode, [switch]$NoStart)
    $script:helperCalls++; $script:noStartSeen = [bool]$NoStart
    $null = Restore-VMCheckpoint -VMName $VMName -Name $CheckpointName -Confirm:$false -ErrorAction Stop
    [pscustomobject]@{ Mode = 'TurnOffFirst'; Landed = [string]$script:vmState; TurnOffSeconds = 0.1; RestoreSeconds = 0.1; StartSeconds = $null; Started = -not $NoStart } }
${function:Wait-Win32ToolkitVMReady_Saved} = ${function:Wait-Win32ToolkitVMReady}
$sessionK = [pscustomobject]@{ Kind = 'session-double' }
function Wait-Win32ToolkitVMReady { param($VMName, $Credential, [switch]$SkipPrep, [switch]$ReturnSession) if ($ReturnSession) { $sessionK } else { $true } }
$tearK = {
    param([switch]$AllowPark)
    $script:noStartSeen = $null
    $v = @(Remove-Win32ToolkitHyperVSession -Session 'fake' -VMName 'vmA' -CheckpointName 'clean-base' -Revert -Lease $L5 -AllowPark:$AllowPark -Verbose 4>&1 3>$null)
    [pscustomobject]@{ Out = @($v | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }); Verbose = @($v | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message }) }
}
$openK = {
    $info = @{}
    $v = @(New-Win32ToolkitHyperVSession -VMName 'vmA' -Credential $cred -CheckpointName 'clean-base' -Info $info -Lease $L6 -Verbose 4>&1 3>$null)
    [pscustomobject]@{ Info = $info; Exact = (@($v | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Count -eq 1)
        Why = @($v | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -like '*clean marker is not used*' } | ForEach-Object { $_.Message }) }
}
# The teardown: park only when asked (-AllowPark = an unattended run), HyperVTeardownPark Saved and TurnOffFirst.
foreach ($case in @(
        @{ Tag = 'Saved + -AllowPark, the VM Saved afterwards'; Cfg = @{ HyperVTeardownPark = 'Saved' }; Allow = $true; State = 'Saved'; NoStart = $true; Parked = 'Saved' }
        @{ Tag = 'saved (any case, blanks) + -AllowPark'; Cfg = @{ HyperVTeardownPark = ' saved ' }; Allow = $true; State = 'Saved'; NoStart = $true; Parked = 'Saved' }
        @{ Tag = 'Saved + -AllowPark, but the VM is Running afterwards'; Cfg = @{ HyperVTeardownPark = 'Saved' }; Allow = $true; State = 'Running'; NoStart = $true; Parked = 'Running' }
        @{ Tag = 'Saved without -AllowPark (a watched run)'; Cfg = @{ HyperVTeardownPark = 'Saved' }; Allow = $false; State = 'Saved'; NoStart = $false; Parked = 'Running' }
        @{ Tag = 'Saved + Legacy (A-15: not parked, one verbose line)'; Cfg = @{ HyperVTeardownPark = 'Saved'; HyperVRevertMode = 'Legacy' }; Allow = $true; State = 'Saved'; NoStart = $false; Parked = 'Running'; Verbose = 'parking needs TurnOffFirst' }
        @{ Tag = 'Running (the default)'; Cfg = @{}; Allow = $true; State = 'Saved'; NoStart = $false; Parked = 'Running' }
        @{ Tag = 'banana (anything but Saved)'; Cfg = @{ HyperVTeardownPark = 'banana' }; Allow = $true; State = 'Saved'; NoStart = $false; Parked = 'Running' })) {
    Reset-State; $script:cfgK = $case.Cfg; $script:vmState = $case.State
    $t = & $tearK -AllowPark:$case.Allow
    $m = $script:HyperVCleanMarker
    $verboseOk = -not $case.Verbose -or @($t.Verbose | Where-Object { $_ -like "*$($case.Verbose)*" }).Count -eq 1
    if ($t.Out.Count -eq 0 -and $script:noStartSeen -eq $case.NoStart -and $m -and $m.Parked -ceq $case.Parked -and $m.VMId -eq [string]$script:vmId -and $verboseOk) {
        Ok "$($case.Tag): -NoStart $($case.NoStart), marker Parked $($case.Parked)$(if ($case.NoStart -and $case.Parked -eq 'Saved') { ' (the helper left it Saved: Started $false)' })"
    } else { Bad "$($case.Tag): out=$($t.Out.Count) nostart=$($script:noStartSeen) marker=$($m | ConvertTo-Json -Compress) verbose=$($t.Verbose -join ' | ')" }
}
# The open after a parked teardown.
$stampK = { param([int]$AgeSeconds = 30) $script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = [string]$script:vmId; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddSeconds(-$AgeSeconds); LeaseEpoch = 'epoch-a'; LeaseGeneration = 5; Parked = 'Saved' } }
Reset-State; $script:cimCalls = 0; $script:cimThrows = $false; $script:vmState = 'Saved'; & $stampK 30
$script:vmStateChange = (Get-Date).AddSeconds(-31)
$k = & $openK
if ($k.Exact -and $script:helperCalls -eq 0 -and $script:restores -eq 0 -and $script:started -eq 1 -and $k.Info['RevertSkipped'] -eq $true -and $k.Info['Warm'] -eq $true -and $k.Why.Count -eq 0 -and
    $script:cimCalls -eq 1 -and $script:cimFilter -ceq "root\virtualization\v2|Msvm_ComputerSystem|Name = '0E5F9E66-1111-2222-3333-444455556666'") {
    Ok 'parked marker + VM Saved + its last state change before the stamp: only Start-VM, RevertSkipped $true (WMI asked by the upper-case VM Id)'
} else { Bad "parked hit: exact=$($k.Exact) helper=$($script:helperCalls) started=$($script:started) info=$($k.Info | ConvertTo-Json -Compress -Depth 1) why=$($k.Why -join ' | ') cim=$($script:cimCalls) $($script:cimFilter)" }
Reset-State; $script:cimCalls = 0; $script:vmState = 'Saved'; & $stampK 30
$script:vmStateChange = (Get-Date).AddSeconds(-27)   # 3 s after the stamp: within the 5 s slack
$k = & $openK
if ($script:helperCalls -eq 0 -and $k.Info['RevertSkipped'] -eq $true) { Ok 'a state change 3 s after the stamp (within the 5 s slack): still only Start-VM' } else { Bad "slack: helper=$($script:helperCalls) why=$($k.Why -join ' | ')" }
foreach ($case in @(
        @{ Tag = 'a state change 60 s after the stamp (another tool started and saved the VM)'; Set = { $script:vmState = 'Saved'; $script:vmStateChange = (Get-Date).AddSeconds(30) }; Want = 'is later than the teardown that parked it' }
        @{ Tag = 'WMI throws'; Set = { $script:vmState = 'Saved'; $script:cimThrows = $true }; Want = 'last state change could not be read (WMI is not available)' }
        @{ Tag = 'WMI returns no time'; Set = { $script:vmState = 'Saved'; $script:vmStateChange = $null }; Want = 'last state change could not be read' }
        @{ Tag = 'the VM is Running (started since)'; Set = { $script:vmState = 'Running'; $script:vmStateChange = (Get-Date).AddSeconds(-31) }; Want = 'the teardown left the VM Saved, but it is Running now' })) {
    Reset-State; $script:cimCalls = 0; $script:cimThrows = $false; & $stampK 30
    & $case.Set
    $k = & $openK
    if ($k.Exact -and $script:helperCalls -eq 1 -and $k.Info['RevertSkipped'] -eq $false -and $k.Why.Count -eq 1 -and $k.Why[0] -like "*$($case.Want)*") { Ok "parked marker, $($case.Tag): the full restore, the verbose line names it" }
    else { Bad "$($case.Tag): helper=$($script:helperCalls) info=$($k.Info | ConvertTo-Json -Compress -Depth 1) why=$($k.Why -join ' | ')" }
}
# No marker: the full sequence; a marker that is not parked never asks WMI.
Reset-State; $script:cimCalls = 0; $script:vmState = 'Saved'
$k = & $openK
$missOk = $script:helperCalls -eq 1 -and $k.Info['RevertSkipped'] -eq $false
Reset-State; $script:cimCalls = 0
$script:HyperVCleanMarker = @{ VMName = 'vmA'; VMId = [string]$script:vmId; CheckpointName = 'clean-base'; StampedAt = (Get-Date).AddSeconds(-30); LeaseEpoch = 'epoch-a'; LeaseGeneration = 5; Parked = 'Running' }
$k = & $openK
if ($missOk -and $script:helperCalls -eq 0 -and $k.Info['RevertSkipped'] -eq $true -and $script:cimCalls -eq 0) { Ok 'no marker: the full restore; a Running-parked marker keeps the uptime rule and never asks WMI' } else { Bad "miss/running: miss=$missOk helper=$($script:helperCalls) cim=$($script:cimCalls)" }
${function:Restore-Win32ToolkitTestVMCheckpoint} = ${function:Restore-Win32ToolkitTestVMCheckpoint_Saved}
${function:Wait-Win32ToolkitVMReady} = ${function:Wait-Win32ToolkitVMReady_Saved}
Remove-Item Function:\Restore-Win32ToolkitTestVMCheckpoint_Saved, Function:\Wait-Win32ToolkitVMReady_Saved, Function:\Get-CimInstance, Function:\Get-Win32ToolkitConfigValue
Reset-State

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
