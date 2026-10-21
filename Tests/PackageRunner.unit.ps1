<#
    The guest package runner (spec 2.13 / 5.6): New-Win32ToolkitPackageRunnerScript writes
    Sandbox\Invoke-PsadtPackage.ps1 (UTF-8 BOM, value-free, 5.1-safe) and Sandbox\IntuneCommandLine.json
    (BOM-less, from Get-Win32ToolkitIntuneCommandLine). The runner is then EXECUTED under Windows
    PowerShell 5.1 against fake packages (stub deploy scripts and a stub launcher .cmd - never real PSADT):

      [1] generation: both files, encodings, 5.1 parse, value-free, -WhatIf writes nothing
      [2] direct mode: the stub's exact exit code (3010), a 64-bit child (also from a 32-bit parent),
          working directory = package folder, -DeployMode passed only when given, log line
      [3] -IntuneParity: the published command line through SysWOW64\cmd.exe (32-bit parent), from the
          package folder, exact exit code (1641), parent=x86-cmd - with NoDefaultCurrentDirectoryInExePath
          inherited from the host (the runner must clear it)
      [4] -IntuneParity with no command line (Repair, a JSON without the key, no JSON) -> exit 87 and a
          'parent=none ... result=Failed' line, the stub never runs
      [5] process isolation: two runs back to back from ONE parent shell -> two distinct child PIDs, both
          different from the parent, both exit codes logged in order
      [6] timeout: a 1-minute limit kills the stub AND its child (taskkill /T) -> exit 1460, result=Timeout

    Get-Win32ToolkitIntuneCommandLine (WP-C) is shadowed exactly as its contract (spec 2.10) defines it.
    The 5.1 parts are skipped (with a note) only when powershell.exe is absent.

    Run:  pwsh -File Tests\PackageRunner.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\New-Win32ToolkitPackageRunnerScript.ps1')

# Contract shadow (spec 2.10): constant, no parameters.
function Get-Win32ToolkitIntuneCommandLine {
    [pscustomobject]@{
        Install   = 'Invoke-AppDeployToolkit.exe -DeploymentType Install'
        Uninstall = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'
        Launcher  = 'Invoke-AppDeployToolkit.exe'
        Script    = 'Invoke-AppDeployToolkit.ps1'
    }
}

$utf8Bom   = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Test-Bom([string]$Path) { $b = [System.IO.File]::ReadAllBytes($Path); $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF }

# Short root (MAX_PATH) with a SPACE in the package folder names: proves the -File path is quoted for 5.1.
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32pr_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$ps51  = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ps32  = Join-Path $env:WinDir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
$has51 = Test-Path -LiteralPath $ps51
$spawned = New-Object System.Collections.Generic.List[int]   # every stub PID we learn: killed in finally

