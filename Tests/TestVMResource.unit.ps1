<#
    Set-Win32ToolkitTestVMResource — reconfigure the Hyper-V test VM's CPU/memory and re-freeze the clean-base
    checkpoint. Every Hyper-V cmdlet is shadowed; no VM, no host mutation. Asserts the ordered sequence
    (stop -> drop checkpoint -> set CPU/mem -> boot -> wait -> re-checkpoint -> persist), the host-capacity
    hard-block, the floor, VM-not-found, "nothing to change", and that -WhatIf mutates nothing. Plus the
    ConvertTo-Win32ToolkitByteSize parser.

    Run:  pwsh -File Tests\TestVMResource.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitByteSize.ps1')
. (Join-Path $repo 'Private\Clear-Win32ToolkitHyperVStateCache.ps1')   # reconfigure invalidates the HyperV state caches
. (Join-Path $repo 'Public\Set-Win32ToolkitTestVMResource.ps1')

# --- shadowed Hyper-V + config surface, logging the call sequence ---------------------------------
$script:calls    = @()
$script:cfg      = @{}
$script:vmExists = $true
$script:vmState  = 'Off'    # state Get-VM reports (the post-Stop "did it power off?" guard reads this)
$script:curCpu   = 2
$script:curMem   = [uint64]4GB
$script:hostCpu  = 8
$script:hostRam  = [uint64]16GB
$script:desktopUp = $true

function Log($s) { $script:calls += $s }

function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
function Set-Win32ToolkitConfigValue { param($Name, $Value) $script:cfg[$Name] = "$Value"; Log "cfg:$Name=$Value" }
function Get-Win32ToolkitGuestCredential { [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }

function Get-VM { param($Name, $ErrorAction) if ($script:vmExists) { [pscustomobject]@{ Name = $Name; State = $script:vmState } } else { $null } }
function Get-VMHost { [pscustomobject]@{ LogicalProcessorCount = $script:hostCpu; MemoryCapacity = $script:hostRam } }
function Get-VMProcessor { param($VMName) [pscustomobject]@{ Count = $script:curCpu } }
function Get-VMMemory { param($VMName) [pscustomobject]@{ Startup = $script:curMem } }
function Stop-VM { param($Name, [switch]$TurnOff, [switch]$Force, $ErrorAction) Log 'Stop-VM' }
function Get-VMCheckpoint { param($VMName, $ErrorAction) [pscustomobject]@{ Name = 'clean-base' } }
function Remove-VMCheckpoint { param([Parameter(ValueFromPipeline)]$InputObject) process { Log 'Remove-VMCheckpoint' } }
function Set-VMProcessor { param($VMName, $Count) Log "Set-VMProcessor:$Count" }
function Set-VMMemory { param($VMName, $DynamicMemoryEnabled, $StartupBytes) Log "Set-VMMemory:$StartupBytes" }
function Start-VM { param($Name, $ErrorAction) Log 'Start-VM' }
function Wait-Win32ToolkitVMReady { param($VMName, $Credential) Log 'Wait-VMReady'; $true }
function Invoke-Command { param($VMName, $Credential, $ScriptBlock, $ErrorAction) $script:desktopUp }
# Speed-up PR 1 (D5): -AutomaticCheckpointsEnabled is logged as its own entry; the checkpoint-time call logs both.
function Set-VM { param($Name, $CheckpointType, $AutomaticCheckpointsEnabled, $ErrorAction)
    if ($CheckpointType) { Log "Set-VM:CheckpointType=$CheckpointType" }
    if ($null -ne $AutomaticCheckpointsEnabled) { Log "Set-VM:Auto=$AutomaticCheckpointsEnabled$(if ($CheckpointType) { '+CheckpointType' })" } }
function Checkpoint-VM { param($VMName, $SnapshotName) Log "Checkpoint-VM:$SnapshotName" }
function Start-Sleep { param($Seconds) }
# C-5/C-9 (speed-up PR 1): the real Clear-Win32ToolkitHyperVStateCache also clears the stored checkpoint answers;
# the developer's real HKCU is never touched.
$script:probeClears = 0
function Clear-Win32ToolkitParityProbeCache { $script:probeClears++ }
function Remove-ItemProperty { throw 'real HKCU must not be touched' }
# C-9 (speed-up PR 3): the VM commands hold the VM's lease; the doubles log it into the call sequence and hand out a fake
# lease ([10] makes it time out).
$script:leaseThrows = $false
function Enter-Win32ToolkitHyperVLease { param($VMName, $VMId, $ProjectPath, $Purpose)
    Log "Lease:enter:${VMName}:$Purpose"
    if ($script:leaseThrows) {
        throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new("Another process kept the test VM '$VMName' for more than 60 minutes."),
            'W32T.HyperVLeaseTimeout', [System.Management.Automation.ErrorCategory]::ResourceBusy, $VMName)
    }
    [pscustomobject]@{ Kind = 'VM'; VMName = $VMName; Epoch = 'e'; Generation = 1; PreviousGeneration = 0; Nested = $false } }
