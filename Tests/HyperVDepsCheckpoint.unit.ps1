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
          are cleaned up. Test campaign F2: neither the prebuilt zip (the thread job rebuilds
          New-Win32ToolkitProjectZip from its text) nor the inline one carries Sandbox\Logs\Runs\.

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
. (Join-Path $repo 'Private\New-Win32ToolkitProjectZip.ps1')   # C-9: the zip prebuild rebuilds it in the thread job
# C-9 (speed-up PR 3): the run resolves its VM / checkpoint through the real resolver (fed by the config shadow); no pin leaks in.
. (Join-Path $repo 'Private\Get-Win32ToolkitHyperVTarget.ps1')
Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue
# C-9 (Hyper-V speed-up PR 1): the provider's record helpers, inert (no Lane, no copy-in hash); none reaches Hyper-V.
function Get-Win32ToolkitHyperVLane { param($VMName, $CheckpointName, $VM) }
function Get-Win32ToolkitZipContentHash { param($ZipPath) }
function Get-Win32ToolkitCheckpointAttestation { param($Session, $VMName, $CheckpointName, $VMId, $CheckpointId, $CreationTimeUtcTicks, [switch]$AllowLive, [switch]$AllowStore, $SignedInAnswer) }
function Write-Win32ToolkitCheckpointAdvisory { param($Kind, $Key, $Message) }
function Test-Win32ToolkitVMConnectOpen { param($VMName, $VMId) $false }
function Get-Win32ToolkitCheckpointAutoSetting { param($CheckpointId) }
# C-9 (speed-up PR 3): the run takes the VM's lease first; inert doubles (a fake lease, a release that does nothing), never a lock file.
function Enter-Win32ToolkitHyperVLease { param($VMName, $VMId, $ProjectPath, $Purpose) [pscustomobject]@{ Kind = 'VM'; VMName = $VMName; Epoch = 'inert'; Generation = 1; PreviousGeneration = 0; Nested = $false } }
function Exit-Win32ToolkitHyperVLease { param($Lease) }
# C-9 (speed-up PR 4): the asynchronous teardown's owner and background restore, inert (no owner; HyperVAsyncTeardown reads Off).
function Get-Win32ToolkitAsyncTeardownOwner { $null }
function Start-Win32ToolkitHyperVBackgroundRestore { param($VMName, $CheckpointName, $Mode, $Lease, $Kind, [switch]$NoStart, $Info) $false }

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
    $exists = [bool]($PrebuiltZip -and (Test-Path -LiteralPath $PrebuiltZip))
    $entries = @()
    if ($exists) { $za = [System.IO.Compression.ZipFile]::OpenRead($PrebuiltZip); try { $entries = @($za.Entries | ForEach-Object { $_.FullName }) } finally { $za.Dispose() } }
    $script:copyCalls += [pscustomobject]@{ Guest = $GuestPath; Zip = $PrebuiltZip; ZipExists = $exists; Entries = $entries }
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
# Speed-up PR 1 (D5): records how the deps checkpoint's Set-VM was called.
$script:setVm = @()
function Set-VM { param($Name, $CheckpointType, $AutomaticCheckpointsEnabled, [Parameter(ValueFromRemainingArguments)]$Rest) $script:setVm += [pscustomobject]@{ CheckpointType = $CheckpointType; Auto = $AutomaticCheckpointsEnabled } }
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
if (@($script:setVm).Count -ge 1 -and $script:setVm[-1].CheckpointType -eq 'Standard' -and $script:setVm[-1].Auto -eq $false) { Ok 'ON+miss: the deps checkpoint''s Set-VM is Standard with automatic checkpoints off (speed-up PR 1, D5)' } else { Bad "Set-VM: $($script:setVm | ConvertTo-Json -Compress)" }

# b3: ON + existing checkpoint => opens it, dep phase skipped, guest installer script removed.
Reset-Run
$script:existingDepsCp = $key
$r = Invoke-Win32ToolkitHyperVRun -ProjectPath $projD -Phase $phases 3>$null 6>$null
if ($script:opened[0] -eq $key) { Ok 'ON+hit: session opens on the deps checkpoint' } else { Bad "opened: $($script:opened)" }
if ($script:phasesRun -notcontains 'Install dependencies' -and $script:phasesRun -contains 'Install app') { Ok 'ON+hit: dep phase SKIPPED, app phase still runs' } else { Bad "phases: $($script:phasesRun)" }
if (@($script:guestCmds) -match 'InstallDependencies') { Ok 'ON+hit: in-guest InstallDependencies.ps1 removed (capture script skips deps too)' } else { Bad "guest cmds: $($script:guestCmds)" }
if (@($script:cpCreated).Count -eq 0) { Ok 'ON+hit: nothing re-created' } else { Bad "created: $($script:cpCreated)" }

