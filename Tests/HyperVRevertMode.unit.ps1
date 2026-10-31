<#
    Hyper-V speed-up PR 2 (D4, D5, B1, A-9, V-4): Restore-Win32ToolkitTestVMCheckpoint, the one restore helper of the
    test VM (session open, teardown, Reset-Win32ToolkitTestVM, the pre-check through the session helpers).

      (f)  TurnOffFirst, Running (or Paused) VM, checkpoint taken with automatic checkpoints off: Stop-VM -TurnOff,
           Restore-VMCheckpoint, Start-VM; no warning; Mode TurnOffFirst, Landed Saved, Started $true.
      (f2) A Saved or Off VM is not turned off.
      (g)  The checkpoint lands the VM Off: the cold-checkpoint warning, then Start-VM; Landed Off, Started $true (V-4).
      (h)  The checkpoint reads automatic checkpoints on, unknown, or the name matches two checkpoints: the Legacy restore
           (no Stop-VM, no Start-VM) and exactly one warning per process and checkpoint, which also silences the
           provider's own advisory for that checkpoint (one warning in all).
      (h2) The checkpoint reads off but the VM reads AutomaticCheckpointsEnabled True after the restore: Set-VM on the VM
           before Start-VM, one warning (A-9).
      (i)  HyperVRevertMode Legacy (any case) or -Mode Legacy: one Restore-VMCheckpoint, nothing else that changes the
           VM; an invalid value: TurnOffFirst and one verbose line; absent or blank: TurnOffFirst, no such line.
      (i2) -NoStart: no Start-VM.
      (x)  A failing Get-VMCheckpoint, Stop-VM, Restore-VMCheckpoint, Set-VM or Start-VM: the helper throws the cmdlet's
           error, and nothing after the failing step runs.
      (v)  One verbose line per step, with its seconds.
      (r)  Output shape (C-12, V-1): exactly one object in every case although every Hyper-V double returns an object;
           Reset-Win32ToolkitTestVM emits nothing (also when the advisory prints) and calls the helper once, after the
           cache clear; -WhatIf changes nothing.
      (s)  Speed-up PR 3: a VM in a transitional state (Starting, Stopping, Saving, Pausing, Resuming, Reset, FastSaving,
           *Critical) is waited for first, every 2 s up to 60 polls / 120 s, then the restore goes on; Legacy too; a
           state that cannot be read is not waited for.
      (t)  Speed-up PR 3: Reset holds the VM's lease around the cache clear and the restore; a lease timeout changes
           nothing; -WhatIf takes no lease.
      (y)  File hygiene: ASCII, one function, every catch starts with the C-2 line.

    Every Hyper-V cmdlet, the HKCU read and the checkpoint's WMI read are shadowed; nothing reaches a VM.

    Run:  pwsh -File Tests\HyperVRevertMode.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: no PSScriptAnalyzer warning in the suites).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows keep the real command names')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Justification = 'test shadows mirror the real -Confirm parameter')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\Write-Win32ToolkitCheckpointAdvisory.ps1')
. (Join-Path $repo 'Private\Restore-Win32ToolkitTestVMCheckpoint.ps1')
. (Join-Path $repo 'Public\Reset-Win32ToolkitTestVM.ps1')
# C-9 (speed-up PR 3): Reset's defaults come from the real resolver (fed by the config shadow); no pin leaks in.
. (Join-Path $repo 'Private\Get-Win32ToolkitHyperVTarget.ps1')
Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue

# -- shadows: a small VM model; every Hyper-V double logs and RETURNS AN OBJECT (an unassigned call would leak it) ------
$vmId = '0e5f9e66-1111-2222-3333-444455556666'
$cpId = '29613cba-d62f-4998-a421-df2e124a2b4f'
$script:log = [System.Collections.Generic.List[string]]::new()
$script:cfg = @{}
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
$script:autoAnswer = $false
function Get-Win32ToolkitCheckpointAutoSetting { param($CheckpointId) $script:log.Add("auto:$CheckpointId"); $script:autoAnswer }
$script:cpCount = 1
function Get-VMCheckpoint { param($VMName, $Name, $ErrorAction)
    $script:log.Add("get-cp:${VMName}:$Name")
    if ($script:failAt -eq 'get-cp') { throw 'Hyper-V was unable to find a checkpoint' }
    for ($i = 0; $i -lt $script:cpCount; $i++) { [pscustomobject]@{ Name = $Name; VMName = $VMName; VMId = [guid]$vmId; Id = [guid]$cpId } }
}
function Get-VM { param($Name, $ErrorAction)
    $script:log.Add('get-vm')
    if ($script:failAt -eq 'get-vm-after' -and $script:restored) { throw 'Get-VM failed' }
    # (s) speed-up PR 3: the states the next reads report before the model's own ($script:stateQueue), a first read that fails.
    if ($script:getVmFailFirst) { $script:getVmFailFirst = $false; throw 'Get-VM failed once' }
    $st = if ($script:stateQueue.Count -gt 0) { $script:stateQueue.Dequeue() } else { $script:vmState }
    [pscustomobject]@{ Name = $Name; Id = [guid]$vmId; State = $st; AutomaticCheckpointsEnabled = $script:vmAuto }
}
$script:stateQueue = [System.Collections.Generic.Queue[string]]::new(); $script:getVmFailFirst = $false
function Stop-VM { param($Name, [switch]$TurnOff, [switch]$Force, [switch]$Confirm, $ErrorAction)
    $script:log.Add("stop:turnoff=$($TurnOff.IsPresent):force=$($Force.IsPresent)")
    if ($script:failAt -eq 'stop') { throw 'The virtual machine could not be turned off' }
    $script:vmState = 'Off'; [pscustomobject]@{ Leak = 'stop' }
}
function Restore-VMCheckpoint { param($VMName, $Name, [switch]$Confirm, $ErrorAction)
    $script:log.Add("restore:${VMName}:$Name")
    if ($script:failAt -eq 'restore') { throw 'The checkpoint could not be applied' }
    $script:restored = $true
    $script:vmState = if ($script:vmStateBeforeRestore -contains $script:vmState -and $script:landRunningWhenRunning) { 'Running' } else { $script:landState }
    $script:vmAuto = $script:landAuto
    [pscustomobject]@{ Leak = 'restore' }
}
function Set-VM { param($Name, $AutomaticCheckpointsEnabled, [switch]$Confirm, $ErrorAction)
    $script:log.Add("set-vm:${Name}:auto=$AutomaticCheckpointsEnabled")
    if ($script:failAt -eq 'set-vm') { throw 'The setting could not be changed' }
    $script:vmAuto = $AutomaticCheckpointsEnabled; [pscustomobject]@{ Leak = 'set-vm' }
}
function Start-VM { param($Name, [switch]$Confirm, $ErrorAction)
    $script:log.Add("start:auto=$($script:vmAuto)")
    if ($script:failAt -eq 'start') { throw 'The virtual machine could not be started' }
    $script:vmState = 'Running'; [pscustomobject]@{ Leak = 'start' }
}
$script:clears = 0
function Clear-Win32ToolkitHyperVStateCache { param([switch]$MarkerOnly) $script:log.Add('clear'); $script:clears++; $script:HyperVAdvised = $null }
# C-9 (speed-up PR 3): Reset holds the VM's lease. The doubles record on their own ($script:leaseLog, never $script:log, so
# the sequences above stay exact) and hand out a fake lease; (t) makes the lease time out.
$script:leaseLog = [System.Collections.Generic.List[string]]::new(); $script:leaseThrows = $false
$script:leaseObj = [pscustomobject]@{ Kind = 'VM'; Epoch = 'e'; Generation = 1; PreviousGeneration = 0; Nested = $false }
function Enter-Win32ToolkitHyperVLease { param($VMName, $VMId, $ProjectPath, $Purpose)
    $script:leaseLog.Add("enter:${VMName}:${Purpose}:log=$($script:log.Count)")
    if ($script:leaseThrows) {
        throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new("Another process kept the test VM '$VMName' for more than 60 minutes."),
            'W32T.HyperVLeaseTimeout', [System.Management.Automation.ErrorCategory]::ResourceBusy, $VMName)
    }
    $script:leaseObj }
function Exit-Win32ToolkitHyperVLease { param($Lease) $script:leaseLog.Add("exit:same=$([object]::ReferenceEquals($Lease, $script:leaseObj)):log=$($script:log.Count)"); [pscustomobject]@{ Leak = 'exit' } }

function Reset-Model {
    param([string]$State = 'Running', $Auto = $false, [string]$Land = 'Saved', $LandAuto = $false)
    $script:log.Clear(); $script:cfg = @{}; $script:failAt = ''; $script:restored = $false; $script:cpCount = 1
    $script:vmState = $State; $script:autoAnswer = $Auto; $script:landState = $Land; $script:vmAuto = $LandAuto; $script:landAuto = $LandAuto
    # Legacy on a running VM: a memory-state checkpoint comes back Running (Hyper-V saves, applies and resumes).
    $script:vmStateBeforeRestore = @('Running', 'Paused'); $script:landRunningWhenRunning = $false
    $script:HyperVAdvised = $null
    $script:stateQueue.Clear(); $script:getVmFailFirst = $false
}
# One call: every output object, the warnings, the verbose lines, the error.
function Invoke-Restore {
    param([hashtable]$Splat = @{})
    $a = @{ VMName = 'vm-test'; CheckpointName = 'clean-base' } + $Splat
    $out = $null; $threw = $null; $w = $null
    $all = @()
    try { $all = @(Restore-Win32ToolkitTestVMCheckpoint @a -Verbose -WarningVariable w 4>&1 3>$null) } catch { $threw = $_ }
    $out = @($all | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] })
    [pscustomobject]@{ Out = $out; R = $(if ($out.Count -ge 1) { $out[0] } else { $null }); Threw = $threw; Warnings = @($w | ForEach-Object { "$_" })
        Verbose = @($all | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message }); Log = @($script:log) }
}
$one = { param($x) $x.Out.Count -eq 1 -and $x.R -is [pscustomobject] -and @($x.R.PSObject.Properties.Name) -join ',' -eq 'Mode,Landed,TurnOffSeconds,RestoreSeconds,StartSeconds,Started' }
$shapeOk = $true