function Exit-Win32ToolkitHyperVLease { param($Lease) Log "Lease:exit:$(if ($Lease) { $Lease.VMName } else { 'none' })"; [pscustomobject]@{ Leak = 'exit' } }
# advance Get-Date so the desktop-never-up loop exits quickly instead of spinning 10 real minutes
$script:now = [datetime]'2026-01-01T00:00:00'
function Get-Date { param($Format) $script:now = $script:now.AddMinutes(4); $script:now }

function Run { param([hashtable]$P) $script:calls = @(); $script:cfg = @{}; try { Set-Win32ToolkitTestVMResource @P *>$null } catch { $script:err = $_.Exception.Message } }
function ExpectThrow { param([hashtable]$P, [string]$Needle) $script:calls = @(); $script:err = $null; try { Set-Win32ToolkitTestVMResource @P *>$null } catch { $script:err = $_.Exception.Message }; return ($null -ne $script:err -and $script:err -like "*$Needle*") }

# ══ [1] happy path: change CPU + RAM => correct ordered sequence + persistence ═════════════════════
Write-Host '[1] change CPU+RAM: off -> drop checkpoint -> set CPU/mem -> boot -> re-checkpoint -> persist' -ForegroundColor Cyan
$script:vmExists = $true; $script:curCpu = 2; $script:curMem = [uint64]4GB; $script:desktopUp = $true
Run @{ ProcessorCount = 4; MemoryStartupBytes = 8GB }
$seq = $script:calls -join ' > '
$order = @('Stop-VM','Remove-VMCheckpoint','Set-VMProcessor:4','Set-VMMemory:8589934592','Start-VM','Set-VM:CheckpointType=Standard','Checkpoint-VM:clean-base')
$idx = 0; $inOrder = $true
foreach ($step in $order) { $j = ($script:calls | Select-String -SimpleMatch $step); if (-not $j) { $inOrder = $false } }
# strict index ordering
$positions = $order | ForEach-Object { $s = $_; [array]::IndexOf($script:calls, ($script:calls | Where-Object { $_ -eq $s } | Select-Object -First 1)) }
$strict = $true; for ($i = 1; $i -lt $positions.Count; $i++) { if ($positions[$i] -lt $positions[$i-1] -or $positions[$i] -lt 0) { $strict = $false } }
if ($inOrder -and $strict) { Ok "sequence is correct: $seq" } else { Bad "sequence wrong: $seq" }
if ($script:cfg['HyperVProcessorCount'] -eq '4' -and $script:cfg['HyperVMemoryStartupBytes'] -eq '8589934592') { Ok 'new CPU + RAM persisted to config' } else { Bad "cfg cpu=$($script:cfg['HyperVProcessorCount']) mem=$($script:cfg['HyperVMemoryStartupBytes'])" }
if ($script:probeClears -ge 1) { Ok 'the reconfigure cleared the stored checkpoint answers (Clear-Win32ToolkitParityProbeCache, shadowed)' } else { Bad "probe clears: $($script:probeClears)" }