# b3b: an UPDATE-BASELINE run must never CREATE the checkpoint (the read-only C:\PSADTOld copy-in
#      precedes the dep phase and would be frozen into the image, poisoning every later baseline run) —
#      but USING an existing one stays allowed (the teardown revert erases this run's C:\PSADTOld).
Reset-Run
$script:cfg['HyperVDepsCheckpoint'] = 'On'
$baseProj = New-Proj
$r = Invoke-Win32ToolkitHyperVRun -ProjectPath $projD -Phase $phases -BaselineProjectPath $baseProj 3>$null 6>$null
if (@($script:cpCreated).Count -eq 0) { Ok 'baseline run: checkpoint NOT created (would freeze the RX-locked C:\PSADTOld)' } else { Bad "created during baseline run: $($script:cpCreated)" }
if ($script:phasesRun -contains 'Install dependencies') { Ok 'baseline run: dep phase still runs live' } else { Bad 'dep phase lost' }
Reset-Run
$script:existingDepsCp = $key
$r = Invoke-Win32ToolkitHyperVRun -ProjectPath $projD -Phase $phases -BaselineProjectPath $baseProj 3>$null 6>$null
if ($script:opened[0] -eq $key -and $script:phasesRun -notcontains 'Install dependencies') { Ok 'baseline run: USING an existing deps checkpoint still works' } else { Bad "baseline+hit: opened=$($script:opened) phases=$($script:phasesRun)" }
Remove-Item $baseProj -Recurse -Force -ErrorAction SilentlyContinue

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

# c1b (test campaign 2026-10-21): the REAL copy helper consumes (deletes) the prebuilt zip; the teardown
#      must then not try to delete it again and leave a PathNotFound record in the caller's -ErrorVariable.
${function:Copy-Win32ToolkitProjectToGuest_Recording} = ${function:Copy-Win32ToolkitProjectToGuest}
function Copy-Win32ToolkitProjectToGuest { param($Session, $ProjectPath, $GuestPath, [switch]$ReadOnly, $PrebuiltZip)
    Copy-Win32ToolkitProjectToGuest_Recording -Session $Session -ProjectPath $ProjectPath -GuestPath $GuestPath -ReadOnly:$ReadOnly -PrebuiltZip $PrebuiltZip
    if ($PrebuiltZip -and (Test-Path -LiteralPath $PrebuiltZip)) { Remove-Item -LiteralPath $PrebuiltZip -Force }
}
Reset-Run
$Error.Clear()
$evZ = $null
$r = Invoke-Win32ToolkitHyperVRun -ProjectPath $projD -Phase @(@{ Label = 'x'; Command = 'y' }) -ErrorVariable evZ 3>$null 6>$null
$pathNotFound = @(@($evZ) + @($Error) | Where-Object { "$_" -match 'w32proj_.*\.zip' })
if ($r -eq $true -and $pathNotFound.Count -eq 0) { Ok 'consumed prebuilt zip: no PathNotFound record in -ErrorVariable / $Error' } else { Bad "zip cleanup records: $(@($pathNotFound | ForEach-Object { "$_" }) -join ' | ')" }
${function:Copy-Win32ToolkitProjectToGuest} = ${function:Copy-Win32ToolkitProjectToGuest_Recording}
Remove-Item Function:\Copy-Win32ToolkitProjectToGuest_Recording

