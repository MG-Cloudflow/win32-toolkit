<#
    R13.1 + R12 — the opt-in 'clean-base+deps' checkpoint and the zip-prebuild overlap.

      (a) Get-Win32ToolkitDepsCheckpointName: deterministic key over (staged manifest + payload bytes +
          parent checkpoint identity); $null when no deps / no parent (feature inapplicable); any input
          change => different name (stale checkpoints are simply never matched).
      (b) Invoke-Win32ToolkitHyperVRun orchestration: feature OFF (default) => bit-identical behavior,
          no checkpoint ops. ON + no existing checkpoint => the tagged dep phase runs, ONE deps
          checkpoint is created (older ones pruned), teardown reverts to it. ON + existing checkpoint =>
          the session opens on the deps checkpoint, the dep phase is SKIPPED, and the in-guest
          InstallDependencies.ps1 is removed (so the capture script skips deps too). A FAILED dep phase
          never freezes a checkpoint.
      (c) R12: the copy-in zip is PRE-BUILT concurrently and handed to the copy helper; consumed zips
          are cleaned up.

    Run:  pwsh -File Tests\HyperVDepsCheckpoint.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitDepsCheckpointName.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitHyperVRun.ps1')

function New-Proj {
    param([switch]$WithDeps)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('dcp_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'file.txt') 'payload'
    if ($WithDeps) {
        New-Item -ItemType Directory -Path (Join-Path $p 'Sandbox\Dependencies\Acme.Dep') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $p 'Sandbox\Dependencies\dependencies.json') '[{"Name":"Acme.Dep"}]'
        [System.IO.File]::WriteAllBytes((Join-Path $p 'Sandbox\Dependencies\Acme.Dep\dep.msi'), [byte[]](1..32))
    }
    $p
}

# ── (a) key derivation ─────────────────────────────────────────────────────────────────────────────
Write-Host '[a] Get-Win32ToolkitDepsCheckpointName' -ForegroundColor Cyan
$script:parentCp = [pscustomobject]@{ Id = [guid]'11111111-1111-1111-1111-111111111111'; CreationTime = [datetime]'2026-07-01T10:00:00' }
function Get-VMCheckpoint { param($VMName, $Name, [Parameter(ValueFromRemainingArguments)]$Rest)
    if ($Name -eq 'clean-base') { return $script:parentCp }
    if ($script:existingDepsCp -and $Name -eq $script:existingDepsCp) { return [pscustomobject]@{ Name = $Name } }
    if (-not $Name) { return $script:allCps }
    return $null
}
$script:existingDepsCp = $null
$script:allCps = @()

$projD = New-Proj -WithDeps
$n1 = Get-Win32ToolkitDepsCheckpointName -ProjectPath $projD -VMName 'vm' -ParentCheckpointName 'clean-base'
$n2 = Get-Win32ToolkitDepsCheckpointName -ProjectPath $projD -VMName 'vm' -ParentCheckpointName 'clean-base'
if ($n1 -and $n1 -match '^clean-base\+deps-[0-9a-f]{12}$') { Ok "name shape: $n1" } else { Bad "name: $n1" }
if ($n1 -eq $n2) { Ok 'deterministic for identical inputs' } else { Bad "n1=$n1 n2=$n2" }
[System.IO.File]::WriteAllBytes((Join-Path $projD 'Sandbox\Dependencies\Acme.Dep\dep.msi'), [byte[]](9..40))
$n3 = Get-Win32ToolkitDepsCheckpointName -ProjectPath $projD -VMName 'vm' -ParentCheckpointName 'clean-base'
if ($n3 -ne $n1) { Ok 'changed payload bytes => different key (version bump never reuses a stale image)' } else { Bad 'payload change did not change the key' }
$script:parentCp = [pscustomobject]@{ Id = [guid]::NewGuid(); CreationTime = Get-Date }
$n4 = Get-Win32ToolkitDepsCheckpointName -ProjectPath $projD -VMName 'vm' -ParentCheckpointName 'clean-base'
if ($n4 -ne $n3) { Ok 'recreated parent checkpoint => different key (never outlives its base image)' } else { Bad 'parent identity not in the key' }
$projN = New-Proj
if ($null -eq (Get-Win32ToolkitDepsCheckpointName -ProjectPath $projN -VMName 'vm' -ParentCheckpointName 'clean-base')) { Ok 'no staged deps => $null (feature inapplicable)' } else { Bad 'produced a key without deps' }