# ══ [2] CPU-only: Set-VMMemory NOT called, but still stops + re-checkpoints ════════════════════════
Write-Host '[2] CPU-only change does not touch memory, still recreates the checkpoint' -ForegroundColor Cyan
$script:curCpu = 2; $script:curMem = [uint64]4GB
Run @{ ProcessorCount = 6 }
if (($script:calls -contains 'Set-VMProcessor:6') -and -not ($script:calls | Where-Object { $_ -like 'Set-VMMemory:*' })) { Ok 'Set-VMProcessor called, Set-VMMemory NOT called' } else { Bad "calls=$($script:calls -join ',')" }
if (($script:calls -contains 'Stop-VM') -and ($script:calls -contains 'Checkpoint-VM:clean-base')) { Ok 'still stops + re-checkpoints for a CPU-only change' } else { Bad 'CPU-only skipped the re-checkpoint' }

# ══ [3] guards ════════════════════════════════════════════════════════════════════════════════════
Write-Host '[3] validation guards' -ForegroundColor Cyan
if (ExpectThrow @{ } 'Nothing to change') { Ok 'no params -> "nothing to change"' } else { Bad 'accepted an empty change' }
$script:vmExists = $false
if (ExpectThrow @{ ProcessorCount = 4 } 'does not exist') { Ok 'VM missing -> clear "provision it first" error' } else { Bad 'accepted a missing VM' }
$script:vmExists = $true
if (ExpectThrow @{ ProcessorCount = 9 } 'exceeds the host') { Ok "CPU > host ($($script:hostCpu)) -> refused" } else { Bad 'accepted over-host CPU' }
if (ExpectThrow @{ MemoryStartupBytes = 15GB } 'exceeds usable host RAM') { Ok 'RAM > host-minus-reserve -> refused' } else { Bad 'accepted over-host RAM' }
if (ExpectThrow @{ MemoryStartupBytes = 1GB } 'below the') { Ok 'RAM < 2 GB floor -> refused' } else { Bad 'accepted sub-floor RAM' }
# no mutation occurred on any rejected call
$script:calls = @(); try { Set-Win32ToolkitTestVMResource -ProcessorCount 9 *>$null } catch { }
if (-not ($script:calls -contains 'Stop-VM')) { Ok 'a rejected request stops nothing (fails before touching the VM)' } else { Bad 'a rejected request still stopped the VM' }

# ══ [4] -WhatIf changes nothing ═══════════════════════════════════════════════════════════════════
Write-Host '[4] -WhatIf performs no stop / reconfigure / checkpoint / persist' -ForegroundColor Cyan
$script:calls = @(); $script:cfg = @{}
Set-Win32ToolkitTestVMResource -ProcessorCount 4 -MemoryStartupBytes 8GB -WhatIf *>$null
$mutating = @($script:calls | Where-Object { $_ -in 'Stop-VM','Remove-VMCheckpoint','Start-VM','Checkpoint-VM:clean-base' -or $_ -like 'Set-VM*' -or $_ -like 'cfg:*' })
if ($mutating.Count -eq 0) { Ok 'no mutating call under -WhatIf' } else { Bad "mutated under -WhatIf: $($mutating -join ',')" }

# ══ [5] desktop never comes up -> throw, no checkpoint (never freeze a broken state) ═══════════════
Write-Host '[5] guest desktop never settles -> throws, does NOT checkpoint a broken state' -ForegroundColor Cyan
$script:desktopUp = $false
if (ExpectThrow @{ ProcessorCount = 4 } 'did not come up') { Ok 'no-desktop -> clear error' } else { Bad "err=$script:err" }
if (-not ($script:calls | Where-Object { $_ -like 'Checkpoint-VM*' })) { Ok 'no checkpoint taken when the desktop is broken' } else { Bad 'froze a broken state' }
$script:desktopUp = $true