# -- (f) TurnOffFirst on a running VM ----------------------------------------------------------------------------------
Write-Host '(f) TurnOffFirst, Running VM, checkpoint taken with automatic checkpoints off: turn off, restore, start' -ForegroundColor Cyan
Reset-Model -State 'Running' -Auto $false -Land 'Saved'
$x = Invoke-Restore
$want = "get-vm > get-cp:vm-test:clean-base > auto:$cpId > get-vm > stop:turnoff=True:force=True > restore:vm-test:clean-base > get-vm > start:auto=False"
if (-not $x.Threw -and ($x.Log -join ' > ') -eq $want -and $x.Warnings.Count -eq 0) { Ok "the sequence: $want; no warning" } else { Bad "sequence: threw=$($x.Threw) log=$($x.Log -join ' > ') warnings=$($x.Warnings -join ' | ')" }
if ((& $one $x) -and $x.R.Mode -ceq 'TurnOffFirst' -and $x.R.Landed -ceq 'Saved' -and $x.R.Started -eq $true -and $x.R.TurnOffSeconds -is [double] -and $x.R.RestoreSeconds -is [double] -and $x.R.StartSeconds -is [double]) {
    Ok 'the result: exactly one object; Mode TurnOffFirst, Landed Saved, Started $true, the seconds of each step'
} else { $shapeOk = $false; Bad "result: count=$($x.Out.Count) $($x.R | ConvertTo-Json -Compress)" }
Reset-Model -State 'Paused' -Auto $false -Land 'Saved'
$x = Invoke-Restore
if (-not $x.Threw -and @($x.Log | Where-Object { $_ -like 'stop:turnoff=True*' }).Count -eq 1 -and $x.R.Landed -ceq 'Saved' -and $x.R.Started) { Ok 'a Paused VM is turned off too' } else { Bad "paused: $($x.Log -join ' > ')" }
if (-not (& $one $x)) { $shapeOk = $false }

# -- (f2) a Saved or Off VM is not turned off --------------------------------------------------------------------------
Write-Host '(f2) a Saved or Off VM is restored without a turn-off' -ForegroundColor Cyan
foreach ($state in 'Saved', 'Off') {
    Reset-Model -State $state -Auto $false -Land 'Saved'
    $x = Invoke-Restore
    if (-not $x.Threw -and @($x.Log | Where-Object { $_ -like 'stop:*' }).Count -eq 0 -and ($x.Log -join ' > ') -like '*restore:vm-test:clean-base > get-vm > start:auto=False' -and $null -eq $x.R.TurnOffSeconds -and $x.R.Started) {
        Ok "a $state VM: no Stop-VM, restore, start; TurnOffSeconds `$null"
    } else { Bad "${state}: $($x.Log -join ' > ') $($x.R | ConvertTo-Json -Compress)" }
    if (-not (& $one $x)) { $shapeOk = $false }
}

# -- (g) the checkpoint lands the VM Off -------------------------------------------------------------------------------
Write-Host '(g) the checkpoint lands the VM Off: the cold warning, then a start; Landed Off, Started $true (V-4)' -ForegroundColor Cyan
Reset-Model -State 'Running' -Auto $false -Land 'Off'
$x = Invoke-Restore
$cold = "VM 'vm-test' was not Running after restoring 'clean-base' $([char]0x2014) the checkpoint is not a warm memory-state one, so every run pays a full boot. Re-take it with the VM running at a logged-in desktop (Standard checkpoint type) to restore warm-revert speed."
if (-not $x.Threw -and $x.Warnings.Count -eq 1 -and $x.Warnings[0] -ceq $cold -and $x.Log[-1] -eq 'start:auto=False') { Ok 'one warning, word for word the session open''s cold-checkpoint text, then Start-VM' } else { Bad "cold: warnings=$($x.Warnings -join ' | ') log=$($x.Log -join ' > ')" }
if ($x.R.Landed -ceq 'Off' -and $x.R.Started -eq $true -and $x.R.Mode -ceq 'TurnOffFirst') { Ok 'Landed Off although the helper started the VM; Started $true' } else { Bad "cold result: $($x.R | ConvertTo-Json -Compress)" }
if (-not (& $one $x)) { $shapeOk = $false }

