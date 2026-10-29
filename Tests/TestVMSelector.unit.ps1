<#
    Menu selectors: the test VM screen (knowledge-base/designs/menu-selectors.md section 4, V1-V11, D6-D10).

      [1] Get-Win32ToolkitHyperVLeaseState against a real temp lock folder: no folder / no file / a closed file = Free;
          a file held open for writing = InUse with the holder's diagnostics (only for a running process with the
          recorded start time); this process's hold = ThisWindow; a junction folder, a hard-linked file or a foreign
          owner = Unknown; a bad Id = Unknown; the file's bytes are unchanged, nothing is created, no $Error record left.
      [2] Get-Win32ToolkitTestVMChoice: not elevated / no Hyper-V / Get-VM failing = a Problem; duplicate names, names
          with a wildcard character, VMs without a clean checkpoint are listed and not offered; '+deps-', Recovery and
          duplicate-name checkpoints are not offered; an automatic checkpoint is marked; newest first.
      [3] Set-Win32ToolkitHyperVTarget: both values with -ErrorAction Stop, read back, the clean marker cleared; -Default
          clears both; refusals (wildcard, deps checkpoint, missing or duplicate VM, missing checkpoint, a lease this
          process still holds) write nothing; a pending background restore is joined first and a pre-warm released;
          the environment pins are never touched.
      [4] Show-Win32ToolkitTestVMSelect, driven: the V7 question names the data loss (default No for another VM, Yes
          for win32tk-golden and the current VM), No saves nothing, the lane warning (V2), the VM-only-pin note (V4),
          the backend and guest-account notes (V8, V9), not elevated (V10), a pin in this window (V4).
      [5] Show-Win32ToolkitTestVM (D10): Provision checks AND builds the session's VM (-Name / -CheckpointName, the VHDX
          of that name) and its rebuild question names it; Resources, Reset, AutoLogon and Remove pass the VM by name and
          ask with its name; an invalid pin passes nothing; 'Choose the test VM and checkpoint' opens the selector.
      [6] Never a VM-changing call or a lease or a guest-credential read from the selector (calls recorded across [2]-[4]);
          file hygiene of the new files.

    No Hyper-V cmdlet runs for real: every one is shadowed. The environment pins are removed and restored; HKCU is shadowed.

    Run:  pwsh -File Tests\TestVMSelector.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'ConvertTo-Win32ToolkitSafeText', 'Get-Win32ToolkitHyperVTarget', 'Initialize-Win32ToolkitLeaseFileType', 'Get-Win32ToolkitHyperVLeaseState',
    'Get-Win32ToolkitTestVMChoice', 'Set-Win32ToolkitHyperVTarget', 'Show-Win32ToolkitTestVMSelect', 'Show-Win32ToolkitTestVM') {
    . (Join-Path $repo "Private\$f.ps1")
}
$savedVmPin = $env:W32T_HYPERV_VM; $savedCpPin = $env:W32T_HYPERV_CHECKPOINT
Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue

# -- Shadows: HKCU, Hyper-V (recorded), the toolkit helpers the screens call -------------------------------------------
$script:cfg = @{}
$script:writes = [System.Collections.Generic.List[object]]::new()
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$script:cfg[$Name])) { [string]$script:cfg[$Name] } else { $Default } }
function Set-Win32ToolkitConfigValue {
    [CmdletBinding()] param($Name, $Value)
    $script:writes.Add([pscustomobject]@{ Name = $Name; Value = $Value; ErrorAction = [string]$PSBoundParameters['ErrorAction'] })
    $script:cfg[$Name] = $Value
}
$script:elevated = $true
function Test-Win32ToolkitElevated { $script:elevated }
$script:hyperVModule = $true
function Get-Module { param([Parameter(Position = 0)]$Name, [switch]$ListAvailable) if ($script:hyperVModule -and "$Name" -eq 'Hyper-V') { [pscustomobject]@{ Name = 'Hyper-V' } } }
$script:vms = @()
$script:getVmThrows = $false
function Get-VM {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name)
    if ($script:getVmThrows) { throw 'You do not have the required permission to complete this task.' }
    if ($PSBoundParameters.ContainsKey('Name')) {
        $hit = @($script:vms | Where-Object { $_.Name -eq $Name[0] })
        if ($hit.Count -eq 0) { throw "Hyper-V was unable to find a virtual machine with name `"$($Name[0])`"." }
        return $hit
    }
    $script:vms
}
$script:cps = @{}
function Get-VMCheckpoint {
    [CmdletBinding()] param($VM, $VMName, $Name)
    $key = if ($VM) { [string]$VM.Id } else { (@($script:vms | Where-Object Name -eq $VMName) | Select-Object -First 1).Id }
    $all = @($script:cps[[string]$key])
    if ($PSBoundParameters.ContainsKey('Name')) { $all = @($all | Where-Object { $_.Name -eq $Name }) }
    $all
}
$script:changes = [System.Collections.Generic.List[string]]::new()
foreach ($c in 'Start-VM', 'Stop-VM', 'Save-VM', 'Restore-VMCheckpoint', 'Checkpoint-VM', 'Remove-VMCheckpoint', 'Remove-VM', 'Set-VM',
    'Set-VMProcessor', 'Set-VMMemory', 'New-PSSession', 'Invoke-Command', 'Enter-Win32ToolkitHyperVLease', 'Get-Win32ToolkitGuestCredential',
    'Test-Win32ToolkitHyperVReady') {
    Set-Item -Path "function:script:$c" -Value ([scriptblock]::Create("`$script:changes.Add('$c'); @()"))
}
$script:markerCalls = [System.Collections.Generic.List[string]]::new()
function Clear-Win32ToolkitHyperVStateCache { param([switch]$MarkerOnly) $script:markerCalls.Add($(if ($MarkerOnly) { 'MarkerOnly' } else { 'All' })) }
$script:joins = [System.Collections.Generic.List[string]]::new()
function Wait-Win32ToolkitHyperVTeardown {
    param([string]$VMName, [switch]$Prewarm)
    if ($Prewarm) { $script:joins.Add('Prewarm'); $script:HyperVPrewarmLease = $null }
    else { $script:joins.Add("Join:$VMName"); $script:HyperVPendingRestore = $null }
}
function New-Cp { param($Name, $Type = 'Standard', [datetime]$At, [bool]$Auto = $false) [pscustomobject]@{ Name = $Name; SnapshotType = $Type; CreationTime = $At; IsAutomaticCheckpoint = $Auto } }

# -- Spectre shadows ------------------------------------------------------------------------------------------------------
$script:hostLines = [System.Collections.Generic.List[string]]::new()
$script:panels = [System.Collections.Generic.List[string]]::new()
$script:prompts = [System.Collections.Generic.List[object]]::new()
$script:picks = [System.Collections.Queue]::new()
$script:confirms = [System.Collections.Queue]::new()
$script:texts = [System.Collections.Queue]::new()
$script:confirmTexts = [System.Collections.Generic.List[string]]::new()
$script:tables = [System.Collections.Generic.List[object]]::new()
function Clear-Host { }
function Write-SpectreRule { param([Parameter(ValueFromRemainingArguments)]$a) }
function Write-SpectreHost { param([Parameter(Position = 0)]$Message) $script:hostLines.Add([string]$Message) }
function Format-SpectrePanel { param($Data, $Header, $Border, $Color) $script:panels.Add("$Header|$Data") }
function Format-SpectreTable { param([Parameter(ValueFromPipeline)]$InputObject, [Parameter(ValueFromRemainingArguments)]$a) process { $script:tables.Add($InputObject) } }
function Out-SpectreHost { param([Parameter(ValueFromPipeline)]$Data) process { } }
function Get-SpectreEscapedText { param($Text) $Text }
function Read-SpectrePause { param([Parameter(ValueFromRemainingArguments)]$a) }
function Read-SpectreText { param($Message, $DefaultAnswer) if ($script:texts.Count -eq 0) { throw "unexpected text prompt: $Message" }; [string]$script:texts.Dequeue() }
function Read-SpectreConfirm {
    param($Message, $DefaultAnswer)
    $script:confirmTexts.Add("$Message|$DefaultAnswer")
    if ($script:confirms.Count -eq 0) { throw "unexpected question: $Message" }
    [bool]$script:confirms.Dequeue()
}
function Read-SpectreSelection {
    param($Message, $Choices, $ChoiceLabelProperty, $Color, $PageSize)
    $script:prompts.Add([pscustomobject]@{ Message = $Message; Labels = @($Choices | ForEach-Object { $_.Label }) })
    if ($script:picks.Count -eq 0) { throw "unexpected menu: $Message" }
    $want = [string]$script:picks.Dequeue()
    $hit = @($Choices | Where-Object { $_.Label -like $want }) | Select-Object -First 1
    if (-not $hit) { throw "no choice like '$want' in: $(@($Choices | ForEach-Object { $_.Label }) -join ' | ')" }
    $hit
}
function Drive { param([scriptblock]$Screen, [string[]]$Picks, [bool[]]$Confirms = @(), [string[]]$Texts = @())
    $script:hostLines.Clear(); $script:panels.Clear(); $script:prompts.Clear(); $script:picks.Clear(); $script:confirms.Clear()
    $script:texts.Clear(); $script:confirmTexts.Clear(); $script:tables.Clear()
    foreach ($p in $Picks) { $script:picks.Enqueue($p) }
    foreach ($c in $Confirms) { $script:confirms.Enqueue($c) }
    foreach ($t in $Texts) { $script:texts.Enqueue($t) }
    $err = $null
    try { & $Screen } catch { $err = $_ }
    [pscustomobject]@{ Error = $err; PicksLeft = $script:picks.Count; ConfirmsLeft = $script:confirms.Count }
}

# -- A temp lock folder the probe trusts (a session that is not elevated owns its temp folders) ----------------------------
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Owner.Value
$trustSids = @($me, 'S-1-5-32-544', 'S-1-5-18')
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('w32vsel_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$null = New-Item -ItemType Directory -Path $work -Force
$lockRoot = Join-Path $work 'base\locks'
$probe = { param([string]$Id, [string]$Root = $lockRoot, [string[]]$Trust = $trustSids) Get-Win32ToolkitHyperVLeaseState -VMId $Id -LockRoot $Root -TrustedOwnerSid $Trust }
$diag = { param([int]$ProcessId, [string]$Purpose)
    $start = [System.Diagnostics.Process]::GetProcessById($ProcessId).StartTime.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    "w32t-lease v1`nepoch=11111111-2222-3333-4444-555555555555`ngeneration=7`npid=$ProcessId`nprocessStartUtc=$start`npurpose=$Purpose`nacquiredUtc=2026-10-29T14:02:00.0000000Z`n"
}
# Holds a lock file the way a lease holder does: read+write, shared for reading only.
$hold = { param([string]$Path, [string]$Text)
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    $b = [System.Text.Encoding]::UTF8.GetBytes($Text); $fs.SetLength(0); $fs.Write($b, 0, $b.Length); $fs.Flush($true)
    $fs
}
$idA = 'aaaaaaaa-1111-2222-3333-444444444444'
$idB = 'bbbbbbbb-1111-2222-3333-444444444444'
$idC = 'cccccccc-1111-2222-3333-444444444444'
$golden = [pscustomobject]@{ Name = 'win32tk-golden'; Id = [guid]$idA; State = 'Off' }
$devbox = [pscustomobject]@{ Name = 'dev-box'; Id = [guid]$idB; State = 'Running' }
$measure = [pscustomobject]@{ Name = 'win32tk-measure'; Id = [guid]$idC; State = 'Running' }
$t0 = [datetime]::new(2026, 10, 20, 12, 0, 0, [System.DateTimeKind]::Utc)
$held = $null

try {
    # ============================== [1] the lease probe ==============================
    Write-Host '[1] Get-Win32ToolkitHyperVLeaseState: read-only, the lease''s own checks' -ForegroundColor Cyan
    $x = & $probe $idA
    if ($x.State -eq 'Free' -and -not (Test-Path -LiteralPath (Split-Path -Parent $lockRoot))) { Ok 'no lock folder: Free, and nothing was created' } else { Bad "no folder: $($x.State)" }
    $null = New-Item -ItemType Directory -Path $lockRoot -Force
    $x = & $probe $idA
    if ($x.State -eq 'Free' -and @(Get-ChildItem -LiteralPath $lockRoot -Force).Count -eq 0) { Ok 'no lock file: Free, and no file was created' } else { Bad "no file: $($x.State)" }
    $fileA = Join-Path $lockRoot "hyperv-$idA.lock"
    [System.IO.File]::WriteAllText($fileA, (& $diag $PID 'test run'))
    $before = [System.IO.File]::ReadAllBytes($fileA)
    $x = & $probe $idA
    if ($x.State -eq 'Free') { Ok 'a closed lock file (stale diagnostics of a running process): Free' } else { Bad "closed: $($x.State)" }

    $errBefore = $Error.Count
    $held = & $hold $fileA (& $diag $PID 'test run')
    $peekFs = [System.IO.FileStream]::new($fileA, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $before = [byte[]]::new($peekFs.Length); $null = $peekFs.Read($before, 0, $before.Length); $peekFs.Dispose()
    $x = & $probe $idA
    if ($x.State -eq 'InUse' -and $x.Purpose -eq 'test run' -and $x.ProcessId -eq $PID -and $x.SinceUtc -eq [datetime]::new(2026, 10, 29, 14, 2, 0, [System.DateTimeKind]::Utc)) { Ok "held for writing: InUse ($($x.Purpose), process $($x.ProcessId), since $($x.SinceUtc.ToString('u')))" } else { Bad "held: $($x | Out-String)" }
    if ($Error.Count -eq $errBefore) { Ok 'the probe left no record in $Error' } else { Bad "`$Error grew by $($Error.Count - $errBefore): $($Error[0])" }
    $held.Dispose(); $held = $null
    if ([System.Linq.Enumerable]::SequenceEqual([byte[]]$before, [byte[]][System.IO.File]::ReadAllBytes($fileA))) { Ok 'the lock file''s bytes (epoch, generation, diagnostics) are unchanged' } else { Bad 'the probe changed the lock file' }
    # Diagnostics of another process start time (a reused process id): InUse, but no holder named.
    $text = (& $diag $PID 'lane') -replace 'processStartUtc=[^\n]*', 'processStartUtc=2001-01-01T00:00:00.0000000Z'
    $held = & $hold $fileA $text
    $x = & $probe $idA
    if ($x.State -eq 'InUse' -and -not $x.ProcessId -and -not $x.Purpose) { Ok 'diagnostics with another start time: InUse, holder not named' } else { Bad "pid reuse: $($x | Out-String)" }
    $held.Dispose(); $held = $null
    # This process's own hold.
    $script:HyperVLeases = @{ ([System.IO.Path]::GetFullPath($lockRoot).TrimEnd('\') + "\hyperv-$idA.lock") = @{ VMName = 'win32tk-golden'; Count = 1 } }
    $x = & $probe $idA
    if ($x.State -eq 'ThisWindow') { Ok 'this process holds it: ThisWindow' } else { Bad "own hold: $($x.State)" }
    $script:HyperVLeases = $null
    # Untrusted shapes.
    $x = & $probe $idA $lockRoot @('S-1-5-18')
    if ($x.State -eq 'Unknown' -and $x.Why -match 'owner') { Ok "a foreign owner: Unknown ($($x.Why))" } else { Bad "owner: $($x.State) $($x.Why)" }
    $fileB = Join-Path $lockRoot "hyperv-$idB.lock"
    [System.IO.File]::WriteAllText($fileB, 'x')
    $null = New-Item -ItemType HardLink -Path (Join-Path $work 'second-name.lock') -Target $fileB
    $x = & $probe $idB
    if ($x.State -eq 'Unknown' -and $x.Why -match 'not one the toolkit made') { Ok 'a lock file with two names: Unknown' } else { Bad "hard link: $($x.State) $($x.Why)" }
    $junctionRoot = Join-Path $work 'j'
    $null = New-Item -ItemType Directory -Path (Join-Path $work 'target') -Force
    $null = New-Item -ItemType Directory -Path $junctionRoot -Force
    $null = New-Item -ItemType Junction -Path (Join-Path $junctionRoot 'locks') -Target (Join-Path $work 'target')
    $x = & $probe $idA (Join-Path $junctionRoot 'locks')
    if ($x.State -eq 'Unknown' -and $x.Why -match 'link') { Ok 'a lock folder that is a junction: Unknown' } else { Bad "junction: $($x.State) $($x.Why)" }
    [System.IO.Directory]::Delete((Join-Path $junctionRoot 'locks'))   # the link only, never its target
    $x = & $probe 'not-a-guid'
    if ($x.State -eq 'Unknown') { Ok 'an Id that is not a GUID: Unknown' } else { Bad "bad id: $($x.State)" }
    Remove-Item -LiteralPath $fileB, (Join-Path $work 'second-name.lock') -Force

    # From here on, every probe the module code makes looks at the temp lock folder (never the machine's): the real
    # probe under another name, called with the hidden test parameters by a double of the same name. Module code never
    # passes those parameters itself (HyperVLease.unit.ps1 [o]).
    . ([scriptblock]::Create((Get-Content -Raw (Join-Path $repo 'Private\Get-Win32ToolkitHyperVLeaseState.ps1')).Replace('function Get-Win32ToolkitHyperVLeaseState {', 'function Get-Win32ToolkitHyperVLeaseStateReal {')))
    function Get-Win32ToolkitHyperVLeaseState { param([string]$VMId) Get-Win32ToolkitHyperVLeaseStateReal -VMId $VMId -LockRoot $lockRoot -TrustedOwnerSid $trustSids }

    # ============================== [2] the VM list ==============================
    Write-Host '[2] Get-Win32ToolkitTestVMChoice: offered and not offered, read-only' -ForegroundColor Cyan
    $lab1 = [pscustomobject]@{ Name = 'lab'; Id = [guid]::NewGuid(); State = 'Off' }
    $lab2 = [pscustomobject]@{ Name = 'lab'; Id = [guid]::NewGuid(); State = 'Off' }
    $wild = [pscustomobject]@{ Name = 'lab[1]'; Id = [guid]::NewGuid(); State = 'Off' }
    $empty = [pscustomobject]@{ Name = 'empty-vm'; Id = [guid]::NewGuid(); State = 'Off' }
    $dupcp = [pscustomobject]@{ Name = 'dup-cp'; Id = [guid]::NewGuid(); State = 'Off' }
    $script:vms = @($golden, $devbox, $measure, $lab1, $lab2, $wild, $empty, $dupcp)
    $script:cps = @{
        $idA = @((New-Cp 'clean-base' -At $t0), (New-Cp 'clean-base+deps-0a1b2c3d4e5f' -At $t0.AddDays(1)))
        $idB = @((New-Cp 'before-sp' -At $t0.AddDays(2)), (New-Cp 'Automatic Checkpoint - dev-box - (10/23/2026 - 09:00:00)' -At $t0.AddDays(3) -Auto $true), (New-Cp 'backup-1' -Type 'Recovery' -At $t0.AddDays(4)))
        $idC = @((New-Cp 'clean-base' -At $t0))
        ([string]$wild.Id) = @((New-Cp 'clean-base' -At $t0))
        ([string]$dupcp.Id) = @((New-Cp 'clean-base' -At $t0), (New-Cp 'clean-base' -At $t0.AddDays(1)))
    }
    $list = Get-Win32ToolkitTestVMChoice
    $got = ($list.Rows | ForEach-Object { "$($_.Name)=$(if ($_.Offered) { 'offered' } else { "no($($_.WhyNot))" })" }) -join ' | '
    $want = 'dev-box=offered | dup-cp=no(no clean checkpoint) | empty-vm=no(no clean checkpoint) | lab=no(2 VMs have this name) | lab[1]=no(the name cannot be used (1 to 100 characters, no control or wildcard character)) | win32tk-golden=offered | win32tk-measure=offered'
    if ($list.Problem -eq '' -and $got -eq $want) { Ok "rows: $got" } else { Bad "rows: $got (Problem '$($list.Problem)')" }
    $dev = $list.Rows | Where-Object Name -eq 'dev-box'
    $cpGot = ($dev.Checkpoints | ForEach-Object { "$($_.Name.Substring(0, [Math]::Min(20, $_.Name.Length)))=$(if ($_.Offered) { 'ok' } else { 'no' })$(if ($_.Automatic) { '/auto' })" }) -join ' | '
    if ($cpGot -eq 'backup-1=no | Automatic Checkpoint=ok/auto | before-sp=ok') { Ok "dev-box checkpoints, newest first: $cpGot" } else { Bad "dev-box checkpoints: $cpGot" }
    $gold = $list.Rows | Where-Object Name -eq 'win32tk-golden'
    if (@($gold.Checkpoints | Where-Object Offered).Name -eq 'clean-base' -and ($gold.Checkpoints | Where-Object { $_.Name -like '*+deps-*' }).WhyNot -eq 'a dependency layer' -and $gold.Lease.State -eq 'Free') { Ok 'the deps layer is listed, not offered; the lease state is read' } else { Bad "golden: $($gold | ConvertTo-Json -Depth 4 -Compress)" }
    $script:elevated = $false
    if ((Get-Win32ToolkitTestVMChoice).Problem -eq 'NotElevated') { Ok 'not elevated: Problem NotElevated' } else { Bad 'not elevated' }
    $script:elevated = $true; $script:hyperVModule = $false
    if ((Get-Win32ToolkitTestVMChoice).Problem -eq 'NoHyperV') { Ok 'no Hyper-V module: Problem NoHyperV' } else { Bad 'no module' }
    $script:hyperVModule = $true; $script:getVmThrows = $true
    $p = (Get-Win32ToolkitTestVMChoice).Problem
    if ($p -match '^The VMs could not be read: You do not have the required permission') { Ok "Get-VM fails: $p" } else { Bad "get-vm fails: $p" }
    $script:getVmThrows = $false

    # ============================== [3] saving ==============================
    Write-Host '[3] Set-Win32ToolkitHyperVTarget: checked, both values, read back' -ForegroundColor Cyan
    $script:cfg = @{}; $script:writes.Clear(); $script:markerCalls.Clear()
    $r = Set-Win32ToolkitHyperVTarget -VMName 'dev-box' -CheckpointName 'before-sp'
    $w = ($script:writes | ForEach-Object { "$($_.Name)=$($_.Value)/$($_.ErrorAction)" }) -join ' | '
    if ($r.Ok -and $r.VMName -eq 'dev-box' -and $r.CheckpointName -eq 'before-sp' -and $w -eq 'HyperVVMName=dev-box/Stop | HyperVCheckpoint=before-sp/Stop' -and ($script:markerCalls -join ',') -eq 'MarkerOnly' -and $r.Target.VMName -eq 'dev-box') { Ok "saved: $w; clean marker cleared; this window now uses dev-box" } else { Bad "save: Ok=$($r.Ok) writes=$w marker=$($script:markerCalls -join ',')" }
    $script:writes.Clear()
    $r = Set-Win32ToolkitHyperVTarget -Default
    if ($r.Ok -and $r.VMName -eq '' -and $r.CheckpointName -eq '' -and $script:writes.Count -eq 2 -and $r.Target.VMName -eq 'win32tk-golden') { Ok '-Default clears both: the defaults again' } else { Bad "default: $($r | Out-String)" }
    $script:cfg = @{ HyperVVMName = 'win32tk-golden'; HyperVCheckpoint = 'clean-base' }
    foreach ($case in @(
            @{ Vm = 'lab[1]'; Cp = 'clean-base'; Tag = 'a wildcard in the VM name' }, @{ Vm = 'win32tk-golden'; Cp = 'clean-base+deps-0a1b2c3d4e5f'; Tag = 'a dependency layer' },
            @{ Vm = 'nope'; Cp = 'clean-base'; Tag = 'no such VM' }, @{ Vm = 'lab'; Cp = 'clean-base'; Tag = 'two VMs with the name' },
            @{ Vm = 'dev-box'; Cp = 'clean-base'; Tag = 'no such checkpoint' }, @{ Vm = ' dev-box'; Cp = 'before-sp'; Tag = 'a space around the name' })) {
        $script:writes.Clear(); $e = $null
        try { $null = Set-Win32ToolkitHyperVTarget -VMName $case.Vm -CheckpointName $case.Cp } catch { $e = $_ }
        if ($e -and $e.FullyQualifiedErrorId -like 'W32T.HyperVTargetRefused*' -and $script:writes.Count -eq 0 -and $script:cfg['HyperVVMName'] -eq 'win32tk-golden') { Ok "refused, nothing written: $($case.Tag)" } else { Bad "$($case.Tag): err=$e writes=$($script:writes.Count)" }
    }
    $script:HyperVLeases = @{ 'x' = @{ VMName = 'win32tk-golden'; Count = 1 } }
    $script:writes.Clear(); $e = $null
    try { $null = Set-Win32ToolkitHyperVTarget -VMName 'dev-box' -CheckpointName 'before-sp' } catch { $e = $_ }
    if ($e -and $e.FullyQualifiedErrorId -like 'W32T.HyperVTargetRefused*' -and $e.Exception.Message -match 'still using the test VM' -and $script:writes.Count -eq 0) { Ok 'a VM lease this process still holds: refused' } else { Bad "held lease: $e" }
    $script:HyperVLeases = $null
    $script:HyperVPendingRestore = @{ VMName = 'win32tk-golden'; Kind = 'Teardown' }
    $script:HyperVPrewarmLease = [pscustomobject]@{ VMName = 'win32tk-golden' }
    $script:joins.Clear()
    $r = Set-Win32ToolkitHyperVTarget -VMName 'dev-box' -CheckpointName 'before-sp' 6>$null
    if ($r.Ok -and ($script:joins -join ',') -eq 'Join:win32tk-golden,Prewarm') { Ok 'the pending restore of the old VM is joined and the pre-warm released first, then saved' } else { Bad "joins: $($script:joins -join ',') Ok=$($r.Ok)" }
    $env:W32T_HYPERV_VM = 'win32tk-measure'; $env:W32T_HYPERV_CHECKPOINT = 'clean-auto'
    $r = Set-Win32ToolkitHyperVTarget -VMName 'win32tk-golden' -CheckpointName 'clean-base'
    if ($r.Ok -and $env:W32T_HYPERV_VM -eq 'win32tk-measure' -and $env:W32T_HYPERV_CHECKPOINT -eq 'clean-auto' -and $r.Target.Source -eq 'Environment') { Ok 'the window''s pins are untouched; the result says this window keeps its pin' } else { Bad "pins: $env:W32T_HYPERV_VM / $env:W32T_HYPERV_CHECKPOINT" }
    Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT

    # ============================== [4] the selector screen ==============================
    Write-Host '[4] Show-Win32ToolkitTestVMSelect, driven' -ForegroundColor Cyan
    $script:vms = @($golden, $devbox, $measure)
    $screen = { Show-Win32ToolkitTestVMSelect }

    $script:cfg = @{ HyperVVMName = 'win32tk-golden'; HyperVCheckpoint = 'clean-base' }
    $x = Drive $screen -Picks 'Use dev-box', 'before-sp*' -Confirms $true
    $saved = "$($script:cfg['HyperVVMName'])/$($script:cfg['HyperVCheckpoint'])"
    if (-not $x.Error -and $x.PicksLeft -eq 0 -and $saved -eq 'dev-box/before-sp') { Ok 'choose dev-box, then before-sp, confirm: saved' } else { Bad "save: $($x.Error) saved=$saved" }
    if ($script:confirmTexts[0] -eq "Every test restores 'before-sp' and loses all changes made in dev-box since. Use dev-box for tests?|n") { Ok 'the V7 question names the data loss; default No for another VM' } else { Bad "question: $($script:confirmTexts -join ' || ')" }
    if (($script:hostLines -match "also use the checkpoint name 'before-sp'") -and ($script:panels -match 'Tests still run in Windows Sandbox') -and ($script:panels -match 'one saved guest account')) { Ok 'notes: VM-only pins use the name too (V4), the backend (V8), the guest account (V9)' } else { Bad "notes: $($script:hostLines -join ' || ') / $($script:panels -join ' || ')" }
    $cpLabels = $script:prompts[1].Labels
    if (($cpLabels -join '|') -match '^Automatic Checkpoint - dev-box - \(10/23/2026 - 09:00:00\), taken 2026-10-23 12:00 UTC \(automatic checkpoint: not a clean base\)\|before-sp, taken 2026-10-22 12:00 UTC\|Back$') { Ok "checkpoint labels: $($cpLabels -join ' | ')" } else { Bad "checkpoint labels: $($cpLabels -join ' | ')" }
    $x = Drive $screen -Picks 'Use win32tk-measure', 'clean-base*' -Confirms $false
    if (-not $x.Error -and $script:cfg['HyperVVMName'] -eq 'dev-box' -and $script:panels.Count -eq 0) { Ok 'No at the question: nothing saved' } else { Bad "no: $($x.Error) cfg=$($script:cfg['HyperVVMName'])" }
    $x = Drive $screen -Picks 'Use win32tk-golden', 'clean-base*' -Confirms $true
    if (-not $x.Error -and $script:confirmTexts[0] -like '*|y' -and $script:cfg['HyperVVMName'] -eq 'win32tk-golden') { Ok 'win32tk-golden: the question defaults to Yes' } else { Bad "golden default: $($script:confirmTexts -join ' || ')" }
    # V2: a lane runner holds win32tk-measure.
    $fileC = Join-Path $lockRoot "hyperv-$idC.lock"
    $held = & $hold $fileC (& $diag $PID 'lane')
    $x = Drive $screen -Picks 'Use win32tk-measure (in use by another window)', 'clean-base*' -Confirms $false
    $laneTable = @($script:tables | Where-Object { $_.VM -eq 'win32tk-measure' })[0].'In use'
    if (-not $x.Error -and ($script:hostLines -match 'A lane runner holds win32tk-measure for a whole queue') -and $script:confirmTexts[0] -eq 'Use win32tk-measure anyway?|n' -and $script:cfg['HyperVVMName'] -eq 'win32tk-golden') { Ok "a lane holder: warning, 'Use anyway?' default No; No saves nothing ($laneTable)" } else { Bad "lane: $($x.Error) $($script:hostLines -join ' || ') / $($script:confirmTexts -join ' || ')" }
    $held.Dispose(); $held = $null
    # V10: not elevated.
    $script:elevated = $false
    $x = Drive $screen -Picks 'Back to the default*' -Confirms $true
    if (-not $x.Error -and ($script:hostLines -match 'Start the menu as administrator') -and ($script:prompts[0].Labels -join '|') -eq 'Back to the default (win32tk-golden, clean-base)|Back' -and $script:cfg['HyperVVMName'] -eq '') { Ok 'not elevated: no list, only the default and Back; the default clears both' } else { Bad "not elevated: $($x.Error) $($script:prompts[0].Labels -join '|')" }
    $script:elevated = $true
    # V4: a pin in this window.
    $env:W32T_HYPERV_VM = 'win32tk-measure'
    $x = Drive $screen -Picks 'Use dev-box', 'before-sp*' -Confirms $true
    if (-not $x.Error -and ($script:hostLines -match 'This window keeps its W32T_HYPERV_VM pin') -and ($script:panels -match "This window keeps W32T_HYPERV_VM = 'win32tk-measure'") -and $env:W32T_HYPERV_VM -eq 'win32tk-measure' -and $script:cfg['HyperVVMName'] -eq 'dev-box') { Ok 'a pinned window: saved for the other windows, the pin stays and is named' } else { Bad "pinned: $($x.Error) $($script:panels -join ' || ')" }
    Remove-Item Env:\W32T_HYPERV_VM

    $selectorChanges = @($script:changes)   # [5] runs the Test VM screen, whose own readiness line is expected

    # ============================== [5] the Test VM screen (D10) ==============================
    Write-Host '[5] Show-Win32ToolkitTestVM: every item acts on the chosen VM and names it' -ForegroundColor Cyan
    $script:calls = [System.Collections.Generic.List[string]]::new()
    $record = { param([string]$Name, $Bound) $script:calls.Add("$Name " + (($Bound.Keys | Sort-Object | ForEach-Object { "$_=$($Bound[$_])" }) -join ' ')) }
    function Get-Win32ToolkitHyperVPaths { param($BasePath) [pscustomobject]@{ Golden = 'C:\hv\golden'; VMs = 'C:\hv\vms' } }
    function Get-Win32ToolkitBasePath { param([Parameter(ValueFromRemainingArguments)]$a) 'C:\Win32Apps' }
    $script:testPaths = [System.Collections.Generic.List[string]]::new()
    function Test-Path { param($LiteralPath, $Path) $script:testPaths.Add([string]$LiteralPath); $false }
    function Get-VMProcessor { param($VMName) [pscustomobject]@{ Count = 2 } }
    function Get-VMMemory { param($VMName) [pscustomobject]@{ Startup = 4GB } }
    function Get-VMHost { [pscustomobject]@{ LogicalProcessorCount = 8; MemoryCapacity = 32GB } }
    function New-Win32ToolkitTestVM { [CmdletBinding()] param($IsoPath, $Name, $CheckpointName, [switch]$Force) & $record 'New' $PSBoundParameters }
    function Set-Win32ToolkitTestVMResource { [CmdletBinding()] param($ProcessorCount, $MemoryStartupBytes, $Name, $CheckpointName) & $record 'Resource' $PSBoundParameters }
    function Reset-Win32ToolkitTestVM { [CmdletBinding()] param($Name, $CheckpointName) & $record 'Reset' $PSBoundParameters }
    function Remove-Win32ToolkitTestVM { [CmdletBinding()] param($Name, [switch]$RemoveVhdx) & $record 'Remove' $PSBoundParameters }
    function Repair-Win32ToolkitTestVMCheckpoint { [CmdletBinding()] param($Name, $CheckpointName) & $record 'Repair' $PSBoundParameters; $true }
    $script:selectorShown = 0
    function Show-Win32ToolkitTestVMSelect { $script:selectorShown++ }
    $tvm = { Show-Win32ToolkitTestVM }
    $script:cfg = @{ HyperVVMName = 'dev-box'; HyperVCheckpoint = 'before-sp' }

    $x = Drive $tvm -Picks 'Provision*', 'Back' -Confirms $true -Texts '"C:\ISO\Win11_x64.iso"'
    $q = @($script:confirmTexts)[0]
    if (-not $x.Error -and $script:calls[0] -eq 'New CheckpointName=before-sp Force=True IsoPath=C:\ISO\Win11_x64.iso Name=dev-box Verbose=True' -and $q -eq "Delete VM 'dev-box' and rebuild VM 'dev-box' from scratch?|n" -and ($script:testPaths -contains 'C:\hv\golden\dev-box.vhdx')) { Ok "Provision checks and rebuilds dev-box, not win32tk-golden: $($script:calls[0]); question '$q'" } else { Bad "provision: $($x.Error) calls=$($script:calls -join ' || ') q=$q paths=$($script:testPaths -join ',')" }
    $script:calls.Clear()
    $x = Drive $tvm -Picks 'Reset*', 'Back' -Confirms $true
    if (-not $x.Error -and $script:calls[0] -eq 'Reset CheckpointName=before-sp Name=dev-box' -and $script:confirmTexts[0] -eq "Reset VM 'dev-box' to its checkpoint 'before-sp'? Every change made in the VM since then is lost.|n") { Ok 'Reset asks (default No for dev-box), names both, passes both' } else { Bad "reset: $($x.Error) $($script:calls -join ' || ') $($script:confirmTexts -join ' || ')" }
    $script:calls.Clear()
    $x = Drive $tvm -Picks 'Reset*', 'Back' -Confirms $false
    if (-not $x.Error -and $script:calls.Count -eq 0) { Ok 'Reset: No changes nothing' } else { Bad "reset no: $($script:calls -join ' || ')" }
    $x = Drive $tvm -Picks 'Configure guest AutoLogon*', 'Back' -Confirms $true
    if (-not $x.Error -and $script:calls[0] -eq 'Repair CheckpointName=before-sp Name=dev-box' -and $script:confirmTexts[0] -like "This removes every checkpoint of VM 'dev-box' and takes a new 'before-sp'*|n") { Ok 'AutoLogon asks first (every checkpoint is removed), passes both' } else { Bad "autologon: $($x.Error) $($script:calls -join ' || ') $($script:confirmTexts -join ' || ')" }
    $script:calls.Clear()
    $x = Drive $tvm -Picks 'Remove the test VM*', 'Back' -Confirms $true
    if (-not $x.Error -and $script:calls[0] -eq 'Remove Name=dev-box RemoveVhdx=True' -and $script:confirmTexts[0] -eq "Remove VM 'dev-box' and delete its virtual disks?|n") { Ok 'Remove names the VM and passes it' } else { Bad "remove: $($x.Error) $($script:calls -join ' || ') $($script:confirmTexts -join ' || ')" }
    $script:calls.Clear()
    $script:vms = @($golden, $devbox)
    $x = Drive $tvm -Picks 'Change VM resources*', 'Back' -Confirms $true -Texts '4', ''
    if (-not $x.Error -and $script:calls[0] -eq 'Resource CheckpointName=before-sp Name=dev-box ProcessorCount=4' -and $script:confirmTexts[0] -eq "Apply the change to VM 'dev-box' now?|y") { Ok 'Resources names the VM and passes both' } else { Bad "resources: $($x.Error) $($script:calls -join ' || ') $($script:confirmTexts -join ' || ')" }
    $script:calls.Clear()
    $x = Drive $tvm -Picks 'Choose the test VM and checkpoint', 'Back'
    if (-not $x.Error -and $script:selectorShown -eq 1 -and ($script:hostLines -match "^Test VM: \[blue\]dev-box\[/\], checkpoint \[blue\]before-sp\[/\] \[grey\]\(saved in Settings\)\[/\]$")) { Ok 'the target line, and the first item opens the selector' } else { Bad "select: $($x.Error) shown=$($script:selectorShown) $($script:hostLines -join ' || ')" }
    if ($script:prompts[0].Labels[0] -eq 'Choose the test VM and checkpoint') { Ok 'Choose the test VM and checkpoint is the first item' } else { Bad "first item: $($script:prompts[0].Labels[0])" }
    $script:cfg = @{ HyperVVMName = 'win32tk-golden'; HyperVCheckpoint = 'clean-base' }
    $x = Drive $tvm -Picks 'Reset*', 'Back' -Confirms $true
    if (-not $x.Error -and $script:confirmTexts[0] -like '*|y') { Ok 'Reset of win32tk-golden defaults to Yes' } else { Bad "golden reset: $($script:confirmTexts -join ' || ')" }
    $script:calls.Clear()
    $env:W32T_HYPERV_VM = "bad`tname"
    $x = Drive $tvm -Picks 'Reset*', 'Back' -Confirms $true
    if (-not $x.Error -and ($script:hostLines -match '^\[red\]Test VM pin not valid:') -and $script:calls[0] -eq 'Reset ') { Ok 'an invalid pin: a red line, and nothing is passed (the command stops on its own)' } else { Bad "invalid pin: $($x.Error) $($script:calls -join ' || ')" }
    Remove-Item Env:\W32T_HYPERV_VM

    # ============================== [6] never ==============================
    Write-Host '[6] no VM change, no lease, no guest credential from the selector; file hygiene' -ForegroundColor Cyan
    if ($selectorChanges.Count -eq 0) { Ok 'no VM-changing cmdlet, no lease, no credential read, no readiness probe in [1]-[4]' } else { Bad "calls: $($selectorChanges -join ', ')" }
    if (@($script:changes | Where-Object { $_ -ne 'Test-Win32ToolkitHyperVReady' }).Count -eq 0) { Ok 'the Test VM screen in [5]: only its readiness line, every VM command through its (shadowed) command' } else { Bad "[5] calls: $($script:changes -join ', ')" }
    $c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
    foreach ($f in 'Initialize-Win32ToolkitLeaseFileType', 'Get-Win32ToolkitHyperVLeaseState', 'Get-Win32ToolkitTestVMChoice', 'Set-Win32ToolkitHyperVTarget', 'Show-Win32ToolkitTestVMSelect') {
        $path = Join-Path $repo "Private\$f.ps1"
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
        $top = @($ast.EndBlock.Statements)
        $oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq $f
        $ascii = @([System.IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 127 }).Count -eq 0
        $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        # The screen's catches are the display sink (they show the error panel); every other catch starts with the C-2 line.
        $badCatch = if ($f -eq 'Show-Win32ToolkitTestVMSelect') { @() } else { @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) }) }
        $changing = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^(Start|Stop|Save|Restore|Checkpoint|Remove|Set|New|Enter)-VM|^(Restore|Remove)-VMCheckpoint$|^Checkpoint-VM$|^Enter-Win32ToolkitHyperVLease$|^Get-Win32ToolkitGuestCredential$|^New-PSSession$|^Invoke-Command$' }, $true))
        if (@($errs).Count -eq 0 -and $oneFunction -and $ascii -and $badCatch.Count -eq 0 -and $changing.Count -eq 0) { Ok "$f.ps1: one function, ASCII, C-2 catches, no VM-changing call" }
        else { Bad "$f.ps1: errors $(@($errs).Count), one function $oneFunction, ascii $ascii, bad catches $($badCatch.Count), changing $(@($changing | ForEach-Object { $_.GetCommandName() }) -join ',')" }
    }
}
finally {
    if ($held) { $held.Dispose() }
    $script:HyperVLeases = $null; $script:HyperVPendingRestore = $null; $script:HyperVPrewarmLease = $null
    if ($null -ne $savedVmPin) { $env:W32T_HYPERV_VM = $savedVmPin } else { Remove-Item Env:\W32T_HYPERV_VM -ErrorAction SilentlyContinue }
    if ($null -ne $savedCpPin) { $env:W32T_HYPERV_CHECKPOINT = $savedCpPin } else { Remove-Item Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue }
    $j = Join-Path $work 'j\locks'
    if ([System.IO.Directory]::Exists($j)) { [System.IO.Directory]::Delete($j) }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -gt 0) { Write-Host "FAILED: $fail" -ForegroundColor Red; exit 1 }
Write-Host 'All test VM selector checks passed.' -ForegroundColor Green
exit 0