try {
# == [1] generation ===============================================================================
Write-Host '[1] New-Win32ToolkitPackageRunnerScript writes the runner + the command-line data file' -ForegroundColor Cyan
$projA = Join-Path $root "Contoso O'Brien `$x"
$projB = Join-Path $root 'Other_x64_9.9'
New-Item -ItemType Directory -Path $projA, $projB -Force | Out-Null
$ret = New-Win32ToolkitPackageRunnerScript -ProjectPath $projA
$runnerA = Join-Path $projA 'Sandbox\Invoke-PsadtPackage.ps1'
$jsonA   = Join-Path $projA 'Sandbox\IntuneCommandLine.json'
if ($ret -eq $runnerA -and (Test-Path -LiteralPath $runnerA)) { Ok 'returns the runner path; Sandbox\Invoke-PsadtPackage.ps1 written' } else { Bad "returned [$ret]" }
if (Test-Path -LiteralPath $jsonA) { Ok 'Sandbox\IntuneCommandLine.json written' } else { Bad 'no IntuneCommandLine.json' }
if (Test-Bom $runnerA) { Ok 'runner is UTF-8 WITH BOM (5.1 reads BOM-less as ANSI)' } else { Bad 'runner has no BOM' }
if (-not (Test-Bom $jsonA)) { Ok 'data JSON is BOM-less UTF-8' } else { Bad 'data JSON has a BOM' }
$cl = Get-Content -LiteralPath $jsonA -Raw | ConvertFrom-Json
$exp = Get-Win32ToolkitIntuneCommandLine
if ($cl.Install -eq $exp.Install -and $cl.Uninstall -eq $exp.Uninstall -and $cl.Launcher -eq $exp.Launcher -and $cl.Script -eq $exp.Script) { Ok 'JSON = Get-Win32ToolkitIntuneCommandLine (Install/Uninstall/Launcher/Script)' } else { Bad "json: $($cl | ConvertTo-Json -Compress)" }
if ("$($cl.Install) $($cl.Uninstall)" -notmatch 'DeployMode|AllowWowProcess|Sysnative') { Ok 'command lines carry no -DeployMode / AllowWowProcess / Sysnative (D4, D6)' } else { Bad 'forbidden token in the command line' }

$runnerText = [System.IO.File]::ReadAllText($runnerA)
$perr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($runnerText, [ref]$null, [ref]$perr)
if (-not $perr) { Ok 'runner parses (host parser)' } else { Bad "host parse: $($perr[0].Message)" }
if ([regex]::IsMatch($runnerText, '[^\x00-\x7F]')) { Bad 'runner text is not ASCII' } else { Ok 'runner text is ASCII' }

$null = New-Win32ToolkitPackageRunnerScript -ProjectPath $projB
$runnerB = Join-Path $projB 'Sandbox\Invoke-PsadtPackage.ps1'
if ([System.IO.File]::ReadAllText($runnerB) -ceq $runnerText) { Ok 'VALUE-FREE: identical runner for two different projects' } else { Bad 'runner text depends on the project' }
if ($runnerText -notmatch [regex]::Escape("O'Brien") -and $runnerText -notmatch [regex]::Escape($root)) { Ok 'no project name or host path spliced into the runner' } else { Bad 'project value spliced into the runner' }
$dataB = [System.IO.File]::ReadAllText((Join-Path $projB 'Sandbox\IntuneCommandLine.json'))
if ($dataB -ceq [System.IO.File]::ReadAllText($jsonA)) { Ok 'data file identical for both projects (constant contract)' } else { Bad 'data file differs per project' }

$projW = Join-Path $root 'whatif'
New-Item -ItemType Directory -Path $projW -Force | Out-Null
$retW = New-Win32ToolkitPackageRunnerScript -ProjectPath $projW -WhatIf
if ($retW -eq (Join-Path $projW 'Sandbox\Invoke-PsadtPackage.ps1') -and -not (Test-Path -LiteralPath (Join-Path $projW 'Sandbox'))) { Ok '-WhatIf: returns the runner path, writes nothing (SupportsShouldProcess)' } else { Bad "-WhatIf wrote files or returned [$retW]" }

if (-not $has51) {
    Write-Host '  SKIP: Windows PowerShell 5.1 (powershell.exe) not present - 5.1 parse and execution checks skipped' -ForegroundColor DarkYellow
}
else {
    $env:W32T_PR_FILE = $runnerA
    $n51 = (& $ps51 -NoProfile -Command '$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:W32T_PR_FILE,[ref]$null,[ref]$e); @($e).Count' | Out-String).Trim()
    if ($n51 -eq '0') { Ok 'runner parses under Windows PowerShell 5.1 (0 errors)' } else { Bad "5.1 parse errors: $n51" }
    $env:W32T_PR_FILE = $jsonA
    $j51 = (& $ps51 -NoProfile -Command '$j = Get-Content -LiteralPath $env:W32T_PR_FILE -Raw -Encoding UTF8 | ConvertFrom-Json; $j.Install + "|" + $j.Uninstall' | Out-String).Trim()
    if ($j51 -eq "$($exp.Install)|$($exp.Uninstall)") { Ok 'data JSON parses under Windows PowerShell 5.1' } else { Bad "5.1 json: $j51" }
    Remove-Item Env:\W32T_PR_FILE -ErrorAction SilentlyContinue

    # -- fake packages ----------------------------------------------------------------------------
    # A stub deploy script: records PID, bitness, args and working directory, then exits with a fixed code.
    $stubTemplate = @'
param([string]$DeploymentType = 'Install', [string]$DeployMode = '')
$rec = New-Object psobject -Property @{ Pid = $PID; Is64 = [Environment]::Is64BitProcess; Type = $DeploymentType; Mode = $DeployMode; Cwd = (Get-Location).Path }
($rec | ConvertTo-Json -Compress) | Add-Content -LiteralPath (Join-Path $PSScriptRoot 'rec.txt') -Encoding UTF8
exit __CODE__
'@
    function NewFakePackage([string]$Name, [int]$Code) {
        $d = Join-Path $root $Name
        New-Item -ItemType Directory -Path (Join-Path $d 'Sandbox') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $d 'Invoke-AppDeployToolkit.ps1'), $stubTemplate.Replace('__CODE__', [string]$Code), $utf8Bom)
        Copy-Item -LiteralPath $runnerA -Destination (Join-Path $d 'Sandbox\Invoke-PsadtPackage.ps1') -Force
        $d
    }
    function Get-Rec([string]$Pkg) {
        $f = Join-Path $Pkg 'rec.txt'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        @(Get-Content -LiteralPath $f | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    function Get-ExitCodeLogLine([string]$Pkg) {
        $f = Join-Path $Pkg 'Sandbox\Logs\PsadtExitCodes.log'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        @(Get-Content -LiteralPath $f | Where-Object { $_ })
    }
    # Runs the runner in a child Windows PowerShell; returns its exit code.
    function Invoke-Runner([string]$Pkg, [string[]]$RunnerArgs, [string]$Shell = $ps51) {
        & $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Pkg 'Sandbox\Invoke-PsadtPackage.ps1') @RunnerArgs | Out-Null
        $LASTEXITCODE
    }

    # == [2] direct mode =========================================================================
    Write-Host '[2] direct mode: own 64-bit child, exact exit code, log line' -ForegroundColor Cyan
    $pkgA = NewFakePackage 'pkg A' 3010
    $rc = Invoke-Runner $pkgA @('-Path', (Join-Path $pkgA 'Invoke-AppDeployToolkit.ps1'), '-DeploymentType', 'Install', '-Label', 'app')
    $rec = @(Get-Rec $pkgA)
    if ($rc -eq 3010) { Ok 'runner exit code = the stub''s exact 3010' } else { Bad "rc=$rc" }
    if ($rec.Count -eq 1 -and $rec[0].Is64 -eq $true) { Ok 'the package ran in a 64-bit Windows PowerShell child' } else { Bad "rec=$($rec | ConvertTo-Json -Compress)" }
    if ($rec.Count -eq 1 -and $rec[0].Type -eq 'Install' -and $rec[0].Mode -eq '') { Ok 'watched default: -DeploymentType Install, no -DeployMode (PSADT Auto)' } else { Bad "args: $($rec | ConvertTo-Json -Compress)" }
    if ($rec.Count -eq 1 -and $rec[0].Cwd.TrimEnd('\') -eq $pkgA.TrimEnd('\')) { Ok 'working directory = the package folder (path with a space, quoted for 5.1)' } else { Bad "cwd=$($rec[0].Cwd)" }
    $log = @(Get-ExitCodeLogLine $pkgA)
    if ($log.Count -eq 1 -and $log[0] -match '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)Z\] app Install parent=x64-direct exit=3010 result=SoftReboot$') { Ok "log: '$($log[0])'" } else { Bad "log: $($log -join ' / ')" }
    # UTC with a 'Z' (test campaign 2026-10-21), so the guest lines and the host's run marker read in order.
    if ($log.Count -eq 1 -and $log[0] -match '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)Z\]' -and
        [Math]::Abs(([datetime]::UtcNow - [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)).TotalSeconds) -lt 300) { Ok 'the exit-code line time is UTC' } else { Bad "log time: $($log -join ' / ') vs UtcNow $([datetime]::UtcNow)" }

    $rc = Invoke-Runner $pkgA @('-Path', (Join-Path $pkgA 'Invoke-AppDeployToolkit.ps1'), '-DeploymentType', 'Uninstall', '-DeployMode', 'Silent', '-Label', 'app')
    $rec = @(Get-Rec $pkgA)
    if ($rc -eq 3010 -and $rec[-1].Type -eq 'Uninstall' -and $rec[-1].Mode -eq 'Silent') { Ok '-DeploymentType Uninstall -DeployMode Silent passed through' } else { Bad "rc=$rc rec=$($rec[-1] | ConvertTo-Json -Compress)" }
    $rc = Invoke-Runner $pkgA @('-Path', (Join-Path $pkgA 'Invoke-AppDeployToolkit.ps1'), '-DeployMode', '', '-Label', 'app')
    if ($rc -eq 3010 -and (@(Get-Rec $pkgA)[-1].Mode -eq '')) { Ok "-DeployMode '' binds (= Auto, nothing passed)" } else { Bad "rc=$rc" }
    $log = @(Get-ExitCodeLogLine $pkgA)
    if ($log.Count -eq 3 -and $log[1] -match 'app Uninstall parent=x64-direct exit=3010 result=SoftReboot$') { Ok 'one log line per run, in order' } else { Bad "log: $($log -join ' / ')" }

    if (Test-Path -LiteralPath $ps32) {
        $rc = Invoke-Runner $pkgA @('-Path', (Join-Path $pkgA 'Invoke-AppDeployToolkit.ps1'), '-Label', 'from32') $ps32
        $last = @(Get-Rec $pkgA)[-1]
        if ($rc -eq 3010 -and $last.Is64 -eq $true) { Ok 'from a 32-bit parent the package still runs 64-bit (Sysnative)' } else { Bad "rc=$rc is64=$($last.Is64)" }
    } else { Write-Host '  SKIP: no SysWOW64 Windows PowerShell (32-bit parent case)' -ForegroundColor DarkYellow }

    # == [3] Intune parity =======================================================================
    Write-Host '[3] -IntuneParity: published command line from a 32-bit cmd.exe parent' -ForegroundColor Cyan
    $pkgP = NewFakePackage 'pkg P' 0
    # A stub LAUNCHER (stands in for Invoke-AppDeployToolkit.exe): records the cmd bitness, cwd and args.
    $launcher = "@echo off`r`n>>`"%~dp0parity.txt`" echo %PROCESSOR_ARCHITECTURE%^|%CD%^|%*`r`nexit /b 1641`r`n"
    [System.IO.File]::WriteAllText((Join-Path $pkgP 'stub-launcher.cmd'), $launcher, (New-Object System.Text.ASCIIEncoding))
    $testCl = [ordered]@{ Install = 'stub-launcher.cmd -DeploymentType Install'; Uninstall = 'stub-launcher.cmd -DeploymentType Uninstall'; Launcher = 'stub-launcher.cmd'; Script = 'Invoke-AppDeployToolkit.ps1' }
    [System.IO.File]::WriteAllText((Join-Path $pkgP 'Sandbox\IntuneCommandLine.json'), ($testCl | ConvertTo-Json), $utf8NoBom)
    # The host may set NoDefaultCurrentDirectoryInExePath (this one does): the child inherits it, and the
    # runner must clear it or 'cmd /c <bare name>' cannot find the launcher in the package folder.
    $prevNdc = $env:NoDefaultCurrentDirectoryInExePath
    $env:NoDefaultCurrentDirectoryInExePath = '1'
    try {
        $rcI = Invoke-Runner $pkgP @('-Path', (Join-Path $pkgP 'Invoke-AppDeployToolkit.ps1'), '-IntuneParity', '-DeploymentType', 'Install', '-Label', 'app')
        $rcU = Invoke-Runner $pkgP @('-Path', (Join-Path $pkgP 'Invoke-AppDeployToolkit.ps1'), '-IntuneParity', '-DeploymentType', 'Uninstall', '-Label', 'app')
    } finally { $env:NoDefaultCurrentDirectoryInExePath = $prevNdc }
    $par = @(if (Test-Path -LiteralPath (Join-Path $pkgP 'parity.txt')) { Get-Content -LiteralPath (Join-Path $pkgP 'parity.txt') | Where-Object { $_ } })
    if ($rcI -eq 1641 -and $rcU -eq 1641) { Ok 'runner exit code = the launcher''s exact 1641 (install and uninstall)' } else { Bad "rcI=$rcI rcU=$rcU" }
    if ($par.Count -eq 2 -and $par[0] -like 'x86|*') { Ok 'launcher ran under a 32-bit cmd.exe (PROCESSOR_ARCHITECTURE=x86), like the IME' } else { Bad "parity: $($par -join ' / ')" }
    if ($par.Count -eq 2 -and ($par[0] -split '\|')[1].TrimEnd('\') -eq $pkgP.TrimEnd('\')) { Ok 'launcher ran from the package folder (bare name resolved there)' } else { Bad "parity: $($par -join ' / ')" }
    if ($par.Count -eq 2 -and ($par[0] -split '\|')[2] -eq '-DeploymentType Install' -and ($par[1] -split '\|')[2] -eq '-DeploymentType Uninstall') { Ok 'exactly the published command line (from the data file), no -DeployMode' } else { Bad "parity: $($par -join ' / ')" }
    if (@(Get-Rec $pkgP).Count -eq 0) { Ok 'the .ps1 was NOT run directly in parity mode' } else { Bad 'parity mode ran the deploy script directly' }
    $logP = @(Get-ExitCodeLogLine $pkgP)
    if ($logP.Count -eq 2 -and $logP[0] -match 'app Install parent=x86-cmd exit=1641 result=HardReboot$' -and $logP[1] -match 'app Uninstall parent=x86-cmd exit=1641 result=HardReboot$') { Ok 'log: parent=x86-cmd exit=1641 result=HardReboot' } else { Bad "log: $($logP -join ' / ')" }

    # == [4] parity without a command line =======================================================
    Write-Host '[4] -IntuneParity without a command line -> exit 87, result=Failed parent=none (never a false Success)' -ForegroundColor Cyan
    $rcR = Invoke-Runner $pkgP @('-Path', (Join-Path $pkgP 'Invoke-AppDeployToolkit.ps1'), '-IntuneParity', '-DeploymentType', 'Repair', '-Label', 'app')
    $logP = @(Get-ExitCodeLogLine $pkgP)
    if ($rcR -eq 87 -and $logP[-1] -match 'app Repair parent=none exit=87 result=Failed') { Ok 'Repair (not in the contract) -> 87 + Failed line' } else { Bad "rc=$rcR log=$($logP[-1])" }
    $noUn = [ordered]@{ Install = 'stub-launcher.cmd -DeploymentType Install' }
    [System.IO.File]::WriteAllText((Join-Path $pkgP 'Sandbox\IntuneCommandLine.json'), ($noUn | ConvertTo-Json), $utf8NoBom)
    $rcN = Invoke-Runner $pkgP @('-Path', (Join-Path $pkgP 'Invoke-AppDeployToolkit.ps1'), '-IntuneParity', '-DeploymentType', 'Uninstall', '-Label', 'app')
    $logP = @(Get-ExitCodeLogLine $pkgP)
    if ($rcN -eq 87 -and $logP[-1] -match 'app Uninstall parent=none exit=87 result=Failed') { Ok 'JSON without the Uninstall key -> 87 + Failed line' } else { Bad "rc=$rcN log=$($logP[-1])" }
    Remove-Item -LiteralPath (Join-Path $pkgP 'Sandbox\IntuneCommandLine.json') -Force
    $rcM = Invoke-Runner $pkgP @('-Path', (Join-Path $pkgP 'Invoke-AppDeployToolkit.ps1'), '-IntuneParity', '-DeploymentType', 'Install', '-Label', 'app')
    $logP = @(Get-ExitCodeLogLine $pkgP)
    if ($rcM -eq 87 -and $logP[-1] -match 'app Install parent=none exit=87 result=Failed') { Ok 'missing IntuneCommandLine.json -> 87 + Failed line' } else { Bad "rc=$rcM log=$($logP[-1])" }
    $parAfter = @(Get-Content -LiteralPath (Join-Path $pkgP 'parity.txt') | Where-Object { $_ })
    if ($parAfter.Count -eq 2) { Ok 'the launcher never ran for the three 87 cases' } else { Bad "launcher ran $($parAfter.Count) times" }

    # == [5] process isolation ===================================================================
    Write-Host '[5] two runs back to back from ONE parent shell -> two distinct child processes' -ForegroundColor Cyan
    $pkg1 = NewFakePackage 'iso one' 3010
    $pkg2 = NewFakePackage 'iso two' 0
    $parentScript = Join-Path $root 'parent.ps1'
    $parentText = @'
param([string]$Runner, [string]$P1, [string]$P2)
& $Runner -Path $P1 -DeployMode Silent -Label first
$a = $LASTEXITCODE
& $Runner -Path $P2 -DeployMode Silent -Label second
$b = $LASTEXITCODE
'PARENT=' + $PID + ';A=' + $a + ';B=' + $b
'@
    [System.IO.File]::WriteAllText($parentScript, $parentText, $utf8Bom)
    $out = (& $ps51 -NoProfile -ExecutionPolicy Bypass -File $parentScript -Runner (Join-Path $pkg1 'Sandbox\Invoke-PsadtPackage.ps1') -P1 (Join-Path $pkg1 'Invoke-AppDeployToolkit.ps1') -P2 (Join-Path $pkg2 'Invoke-AppDeployToolkit.ps1') | Out-String).Trim()
    $m = [regex]::Match($out, 'PARENT=(\d+);A=(-?\d+);B=(-?\d+)')
    $r1 = @(Get-Rec $pkg1); $r2 = @(Get-Rec $pkg2)
    if ($m.Success -and $m.Groups[2].Value -eq '3010' -and $m.Groups[3].Value -eq '0') { Ok 'the parent shell saw both exact exit codes (3010, then 0) and kept running' } else { Bad "parent out: $out" }
    if ($r1.Count -eq 1 -and $r2.Count -eq 1 -and $r1[0].Pid -ne $r2[0].Pid) { Ok "two DISTINCT child PIDs ($($r1[0].Pid), $($r2[0].Pid))" } else { Bad "pids: $($r1.Pid) / $($r2.Pid)" }
    if ($m.Success -and $r1.Count -eq 1 -and $r2.Count -eq 1 -and "$($r1[0].Pid)" -ne $m.Groups[1].Value -and "$($r2[0].Pid)" -ne $m.Groups[1].Value) { Ok "neither package ran in the parent shell (PID $($m.Groups[1].Value))" } else { Bad "parent=$($m.Groups[1].Value) children=$($r1.Pid),$($r2.Pid)" }
    $l1 = @(Get-ExitCodeLogLine $pkg1)
    if ($l1.Count -eq 2 -and $l1[0] -match 'first Install parent=x64-direct exit=3010 result=SoftReboot$' -and $l1[1] -match 'second Install parent=x64-direct exit=0 result=Success$') { Ok 'both exit codes logged, in order' } else { Bad "log: $($l1 -join ' / ')" }

    # == [6] timeout =============================================================================
    Write-Host '[6] timeout: the process TREE is killed -> exit 1460, result=Timeout (about 1 minute)' -ForegroundColor Cyan
    $pkgT = NewFakePackage 'hang' 0
    $hang = @'
param([string]$DeploymentType = 'Install', [string]$DeployMode = '')
$kid = Start-Process -FilePath (Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 600' -WindowStyle Hidden -PassThru
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'pids.txt') -Value @($PID, $kid.Id) -Encoding ASCII
Start-Sleep -Seconds 600
exit 0
'@
    [System.IO.File]::WriteAllText((Join-Path $pkgT 'Invoke-AppDeployToolkit.ps1'), $hang, $utf8Bom)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rcT = Invoke-Runner $pkgT @('-Path', (Join-Path $pkgT 'Invoke-AppDeployToolkit.ps1'), '-DeployMode', 'Silent', '-Label', 'app', '-TimeoutMinutes', '1')
    $sw.Stop()
    $pidsT = @()
    if (Test-Path -LiteralPath (Join-Path $pkgT 'pids.txt')) { $pidsT = @(Get-Content -LiteralPath (Join-Path $pkgT 'pids.txt') | Where-Object { $_ } | ForEach-Object { [int]$_ }) }
    foreach ($x in $pidsT) { $spawned.Add($x) }
    if ($rcT -eq 1460) { Ok "runner exit code 1460 after $([math]::Round($sw.Elapsed.TotalSeconds)) s" } else { Bad "rc=$rcT" }
    $logT = @(Get-ExitCodeLogLine $pkgT)
    if ($logT.Count -eq 1 -and $logT[0] -match 'app Install parent=x64-direct exit=1460 result=Timeout$') { Ok 'log: exit=1460 result=Timeout' } else { Bad "log: $($logT -join ' / ')" }
    $alive = @()
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $alive = @($pidsT | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($alive.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } until ((Get-Date) -gt $deadline)
    if ($pidsT.Count -eq 2 -and $alive.Count -eq 0) { Ok 'the stub AND its child process are gone (taskkill /T /F)' } else { Bad "pids=$($pidsT -join ',') still alive=$($alive -join ',')" }
}
}
finally {
    foreach ($x in $spawned) { Stop-Process -Id $x -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PackageRunner tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PackageRunner test(s) FAILED." -ForegroundColor Red; exit 1 }