# -- (h) the precondition fails: the Legacy restore and one warning ----------------------------------------------------
Write-Host '(h) a checkpoint taken with automatic checkpoints on (or unknown): the Legacy restore and one warning per process' -ForegroundColor Cyan
Reset-Model -State 'Running' -Auto $true -Land 'Saved'
$script:landRunningWhenRunning = $true
$x = Invoke-Restore
$wantH = "get-vm > get-cp:vm-test:clean-base > auto:$cpId > restore:vm-test:clean-base > get-vm"
if (-not $x.Threw -and ($x.Log -join ' > ') -eq $wantH) { Ok "Legacy: $wantH (no Stop-VM, no Start-VM)" } else { Bad "legacy sequence: $($x.Log -join ' > ')" }
if ($x.Warnings.Count -eq 1 -and $x.Warnings[0] -like "The test VM's checkpoint 'clean-base' was taken with automatic checkpoints on. Turn them off (Set-VM -Name 'vm-test' -AutomaticCheckpointsEnabled `$false) and re-take the checkpoint (docs/hyperv-vm.md). Until then every restore keeps the slower path that saves the running VM first.") {
    Ok 'exactly one warning: the PR 1 text plus "until then every restore keeps the slower path"'
} else { Bad "warnings: $($x.Warnings -join ' | ')" }
if ($x.R.Mode -ceq 'Legacy' -and $x.R.Landed -ceq 'Running' -and $x.R.Started -eq $false -and $null -eq $x.R.TurnOffSeconds -and $null -eq $x.R.StartSeconds) { Ok 'Mode Legacy, Landed Running, Started $false' } else { Bad "legacy result: $($x.R | ConvertTo-Json -Compress)" }
if (-not (& $one $x)) { $shapeOk = $false }
$script:log.Clear()
$x2 = Invoke-Restore
if ($x2.Warnings.Count -eq 0 -and $x2.R.Mode -ceq 'Legacy') { Ok 'a second restore in the same process: Legacy again, no second warning' } else { Bad "second: warnings=$($x2.Warnings -join ' | ')" }
$w = $null
Write-Win32ToolkitCheckpointAdvisory -Kind AutoCheckpoints -Key "$vmId|$cpId" -Message 'the provider''s advisory' -WarningVariable w 3>$null
if (@($w).Count -eq 0) { Ok 'the key is "<VM Id>|<checkpoint Id>": the provider''s own AutoCheckpoints advisory for this checkpoint stays silent (one warning in all)' } else { Bad "provider advisory printed: $w" }
foreach ($case in @(
        @{ Tag = 'the checkpoint''s setting cannot be read ($null)'; Set = { $script:autoAnswer = $null } }
        @{ Tag = 'two checkpoints answer to the name'; Set = { $script:cpCount = 2 } })) {
    Reset-Model -State 'Running' -Auto $false -Land 'Saved'
    $script:landRunningWhenRunning = $true
    & $case.Set
    $x = Invoke-Restore
    if (-not $x.Threw -and $x.R.Mode -ceq 'Legacy' -and @($x.Log | Where-Object { $_ -like 'stop:*' -or $_ -like 'start:*' }).Count -eq 0 -and $x.Warnings.Count -eq 1 -and $x.Warnings[0] -like '*could not be read*slower path*') {
        Ok "$($case.Tag): Legacy, no turn-off or start, one warning"
    } else { Bad "$($case.Tag): log=$($x.Log -join ' > ') warnings=$($x.Warnings -join ' | ')" }
    if (-not (& $one $x)) { $shapeOk = $false }
}

# -- (h2) the VM reads automatic checkpoints on after the restore -----------------------------------------------------
Write-Host '(h2) checkpoint off, but the VM reads AutomaticCheckpointsEnabled True after the restore: Set-VM before Start-VM (A-9)' -ForegroundColor Cyan
Reset-Model -State 'Running' -Auto $false -Land 'Saved' -LandAuto $true
$x = Invoke-Restore
$iSet = [array]::IndexOf($x.Log, 'set-vm:vm-test:auto=False'); $iStart = [array]::IndexOf($x.Log, 'start:auto=False')
if (-not $x.Threw -and $iSet -ge 0 -and $iStart -gt $iSet -and @($x.Log | Where-Object { $_ -like 'start:auto=True' }).Count -eq 0) { Ok 'Set-VM -AutomaticCheckpointsEnabled $false on the VM, then Start-VM: never a start with them on' } else { Bad "a-9: $($x.Log -join ' > ')" }
if ($x.Warnings.Count -eq 1 -and $x.Warnings[0] -like "The test VM 'vm-test' had automatic checkpoints on after restoring 'clean-base'*turned off on the VM before it was started.") { Ok 'one warning' } else { Bad "a-9 warnings: $($x.Warnings -join ' | ')" }
if ($x.R.Mode -ceq 'TurnOffFirst' -and $x.R.Started) { Ok 'still TurnOffFirst, started' } else { Bad "a-9 result: $($x.R | ConvertTo-Json -Compress)" }
if (-not (& $one $x)) { $shapeOk = $false }
Reset-Model -State 'Running' -Auto $false -Land 'Saved' -LandAuto $true
$x = Invoke-Restore -Splat @{ NoStart = $true }
if (@($x.Log | Where-Object { $_ -eq 'set-vm:vm-test:auto=False' }).Count -eq 1 -and @($x.Log | Where-Object { $_ -like 'start:*' }).Count -eq 0) { Ok 'with -NoStart the setting is still turned off' } else { Bad "a-9 nostart: $($x.Log -join ' > ')" }

