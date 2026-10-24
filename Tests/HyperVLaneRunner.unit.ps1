<#
    Hyper-V speed-up PR 3 (D31, A-17, V-14, V-18): scripts\Invoke-Win32ToolkitHyperVLane.ps1, the in-repo lane runner, against a
    stub module (Tests\Fixtures\LaneRunner\win32-toolkit.psm1) whose functions log every call. Each case runs the runner in
    its own pwsh (a driver script passes the hidden -Clock), so every lane really is one process with one import.

      [a] Queue validation: not JSON, not an array, empty, an item that is not an object, an unknown or wrongly cased key,
          a missing or not existing ProjectPath, a wrong Scenario, VersionsBack 0 / 1001 / 2.5 / "3", a wrong
          BaselineInstallerType, an Update-only key on InstallUninstall, a BaselineProjectPath that does not exist, an
          invalid -VMName -> W32T.LaneQueueInvalid, exit 1, the module never imported, nothing run, no result file.
      [b] A queue of three: the pin, the checkpoint and W32T_PSADT_VERSION are set before the one import; per item the
          project lease (normal wait) before the run and its VM lease (lock order project -> VM), released after;
          -Backend HyperV -Unattended and the item's keys; lane-result.json (items, verdicts, Timing.OpenRevertSkipped
          and TotalSeconds from the record each run wrote, UTC times); exit 0; every test runs with the error preference
          Continue (no -ErrorAction Stop) and sees none of the runner's variables (the stub logs both).
      [c] The clean marker is dropped (-MarkerOnly, one line with the reason) after a gap over -MaxGapSeconds, with a VM
          console open, and before every item with -FreshRestore; not otherwise.
      [d] -HoldLease: refused on the default test VM (HyperVVMName, else win32tk-golden); on a lane VM the VM lease is
          taken first and released last, each project lease is tried once (-WaitSeconds 0), a busy project is recorded
          as W32T.ProjectLeaseTimeout and not run, the queue goes on, exit 1; a VM lease that times out runs nothing.
      [e] Exit codes: a W32T error from an item -> 1 (the queue goes on); the command's own non-terminating
          'Test-Win32ToolkitProject failed:' error (the stub ends like the real command) -> 2; a helper's
          non-terminating error does not end the item (Passed, exit 0).
      [f] win32-toolkit already loaded from another folder -> W32T.LaneQueueInvalid, nothing run.
      [g] -Diagnostics: one transcript per item next to the result; -ResultPath.
      [h] The script: ASCII, Import-Module without -Force, the environment set (and the inherited checkpoint and PSADT
          variables cleared) before the import; the body is one & { } block; no -ErrorAction on the test call.
      [i] Started directly with pwsh -File (the documented launch, whose body would run in the global scope): the
          tests still run with Continue and see no runner variable; a helper's error vs the command's failure;
          W32T_HYPERV_CHECKPOINT / W32T_PSADT_VERSION inherited from the caller are cleared (one line each, null in the
          result) unless -CheckpointName / -PsadtVersion are given, which win.

    Temp folders only; the stub never reaches Hyper-V.

    Run:  pwsh -File Tests\HyperVLaneRunner.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$runner = Join-Path $repo 'scripts\Invoke-Win32ToolkitHyperVLane.ps1'
