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
function Set-VM { param($Name, $CheckpointType) Log "Set-VM:CheckpointType=$CheckpointType" }
function Checkpoint-VM { param($VMName, $SnapshotName) Log "Checkpoint-VM:$SnapshotName" }
function Start-Sleep { param($Seconds) }
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

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestVMResource tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestVMResource test(s) FAILED." -ForegroundColor Red; exit 1 }
