<#
    Unit tests for dependency STAGING — making the test/capture guest install declared dependencies
    BEFORE the app, exactly as Intune does on a real device.

    winget download and the project copy are shadowed; nothing hits the network.

    Run:  pwsh -File Tests\DependencyStaging.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitDependencyRef.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitDependencies.ps1')
. (Join-Path $repo 'Public\Set-Win32ToolkitAppDependency.ps1')
. (Join-Path $repo 'Private\Initialize-Win32ToolkitDependencyStaging.ps1')

$VC = 'Microsoft.VCRedist.2015+.x64'

# --- shadows --------------------------------------------------------------------------------------
$script:downloaded = @()
function Download-OldVersionInstaller {
    param($AppId, $Version, $ProjectPath, $Architecture, $Scope, $InstallerType, $Locale, $DestinationDir)
    $script:downloaded += [pscustomobject]@{ AppId = $AppId; Version = $Version; Dest = $DestinationDir }
    Set-Content -LiteralPath (Join-Path $DestinationDir 'vc_redist.x64.exe') -Value 'exe'
    [pscustomobject]@{ InstallerName = 'vc_redist.x64.exe'; InstallerType = 'exe'; SilentArgs = '/install /quiet /norestart' }
}

# Every temp folder is registered here and removed at the end, pass or fail (test campaign 2026-10-21, H7-F12).
$script:tmp = [System.Collections.Generic.List[string]]::new()
function New-TempPath([string]$Prefix) { $p = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N').Substring(0, 8)); $script:tmp.Add($p); $p }

function New-Proj {
    $root = New-TempPath 'w32ds_'
    $p    = Join-Path $root 'Contoso\Notepad_x64_8.6'
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force | Out-Null
    $p
}

try {
    Write-Host '[1] no dependencies declared -> stages nothing (regression contract)' -ForegroundColor Cyan
    $p0 = New-Proj
    $n = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p0
    if ($n -eq 0 -and -not (Test-Path (Join-Path $p0 'Sandbox\InstallDependencies.ps1'))) { Ok 'no staging, no guest script' } else { Bad "n=$n" }

    Write-Host '[2] winget dep -> installer downloaded + data manifest + value-free guest script' -ForegroundColor Cyan
    $p1 = New-Proj
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p1 -DependsOn "winget:$VC"
    $script:downloaded = @()
    $n = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p1 6>$null
    $script1 = Join-Path $p1 'Sandbox\InstallDependencies.ps1'
    $man     = Join-Path $p1 'Sandbox\Dependencies\dependencies.json'

    if ($n -eq 1) { Ok 'one dependency staged' } else { Bad "n=$n" }
    if ($script:downloaded.Count -eq 1 -and $script:downloaded[0].AppId -eq $VC) { Ok "winget id passed VERBATIM ('+'/'.' intact)" } else { Bad ($script:downloaded | Out-String) }
    if (-not $script:downloaded[0].Version) { Ok 'no -Version => latest (any version satisfies a dependency)' } else { Bad "pinned v$($script:downloaded[0].Version)" }
    if (Test-Path $man) { Ok 'dependencies.json written' } else { Bad 'no manifest' }

    $entries = Get-Content -LiteralPath $man -Raw | ConvertFrom-Json
    if ($entries[0].SilentArgs -eq '/install /quiet /norestart' -and $entries[0].Path -like 'C:\PSADT\Sandbox\Dependencies\*') { Ok 'silent args + guest path stored as DATA' } else { Bad ($entries | Out-String) }

    $guest = Get-Content -LiteralPath $script1 -Raw
    if ($guest -notmatch [regex]::Escape('/install /quiet /norestart') -and $guest -notmatch [regex]::Escape($VC)) {
        Ok 'guest script is VALUE-FREE (no untrusted value spliced into code)'
    } else { Bad 'untrusted value spliced into the generated script' }
    $b = [System.IO.File]::ReadAllBytes($script1)
    if ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { Ok 'guest script written UTF-8 WITH BOM (5.1-safe)' } else { Bad 'no BOM' }
    $perr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($guest, [ref]$null, [ref]$perr)
    if (-not $perr) { Ok 'guest script parses' } else { Bad $perr[0].Message }

    Write-Host '[3] project dep -> the packaged project is copied in and installed via its own PSADT' -ForegroundColor Cyan
    $p2 = New-Proj
    # a fake packaged dependency project under the SAME Projects root the stager resolves from
    $projectsRoot = Split-Path -Parent (Split-Path -Parent $p2)
    $depProj = Join-Path $projectsRoot 'Contoso\VCRedist_x64_14.38'
    New-Item -ItemType Directory -Path $depProj -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $depProj 'Invoke-AppDeployToolkit.ps1') -Value '# psadt'
    function Get-Win32ToolkitBasePath { param($BasePath, [switch]$NonInteractive) 'IGNORED' }
    function Get-Win32ToolkitPaths { param($BasePath) [pscustomobject]@{ Projects = $projectsRoot } }

    $null = Set-Win32ToolkitAppDependency -ProjectPath $p2 -DependsOn 'project:Contoso\VCRedist_x64_14.38'
    $n = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p2 6>$null
    $man2 = Join-Path $p2 'Sandbox\Dependencies\dependencies.json'
    $e2 = @(Get-Content -LiteralPath $man2 -Raw | ConvertFrom-Json)
    if ($n -eq 1 -and $e2[0].Type -eq 'psadt' -and $e2[0].Path -eq 'C:\PSADT\Sandbox\Dependencies\VCRedist_x64_14.38\Invoke-AppDeployToolkit.ps1') {
        Ok 'project dep staged; installs via its own PSADT silently'
    } else { Bad ($e2 | Out-String) }
    if (Test-Path (Join-Path $p2 'Sandbox\Dependencies\VCRedist_x64_14.38\Invoke-AppDeployToolkit.ps1')) { Ok 'dependency package copied into the project' } else { Bad 'not copied' }

    Write-Host '[4] re-staging is clean (a removed dependency does not linger in the guest)' -ForegroundColor Cyan
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p2 -Clear
    $n = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p2
    if ($n -eq 0 -and -not (Test-Path (Join-Path $p2 'Sandbox\Dependencies'))) { Ok 'stale staging removed' } else { Bad 'stale dependency left staged' }

    Write-Host '[5] intune: dep cannot be staged -> warns, stages nothing (relationship still made at publish)' -ForegroundColor Cyan
    $p3 = New-Proj
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p3 -DependsOn 'intune:8d0a1f2c-1111-2222-3333-444455556666'
    $n = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p3 -WarningAction SilentlyContinue
    if ($n -eq 0) { Ok 'intune-only dep is not stageable (warned)' } else { Bad "n=$n" }

    Write-Host '[6] the guest script runs each packaged dependency in its OWN Windows PowerShell process' -ForegroundColor Cyan
    # (source checks on the generated, value-free script; [7] executes it)
    $g6 = $guest
    if ($g6 -match "Start-Process -FilePath \`$ps -ArgumentList @\('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', \('""' \+ \`$d\.Path \+ '""'\), '-DeploymentType', 'Install', '-DeployMode', 'Silent'\) -WorkingDirectory \(Split-Path -Parent \`$d\.Path\) -PassThru") { Ok 'psadt dependency = Start-Process powershell.exe -File "<quoted path>" -DeploymentType Install -DeployMode Silent, cwd = its folder (bounded wait below)' } else { Bad 'Start-Process child launch not found' }
    if ($g6 -match [regex]::Escape("Join-Path `$env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'")) { Ok 'child = the System32 Windows PowerShell (full path)' } else { Bad 'powershell.exe path not absolute' }
    if ($g6 -notmatch '& \$d\.Path') { Ok 'no in-process "& $d.Path" call left' } else { Bad 'dependency still dot-called in-process' }
    if ($g6 -match '\$okCodes = @\(0, 1707, 3010, 1641\)' -and $g6 -match '\$okCodes -notcontains \$rc') { Ok 'success = 0, 1707, 3010, 1641' } else { Bad 'success codes wrong' }

    Write-Host '[7] two project: dependencies -> two psadt entries, EXECUTED under 5.1: separate processes, exact codes' -ForegroundColor Cyan
    # A Projects root WITH A SPACE, so the quoted -File path is exercised for real.
    $spRoot = New-TempPath 'w32ds sp_'
    $spProjects = Join-Path $spRoot 'Projects'
    $p7 = Join-Path $spProjects 'Contoso\App_x64_1.0'
    New-Item -ItemType Directory -Path (Join-Path $p7 'SupportFiles') -Force | Out-Null
    foreach ($dn in 'DepOne_x64_1.0', 'DepTwo_x64_2.0') {
        $dp = Join-Path $spProjects "Contoso\$dn"
        New-Item -ItemType Directory -Path $dp -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dp 'Invoke-AppDeployToolkit.ps1') -Value '# psadt'
    }
    $projectsRoot = $spProjects   # the [3] Get-Win32ToolkitPaths double resolves Projects from this at call time
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p7 -DependsOn 'project:Contoso\DepOne_x64_1.0'
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p7 -DependsOn 'project:Contoso\DepTwo_x64_2.0'
    $n7 = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p7 6>$null
    $man7 = Join-Path $p7 'Sandbox\Dependencies\dependencies.json'
    $e7 = @(Get-Content -LiteralPath $man7 -Raw | ConvertFrom-Json)
    if ($n7 -eq 2 -and $e7.Count -eq 2 -and @($e7 | Where-Object { $_.Type -eq 'psadt' }).Count -eq 2 -and $e7[0].Name -eq 'Contoso\DepOne_x64_1.0' -and $e7[1].Name -eq 'Contoso\DepTwo_x64_2.0') { Ok 'dependencies.json holds the two psadt entries, in declared order' } else { Bad ($e7 | Out-String) }

    $ps51 = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51)) { Write-Host '  SKIP: Windows PowerShell 5.1 not present for the execution check' -ForegroundColor DarkYellow }
    else {
        $stubText = @'
param([string]$DeploymentType = '', [string]$DeployMode = '')
(($PID, $DeploymentType, $DeployMode, (Get-Location).Path) -join '|') | Add-Content -LiteralPath (Join-Path $PSScriptRoot 'rec.txt') -Encoding UTF8
exit __CODE__
'@
        $stage = @{}
        foreach ($dn in 'DepOne_x64_1.0', 'DepTwo_x64_2.0') { $stage[$dn] = Join-Path $p7 "Sandbox\Dependencies\$dn" }
        function SetStub([string]$Dir, [int]$Code) {
            [System.IO.File]::WriteAllText((Join-Path $Dir 'Invoke-AppDeployToolkit.ps1'), $stubText.Replace('__CODE__', [string]$Code), (New-Object System.Text.UTF8Encoding($true)))
            Remove-Item -LiteralPath (Join-Path $Dir 'rec.txt') -Force -ErrorAction SilentlyContinue
        }
        function Get-StubRec([string]$Dir) { $f = Join-Path $Dir 'rec.txt'; if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f | Where-Object { $_ }) } else { @() } }
        # TEST-ONLY: the manifest DATA points at the staged host copies, and the script copy's single
        # '$manifest = ...' line points at that manifest. Nothing else in the generated script is touched.
        $tmpMan = Join-Path $p7 'Sandbox\test-dependencies.json'
        $data = @($e7 | ForEach-Object { $_.Path = $_.Path.Replace('C:\PSADT', $p7); $_ })
        [System.IO.File]::WriteAllText($tmpMan, (ConvertTo-Json -InputObject $data -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        $genText = [System.IO.File]::ReadAllText((Join-Path $p7 'Sandbox\InstallDependencies.ps1'))
        $manLine = [regex]::Match($genText, "(?m)^\`$manifest = 'C:\\PSADT\\[^']*'\r?$")
        $copyText = $genText.Substring(0, $manLine.Index) + "`$manifest = '" + $tmpMan.Replace("'", "''") + "'" + $genText.Substring($manLine.Index + $manLine.Value.TrimEnd("`r").Length)
        $diffLines = @(Compare-Object ($genText -split "`r?`n") ($copyText -split "`r?`n"))
        if ($manLine.Success -and $diffLines.Count -eq 2) { Ok 'test copy differs from the generated script ONLY in the $manifest line' } else { Bad "manifest line edit: success=$($manLine.Success) diff=$($diffLines.Count)" }
        $copyPath = Join-Path $p7 'Sandbox\InstallDependencies.test.ps1'
        [System.IO.File]::WriteAllText($copyPath, $copyText, (New-Object System.Text.UTF8Encoding($true)))
        $depLog = Join-Path $p7 'Sandbox\Logs\PsadtExitCodes.log'
        function Get-DepLine { if (Test-Path -LiteralPath $depLog) { @(Get-Content -LiteralPath $depLog | Where-Object { $_ }) } else { @() } }
        function Invoke-Guest {
            Remove-Item -LiteralPath $depLog -Force -ErrorAction SilentlyContinue
            $o = Join-Path $spRoot 'guest.out.txt'
            $gp = Start-Process -FilePath $ps51 -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $copyPath + '"')) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o
            [pscustomobject]@{ Pid = $gp.Id; Exit = $gp.ExitCode }
        }

        SetStub $stage['DepOne_x64_1.0'] 0
        SetStub $stage['DepTwo_x64_2.0'] 3010
        $g = Invoke-Guest
        $r1 = @(Get-StubRec $stage['DepOne_x64_1.0']); $r2 = @(Get-StubRec $stage['DepTwo_x64_2.0'])
        if ($g.Exit -eq 0) { Ok 'stubs exit 0 / 3010 -> guest exits 0' } else { Bad "guest exit=$($g.Exit)" }
        if ($r1.Count -eq 1 -and $r2.Count -eq 1) {
            $f1 = $r1[0] -split '\|'; $f2 = $r2[0] -split '\|'
            if ($f1[0] -ne $f2[0]) { Ok "two DISTINCT dependency PIDs ($($f1[0]), $($f2[0]))" } else { Bad "same PID $($f1[0]) - not isolated" }
            if ($f1[0] -ne "$($g.Pid)" -and $f2[0] -ne "$($g.Pid)") { Ok "neither ran in the guest script's process (PID $($g.Pid))" } else { Bad "a dependency ran in the guest process ($($g.Pid))" }
            if ($f1[1] -eq 'Install' -and $f1[2] -eq 'Silent' -and $f2[1] -eq 'Install' -and $f2[2] -eq 'Silent') { Ok 'each child got -DeploymentType Install -DeployMode Silent' } else { Bad "args: $($r1[0]) / $($r2[0])" }
            if ($f1[3].TrimEnd('\') -eq $stage['DepOne_x64_1.0'] -and $f2[3].TrimEnd('\') -eq $stage['DepTwo_x64_2.0']) { Ok 'working directory = each dependency''s own folder (path with a space)' } else { Bad "cwd: $($f1[3]) / $($f2[3])" }
        } else { Bad "stub records: one=$($r1.Count) two=$($r2.Count)" }
        # Each result lands in Sandbox\Logs\PsadtExitCodes.log in the runner's format (test campaign 2026-10-21, S11-F2).
        $dl = @(Get-DepLine)
        if ($dl.Count -eq 2 -and $dl[0] -match '^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\dZ\] dep:Contoso_DepOne_x64_1\.0 Install parent=x64-direct exit=0 result=Success$' -and
            $dl[1] -match '^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\dZ\] dep:Contoso_DepTwo_x64_2\.0 Install parent=x64-direct exit=3010 result=SoftReboot$') { Ok "exit codes logged: '$($dl[0])' / '$($dl[1])'" } else { Bad "dep lines: $($dl -join ' | ')" }

        SetStub $stage['DepOne_x64_1.0'] 0
        SetStub $stage['DepTwo_x64_2.0'] 60008
        $g = Invoke-Guest
        $r1 = @(Get-StubRec $stage['DepOne_x64_1.0']); $r2 = @(Get-StubRec $stage['DepTwo_x64_2.0'])
        if ($g.Exit -eq 60008) { Ok 'second dependency exits 60008 -> guest exits 60008 (exact code propagated)' } else { Bad "guest exit=$($g.Exit)" }
        if ($r1.Count -eq 1 -and $r2.Count -eq 1) { Ok 'the first dependency ran before the failing second one' } else { Bad "records one=$($r1.Count) two=$($r2.Count)" }
        $dl = @(Get-DepLine)
        if ($dl.Count -eq 2 -and $dl[1] -match 'dep:Contoso_DepTwo_x64_2\.0 Install parent=x64-direct exit=60008 result=Failed$') { Ok 'the failing dependency is logged with exit=60008 result=Failed' } else { Bad "dep lines: $($dl -join ' | ')" }

        SetStub $stage['DepOne_x64_1.0'] 1603
        SetStub $stage['DepTwo_x64_2.0'] 0
        $g = Invoke-Guest
        if ($g.Exit -eq 1603 -and @(Get-StubRec $stage['DepTwo_x64_2.0']).Count -eq 0) { Ok 'a failing first dependency stops the chain with its code (1603); the second never runs' } else { Bad "guest exit=$($g.Exit)" }
        $dl = @(Get-DepLine)
        if ($dl.Count -eq 1 -and $dl[0] -match 'dep:Contoso_DepOne_x64_1\.0 Install parent=x64-direct exit=1603 result=Failed$') { Ok 'only the failing first dependency is logged (1603)' } else { Bad "dep lines: $($dl -join ' | ')" }
        $genNow = [System.IO.File]::ReadAllText((Join-Path $p7 'Sandbox\InstallDependencies.ps1'))
        if ($genNow -match 'WaitForExit\(\$timeoutMs\)' -and $genNow -match '\$timeoutMs = 25 \* 60000' -and $genNow -match '\$rc = 1460' -and $genNow -notmatch '-Wait -PassThru') { Ok 'each dependency is bounded by the runner''s 25-minute limit (1460 = Timeout); no unbounded -Wait' } else { Bad 'dependency installs are not bounded' }
    }

    Write-Host '[8] staging reuse is tied to the generator template (an old build''s guest script is never reused)' -ForegroundColor Cyan
    # The host-side marker cache is enabled ONLY from here on (earlier sections ran with no cache root).
    $cache8 = New-TempPath 'w32ds_cache_'
    New-Item -ItemType Directory -Path $cache8 -Force | Out-Null
    function Get-Win32ToolkitPipelineCacheRoot { $cache8 }
    $p8 = New-Proj
    $s8 = Join-Path $p8 'Sandbox\InstallDependencies.ps1'
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p8 -DependsOn "winget:$VC"
    $script:downloaded = @()
    $n8 = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p8 6>$null
    $current8 = [System.IO.File]::ReadAllBytes($s8)
    $marks8 = @(Get-ChildItem -LiteralPath (Join-Path $cache8 'staging') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($n8 -eq 1 -and $script:downloaded.Count -eq 1 -and $marks8.Count -eq 1) { Ok 'first call stages (one download) and records a host-side marker' } else { Bad "n=$n8 downloads=$($script:downloaded.Count) markers=$($marks8.Count)" }

    $n8 = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p8 6>$null
    if ($n8 -eq 1 -and $script:downloaded.Count -eq 1) { Ok 'unchanged staging + current template -> reused (no second download)' } else { Bad "n=$n8 downloads=$($script:downloaded.Count)" }

    # What an OLDER build leaves behind: the same staged payload, but its own guest script (packaged
    # dependencies dot-called in-process, only 0/3010 accepted), and a marker that is CONSISTENT with that
    # tree (the old build hashed its own script). Every pre-existing reuse check passes on this state.
    $oldGuest = @'
# InstallDependencies.ps1 as written by an older win32-toolkit build
$ErrorActionPreference = 'Stop'
$deps = Get-Content -LiteralPath 'C:\PSADT\Sandbox\Dependencies\dependencies.json' -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($d in @($deps)) {
    $rc = 0
    if ($d.Type -eq 'psadt') { & $d.Path -DeploymentType Install -DeployMode Silent; $rc = $LASTEXITCODE }
    if (@(0, 3010) -notcontains $rc) { exit $rc }
}
exit 0
'@
    [System.IO.File]::WriteAllText($s8, $oldGuest, (New-Object System.Text.UTF8Encoding($true)))
    $oldSha = (Get-FileHash -LiteralPath $s8 -Algorithm SHA256).Hash
    $mark8 = Get-Content -LiteralPath $marks8[0].FullName -Raw | ConvertFrom-Json
    $entry8 = @($mark8.Files | Where-Object { $_.Path -eq 'Sandbox\InstallDependencies.ps1' })
    if ($entry8.Count -eq 1) { $entry8[0].Sha256 = $oldSha } else { Bad "marker has $($entry8.Count) script entries" }
    $mark8.StagedAt = (Get-Date).ToString('o')
    [System.IO.File]::WriteAllText($marks8[0].FullName, (ConvertTo-Json -InputObject $mark8 -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

    $n8 = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p8 6>$null
    $after8 = [System.IO.File]::ReadAllBytes($s8)
    if ($n8 -eq 1 -and $script:downloaded.Count -eq 2) { Ok 'old build''s staging (consistent marker, same declared set, < 6 h) -> restaged, not reused' } else { Bad "n=$n8 downloads=$($script:downloaded.Count) (stale staging reused)" }
    if ([System.Linq.Enumerable]::SequenceEqual([byte[]]$after8, [byte[]]$current8)) { Ok 'the guest script is the current template again (BOM, byte-identical to a fresh staging)' } else { Bad 'guest script is not the current template' }
    $t8 = [System.IO.File]::ReadAllText($s8)
    if ($t8 -notmatch '& \$d\.Path' -and $t8 -match '\$okCodes = @\(0, 1707, 3010, 1641\)') { Ok 'no in-process "& $d.Path" call; success = 0, 1707, 3010, 1641' } else { Bad 'old guest script survived' }

    $n8 = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p8 6>$null
    if ($n8 -eq 1 -and $script:downloaded.Count -eq 2) { Ok 'the restaged tree is reused again by the next call' } else { Bad "n=$n8 downloads=$($script:downloaded.Count)" }

    Write-Host '[9] a project: dependency resolves against the caller''s -BasePath, never a prompt (test campaign 2026-10-21, S11-F3)' -ForegroundColor Cyan
    function Get-Win32ToolkitPipelineCacheRoot { $null }   # no reuse marker in this section
    $baseA = New-TempPath 'w32dsA_'   # the registry base
    $baseB = New-TempPath 'w32dsB_'   # the caller's -BasePath
    foreach ($b in $baseA, $baseB) {
        $dp = Join-Path $b 'Projects\Contoso\Tool_x64_1.0'
        New-Item -ItemType Directory -Path $dp -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dp 'Invoke-AppDeployToolkit.ps1') -Value "# psadt from $(Split-Path -Leaf $b)"
    }
    $script:regBase = $baseA
    $script:prompted = $false
    function Get-Win32ToolkitBasePath { param($BasePath, [switch]$NonInteractive)
        if ($BasePath) { return $BasePath }
        if ($script:regBase) { return $script:regBase }
        if ($NonInteractive) { return $null }
        $script:prompted = $true; 'C:\Win32Apps'
    }
    function Get-Win32ToolkitPaths { param($BasePath) [pscustomobject]@{ Projects = (Join-Path $BasePath 'Projects') } }
    $p9 = New-Proj
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p9 -DependsOn 'project:Contoso\Tool_x64_1.0'
    $staged9 = Join-Path $p9 'Sandbox\Dependencies\Tool_x64_1.0\Invoke-AppDeployToolkit.ps1'
    $n9 = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p9 -BasePath $baseB 6>$null
    if ($n9 -eq 1 -and (Get-Content -LiteralPath $staged9 -Raw) -match ([regex]::Escape((Split-Path -Leaf $baseB)))) { Ok '-BasePath B stages B\Projects\<ref> although the registry says A' } else { Bad "n=$n9 staged: $(if (Test-Path $staged9) { Get-Content $staged9 -Raw })" }
    $n9 = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p9 6>$null
    if ($n9 -eq 1 -and (Get-Content -LiteralPath $staged9 -Raw) -match ([regex]::Escape((Split-Path -Leaf $baseA)))) { Ok 'no -BasePath -> the registry base' } else { Bad "n=$n9 staged: $(if (Test-Path $staged9) { Get-Content $staged9 -Raw })" }
    $script:regBase = $null
    $e9 = $null
    try { $null = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p9 6>$null } catch { $e9 = $_ }
    if ($e9 -and $e9.FullyQualifiedErrorId -eq 'W32T.DependencyNotStaged' -and -not $script:prompted -and "$e9" -match "'project:Contoso\\Tool_x64_1\.0' could not be staged: no base folder is configured") { Ok 'no base folder anywhere -> W32T.DependencyNotStaged (S11-F4), never a prompt' } else { Bad "prompted=$($script:prompted) err=$($e9.FullyQualifiedErrorId) $e9" }
    $src9 = Get-Content -LiteralPath (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1') -Raw
    if ($src9 -match "\`$depArgs\['BasePath'\] = \`$BasePath" -and $src9 -match 'Initialize-Win32ToolkitDependencyStaging @depArgs') { Ok 'Test-Win32ToolkitProject passes its -BasePath to the staging (only when bound)' } else { Bad 'Test-Win32ToolkitProject does not pass -BasePath' }

    Write-Host '[10] a winget: or project: dependency that cannot be staged fails closed (test campaign 2026-10-21, S11-F4)' -ForegroundColor Cyan
    $cache10 = New-TempPath 'w32dsC_'
    New-Item -ItemType Directory -Path $cache10 -Force | Out-Null
    function Get-Win32ToolkitPipelineCacheRoot { $cache10 }
    $script:regBase = $baseA
    function Test-NotStaged([string]$Project, [string]$Pattern) {
        $e = $null
        try { $null = Initialize-Win32ToolkitDependencyStaging -ProjectPath $Project 6>$null 3>$null } catch { $e = $_ }
        $left = (Test-Path -LiteralPath (Join-Path $Project 'Sandbox\Dependencies')) -or (Test-Path -LiteralPath (Join-Path $Project 'Sandbox\InstallDependencies.ps1')) -or @(Get-ChildItem -LiteralPath (Join-Path $cache10 'staging') -File -ErrorAction SilentlyContinue).Count -gt 0
        [pscustomobject]@{ Ok = ($e -and $e.FullyQualifiedErrorId -eq 'W32T.DependencyNotStaged' -and "$e" -match $Pattern -and -not $left); Error = "$($e.FullyQualifiedErrorId) $e"; Left = $left }
    }
    # (a) the winget download fails -> no staging, no marker, no dependencies.json
    $p10 = New-Proj
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p10 -DependsOn 'project:Contoso\Tool_x64_1.0', "winget:$VC"
    $dlSaved = ${function:Download-OldVersionInstaller}
    ${function:Download-OldVersionInstaller} = { param($AppId, $Version, $ProjectPath, $Architecture, $Scope, $InstallerType, $Locale, $DestinationDir) throw 'winget download exited with code -1978335114 (0x8A150076)' }
    $r = Test-NotStaged $p10 "'winget:Microsoft\.VCRedist\.2015\+\.x64' could not be staged: the winget download failed \(winget download exited with code -1978335114"
    if ($r.Ok) { Ok 'winget download failure -> W32T.DependencyNotStaged naming the dependency and the reason; nothing left staged, no marker' } else { Bad "winget: $($r.Error) left=$($r.Left)" }
    ${function:Download-OldVersionInstaller} = $dlSaved
    # (b) a project: dependency that does not exist
    $p11 = New-Proj
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p11 -DependsOn 'project:Contoso\DoesNotExist'
    $r = Test-NotStaged $p11 "'project:Contoso\\DoesNotExist' could not be staged: the project was not found"
    if ($r.Ok) { Ok 'missing project: dependency -> W32T.DependencyNotStaged; nothing left staged' } else { Bad "project: $($r.Error) left=$($r.Left)" }
    # The fail-closed path adds ONE error record - the W32T one - and no PathNotFound noise from its own cleanup of
    # files that do not exist (re-verification 2026-10-21, B3 #3: NewGlobalErrors was 3 for 1 throw).
    $Error.Clear(); $ev11 = $null; $e11 = $null
    try { $null = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p11 -ErrorVariable ev11 6>$null 3>$null } catch { $e11 = $_ }
    $noise11 = @(@($ev11) + @($Error) | Where-Object { "$($_.FullyQualifiedErrorId)" -like 'PathNotFound*' })
    if ($e11.FullyQualifiedErrorId -eq 'W32T.DependencyNotStaged' -and $Error.Count -eq 1 -and $noise11.Count -eq 0) { Ok 'the cannot-stage throw leaves exactly one $Error record and no PathNotFound in -ErrorVariable' } else { Bad "`$Error=$($Error.Count) [$(@($Error | ForEach-Object { "$($_.FullyQualifiedErrorId)" }) -join ' | ')] ev=[$(@($ev11 | ForEach-Object { "$($_.FullyQualifiedErrorId)" }) -join ' | ')]" }
    # (c) a reuse marker that recorded fewer dependencies than the stageable set (an older build that warned and went on)
    $p12 = New-Proj
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p12 -DependsOn 'project:Contoso\Tool_x64_1.0', "winget:$VC"
    $script:downloaded = @()
    $n12 = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p12 6>$null
    $mk = @(Get-ChildItem -LiteralPath (Join-Path $cache10 'staging') -File)[0]
    $m = Get-Content -LiteralPath $mk.FullName -Raw | ConvertFrom-Json
    $m.Count = 1
    [System.IO.File]::WriteAllText($mk.FullName, (ConvertTo-Json -InputObject $m -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    $n12b = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p12 6>$null
    if ($n12 -eq 2 -and $n12b -eq 2 -and $script:downloaded.Count -eq 2) { Ok 'a marker with Count 1 for 2 stageable dependencies is not reused (restaged)' } else { Bad "n=$n12/$n12b downloads=$($script:downloaded.Count)" }
    $n12c = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p12 6>$null
    if ($n12c -eq 2 -and $script:downloaded.Count -eq 2) { Ok 'a complete marker is reused as before' } else { Bad "reuse: n=$n12c downloads=$($script:downloaded.Count)" }
    # (d) intune: stays a warning
    $p13 = New-Proj
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p13 -DependsOn 'intune:8d0a1f2c-1111-2222-3333-444455556666'
    $e13 = $null; try { $n13 = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p13 -WarningAction SilentlyContinue 6>$null } catch { $e13 = $_ }
    if (-not $e13 -and $n13 -eq 0) { Ok 'intune: is still only warned about (no package to stage; TODO)' } else { Bad "intune threw: $e13" }

    Write-Host '[11] staging defence in depth: only <Template>\<Name> inside Projects\; same-named projects never share a folder (S11-F5)' -ForegroundColor Cyan
    function Get-Win32ToolkitPipelineCacheRoot { $null }
    # A hand-edited / old AppConfig.json reference that escapes Projects\ (Set-Win32ToolkitAppDependency now refuses it).
    $p14 = New-Proj
    $cfg14 = Get-Win32ToolkitAppConfig -ProjectPath $p14
    $cfg14 | Add-Member -NotePropertyName Dependencies -NotePropertyValue @([pscustomobject]@{ Source = 'project'; Ref = '..\..\Elsewhere\Tool'; DependencyType = 'autoInstall' }) -Force
    $null = Set-Win32ToolkitAppConfig -ProjectPath $p14 -Config $cfg14
    $e14 = $null; try { $null = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p14 6>$null } catch { $e14 = $_ }
    if ($e14 -and $e14.FullyQualifiedErrorId -eq 'W32T.DependencyNotStaged' -and "$e14" -match "is not '<Template>\\<ProjectName>' inside" -and -not (Test-Path -LiteralPath (Join-Path $p14 'Sandbox\Dependencies'))) { Ok "'..\..\Elsewhere\Tool' in AppConfig -> W32T.DependencyNotStaged, nothing copied" } else { Bad "traversal: $($e14.FullyQualifiedErrorId) $e14" }
    # Two dependencies whose project folders share a name: the second is staged under '<Template>_<Name>'.
    foreach ($tpl in 'Contoso', 'Other') {
        $dp = Join-Path $baseA "Projects\$tpl\Tool_x64_1.0"
        New-Item -ItemType Directory -Path $dp -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dp 'Invoke-AppDeployToolkit.ps1') -Value "# psadt $tpl"
    }
    $p15 = New-Proj
    $null = Set-Win32ToolkitAppDependency -ProjectPath $p15 -DependsOn 'project:Contoso\Tool_x64_1.0', 'project:Other\Tool_x64_1.0' -WarningAction SilentlyContinue
    $n15 = Initialize-Win32ToolkitDependencyStaging -ProjectPath $p15 -BasePath $baseA 6>$null
    $e15 = @(Get-Content -LiteralPath (Join-Path $p15 'Sandbox\Dependencies\dependencies.json') -Raw | ConvertFrom-Json)
    $c1 = Get-Content -LiteralPath (Join-Path $p15 'Sandbox\Dependencies\Tool_x64_1.0\Invoke-AppDeployToolkit.ps1') -Raw
    $c2 = Get-Content -LiteralPath (Join-Path $p15 'Sandbox\Dependencies\Other_Tool_x64_1.0\Invoke-AppDeployToolkit.ps1') -Raw -ErrorAction SilentlyContinue
    if ($n15 -eq 2 -and $e15[0].Path -eq 'C:\PSADT\Sandbox\Dependencies\Tool_x64_1.0\Invoke-AppDeployToolkit.ps1' -and $e15[1].Path -eq 'C:\PSADT\Sandbox\Dependencies\Other_Tool_x64_1.0\Invoke-AppDeployToolkit.ps1' -and
        $c1 -match 'Contoso' -and $c2 -match 'Other') { Ok 'Contoso\Tool and Other\Tool get separate folders (Tool_x64_1.0, Other_Tool_x64_1.0) and guest paths' } else { Bad "collision: n=$n15 paths=$(@($e15 | ForEach-Object Path) -join ' | ')" }
}
finally { foreach ($tp in $script:tmp) { Remove-Item -LiteralPath $tp -Recurse -Force -ErrorAction SilentlyContinue } }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All DependencyStaging tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail DependencyStaging test(s) FAILED." -ForegroundColor Red; exit 1 }