# -- (i) HyperVRevertMode ----------------------------------------------------------------------------------------------
Write-Host '(i) HyperVRevertMode: Legacy = one Restore-VMCheckpoint; invalid -> TurnOffFirst + one verbose line' -ForegroundColor Cyan
foreach ($value in 'Legacy', 'legacy', ' LEGACY ') {
    Reset-Model -State 'Running' -Auto $false -Land 'Saved'
    $script:landRunningWhenRunning = $true
    $script:cfg = @{ HyperVRevertMode = $value }
    $x = Invoke-Restore
    if (-not $x.Threw -and ($x.Log -join ' > ') -eq 'get-vm > restore:vm-test:clean-base > get-vm' -and $x.R.Mode -ceq 'Legacy' -and $x.R.Landed -ceq 'Running' -and -not $x.R.Started -and $x.Warnings.Count -eq 0) {
        Ok "HyperVRevertMode '$value': one Restore-VMCheckpoint (and the state reads before and after), no checkpoint or setting read, no turn-off, no start, no warning"
    } else { Bad "'$value': log=$($x.Log -join ' > ') result=$($x.R | ConvertTo-Json -Compress)" }
    if (-not (& $one $x)) { $shapeOk = $false }
}
Reset-Model -State 'Running' -Auto $false -Land 'Saved'
$script:landRunningWhenRunning = $true
$x = Invoke-Restore -Splat @{ Mode = 'Legacy' }
if (($x.Log -join ' > ') -eq 'get-vm > restore:vm-test:clean-base > get-vm' -and $x.R.Mode -ceq 'Legacy') { Ok '-Mode Legacy wins over the (absent) setting' } else { Bad "-Mode Legacy: $($x.Log -join ' > ')" }
Reset-Model -State 'Running' -Auto $false -Land 'Saved'
$script:cfg = @{ HyperVRevertMode = 'Legacy' }
$x = Invoke-Restore -Splat @{ Mode = 'TurnOffFirst' }
if ($x.R.Mode -ceq 'TurnOffFirst' -and @($x.Log | Where-Object { $_ -like 'stop:*' }).Count -eq 1) { Ok '-Mode TurnOffFirst wins over HyperVRevertMode Legacy' } else { Bad "-Mode TurnOffFirst: $($x.Log -join ' > ')" }
foreach ($case in @(
        @{ Value = 'Fast'; Line = 1 }
        @{ Value = 'TurnOffFirst'; Line = 0 }
        @{ Value = 'turnofffirst'; Line = 0 }
        @{ Value = '   '; Line = 0 }
        @{ Value = $null; Line = 0 })) {
    Reset-Model -State 'Running' -Auto $false -Land 'Saved'
    if ($null -ne $case.Value) { $script:cfg = @{ HyperVRevertMode = $case.Value } }
    $x = Invoke-Restore
    $lines = @($x.Verbose | Where-Object { $_ -like 'HyperVRevertMode*neither TurnOffFirst nor Legacy*' })
    if (-not $x.Threw -and $x.R.Mode -ceq 'TurnOffFirst' -and @($x.Log | Where-Object { $_ -like 'stop:*' }).Count -eq 1 -and $lines.Count -eq $case.Line) {
        Ok "HyperVRevertMode $(if ($null -eq $case.Value) { 'absent' } else { "'$($case.Value)'" }): TurnOffFirst, $($case.Line) verbose line(s) about the value"
    } else { Bad "value '$($case.Value)': mode=$($x.R.Mode) lines=$($lines.Count) verbose=$($x.Verbose -join ' | ')" }
}

# -- (i2) -NoStart -----------------------------------------------------------------------------------------------------
Write-Host '(i2) -NoStart leaves the VM as it landed' -ForegroundColor Cyan
foreach ($land in 'Saved', 'Off') {
    Reset-Model -State 'Running' -Auto $false -Land $land
    $x = Invoke-Restore -Splat @{ NoStart = $true }
    if (-not $x.Threw -and @($x.Log | Where-Object { $_ -like 'start:*' }).Count -eq 0 -and $x.R.Landed -ceq $land -and $x.R.Started -eq $false -and $null -eq $x.R.StartSeconds -and $x.Warnings.Count -eq 0) {
        Ok "landed ${land}: no Start-VM, no warning, Started `$false"
    } else { Bad "nostart ${land}: $($x.Log -join ' > ') warnings=$($x.Warnings -join ' | ')" }
    if (-not (& $one $x)) { $shapeOk = $false }
}