# ══ [6] the byte-size parser ══════════════════════════════════════════════════════════════════════
Write-Host '[6] ConvertTo-Win32ToolkitByteSize' -ForegroundColor Cyan
$cases = @(
    @{ In = '6GB';        Out = [uint64]6GB }
    @{ In = '6144MB';     Out = [uint64]6GB }
    @{ In = '6';          Out = [uint64]6GB }   # bare number => GB
    @{ In = '512MB';      Out = [uint64]512MB }
    @{ In = '6442450944'; Out = [uint64]6442450944 * 1GB }  # bare integer treated as GB
)
$allOk = $true
foreach ($c in $cases) { if ((ConvertTo-Win32ToolkitByteSize -Text $c.In) -ne $c.Out) { $allOk = $false; Bad "parse '$($c.In)' -> $(ConvertTo-Win32ToolkitByteSize -Text $c.In), expected $($c.Out)" } }
if ($allOk) { Ok 'GB/MB/bare-number sizes parse correctly' }
if ($null -eq (ConvertTo-Win32ToolkitByteSize -Text 'abc') -and $null -eq (ConvertTo-Win32ToolkitByteSize -Text '')) { Ok 'garbage / empty -> $null (caller can re-prompt)' } else { Bad 'garbage did not return $null' }
# a huge bare number (=> GB) overflows uint64 — must return $null, NOT throw (would crash the unguarded TUI menu)
$ov = $null; $threw = $false; try { $ov = ConvertTo-Win32ToolkitByteSize -Text '20000000000' } catch { $threw = $true }
if (-not $threw -and $null -eq $ov) { Ok 'overflowing size -> $null, does not throw (menu stays alive)' } else { Bad "overflow: threw=$threw out=$ov" }

# ══ [7] Stop-VM silently fails (VM stays running) -> throw BEFORE destroying the checkpoint ═════════
Write-Host '[7] a VM that will not power off -> throws, does NOT remove the checkpoint or change hardware' -ForegroundColor Cyan
$script:vmState = 'Running'   # Stop-VM (shadow) does not change state, so the guard sees it still running
if (ExpectThrow @{ ProcessorCount = 4 } 'Could not power off') { Ok 'refuses when the VM will not power off' } else { Bad "err=$script:err" }
if (-not ($script:calls -contains 'Remove-VMCheckpoint') -and -not ($script:calls | Where-Object { $_ -like 'Set-VMProcessor*' })) {
    Ok 'the clean-base checkpoint is NOT removed and no hardware is changed (recoverable)'
} else { Bad "destructive steps ran anyway: $($script:calls -join ',')" }
$script:vmState = 'Off'

# ══ [8] speed-up PR 1 (D5): automatic checkpoints off before the start, and in the re-taken checkpoint ═══════════════
Write-Host '[8] automatic checkpoints are turned off before Start-VM and carried by the checkpoint-time Set-VM' -ForegroundColor Cyan
$script:vmState = 'Off'; $script:desktopUp = $true; $script:curCpu = 2; $script:curMem = [uint64]4GB
Run @{ ProcessorCount = 4 }
$iAuto = [array]::IndexOf($script:calls, 'Set-VM:Auto=False'); $iStart = [array]::IndexOf($script:calls, 'Start-VM'); $iStop = [array]::IndexOf($script:calls, 'Stop-VM')
if ($iAuto -ge 0 -and $iStart -gt $iAuto -and $iAuto -gt $iStop) { Ok 'Set-VM -AutomaticCheckpointsEnabled $false after the power-off and BEFORE Start-VM' } else { Bad "order: $($script:calls -join ' > ')" }
$iCpSet = [array]::IndexOf($script:calls, 'Set-VM:Auto=False+CheckpointType'); $iCp = [array]::IndexOf($script:calls, 'Checkpoint-VM:clean-base')
if ($iCpSet -gt $iStart -and $iCp -gt $iCpSet) { Ok 'the checkpoint-time Set-VM carries -AutomaticCheckpointsEnabled $false (the checkpoint keeps the setting)' } else { Bad "checkpoint Set-VM: $($script:calls -join ' > ')" }
$script:vmState = 'Running'
$null = ExpectThrow @{ ProcessorCount = 4 } 'Could not power off'
if (-not ($script:calls | Where-Object { $_ -like 'Set-VM*' })) { Ok 'a VM that will not power off: no Set-VM at all (as [7])' } else { Bad "set-vm on refusal: $($script:calls -join ',')" }
$script:vmState = 'Off'