$stubModule = Join-Path $repo 'Tests\Fixtures\LaneRunner\win32-toolkit.psm1'
$pwsh = (Get-Process -Id $PID).Path
$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('w32lane_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [System.Text.UTF8Encoding]::new($false)
$script:laneCase = 0

# Projects A, B, C (folders only: the stub writes their records).
foreach ($p in 'App-A', 'App-B', 'App-C', 'Base-B') { $null = New-Item -ItemType Directory -Path (Join-Path $TMP "projects\$p") -Force }
$pA = Join-Path $TMP 'projects\App-A'; $pB = Join-Path $TMP 'projects\App-B'; $pC = Join-Path $TMP 'projects\App-C'; $pBase = Join-Path $TMP 'projects\Base-B'

# One lane run: its own folder (queue, stub config, log, driver), its own pwsh; returns exit code, output, log, result.
#   -Direct: the runner itself is started with pwsh -File (its documented launch: the body then runs in the global
#   scope), without the hidden -Clock; -Env: variables set in the lane's environment (all W32T_* pins are removed first).
function Invoke-Lane {
    param($Queue, [string]$QueueText, [hashtable]$Params = @{}, [hashtable]$Stub = @{}, [int]$ClockStep = 1, [string]$Before = '', [string]$ResultName = '',
        [switch]$Direct, [hashtable]$Env = @{})
    $script:laneCase++
    $dir = Join-Path $TMP ("case{0:d2}" -f $script:laneCase)
    $null = New-Item -ItemType Directory -Path $dir -Force
    foreach ($p in 'App-A', 'App-B', 'App-C') { Remove-Item -LiteralPath (Join-Path $TMP "projects\$p\Documentation") -Recurse -Force -ErrorAction SilentlyContinue }
    $qPath = Join-Path $dir 'queue.json'
    $text = if ($PSBoundParameters.ContainsKey('QueueText')) { $QueueText } else { ConvertTo-Json -InputObject @($Queue) -Depth 5 }
    [System.IO.File]::WriteAllText($qPath, $text, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $dir 'stub.json'), (ConvertTo-Json -InputObject $Stub -Depth 5), $utf8)
    $log = Join-Path $dir 'stub.log'
    $argText = foreach ($k in $Params.Keys) {
        $v = $Params[$k]
        if ($v -is [switch] -or $v -is [bool]) { if ($v) { "-$k" } } else { "-$k '$([string]$v -replace "'", "''")'" }
    }
    $resArg = if ($ResultName) { "-ResultPath '$(Join-Path $dir $ResultName)'" } else { '' }
    $driver = @"
`$global:w32tClock = 0
`$clock = { `$global:w32tClock++; [datetime]::new(2026, 10, 24, 10, 0, 0, [System.DateTimeKind]::Utc).AddSeconds(`$global:w32tClock * $ClockStep) }
$Before
& '$runner' -QueuePath '$qPath' -ModulePath '$stubModule' $resArg $($argText -join ' ') -Clock `$clock
exit `$LASTEXITCODE
"@
    $driverPath = Join-Path $dir 'driver.ps1'
    [System.IO.File]::WriteAllText($driverPath, $driver, $utf8)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($pwsh)
    if ($Direct) {
        foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $runner, '-QueuePath', $qPath, '-ModulePath', $stubModule)) { $psi.ArgumentList.Add($a) }
        if ($ResultName) { $psi.ArgumentList.Add('-ResultPath'); $psi.ArgumentList.Add((Join-Path $dir $ResultName)) }
        foreach ($k in $Params.Keys) {
            $v = $Params[$k]
            if ($v -is [switch] -or $v -is [bool]) { if ($v) { $psi.ArgumentList.Add("-$k") } } else { $psi.ArgumentList.Add("-$k"); $psi.ArgumentList.Add([string]$v) }
        }
    }
    else { foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $driverPath)) { $psi.ArgumentList.Add($a) } }
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.Environment['W32T_LANE_STUB'] = Join-Path $dir 'stub.json'
    $psi.Environment['W32T_LANE_STUB_LOG'] = $log
    foreach ($v in 'W32T_HYPERV_VM', 'W32T_HYPERV_CHECKPOINT', 'W32T_PSADT_VERSION') { $null = $psi.Environment.Remove($v) }
    foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(120000)) { $p.Kill($true) }
    $p.WaitForExit()
    $resPath = if ($ResultName) { Join-Path $dir $ResultName } else { Join-Path $dir 'lane-result.json' }
    $resText = if (Test-Path -LiteralPath $resPath) { Get-Content -LiteralPath $resPath -Raw } else { '' }
    $res = if ($resText) { $resText | ConvertFrom-Json } else { $null }
    [pscustomobject]@{ Exit = $p.ExitCode; Out = $out.Result + $err.Result; Log = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }); Result = $res; ResultText = $resText; Dir = $dir }
}
$q3 = @(
    [ordered]@{ ProjectPath = $pA; Scenario = 'InstallUninstall' }
    [ordered]@{ ProjectPath = $pB; Scenario = 'Update'; VersionsBack = 2; BaselineInstallerType = 'msi' }
    [ordered]@{ ProjectPath = $pC; Scenario = 'InstallUninstall' })
$lane = @{ VMName = 'lane-vm' }