# -- (x) a failing step ------------------------------------------------------------------------------------------------
Write-Host '(x) a failing step: the helper throws the cmdlet''s error and stops there' -ForegroundColor Cyan
foreach ($case in @(
        @{ At = 'get-cp'; Msg = 'unable to find a checkpoint'; NotAfter = 'restore:*' }
        @{ At = 'stop'; Msg = 'could not be turned off'; NotAfter = 'restore:*' }
        @{ At = 'restore'; Msg = 'could not be applied'; NotAfter = 'start:*' }
        @{ At = 'set-vm'; Msg = 'could not be changed'; NotAfter = 'start:*'; LandAuto = $true }
        @{ At = 'start'; Msg = 'could not be started'; NotAfter = '' })) {
    Reset-Model -State 'Running' -Auto $false -Land 'Saved' -LandAuto ([bool]$case.LandAuto)
    $script:failAt = $case.At
    $x = Invoke-Restore
    $after = if ($case.NotAfter) { @($x.Log | Where-Object { $_ -like $case.NotAfter }).Count } else { 0 }
    if ($x.Threw -and "$($x.Threw)" -like "*$($case.Msg)*" -and $x.Threw.FullyQualifiedErrorId -notlike 'W32T.*' -and $after -eq 0 -and $x.Out.Count -eq 0) {
        Ok "$($case.At) fails: the helper throws '$($case.Msg)' (not a W32T error), nothing after it runs, no output"
    } else { Bad "$($case.At): threw=$($x.Threw) log=$($x.Log -join ' > ') out=$($x.Out.Count)" }
}
Reset-Model -State 'Running' -Auto $false -Land 'Saved'
$script:cfg = @{ HyperVRevertMode = 'Legacy' }; $script:landRunningWhenRunning = $true
$script:failAt = 'get-vm-after'
$x = Invoke-Restore
if (-not $x.Threw -and $x.R.Mode -ceq 'Legacy' -and $null -eq $x.R.Landed -and @($x.Log | Where-Object { $_ -like 'restore:*' }).Count -eq 1) { Ok 'Legacy: the state read after a successful restore fails -> Landed $null, no throw (the restore counts)' } else { Bad "legacy get-vm: threw=$($x.Threw) $($x.R | ConvertTo-Json -Compress)" }

# -- (v) one verbose line per step -------------------------------------------------------------------------------------
Write-Host '(v) one verbose line per step with its seconds' -ForegroundColor Cyan
Reset-Model -State 'Running' -Auto $false -Land 'Saved'
$x = Invoke-Restore
$steps = @(
    @($x.Verbose | Where-Object { $_ -match "^'vm-test': turned off \(Running\) in \d+(\.\d)? s\.$" }).Count
    @($x.Verbose | Where-Object { $_ -match "^'vm-test': restored 'clean-base' \(TurnOffFirst\) in \d+(\.\d)? s; the VM landed Saved\.$" }).Count
    @($x.Verbose | Where-Object { $_ -match "^'vm-test': started \(resumed from Saved\) in \d+(\.\d)? s\.$" }).Count)
if (($steps -join ',') -eq '1,1,1') { Ok 'turn-off, restore and start each print one verbose line with the seconds' } else { Bad "verbose: $($x.Verbose -join ' | ')" }

# -- (r) output shape; Reset -------------------------------------------------------------------------------------------
Write-Host '(r) exactly one object from the helper; Reset-Win32ToolkitTestVM emits nothing' -ForegroundColor Cyan
if ($shapeOk) { Ok 'every case above: exactly one object with Mode, Landed, TurnOffSeconds, RestoreSeconds, StartSeconds, Started (the doubles'' objects never leak)' } else { Bad 'a case returned another shape (see above)' }
foreach ($case in @(
        @{ Tag = 'TurnOffFirst'; Auto = $false; Want = 'TurnOffFirst' }
        @{ Tag = 'the Legacy fallback with its warning'; Auto = $true; Want = 'Legacy' })) {
    Reset-Model -State 'Running' -Auto $case.Auto -Land 'Saved'
    $script:landRunningWhenRunning = $true
    $w = $null
    $o = @(Reset-Win32ToolkitTestVM -Name 'vm-test' -CheckpointName 'clean-base' -Confirm:$false -WarningVariable w 3>$null)
    $iClear = [array]::IndexOf($script:log, 'clear'); $iCp = [array]::IndexOf($script:log, 'get-cp:vm-test:clean-base')
    $restores = @($script:log | Where-Object { $_ -like 'restore:*' }).Count
    $warnOk = if ($case.Auto) { @($w).Count -eq 1 } else { @($w).Count -eq 0 }
    $startOk = if ($case.Auto) { @($script:log | Where-Object { $_ -like 'start:*' }).Count -eq 0 } else { $script:log[-1] -eq 'start:auto=False' }
    if ($o.Count -eq 0 -and $iClear -eq 0 -and $iCp -gt $iClear -and $restores -eq 1 -and $warnOk -and $startOk) {
        Ok "Reset ($($case.Tag)): emits nothing; the cache clear first, then the helper once$(if ($case.Auto) { ' (one warning)' } else { ' (turn off, restore, start)' })"
    } else { Bad "Reset ($($case.Tag)): out=$($o.Count) warnings=$(@($w).Count) log=$($script:log -join ' > ')" }
}
Reset-Model -State 'Running' -Auto $false -Land 'Saved'
$o = @(Reset-Win32ToolkitTestVM -Name 'vm-test' -WhatIf 6>$null)
if ($o.Count -eq 0 -and $script:log.Count -eq 0) { Ok 'Reset -WhatIf: no cache clear, no restore' } else { Bad "whatif: $($script:log -join ' > ')" }