# ── (b)+(c) orchestration ──────────────────────────────────────────────────────────────────────────
Write-Host '[b] Invoke-Win32ToolkitHyperVRun: deps-checkpoint lifecycle + zip prebuild' -ForegroundColor Cyan
$script:cfg = @{}
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
function Get-Win32ToolkitGuestCredential { New-Object System.Management.Automation.PSCredential('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
$script:opened = @()
function New-Win32ToolkitHyperVSession { param($VMName, $Credential, $CheckpointName, [switch]$EnsureDesktop, [switch]$SkipRevert) $script:opened += $CheckpointName; 'sess' }
$script:reverted = @()
function Remove-Win32ToolkitHyperVSession { param($Session, $VMName, $CheckpointName, [switch]$Revert) $script:reverted += $CheckpointName }
$script:copyCalls = @()
function Copy-Win32ToolkitProjectToGuest { param($Session, $ProjectPath, $GuestPath, [switch]$ReadOnly, $PrebuiltZip)
    $script:copyCalls += [pscustomobject]@{ Guest = $GuestPath; Zip = $PrebuiltZip; ZipExists = [bool]($PrebuiltZip -and (Test-Path -LiteralPath $PrebuiltZip)) }
}
$script:guestCmds = @()
function Invoke-Command { [CmdletBinding()] param($Session, [scriptblock]$ScriptBlock, $ArgumentList, [Parameter(ValueFromRemainingArguments)]$Rest) $script:guestCmds += "$ArgumentList" }
$script:phasesRun = @()
$script:depExit = 0
function Invoke-Win32ToolkitGuestPhase { param($Session, $Command, $Label) $script:phasesRun += $Label; if ($Label -like '*dep*') { $script:depExit } else { 0 } }
function Copy-Win32ToolkitResultsFromGuest { param([Parameter(ValueFromRemainingArguments)]$Rest) }
$script:cpCreated = @()
function Checkpoint-VM { param($VMName, $SnapshotName, [Parameter(ValueFromRemainingArguments)]$Rest) $script:cpCreated += $SnapshotName; if ($script:cpFail) { throw 'cp failed' } }
$script:cpFail = $false
function Set-VM { param([Parameter(ValueFromRemainingArguments)]$Rest) }
$script:cpRemoved = @()
function Remove-VMCheckpoint { param([Parameter(ValueFromPipeline = $true)]$InputObject, [Parameter(ValueFromRemainingArguments)]$Rest) process { $script:cpRemoved += $InputObject.Name } }

function Reset-Run {
    $script:opened = @(); $script:reverted = @(); $script:copyCalls = @(); $script:guestCmds = @()
    $script:phasesRun = @(); $script:cpCreated = @(); $script:cpRemoved = @(); $script:depExit = 0
    $script:existingDepsCp = $null; $script:allCps = @()
}
$phases = @(
    @{ Label = 'Install dependencies'; Command = 'dep-cmd'; DepPhase = $true }
    @{ Label = 'Install app'; Command = 'app-cmd' }
)
$script:parentCp = [pscustomobject]@{ Id = [guid]'22222222-2222-2222-2222-222222222222'; CreationTime = [datetime]'2026-07-01T10:00:00' }
$key = Get-Win32ToolkitDepsCheckpointName -ProjectPath $projD -VMName 'win32tk-golden' -ParentCheckpointName 'clean-base'

# b1: feature OFF (default) => no checkpoint ops, dep phase runs, clean-base everywhere.
Reset-Run
$r = Invoke-Win32ToolkitHyperVRun -ProjectPath $projD -Phase $phases 3>$null 6>$null
if ($r -eq $true -and $script:opened[0] -eq 'clean-base' -and $script:reverted[0] -eq 'clean-base') { Ok 'OFF: opens + reverts clean-base (bit-identical default)' } else { Bad "OFF: opened=$($script:opened) reverted=$($script:reverted)" }
if (@($script:cpCreated).Count -eq 0 -and $script:phasesRun -contains 'Install dependencies') { Ok 'OFF: dep phase runs, no checkpoint created' } else { Bad "OFF: created=$($script:cpCreated) phases=$($script:phasesRun)" }

# b2: ON + no existing checkpoint => dep phase runs, checkpoint created, teardown reverts to it.
Reset-Run
$script:cfg['HyperVDepsCheckpoint'] = 'On'
$script:allCps = @([pscustomobject]@{ Name = 'clean-base+deps-oldoldoldold' })
$r = Invoke-Win32ToolkitHyperVRun -ProjectPath $projD -Phase $phases 3>$null 6>$null
if ($script:opened[0] -eq 'clean-base' -and $script:phasesRun -contains 'Install dependencies') { Ok 'ON+miss: opens clean-base, dep phase runs live' } else { Bad "ON+miss: opened=$($script:opened) phases=$($script:phasesRun)" }
if (@($script:cpCreated) -contains $key) { Ok "ON+miss: '$key' created after the successful dep install" } else { Bad "created: $($script:cpCreated) expected $key" }
if ($script:cpRemoved -contains 'clean-base+deps-oldoldoldold') { Ok 'ON+miss: stale deps checkpoints pruned (cap: one retained)' } else { Bad "removed: $($script:cpRemoved)" }
if ($script:reverted[0] -eq $key) { Ok 'ON+miss: teardown reverts to the deps checkpoint (clean-with-deps)' } else { Bad "reverted: $($script:reverted)" }

# b3: ON + existing checkpoint => opens it, dep phase skipped, guest installer script removed.
Reset-Run
$script:existingDepsCp = $key
$r = Invoke-Win32ToolkitHyperVRun -ProjectPath $projD -Phase $phases 3>$null 6>$null
if ($script:opened[0] -eq $key) { Ok 'ON+hit: session opens on the deps checkpoint' } else { Bad "opened: $($script:opened)" }
if ($script:phasesRun -notcontains 'Install dependencies' -and $script:phasesRun -contains 'Install app') { Ok 'ON+hit: dep phase SKIPPED, app phase still runs' } else { Bad "phases: $($script:phasesRun)" }
if (@($script:guestCmds) -match 'InstallDependencies') { Ok 'ON+hit: in-guest InstallDependencies.ps1 removed (capture script skips deps too)' } else { Bad "guest cmds: $($script:guestCmds)" }
if (@($script:cpCreated).Count -eq 0) { Ok 'ON+hit: nothing re-created' } else { Bad "created: $($script:cpCreated)" }

# b4: a FAILED dep phase never freezes a checkpoint.
Reset-Run
$script:depExit = 1618
$r = Invoke-Win32ToolkitHyperVRun -ProjectPath $projD -Phase $phases 3>$null 6>$null
if (@($script:cpCreated).Count -eq 0) { Ok 'failed dep install => NO checkpoint (never freeze a broken state)' } else { Bad "created after failure: $($script:cpCreated)" }
if ($script:reverted[0] -eq 'clean-base') { Ok 'failed dep install => teardown reverts to clean-base' } else { Bad "reverted: $($script:reverted)" }
$script:cfg.Clear()

# c: zip prebuild — the copy helper received a PREBUILT zip that existed at call time.
Reset-Run
$r = Invoke-Win32ToolkitHyperVRun -ProjectPath $projD -Phase @(@{ Label = 'x'; Command = 'y' }) 3>$null 6>$null
$projCopy = @($script:copyCalls | Where-Object { $_.Guest -eq 'C:\PSADT' })[0]
if ($projCopy -and $projCopy.Zip -and $projCopy.ZipExists) { Ok 'copy-in received a prebuilt zip (built during the revert)' } else { Bad "copy call: $($projCopy | Out-String)" }
if ($projCopy -and -not (Test-Path -LiteralPath $projCopy.Zip)) { Ok 'prebuilt zip cleaned up after the run' } else { Bad 'zip leaked' }

Remove-Item $projD, $projN -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