# == [9] speed-up PR 2 (V-Fe11): a checkpoint that could not be taken stops the command ===========================
Write-Host '[9] Checkpoint-VM fails -> the command throws: no success line, no settings written' -ForegroundColor Cyan
# The real cmdlet reports the failure as a non-terminating error. The double does the same (an advanced function, so
# -ErrorAction Stop turns it into a throw), and the call runs with the session default $ErrorActionPreference Continue.
${function:Checkpoint-VM_Saved} = ${function:Checkpoint-VM}
function Checkpoint-VM { [CmdletBinding()] param($VMName, $SnapshotName) Log "Checkpoint-VM:$SnapshotName"; Write-Error 'Simulated: the checkpoint operation failed.' }
$script:vmState = 'Off'; $script:desktopUp = $true; $script:curCpu = 2; $script:curMem = [uint64]4GB
$script:calls = @(); $script:cfg = @{}
$r9 = & {
    $ErrorActionPreference = 'Continue'
    $iv = $null; $t = $null
    try { $null = Set-Win32ToolkitTestVMResource -ProcessorCount 4 -InformationVariable iv 2>$null 3>$null 6>$null } catch { $t = $_ }
    [pscustomobject]@{ Threw = $t; Info = @($iv | ForEach-Object { "$_" }) }
}
${function:Checkpoint-VM} = ${function:Checkpoint-VM_Saved}
Remove-Item Function:\Checkpoint-VM_Saved
if ($r9.Threw -and "$($r9.Threw)" -like '*checkpoint operation failed*') { Ok 'the command throws the checkpoint error' } else { Bad "no throw: $($r9.Threw)" }
if (@($r9.Info | Where-Object { $_ -like '*checkpoint recreated*' }).Count -eq 0) { Ok 'no "checkpoint recreated" success line' } else { Bad "success line printed: $($r9.Info -join ' | ')" }
if (@($script:calls | Where-Object { $_ -like 'cfg:*' }).Count -eq 0 -and ($script:calls -contains 'Checkpoint-VM:clean-base')) { Ok 'no setting written after the failed checkpoint' } else { Bad "after a failed checkpoint: $($script:calls -join ' > ')" }