# -- (s) speed-up PR 3: a VM in the middle of a state change is waited for first ----------------------------------------
Write-Host '(s) (PR 3) a transitional VM state is waited for (2 s polls, at most 120 s) before the restore' -ForegroundColor Cyan
$script:sleeps = [System.Collections.Generic.List[double]]::new()
function Start-Sleep { param($Seconds, $Milliseconds) $script:sleeps.Add([double]$Seconds) }
try {
    # Saving twice, then Running: two 2 s waits, then the usual TurnOffFirst sequence.
    Reset-Model -State 'Running' -Auto $false -Land 'Saved'
    foreach ($s in 'Saving', 'Saving') { $script:stateQueue.Enqueue($s) }
    $script:sleeps.Clear()
    $x = Invoke-Restore
    $wantS = "get-vm > get-vm > get-vm > get-cp:vm-test:clean-base > auto:$cpId > get-vm > stop:turnoff=True:force=True > restore:vm-test:clean-base > get-vm > start:auto=False"
    if (-not $x.Threw -and ($x.Log -join ' > ') -eq $wantS -and ($script:sleeps -join ',') -eq '2,2' -and $x.R.Mode -ceq 'TurnOffFirst' -and
        @($x.Verbose | Where-Object { $_ -ceq "'vm-test' is Saving; waiting for it to settle before the restore..." }).Count -eq 1) {
        Ok 'Saving, Saving, Running: two 2 s waits (one verbose line), then turn off, restore, start'
    } else { Bad "saving: log=$($x.Log -join ' > ') sleeps=$($script:sleeps -join ',') verbose=$($x.Verbose -join ' | ')" }
    if (& $one $x) { Ok 'still exactly one object' } else { Bad "shape: $($x.Out.Count)" }
    # Every transitional state, and a *Critical one, waits; settled states do not.
    foreach ($case in @(
            @{ State = 'Starting'; Waits = 1 }, @{ State = 'Stopping'; Waits = 1 }, @{ State = 'Pausing'; Waits = 1 }, @{ State = 'Resuming'; Waits = 1 }
            @{ State = 'Reset'; Waits = 1 }, @{ State = 'FastSaving'; Waits = 1 }, @{ State = 'RunningCritical'; Waits = 1 }, @{ State = 'SavingCritical'; Waits = 1 }
            @{ State = 'Running'; Waits = 0 }, @{ State = 'Off'; Waits = 0 }, @{ State = 'Saved'; Waits = 0 }, @{ State = 'Paused'; Waits = 0 })) {
        Reset-Model -State 'Running' -Auto $false -Land 'Saved'
        $script:stateQueue.Enqueue($case.State)
        $script:sleeps.Clear()
        $x = Invoke-Restore
        if (-not $x.Threw -and $script:sleeps.Count -eq $case.Waits -and $x.R.Started) { Ok "$($case.State): $($case.Waits) wait(s)" } else { Bad "$($case.State): sleeps=$($script:sleeps.Count) threw=$($x.Threw)" }
    }
    # Never settles: 60 polls of 2 s (the 120 s ceiling), one verbose line, then the restore goes on.
    Reset-Model -State 'Saving' -Auto $false -Land 'Saved'
    $script:sleeps.Clear()
    $x = Invoke-Restore
    if ($script:sleeps.Count -eq 60 -and @($script:sleeps | Where-Object { $_ -ne 2 }).Count -eq 0 -and @($x.Log | Where-Object { $_ -like 'restore:*' }).Count -eq 1 -and
        @($x.Verbose | Where-Object { $_ -like "'vm-test' is still Saving after * s; restoring anyway." }).Count -eq 1) {
        Ok 'a state that never settles: 60 polls of 2 s (the ceiling), one verbose line, then the restore runs and the cmdlets report'
    } else { Bad "never settles: sleeps=$($script:sleeps.Count) log=$($x.Log -join ' > ') verbose=$($x.Verbose -join ' | ')" }
    # The Legacy restore waits too.
    Reset-Model -State 'Running' -Auto $false -Land 'Saved'
    $script:landRunningWhenRunning = $true
    $script:cfg = @{ HyperVRevertMode = 'Legacy' }
    $script:stateQueue.Enqueue('Stopping')
    $script:sleeps.Clear()
    $x = Invoke-Restore
    if (-not $x.Threw -and ($x.Log -join ' > ') -eq 'get-vm > get-vm > restore:vm-test:clean-base > get-vm' -and $script:sleeps.Count -eq 1 -and $x.R.Mode -ceq 'Legacy') { Ok 'Legacy: waits for Stopping, then the one restore' } else { Bad "legacy wait: log=$($x.Log -join ' > ') sleeps=$($script:sleeps.Count)" }
    # A VM that cannot be read before the restore: no wait (fail-open), the steps go on.
    Reset-Model -State 'Running' -Auto $false -Land 'Saved'
    $script:getVmFailFirst = $true
    $script:sleeps.Clear()
    $x = Invoke-Restore
    if (-not $x.Threw -and $script:sleeps.Count -eq 0 -and $x.R.Mode -ceq 'TurnOffFirst' -and $x.R.Started -and @($x.Verbose | Where-Object { $_ -like '*the VM state could not be read before the restore*' }).Count -eq 1) {
        Ok 'the first state read fails: one verbose line, no wait, the restore goes on'
    } else { Bad "read fails: threw=$($x.Threw) sleeps=$($script:sleeps.Count) verbose=$($x.Verbose -join ' | ')" }
}
finally { Remove-Item Function:\Start-Sleep }