try {
    # ============================== [a] queue validation ==============================
    Write-Host '[a] an invalid queue: W32T.LaneQueueInvalid, exit 1, nothing imported or run' -ForegroundColor Cyan
    foreach ($case in @(
            @{ Tag = 'not JSON'; Text = '{ not json' }
            @{ Tag = 'an object, not an array'; Text = "{ ""ProjectPath"": ""$($pA -replace '\\', '\\')"", ""Scenario"": ""InstallUninstall"" }" }
            @{ Tag = 'an empty array'; Text = '[]' }
            @{ Tag = 'an item that is not an object'; Q = @('App-A') }
            @{ Tag = 'an unknown key'; Q = @([ordered]@{ ProjectPath = $pA; Scenario = 'InstallUninstall'; Backend = 'Sandbox' }) }
            @{ Tag = 'a key in another case'; Q = @([ordered]@{ projectPath = $pA; Scenario = 'InstallUninstall' }) }
            @{ Tag = 'no ProjectPath'; Q = @([ordered]@{ Scenario = 'InstallUninstall' }) }
            @{ Tag = 'a ProjectPath that does not exist'; Q = @([ordered]@{ ProjectPath = (Join-Path $TMP 'nope'); Scenario = 'InstallUninstall' }) }
            @{ Tag = 'a ProjectPath that is not text'; Q = @([ordered]@{ ProjectPath = 5; Scenario = 'InstallUninstall' }) }
            @{ Tag = 'Scenario in another case'; Q = @([ordered]@{ ProjectPath = $pA; Scenario = 'installuninstall' }) }
            @{ Tag = 'an unknown Scenario'; Q = @([ordered]@{ ProjectPath = $pA; Scenario = 'Capture' }) }
            @{ Tag = 'VersionsBack 0'; Q = @([ordered]@{ ProjectPath = $pB; Scenario = 'Update'; VersionsBack = 0 }) }
            @{ Tag = 'VersionsBack 1001'; Q = @([ordered]@{ ProjectPath = $pB; Scenario = 'Update'; VersionsBack = 1001 }) }
            @{ Tag = 'VersionsBack 2.5'; Q = @([ordered]@{ ProjectPath = $pB; Scenario = 'Update'; VersionsBack = 2.5 }) }
            @{ Tag = 'VersionsBack as text'; Q = @([ordered]@{ ProjectPath = $pB; Scenario = 'Update'; VersionsBack = '3' }) }
            @{ Tag = 'an unknown BaselineInstallerType'; Q = @([ordered]@{ ProjectPath = $pB; Scenario = 'Update'; BaselineInstallerType = 'zip' }) }
            @{ Tag = 'an Update key on InstallUninstall'; Q = @([ordered]@{ ProjectPath = $pA; Scenario = 'InstallUninstall'; SpecificVersion = '1.2.3' }) }
            @{ Tag = 'a BaselineProjectPath that does not exist'; Q = @([ordered]@{ ProjectPath = $pB; Scenario = 'Update'; BaselineProjectPath = (Join-Path $TMP 'nope') }) }
            @{ Tag = 'a SpecificVersion with a control character'; Q = @([ordered]@{ ProjectPath = $pB; Scenario = 'Update'; SpecificVersion = "1.0`t2" }) }
            @{ Tag = 'a blank -VMName'; Q = $q3; Params = @{ VMName = '   ' } })) {
        $ip = if ($case.Params) { $case.Params } else { $lane }
        $x = if ($case.ContainsKey('Text')) { Invoke-Lane -QueueText $case.Text -Params $ip } else { Invoke-Lane -Queue $case.Q -Params $ip }
        if ($x.Exit -eq 1 -and $x.Out -match 'W32T\.LaneQueueInvalid' -and $x.Out -match 'Nothing was run' -and $x.Log.Count -eq 0 -and $null -eq $x.Result) {
            Ok "$($case.Tag): exit 1, W32T.LaneQueueInvalid, no import, no result file"
        } else { Bad "$($case.Tag): exit=$($x.Exit) log=$($x.Log -join ' | ') out=$($x.Out)" }
    }
    # a valid BaselineProjectPath and SpecificVersion pass
    $x = Invoke-Lane -Queue @([ordered]@{ ProjectPath = $pB; Scenario = 'Update'; BaselineProjectPath = $pBase; SpecificVersion = ' 8.7.1 ' }) -Params $lane
    if ($x.Exit -eq 0 -and @($x.Log | Where-Object { $_ -like 'test:App-B:Update:*keys=Backend,BaselineProjectPath,ProjectPath,Scenario,SpecificVersion,Unattended' }).Count -eq 1) {
        Ok 'BaselineProjectPath (an existing folder) and SpecificVersion (trimmed) reach the run'
    } else { Bad "valid update keys: exit=$($x.Exit) log=$($x.Log -join ' | ')" }

    # ============================== [b] a queue of three ==============================
    Write-Host '[b] three items: one import with the pin set first, project lease -> run (VM lease) -> release, the result file' -ForegroundColor Cyan
    $x = Invoke-Lane -Queue $q3 -Params @{ VMName = 'lane-vm'; CheckpointName = 'clean-auto'; PsadtVersion = '4.1.8' }
    $imports = @($x.Log | Where-Object { $_ -like 'import:*' })
    if ($x.Exit -eq 0 -and $imports.Count -eq 1 -and $x.Log[0] -ceq 'import:vm=lane-vm;cp=clean-auto;psadt=4.1.8') { Ok 'exit 0; one import, with W32T_HYPERV_VM, W32T_HYPERV_CHECKPOINT and W32T_PSADT_VERSION already set' } else { Bad "import: exit=$($x.Exit) log=$($x.Log -join ' | ') out=$($x.Out)" }
    $flow = @($x.Log | Where-Object { $_ -like 'enter:*' -or $_ -like 'exit:*' -or $_ -like 'test:*' } | ForEach-Object { ($_ -replace ':keys=.*$', '') })
    $wantFlow = @(
        'enter:vm=|project=App-A|purpose=lane|wait=', 'test:App-A:InstallUninstall:backend=HyperV:unattended=True', 'enter:vm=lane-vm|project=|purpose=test run|wait=', 'exit:VM:lane-vm', 'exit:Project:App-A'
        'enter:vm=|project=App-B|purpose=lane|wait=', 'test:App-B:Update:backend=HyperV:unattended=True', 'enter:vm=lane-vm|project=|purpose=test run|wait=', 'exit:VM:lane-vm', 'exit:Project:App-B'
        'enter:vm=|project=App-C|purpose=lane|wait=', 'test:App-C:InstallUninstall:backend=HyperV:unattended=True', 'enter:vm=lane-vm|project=|purpose=test run|wait=', 'exit:VM:lane-vm', 'exit:Project:App-C')
    if (($flow -join "`n") -ceq ($wantFlow -join "`n")) { Ok 'per item: the project lease (normal wait), then the run and its VM lease, both released (lock order project -> VM)' } else { Bad "flow: $($flow -join ' | ')" }
    if (@($x.Log | Where-Object { $_ -like 'test:App-B:*keys=Backend,BaselineInstallerType,ProjectPath,Scenario,Unattended,VersionsBack' }).Count -eq 1) { Ok 'the item''s keys reach Test-Win32ToolkitProject with -Backend HyperV -Unattended' } else { Bad "keys: $($x.Log -join ' | ')" }
    if (@($x.Log | Where-Object { $_ -like 'clear:*' }).Count -eq 0 -and @($x.Log | Where-Object { $_ -like 'vmc:*' }).Count -eq 2) { Ok 'no marker dropped; the console is checked before items 2 and 3' } else { Bad "guard: $($x.Log -join ' | ')" }
    $r = $x.Result
    $it = @($r.Items)
    if ($r -and $r.ExitCode -eq 0 -and $r.VMName -eq 'lane-vm' -and $r.CheckpointName -eq 'clean-auto' -and $r.PsadtVersion -eq '4.1.8' -and $it.Count -eq 3 -and
        (@($it | ForEach-Object { $_.Verdict }) -join ',') -eq 'Passed,Passed,Passed' -and (@($it | ForEach-Object { $_.OpenRevertSkipped }) -join ',') -eq 'False,True,True' -and
        (@($it | ForEach-Object { $_.TotalSeconds }) -join ',') -eq '101.5,102.5,103.5' -and @($it | Where-Object { $_.Ran -ne $true -or $_.ErrorId }).Count -eq 0 -and
        ([regex]::Matches($x.ResultText, '"(StartUtc|EndUtc)":\s*"2026-10-24T10:\d\d:\d\d(\.0+)?Z"')).Count -eq 6) {
        Ok 'lane-result.json: the lane, three items with Verdict, OpenRevertSkipped and TotalSeconds from their records, UTC start/end, ExitCode 0'
    } else { Bad "result: $($r | ConvertTo-Json -Depth 4 -Compress)" }
    if ($x.Out -match '\[10:\d\d:\d\dZ\] lane: item 1: App-A \(InstallUninstall\)') { Ok 'the lane''s own lines carry the UTC time' } else { Bad "lines: $($x.Out)" }
    $states = @($x.Log | Where-Object { $_ -like 'state:*' })
    if ($states.Count -eq 3 -and @($states | Where-Object { $_ -notmatch ':eap=Continue:globals=$' }).Count -eq 0) {
        Ok 'every test runs with the error preference Continue (no -ErrorAction Stop) and sees none of the runner''s variables'
    } else { Bad "state: $($states -join ' | ')" }

    # ============================== [c] dropping the marker ==============================
    Write-Host '[c] the clean marker: dropped after a gap over -MaxGapSeconds, with a console open, with -FreshRestore' -ForegroundColor Cyan
    $x = Invoke-Lane -Queue $q3 -Params $lane -ClockStep 50
    $clears = @($x.Log | Where-Object { $_ -eq 'clear:markeronly=True' })
    $reasons = @($x.Result.Items | ForEach-Object { [string]$_.MarkerCleared })
    if ($x.Exit -eq 0 -and $clears.Count -eq 2 -and $reasons[0] -eq '' -and $reasons[1] -match '^\d+ s since the previous item \(more than 120 s\)$' -and $reasons[2] -match 'since the previous item' -and
        $x.Out -match 'item 2: the run restores the checkpoint first \(\d+ s since the previous item \(more than 120 s\)\)\.') {
        Ok 'a gap over 120 s before items 2 and 3: Clear -MarkerOnly twice, the reason in a line and in the result'
    } else { Bad "gap: clears=$($clears.Count) reasons=$($reasons -join ' | ')" }
    $x = Invoke-Lane -Queue $q3 -Params @{ VMName = 'lane-vm'; MaxGapSeconds = 100000 } -ClockStep 50
    if (@($x.Log | Where-Object { $_ -like 'clear:*' }).Count -eq 0) { Ok 'the same gaps under a larger -MaxGapSeconds: no drop' } else { Bad "max gap: $($x.Log -join ' | ')" }
    $x = Invoke-Lane -Queue $q3 -Params $lane -Stub @{ VMConnect = $true }
    $reasons = @($x.Result.Items | ForEach-Object { [string]$_.MarkerCleared })
    if (@($x.Log | Where-Object { $_ -eq 'clear:markeronly=True' }).Count -eq 2 -and $reasons[1] -eq 'a VM console (vmconnect) is open') { Ok 'a VM console open: dropped before items 2 and 3' } else { Bad "vmconnect: $($reasons -join ' | ')" }
    $x = Invoke-Lane -Queue $q3 -Params @{ VMName = 'lane-vm'; FreshRestore = $true }
    $reasons = @($x.Result.Items | ForEach-Object { [string]$_.MarkerCleared })
    if (@($x.Log | Where-Object { $_ -eq 'clear:markeronly=True' }).Count -eq 3 -and @($reasons | Where-Object { $_ -eq 'a fresh restore was asked for (-FreshRestore)' }).Count -eq 3 -and
        @($x.Log | Where-Object { $_ -like 'clear:*' })[0] -and [array]::IndexOf($x.Log, 'clear:markeronly=True') -lt [array]::IndexOf($x.Log, @($x.Log | Where-Object { $_ -like 'test:App-A*' })[0])) {
        Ok '-FreshRestore: dropped before every item, the first one included'
    } else { Bad "fresh: $($reasons -join ' | ')" }

    # ============================== [d] -HoldLease ==============================
    Write-Host '[d] -HoldLease: never on the default VM; the VM first, each project once (V-18); a busy project is skipped' -ForegroundColor Cyan
    foreach ($case in @(
            @{ Tag = 'the registry''s VM'; VM = 'lane-vm'; Stub = @{ DefaultVM = 'lane-vm' } }
            @{ Tag = 'win32tk-golden (no registry value)'; VM = 'win32tk-golden'; Stub = @{} })) {
        $x = Invoke-Lane -Queue $q3 -Params @{ VMName = $case.VM; HoldLease = $true } -Stub $case.Stub
        if ($x.Exit -eq 1 -and $x.Out -match 'W32T\.LaneQueueInvalid: -HoldLease is refused on the default test VM' -and @($x.Log | Where-Object { $_ -like 'enter:*' -or $_ -like 'test:*' }).Count -eq 0) {
            Ok "-HoldLease on $($case.Tag): refused, nothing leased or run"
        } else { Bad "$($case.Tag): exit=$($x.Exit) log=$($x.Log -join ' | ')" }
    }
    $x = Invoke-Lane -Queue $q3 -Params @{ VMName = 'lane-vm'; HoldLease = $true } -Stub @{ BusyProjects = @('App-B') }
    $flow = @($x.Log | Where-Object { $_ -like 'enter:*' -or $_ -like 'exit:*' -or $_ -like 'test:*' } | ForEach-Object { ($_ -replace ':keys=.*$', '') })
    $it = @($x.Result.Items)
    if ($flow[0] -eq 'enter:vm=lane-vm|project=|purpose=lane|wait=' -and $flow[-1] -eq 'exit:VM:lane-vm' -and @($flow | Where-Object { $_ -like 'enter:vm=|project=*' -and $_ -notlike '*wait=0' }).Count -eq 0 -and
        @($flow | Where-Object { $_ -like 'enter:vm=|project=*' }).Count -eq 3) {
        Ok 'the VM lease first and released last; every project lease tried once (-WaitSeconds 0) while the lane holds the VM'
    } else { Bad "hold flow: $($flow -join ' | ')" }
    if ($x.Exit -eq 1 -and $it[1].ErrorId -eq 'W32T.ProjectLeaseTimeout' -and $it[1].Ran -eq $false -and @($x.Log | Where-Object { $_ -like 'test:App-B*' }).Count -eq 0 -and
        $it[2].Ran -eq $true -and $it[2].Verdict -eq 'Passed' -and $x.Result.ExitCode -eq 1) {
        Ok 'a busy project under -HoldLease: W32T.ProjectLeaseTimeout for that item, not run, the next item runs, exit 1'
    } else { Bad "busy: exit=$($x.Exit) items=$($it | ConvertTo-Json -Compress -Depth 3)" }
    $x = Invoke-Lane -Queue $q3 -Params @{ VMName = 'lane-vm'; HoldLease = $true } -Stub @{ HoldBusy = $true }
    if ($x.Exit -eq 1 -and @($x.Log | Where-Object { $_ -like 'test:*' -or $_ -like 'enter:vm=|project=*' }).Count -eq 0 -and $x.Result -and @($x.Result.Items).Count -eq 0 -and $x.Result.Error -match 'W32T.HyperVLeaseTimeout') {
        Ok 'the lane''s VM lease times out: exit 1, nothing run, the result names the error'
    } else { Bad "hold busy: exit=$($x.Exit) log=$($x.Log -join ' | ') result=$($x.Result | ConvertTo-Json -Compress -Depth 3)" }
    # without -HoldLease a busy project waits (the normal wait) and is reported the same way
    $x = Invoke-Lane -Queue $q3 -Params $lane -Stub @{ BusyProjects = @('App-A') }
    if ($x.Exit -eq 1 -and @($x.Log | Where-Object { $_ -eq 'enter:vm=|project=App-A|purpose=lane|wait=' }).Count -eq 1 -and $x.Result.Items[0].ErrorId -eq 'W32T.ProjectLeaseTimeout' -and $x.Result.Items[1].Ran) {
        Ok 'without -HoldLease: the project lease with the normal wait; a timeout is recorded and the queue goes on'
    } else { Bad "busy no hold: exit=$($x.Exit) log=$($x.Log -join ' | ')" }

    # ============================== [e] exit codes ==============================
    Write-Host '[e] exit codes: a W32T error from an item -> 1, another error -> 2; the queue goes on' -ForegroundColor Cyan
    $x = Invoke-Lane -Queue $q3 -Params $lane -Stub @{ Behaviour = @{ 'App-B' = 'w32t' } }
    if ($x.Exit -eq 1 -and $x.Result.Items[1].ErrorId -eq 'W32T.HyperVTargetNotReady' -and $x.Result.Items[1].Ran -and $x.Result.Items[2].Verdict -eq 'Passed' -and @($x.Log | Where-Object { $_ -eq 'exit:Project:App-B' }).Count -eq 1) {
        Ok 'a W32T error from item 2: recorded, its project lease released, item 3 runs, exit 1'
    } else { Bad "w32t: exit=$($x.Exit) items=$($x.Result.Items | ConvertTo-Json -Compress -Depth 3)" }
    $x = Invoke-Lane -Queue $q3 -Params $lane -Stub @{ Behaviour = @{ 'App-A' = 'plain'; 'App-B' = 'w32t' } }
    if ($x.Exit -eq 2 -and $x.Result.Items[0].ErrorId -eq 'Exception' -and $x.Result.Items[0].Error -match '^Test-Win32ToolkitProject failed: stub: something broke' -and $x.Result.ExitCode -eq 2 -and
        $x.Result.Items[1].ErrorId -eq 'W32T.HyperVTargetNotReady' -and $x.Result.Items[2].Verdict -eq 'Passed') {
        Ok 'another error (the command''s non-terminating "Test-Win32ToolkitProject failed:" error, read with -ErrorVariable): ErrorId Exception, exit 2 (over 1), the queue goes on'
    } else { Bad "plain: exit=$($x.Exit) items=$($x.Result.Items | ConvertTo-Json -Compress -Depth 3)" }
    # A helper that reports an error and goes on does not end the item (as from the command line).
    $x = Invoke-Lane -Queue $q3 -Params $lane -Stub @{ Behaviour = @{ 'App-B' = 'inner' } }
    if ($x.Exit -eq 0 -and $x.Result.Items[1].Verdict -eq 'Passed' -and $null -eq $x.Result.Items[1].ErrorId -and @($x.Log | Where-Object { $_ -eq 'helper-went-on:App-B' }).Count -eq 1 -and
        $x.Out -match 'a helper of App-B reported a problem and went on') {
        Ok 'a helper''s non-terminating error: shown, the run goes on and records Passed, exit 0'
    } else { Bad "inner: exit=$($x.Exit) log=$($x.Log -join ' | ') items=$($x.Result.Items | ConvertTo-Json -Compress -Depth 3)" }
    $x = Invoke-Lane -Queue $q3 -Params $lane -Stub @{ Behaviour = @{ 'App-A' = 'norecord'; 'App-C' = 'Failed' } }
    if ($x.Exit -eq 0 -and $null -eq $x.Result.Items[0].Verdict -and $x.Result.Items[2].Verdict -eq 'Failed') { Ok 'verdicts are data: no record -> Verdict null, Failed recorded, exit 0' } else { Bad "data: exit=$($x.Exit) items=$($x.Result.Items | ConvertTo-Json -Compress -Depth 3)" }

    # ============================== [f] another module already loaded ==============================
    Write-Host '[f] win32-toolkit already loaded from another folder: refused before anything runs' -ForegroundColor Cyan
    $other = Join-Path $TMP 'other\win32-toolkit'
    $null = New-Item -ItemType Directory -Path $other -Force
    Copy-Item -LiteralPath $stubModule -Destination (Join-Path $other 'win32-toolkit.psm1')
    $x = Invoke-Lane -Queue $q3 -Params $lane -Before "Import-Module '$(Join-Path $other 'win32-toolkit.psm1')'"
    if ($x.Exit -eq 1 -and $x.Out -match 'W32T\.LaneQueueInvalid: win32-toolkit is already loaded from .*start a new PowerShell process' -and @($x.Log | Where-Object { $_ -like 'test:*' }).Count -eq 0) {
        Ok 'refused with "start a new PowerShell process"; nothing run'
    } else { Bad "already loaded: exit=$($x.Exit) out=$($x.Out)" }
    $x = Invoke-Lane -Queue $q3 -Params $lane -Before "Import-Module '$stubModule'"
    if ($x.Exit -eq 0 -and @($x.Log | Where-Object { $_ -like 'import:*' }).Count -eq 1) { Ok 'the same module already loaded: used as it is (no second import)' } else { Bad "same module: exit=$($x.Exit) log=$($x.Log -join ' | ')" }

    # ============================== [g] -Diagnostics, -ResultPath ==============================
    Write-Host '[g] -Diagnostics: one transcript per item next to the result; -ResultPath' -ForegroundColor Cyan
    $x = Invoke-Lane -Queue $q3 -Params @{ VMName = 'lane-vm'; Diagnostics = $true } -ResultName 'out\my-result.json'
    $logs = @(Get-ChildItem -LiteralPath (Join-Path $x.Dir 'out') -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
    if ($x.Exit -eq 0 -and $x.Result -and ($logs -join ',') -eq '1-App-A.log,2-App-B.log,3-App-C.log' -and (Get-Content -LiteralPath (Join-Path $x.Dir 'out\2-App-B.log') -Raw) -match 'lane: item 2: App-B') {
        Ok 'the result at -ResultPath; 1-App-A.log, 2-App-B.log, 3-App-C.log hold each item''s lines'
    } else { Bad "diagnostics: exit=$($x.Exit) logs=$($logs -join ',') out=$($x.Out)" }

    # ============================== [h] the script ==============================
    Write-Host '[h] the script: ASCII, one import without -Force, the environment set before it' -ForegroundColor Cyan
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($runner, [ref]$null, [ref]$errs)
    $imports = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' }, $true))
    $force = @($imports | Where-Object { $_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Force' } })
    $envSets = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$env:W32T_(HYPERV_VM|HYPERV_CHECKPOINT|PSADT_VERSION)$' }, $true))
    $ascii = @([System.IO.File]::ReadAllBytes($runner) | Where-Object { $_ -gt 127 }).Count -eq 0
    if (@($errs).Count -eq 0 -and $ascii -and $imports.Count -eq 1 -and $force.Count -eq 0 -and $envSets.Count -eq 3 -and
        @($envSets | Where-Object { $_.Extent.StartOffset -gt $imports[0].Extent.StartOffset }).Count -eq 0) {
        Ok 'ASCII, parses, one Import-Module without -Force, the three variables set before it'
    } else { Bad "script: errors=$(@($errs).Count) ascii=$ascii imports=$($imports.Count) force=$($force.Count) env=$($envSets.Count)" }
    $envClears = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-Item' -and $n.Extent.Text -match 'Env:\\W32T_(HYPERV_CHECKPOINT|PSADT_VERSION)' }, $true))
    if ($envClears.Count -eq 2 -and @($envClears | Where-Object { $_.Extent.StartOffset -gt $imports[0].Extent.StartOffset }).Count -eq 0) { Ok 'the inherited checkpoint and PSADT variables are cleared before the import' } else { Bad "clears: $($envClears.Count)" }
    $runs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-Win32ToolkitProject' }, $true))
    $ea = @($runs | ForEach-Object { $_.CommandElements } | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -in 'ErrorAction', 'EA' })
    $top = @($ast.EndBlock.Statements)
    $oneBlock = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.PipelineAst] -and $top[0].PipelineElements[0].InvocationOperator -eq 'Ampersand' -and
        $top[0].PipelineElements[0].CommandElements[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
    if ($runs.Count -eq 1 -and $ea.Count -eq 0 -and $oneBlock) { Ok 'the body is one & { } block (nothing global) and the test is called without -ErrorAction' } else { Bad "body: runs=$($runs.Count) ea=$($ea.Count) oneBlock=$oneBlock top=$($top.Count)" }
    $lintFile = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\Invoke-Lint.ps1'))
    if ($lintFile -match "Join-Path \`$repo 'scripts\\Invoke-Win32ToolkitHyperVLane\.ps1'") { Ok 'scripts\Invoke-Lint.ps1 lints the lane runner (V-14)' } else { Bad 'the lint gate does not cover the lane runner' }

    # ============================== [i] pwsh -File, inherited variables ==============================
    Write-Host '[i] started with pwsh -File: nothing global, the test''s errors as from the command line; inherited pins cleared' -ForegroundColor Cyan
    $inherited = @{ W32T_HYPERV_CHECKPOINT = 'inherited-cp'; W32T_PSADT_VERSION = '4.2.0-rc2' }
    $x = Invoke-Lane -Queue $q3 -Params $lane -Stub @{ Behaviour = @{ 'App-A' = 'inner'; 'App-B' = 'plain' } } -Direct -Env $inherited
    $states = @($x.Log | Where-Object { $_ -like 'state:*' })
    $it = @($x.Result.Items)
    if ($x.Exit -eq 2 -and $states.Count -eq 3 -and @($states | Where-Object { $_ -notmatch ':eap=Continue:globals=$' }).Count -eq 0) {
        Ok 'pwsh -File: every test runs with the error preference Continue and sees none of the runner''s variables'
    } else { Bad "direct state: exit=$($x.Exit) $($states -join ' | ') out=$($x.Out)" }
    if ($it.Count -eq 3 -and $it[0].Verdict -eq 'Passed' -and $null -eq $it[0].ErrorId -and $it[1].ErrorId -eq 'Exception' -and $it[1].Error -match '^Test-Win32ToolkitProject failed:' -and
        $null -eq $it[1].Verdict -and $it[2].Verdict -eq 'Passed' -and @($x.Log | Where-Object { $_ -eq 'helper-went-on:App-A' }).Count -eq 1) {
        Ok 'pwsh -File: a helper''s error leaves the item Passed; the command''s own failure is ErrorId Exception (exit 2); the queue goes on'
    } else { Bad "direct items: $($it | ConvertTo-Json -Compress -Depth 3)" }
    if ($x.Log[0] -ceq 'import:vm=lane-vm;cp=;psadt=' -and $null -eq $x.Result.CheckpointName -and $null -eq $x.Result.PsadtVersion -and
        $x.Out -match "W32T_HYPERV_CHECKPOINT 'inherited-cp' of the calling session is not used: -CheckpointName was not given" -and
        $x.Out -match "W32T_PSADT_VERSION '4\.2\.0-rc2' of the calling session is not used: -PsadtVersion was not given") {
        Ok 'inherited W32T_HYPERV_CHECKPOINT / W32T_PSADT_VERSION without the parameters: cleared before the import (one line each), recorded as null'
    } else { Bad "inherited: log0=$($x.Log[0]) result cp=$($x.Result.CheckpointName) psadt=$($x.Result.PsadtVersion) out=$($x.Out)" }
    $x = Invoke-Lane -Queue $q3 -Params @{ VMName = 'lane-vm'; CheckpointName = 'given-cp'; PsadtVersion = '4.1.8' } -Direct -Env $inherited
    if ($x.Exit -eq 0 -and $x.Log[0] -ceq 'import:vm=lane-vm;cp=given-cp;psadt=4.1.8' -and $x.Result.CheckpointName -eq 'given-cp' -and $x.Result.PsadtVersion -eq '4.1.8' -and $x.Out -notmatch 'is not used') {
        Ok 'the parameters win over inherited values (pwsh -File), and are recorded'
    } else { Bad "given: exit=$($x.Exit) log0=$($x.Log[0]) out=$($x.Out)" }
}
finally {
    Remove-Item -LiteralPath $TMP -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All HyperVLaneRunner tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail HyperVLaneRunner test(s) FAILED." -ForegroundColor Red; exit 1 }