# == [10] speed-up PR 3 (D10): the reconfigure and the removal hold the VM's lease ====================================
Write-Host '[10] the VM lease: taken before the first VM change, released after the last; a lease timeout changes nothing' -ForegroundColor Cyan
$script:vmState = 'Off'; $script:desktopUp = $true; $script:curCpu = 2; $script:curMem = [uint64]4GB; $script:vmExists = $true
$script:calls = @(); $script:cfg = @{}
$out10 = $null; $err10 = $null
try { $out10 = @(Set-Win32ToolkitTestVMResource -ProcessorCount 4 6>$null 3>$null) } catch { $err10 = $_ }
$iEnter = [array]::IndexOf($script:calls, 'Lease:enter:win32tk-golden:resource change'); $iExit = [array]::IndexOf($script:calls, 'Lease:exit:win32tk-golden')
$iStop = [array]::IndexOf($script:calls, 'Stop-VM'); $iLastCfg = [array]::LastIndexOf($script:calls, 'cfg:HyperVMemoryStartupBytes=4294967296')
if (-not $err10 -and $iEnter -ge 0 -and $iEnter -lt $iStop -and $iExit -gt $iLastCfg -and $iExit -eq $script:calls.Count - 1 -and @($script:calls | Where-Object { $_ -like 'Lease:*' }).Count -eq 2) {
    Ok 'Set-...Resource: the lease before Stop-VM, released after the settings are written (last call)'
} else { Bad "set lease: err=$err10 calls=$($script:calls -join ' > ')" }
if ($out10.Count -eq 1 -and $out10[0].Name -eq 'win32tk-golden') { Ok 'the output is still the VM only (the release double''s object does not leak)' } else { Bad "output: $(@($out10) | ConvertTo-Json -Compress)" }
# A failure inside the lease still releases it.
$script:vmState = 'Running'
$null = ExpectThrow @{ ProcessorCount = 4 } 'Could not power off'
if (($script:calls | Select-Object -Last 1) -eq 'Lease:exit:win32tk-golden') { Ok 'a VM that will not power off: the lease is still released' } else { Bad "failure release: $($script:calls -join ' > ')" }
$script:vmState = 'Off'
# A lease timeout: the W32T error, nothing changed.
$script:leaseThrows = $true
$script:calls = @(); $script:cfg = @{}; $err10 = $null
try { Set-Win32ToolkitTestVMResource -ProcessorCount 4 6>$null 3>$null } catch { $err10 = $_ }
$script:leaseThrows = $false
$changed = @($script:calls | Where-Object { $_ -notlike 'Lease:enter:*' })
if ($err10.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and $changed.Count -eq 0) { Ok 'a lease timeout: W32T.HyperVLeaseTimeout, no stop, no checkpoint change, no setting written' } else { Bad "set timeout: $($err10.FullyQualifiedErrorId) calls=$($script:calls -join ' > ')" }
# Remove-Win32ToolkitTestVM: the same lease around the stop and the removal (with the VM's Id).
. (Join-Path $repo 'Public\Remove-Win32ToolkitTestVM.ps1')
${function:Get-VM_Saved10} = ${function:Get-VM}
function Get-VM { param($Name, $ErrorAction) [pscustomobject]@{ Name = $Name; State = 'Running'; Id = [guid]'0e5f9e66-1111-2222-3333-444455556666'; HardDrives = @() } }
function Remove-VM { param($Name, [switch]$Force, $ErrorAction) Log 'Remove-VM' }
${function:Enter-Win32ToolkitHyperVLease_Saved10} = ${function:Enter-Win32ToolkitHyperVLease}
$script:leaseVmId10 = $null
function Enter-Win32ToolkitHyperVLease { param($VMName, $VMId, $ProjectPath, $Purpose) $script:leaseVmId10 = $VMId; Enter-Win32ToolkitHyperVLease_Saved10 -VMName $VMName -Purpose $Purpose }
try {
    $script:calls = @()
    $o = @(Remove-Win32ToolkitTestVM -Name 'vm-x' -Confirm:$false 6>$null 3>$null)
    if ($o.Count -eq 0 -and ($script:calls -join ' > ') -eq 'Lease:enter:vm-x:removal > Stop-VM > Remove-VMCheckpoint > Remove-VM > Lease:exit:vm-x' -and $script:leaseVmId10 -eq '0e5f9e66-1111-2222-3333-444455556666') {
        Ok 'Remove-Win32ToolkitTestVM: the lease (with the VM''s Id) around the stop and the removal; nothing emitted'
    } else { Bad "remove lease: out=$($o.Count) calls=$($script:calls -join ' > ') id=$($script:leaseVmId10)" }
    $script:leaseThrows = $true; $script:calls = @(); $errR = $null
    try { Remove-Win32ToolkitTestVM -Name 'vm-x' -Confirm:$false 6>$null 3>$null } catch { $errR = $_ }
    $script:leaseThrows = $false
    if ($errR.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and ($script:calls -join ' > ') -eq 'Lease:enter:vm-x:removal') { Ok 'Remove: a lease timeout removes nothing' } else { Bad "remove timeout: $($errR.FullyQualifiedErrorId) calls=$($script:calls -join ' > ')" }
    $script:calls = @()
    $null = Remove-Win32ToolkitTestVM -Name 'vm-x' -WhatIf 6>$null 3>$null
    if ($script:calls.Count -eq 0) { Ok 'Remove -WhatIf: no lease, nothing removed' } else { Bad "remove whatif: $($script:calls -join ' > ')" }
}
finally {
    ${function:Get-VM} = ${function:Get-VM_Saved10}; ${function:Enter-Win32ToolkitHyperVLease} = ${function:Enter-Win32ToolkitHyperVLease_Saved10}
    Remove-Item Function:\Get-VM_Saved10, Function:\Enter-Win32ToolkitHyperVLease_Saved10, Function:\Remove-VM
    $script:leaseThrows = $false
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestVMResource tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestVMResource test(s) FAILED." -ForegroundColor Red; exit 1 }