# -- (t) speed-up PR 3: Reset holds the VM's lease ---------------------------------------------------------------------
Write-Host '(t) (PR 3) Reset-Win32ToolkitTestVM holds the VM''s lease around the cache clear and the restore; a timeout changes nothing' -ForegroundColor Cyan
Reset-Model -State 'Running' -Auto $false -Land 'Saved'
$script:leaseLog.Clear()
$o = @(Reset-Win32ToolkitTestVM -Name 'vm-test' -CheckpointName 'clean-base' -Confirm:$false 3>$null)
$nLog = $script:log.Count
if ($o.Count -eq 0 -and ($script:leaseLog -join ' > ') -eq "enter:vm-test:reset:log=0 > exit:same=True:log=$nLog" -and $script:log[0] -eq 'clear' -and @($script:log | Where-Object { $_ -like 'restore:*' }).Count -eq 1) {
    Ok 'the lease before the cache clear, released after the restore (the same lease); Reset still emits nothing'
} else { Bad "reset lease: out=$($o.Count) lease=$($script:leaseLog -join ' > ') log=$($script:log -join ' > ')" }
Reset-Model -State 'Running' -Auto $false -Land 'Saved'
$script:leaseLog.Clear(); $script:leaseThrows = $true
$threwT = $null
try { $null = Reset-Win32ToolkitTestVM -Name 'vm-test' -Confirm:$false 3>$null } catch { $threwT = $_ }
$script:leaseThrows = $false
if ($threwT -and $threwT.FullyQualifiedErrorId -eq 'W32T.HyperVLeaseTimeout' -and $script:log.Count -eq 0 -and @($script:leaseLog | Where-Object { $_ -like 'exit:*' }).Count -eq 0) {
    Ok 'a lease timeout: Reset throws W32T.HyperVLeaseTimeout, no cache clear, no restore'
} else { Bad "reset timeout: threw=$($threwT.FullyQualifiedErrorId) log=$($script:log -join ' > ') lease=$($script:leaseLog -join ' > ')" }
Reset-Model -State 'Running' -Auto $false -Land 'Saved'
$script:leaseLog.Clear()
$null = @(Reset-Win32ToolkitTestVM -Name 'vm-test' -WhatIf 6>$null)
if ($script:leaseLog.Count -eq 0) { Ok 'Reset -WhatIf takes no lease' } else { Bad "whatif lease: $($script:leaseLog -join ' > ')" }
# Speed-up PR 3 (D11): without -Name / -CheckpointName, Reset restores the session's pinned VM and checkpoint.
Reset-Model -State 'Running' -Auto $false -Land 'Saved'
$script:leaseLog.Clear()
$script:cfg = @{ HyperVVMName = 'lab-vm'; HyperVCheckpoint = 'warm-x' }
try {
    $env:W32T_HYPERV_VM = 'vm-test'; $env:W32T_HYPERV_CHECKPOINT = 'clean-base'
    $null = Reset-Win32ToolkitTestVM -Confirm:$false 3>$null
}
finally { Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue }
if (($script:log -contains 'restore:vm-test:clean-base') -and ($script:leaseLog[0] -like 'enter:vm-test:reset:*')) { Ok 'no -Name: the pinned VM and checkpoint (W32T_HYPERV_VM / W32T_HYPERV_CHECKPOINT), not the registry''s' } else { Bad "pinned default: $($script:log -join ' > ') / $($script:leaseLog -join ' > ')" }
$script:cfg = @{}

# -- (y) file hygiene --------------------------------------------------------------------------------------------------
Write-Host '(y) file hygiene: ASCII, one function, every catch starts with the C-2 line' -ForegroundColor Cyan
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
$file = Join-Path $repo 'Private\Restore-Win32ToolkitTestVMCheckpoint.ps1'
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
$catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
$badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
$ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
$top = @($ast.EndBlock.Statements)
$oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq 'Restore-Win32ToolkitTestVMCheckpoint' -and -not $ast.ParamBlock
if (@($errs).Count -eq 0 -and $catches.Count -ge 1 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "ASCII, one function, $($catches.Count) catch(es) with the C-2 line" } else { Bad "errors $(@($errs).Count), catches $($catches.Count), bad $($badCatch.Count), ascii $ascii, one function $oneFunction" }

# Safety net (speed-up PR 3): no real Hyper-V cmdlet was reached (it would have imported the Hyper-V module, whose aliases
# Get-VMCheckpoint / Remove-VMCheckpoint then win over the shadows above).
if (-not (Microsoft.PowerShell.Core\Get-Module -Name Hyper-V)) { Ok 'the Hyper-V module was never imported (no real Hyper-V cmdlet reached)' } else { Bad 'the Hyper-V module was imported: a real Hyper-V cmdlet was reached' }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All HyperVRevertMode tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail HyperVRevertMode test(s) FAILED." -ForegroundColor Red; exit 1 }