# c2 (test campaign F2): the host's run logs (Sandbox\Logs\Runs\) never go into the guest; everything else does.
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
$projR = New-Proj
New-Item -ItemType Directory -Path (Join-Path $projR 'Sandbox\Logs\Runs\20261020-221500_Update_msi'), (Join-Path $projR 'Files\Empty') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $projR 'Sandbox\Logs\Runs\20261020-221500_Update_msi\UpdateAssertions.log') 'old run'
Set-Content -LiteralPath (Join-Path $projR 'Sandbox\Logs\UpdateAssertions.log') 'latest'
Set-Content -LiteralPath (Join-Path $projR 'Sandbox\Logs\RunsNotes.txt') 'a sibling whose name starts with Runs'
$wantIn = @('file.txt', 'Sandbox/Logs/UpdateAssertions.log', 'Sandbox/Logs/RunsNotes.txt', 'Files/Empty/')
Reset-Run
$r = Invoke-Win32ToolkitHyperVRun -ProjectPath $projR -Phase @(@{ Label = 'x'; Command = 'y' }) 3>$null 6>$null
$projCopy = @($script:copyCalls | Where-Object { $_.Guest -eq 'C:\PSADT' })[0]
$runsIn = @($projCopy.Entries | Where-Object { $_ -like 'Sandbox/Logs/Runs/*' })
$missing = @($wantIn | Where-Object { @($projCopy.Entries) -notcontains $_ })
if ($projCopy.ZipExists -and $runsIn.Count -eq 0 -and $missing.Count -eq 0) { Ok 'the prebuilt (thread job) zip leaves out Sandbox\Logs\Runs\ and keeps everything else (empty folders too)' }
else { Bad "prebuilt entries: $($projCopy.Entries -join ', ')" }
$inline = New-Win32ToolkitProjectZip -ProjectPath $projR
try {
    $za = [System.IO.Compression.ZipFile]::OpenRead($inline); try { $inlineEntries = @($za.Entries | ForEach-Object { $_.FullName }) } finally { $za.Dispose() }
    if (@($inlineEntries | Where-Object { $_ -like 'Sandbox/Logs/Runs/*' }).Count -eq 0 -and @($wantIn | Where-Object { $inlineEntries -notcontains $_ }).Count -eq 0 -and
        (@($inlineEntries | Sort-Object) -join '|') -eq (@($projCopy.Entries | Sort-Object) -join '|')) { Ok 'the inline zip (New-Win32ToolkitProjectZip) has exactly the same entries' }
    else { Bad "inline entries: $($inlineEntries -join ', ')" }
}
finally { Remove-Item -LiteralPath $inline -Force -ErrorAction SilentlyContinue }
# A project whose Sandbox\Logs holds only Runs\ still gets an (empty) Sandbox\Logs in the guest.
Remove-Item -LiteralPath (Join-Path $projR 'Sandbox\Logs\UpdateAssertions.log'), (Join-Path $projR 'Sandbox\Logs\RunsNotes.txt') -Force
$zipPathWanted = Join-Path ([System.IO.Path]::GetTempPath()) ('dcp_zip_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
$got = New-Win32ToolkitProjectZip -ProjectPath $projR -ZipPath $zipPathWanted
try {
    $za = [System.IO.Compression.ZipFile]::OpenRead($got); try { $e2 = @($za.Entries | ForEach-Object { $_.FullName }) } finally { $za.Dispose() }
    if ($got -eq $zipPathWanted -and $e2 -contains 'Sandbox/Logs/' -and @($e2 | Where-Object { $_ -like 'Sandbox/Logs/Runs/*' }).Count -eq 0) { Ok '-ZipPath is honoured; Sandbox\Logs with only Runs\ in it is still created in the guest (empty)' }
    else { Bad "only-runs entries: $($e2 -join ', ') path=$got" }
}
finally { Remove-Item -LiteralPath $zipPathWanted -Force -ErrorAction SilentlyContinue }
# A failed build (a locked file) leaves no half-written zip.
$locked = Join-Path $projR 'locked.bin'
Set-Content -LiteralPath $locked 'x'
$fs = [System.IO.File]::Open($locked, 'Open', 'Read', 'None')
$zipFail = Join-Path ([System.IO.Path]::GetTempPath()) ('dcp_zip_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
$threw = $false
try { $null = New-Win32ToolkitProjectZip -ProjectPath $projR -ZipPath $zipFail } catch { $threw = $true } finally { $fs.Dispose() }
if ($threw -and -not (Test-Path -LiteralPath $zipFail)) { Ok 'a locked file -> the build throws and leaves no zip behind' } else { Bad "locked: threw=$threw zipLeft=$(Test-Path -LiteralPath $zipFail)" }
Remove-Item -LiteralPath $zipFail -Force -ErrorAction SilentlyContinue
Remove-Item $projR -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item $projD, $projN -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
