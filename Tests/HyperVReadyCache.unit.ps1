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
# C-9 (speed-up PR 3): the readiness check names its VM through the real resolver; no pin leaks in from the caller.
. (Join-Path $repo 'Private\Get-Win32ToolkitHyperVTarget.ps1')
Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue

# ── shadows: count the expensive probes ────────────────────────────────────────────────────────────
$script:probes = 0
function Test-Win32ToolkitElevated { $true }
function Get-Module { param([switch]$ListAvailable, $Name, [Parameter(ValueFromRemainingArguments)]$Rest) $script:probes++; [pscustomobject]@{ Name = 'Hyper-V' } }
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Get-VM { param([Parameter(ValueFromRemainingArguments)]$Rest) [pscustomobject]@{ Name = 'win32tk-golden' } }
function Get-VMCheckpoint { param([Parameter(ValueFromRemainingArguments)]$Rest) [pscustomobject]@{ Name = 'clean-base' } }
function Get-Win32ToolkitGuestCredential { New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
# C-5/C-9 (speed-up PR 1): a full clear also clears the stored checkpoint answers; the real HKCU is never touched.
$script:probeClears = 0
function Clear-Win32ToolkitParityProbeCache { $script:probeClears++ }
function Remove-ItemProperty { throw 'real HKCU must not be touched' }

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
if ($script:probeClears -ge 1) { Ok 'the full clear also cleared the stored checkpoint answers (shadowed; the real HKCU untouched)' } else { Bad "probe clears: $($script:probeClears)" }

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

Write-Host '[f] (speed-up PR 3) the memo is for one VM and checkpoint: another pin is probed afresh' -ForegroundColor Cyan
function Get-Win32ToolkitGuestCredential { New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
$script:vmsSeen = [System.Collections.Generic.List[string]]::new()
function Get-VM { param($Name, [Parameter(ValueFromRemainingArguments)]$Rest) $script:vmsSeen.Add([string]$Name); if ($Name -eq 'vm-b') { $null } else { [pscustomobject]@{ Name = $Name } } }
try {
    Clear-Win32ToolkitHyperVStateCache
    $env:W32T_HYPERV_VM = 'vm-a'
    $ra = @(Test-Win32ToolkitHyperVReady)
    $ra2 = @(Test-Win32ToolkitHyperVReady)
    $env:W32T_HYPERV_VM = 'vm-b'
    $rb = @(Test-Win32ToolkitHyperVReady)
    if ($ra.Count -eq 0 -and $ra2.Count -eq 0 -and $rb.Count -eq 1 -and $rb[0] -eq "VM 'vm-b' not found" -and ($script:vmsSeen -join ',') -eq 'vm-a,vm-b') {
        Ok 'VM A ready (probed once, then memoized); pinning VM B within the TTL probes B afresh (not A''s memo)'
    } else { Bad "per key: a=[$($ra -join ';')] b=[$($rb -join ';')] seen=$($script:vmsSeen -join ',')" }
    $env:W32T_HYPERV_CHECKPOINT = 'other-cp'
    $null = @(Test-Win32ToolkitHyperVReady)
    if ($script:vmsSeen.Count -eq 3) { Ok 'another checkpoint pin: probed afresh too' } else { Bad "checkpoint key: seen=$($script:vmsSeen -join ',')" }
    $env:W32T_HYPERV_VM = '   '
    $ri = @(Test-Win32ToolkitHyperVReady)
    if ($ri.Count -eq 1 -and $ri[0] -like 'W32T_HYPERV_VM is not a valid VM name*' -and $script:vmsSeen.Count -eq 3) { Ok 'an invalid pin is a reason (no throw, no Get-VM)' } else { Bad "invalid: [$($ri -join ';')] seen=$($script:vmsSeen.Count)" }
}
finally { Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue }

Write-Host '[g] (live V3 round 2) a missing VM or checkpoint is a reason, not an error record in $Error or a caller''s -ErrorVariable' -ForegroundColor Cyan
# The real cmdlets write a non-terminating 'not found' record (InvalidParameter,Microsoft.HyperV.PowerShell.Commands.GetVM);
# -ErrorAction SilentlyContinue still keeps it in $Error and in the caller's -ErrorVariable, Ignore does not. These shadows
# write the same way and honour -ErrorAction like the cmdlets (advanced functions).
. (Join-Path $repo 'Private\Get-Win32ToolkitTestBackend.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
function Get-VM {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -eq 'no-such-vm') {
        Write-Error -Message "Hyper-V was unable to find a virtual machine with name `"$Name`"." -ErrorId 'InvalidParameter,Microsoft.HyperV.PowerShell.Commands.GetVM' -Category InvalidArgument
        return
    }
    [pscustomobject]@{ Name = $Name }
}
function Get-VMCheckpoint {
    [CmdletBinding()]
    param([string]$VMName, [string]$Name)
    if ($Name -eq 'no-such-cp') {
        Write-Error -Message "Hyper-V was unable to find a checkpoint named '$Name'." -ErrorId 'ObjectNotFound,Microsoft.HyperV.PowerShell.Commands.GetVMCheckpoint' -Category ObjectNotFound
        return
    }
    [pscustomobject]@{ Name = $Name }
}
$hvRecords = { @($Error | Where-Object { [string]$_.FullyQualifiedErrorId -like '*Microsoft.HyperV.PowerShell.Commands.*' }).Count }
try {
    # Control: the shadow leaves a record with SilentlyContinue, as the real Get-VM does (so this case can fail).
    $Error.Clear()
    $null = Get-VM -Name 'no-such-vm' -ErrorAction SilentlyContinue
    if ((& $hvRecords) -eq 1) { Ok 'control: SilentlyContinue leaves one GetVM record in $Error (like the real cmdlet)' } else { Bad "control: $(& $hvRecords) records" }

    $Error.Clear()
    $env:W32T_HYPERV_VM = 'no-such-vm'
    $evVm = $null
    $rv = @(Test-Win32ToolkitHyperVReady -Force -ErrorVariable evVm)
    if ($rv.Count -eq 1 -and $rv[0] -eq "VM 'no-such-vm' not found") { Ok 'missing VM: the reason is returned' } else { Bad "missing VM reasons: [$($rv -join ';')]" }
    if ((& $hvRecords) -eq 0 -and @($evVm).Count -eq 0) { Ok 'missing VM: no Get-VM record in $Error or -ErrorVariable' } else { Bad "missing VM records: Error=$(& $hvRecords) ErrorVariable=$(@($evVm).Count)" }

    $Error.Clear()
    $env:W32T_HYPERV_VM = 'vm-a'
    $env:W32T_HYPERV_CHECKPOINT = 'no-such-cp'
    $evCp = $null
    $rc = @(Test-Win32ToolkitHyperVReady -Force -ErrorVariable evCp)
    if ($rc.Count -eq 1 -and $rc[0] -eq "checkpoint 'no-such-cp' not found on VM 'vm-a'") { Ok 'missing checkpoint: the reason is returned' } else { Bad "missing checkpoint reasons: [$($rc -join ';')]" }
    if ((& $hvRecords) -eq 0 -and @($evCp).Count -eq 0) { Ok 'missing checkpoint: no Get-VMCheckpoint record in $Error or -ErrorVariable' } else { Bad "missing checkpoint records: Error=$(& $hvRecords) ErrorVariable=$(@($evCp).Count)" }

    # The live path: a pinned VM that does not exist throws W32T.HyperVTargetNotReady from the backend resolver; the
    # caller's -ErrorVariable and $Error hold the W32T error only (no Get-VM record next to it).
    Remove-Item Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue
    $env:W32T_HYPERV_VM = 'no-such-vm'
    $script:HyperVReadyCache = $null
    $Error.Clear()
    $evBe = $null
    $fqid = $null
    try { $null = Get-Win32ToolkitTestBackend -Backend HyperV -ErrorVariable evBe } catch { $fqid = [string]$_.FullyQualifiedErrorId }
    $beHv = @($evBe | Where-Object { [string]$_.FullyQualifiedErrorId -like '*Microsoft.HyperV.PowerShell.Commands.*' }).Count
    if ($fqid -like 'W32T.HyperVTargetNotReady*') { Ok 'pinned missing VM: W32T.HyperVTargetNotReady (fails closed)' } else { Bad "pinned missing VM threw: '$fqid'" }
    if ((& $hvRecords) -eq 0 -and $beHv -eq 0) { Ok 'pinned missing VM: no Get-VM record in $Error or the caller''s -ErrorVariable' } else { Bad "pinned missing VM records: Error=$(& $hvRecords) ErrorVariable=$beHv" }
}
finally {
    Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue
    $script:HyperVReadyCache = $null
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
