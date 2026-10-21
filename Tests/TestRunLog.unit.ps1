<#
    Test campaign F2: every test run keeps its own evidence in Sandbox\Logs\Runs\<yyyyMMdd-HHmmss>_<Scenario>[_<Family>]\.
    Before, each run (and each leg of an Update '-BaselineInstallerType Both' run) overwrote the Sandbox\Logs files
    of the run before it, and PsadtExitCodes.log was cleared on every call.

      [1] Initialize-Win32ToolkitTestRunLog: run name, unique folder name, the start marker in PsadtExitCodes.log,
          the collector's completion file removed, the snapshot of the top-level logs
      [2] Save-Win32ToolkitTestRunLog: only new or changed files (length, then SHA-256), only this run's exit-code
          lines, the top-level files untouched; a run that left nothing -> $null and no folder
      [3] Two runs back to back (the legs of a Both run): each folder holds its own logs and exit codes
      [4] Wait-Win32ToolkitCollectedLog: done file present / absent
      [5] Add-Win32ToolkitTestResult / Write-Win32ToolkitTestOutcome record LogFolder only when given
      [6] Get-Win32ToolkitTestRunLogFolder: scenario, verdict and time filters; only the Runs shape is returned
      [7] Invoke-Win32ToolkitFinalize: a failed test names the failed run's own folder(s)

    Real helpers on temp folders; Finalize's collaborators are shadowed. No sandbox, no VM.

    Run:  pwsh -File Tests\TestRunLog.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Initialize-Win32ToolkitTestRunLog.ps1')
. (Join-Path $repo 'Private\Save-Win32ToolkitTestRunLog.ps1')
. (Join-Path $repo 'Private\Wait-Win32ToolkitCollectedLog.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitTestRunLogFolder.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitTestResult.ps1')
. (Join-Path $repo 'Private\Add-Win32ToolkitTestResult.ps1')
. (Join-Path $repo 'Private\Write-Win32ToolkitTestOutcome.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32trl_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = New-Object System.Text.UTF8Encoding($false)
function MakeProject([string]$Name) {
    $p = Join-Path $root $Name
    New-Item -ItemType Directory -Path (Join-Path $p 'Sandbox\Logs') -Force | Out-Null
    $p
}
function Write-RunLog([string]$Project, [string]$Name, [string]$Text) {
    [System.IO.File]::WriteAllText((Join-Path $Project "Sandbox\Logs\$Name"), $Text, $utf8)
}
function Add-Code([string]$Project, [string]$Line) {
    Add-Content -LiteralPath (Join-Path $Project 'Sandbox\Logs\PsadtExitCodes.log') -Value $Line -Encoding UTF8
}
# UTC with a 'Z' (test campaign 2026-10-21): in order with the guest runner's lines whatever the guest's zone.
$markerRx = '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})Z\] -- test run (\S+) --$'

try {
    # --- [1] Initialize -------------------------------------------------------------------------------
    Write-Host '[1] Initialize-Win32ToolkitTestRunLog: name, marker, completion file, snapshot' -ForegroundColor Cyan
    $p = MakeProject 'one'
    Write-RunLog $p 'Capture_PSAppDeployToolkit_Install.log' 'capture run'
    Write-RunLog $p 'CollectLogs.done' 'collected=3'
    # An exit-code log whose last line has no line break: the marker still starts on its own line.
    [System.IO.File]::WriteAllText((Join-Path $p 'Sandbox\Logs\PsadtExitCodes.log'), '[2026-10-20 10:00:00] app Install parent=x64-direct exit=0 result=Success', $utf8)
    $r1 = Initialize-Win32ToolkitTestRunLog -ProjectPath $p -Scenario Update -Family 'E-X.E/..'
    if ($r1 -and $r1.RunName -match '^\d{8}-\d{6}_Update_exe$' -and $r1.RelativePath -eq "Sandbox\Logs\Runs\$($r1.RunName)") { Ok "run name <yyyyMMdd-HHmmss>_Update_<family> ($($r1.RunName)); the family keeps letters and digits only" }
    else { Bad "run: $($r1 | ConvertTo-Json -Compress)" }
    $codes = @(Get-Content -LiteralPath (Join-Path $p 'Sandbox\Logs\PsadtExitCodes.log'))
    if ($codes.Count -eq 2 -and $codes[0] -like '*exit=0 result=Success' -and $codes[1] -ceq $r1.Marker -and $codes[1] -match $markerRx -and $Matches[2] -eq $r1.RunName) { Ok "the marker '[<UTC time>Z] -- test run <name> --' is appended on its own line" }
    else { Bad "codes: $($codes -join ' | ')" }
    $mt = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    if ([Math]::Abs(([datetime]::UtcNow - $mt).TotalSeconds) -lt 120 -and [Math]::Abs(($r1.StartedUtc - $mt).TotalSeconds) -lt 2) { Ok 'the marker time is UTC (= StartedUtc), not host local time' } else { Bad "marker time $($Matches[1]) vs UtcNow $([datetime]::UtcNow) / StartedUtc $($r1.StartedUtc)" }
    if (-not (Test-Path -LiteralPath (Join-Path $p 'Sandbox\Logs\CollectLogs.done'))) { Ok "an earlier run's CollectLogs.done is removed" } else { Bad 'CollectLogs.done left' }
    if ($r1.Snapshot.Keys.Count -eq 1 -and $r1.Snapshot['Capture_PSAppDeployToolkit_Install.log'] -match '^\d+:[0-9A-F]{64}$' -and -not $r1.Snapshot.ContainsKey('PsadtExitCodes.log')) { Ok 'snapshot: <length>:<sha256> per top-level file, PsadtExitCodes.log left out' }
    else { Bad "snapshot: $($r1.Snapshot | ConvertTo-Json -Compress)" }
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $p 'Sandbox\Logs\PsadtExitCodes.log'))
    if ($bytes[0] -ne 0xEF -and @($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'the marker is ASCII, no BOM added' } else { Bad 'marker encoding' }
    $iu = Initialize-Win32ToolkitTestRunLog -ProjectPath (MakeProject 'iu') -Scenario InstallUninstall
    if ($iu.RunName -match '^\d{8}-\d{6}_InstallUninstall$') { Ok 'InstallUninstall: no family segment' } else { Bad "iu name: $($iu.RunName)" }
    # A folder of that name already exists (two runs in the same second): '-2', then '-3'.
    $pd = MakeProject 'dupe'
    $t0 = Get-Date
    $stems = @(0..5 | ForEach-Object { '{0}_Update_msi' -f $t0.AddSeconds($_).ToString('yyyyMMdd-HHmmss') })
    foreach ($s in $stems) { New-Item -ItemType Directory -Path (Join-Path $pd "Sandbox\Logs\Runs\$s"), (Join-Path $pd "Sandbox\Logs\Runs\$s-2") -Force | Out-Null }
    $dupe = Initialize-Win32ToolkitTestRunLog -ProjectPath $pd -Scenario Update -Family msi
    if ($dupe.RunName -match '^(.+)-3$' -and $stems -contains $Matches[1]) { Ok "an existing folder of the same name gets '-2', then '-3' ($($dupe.RunName))" } else { Bad "dupe: $($dupe.RunName)" }
    $np = Join-Path $root 'nologs'
    New-Item -ItemType Directory -Path $np -Force | Out-Null
    $r0 = Initialize-Win32ToolkitTestRunLog -ProjectPath $np -Scenario InstallUninstall
    if ($r0 -and (Test-Path -LiteralPath (Join-Path $np 'Sandbox\Logs\PsadtExitCodes.log'))) { Ok 'no Sandbox\Logs yet: created, marker written' } else { Bad 'no logs folder' }

    # --- [2] Save -------------------------------------------------------------------------------------
    Write-Host '[2] Save-Win32ToolkitTestRunLog: new and changed files only, this run''s exit codes only' -ForegroundColor Cyan
    $p = MakeProject 'save'
    Write-RunLog $p 'Stale_Unchanged.log' 'from an earlier run'
    Write-RunLog $p 'Same_Length.log' 'AAAA'
    Write-RunLog $p 'Grows.log' 'x'
    Add-Code $p '[2026-10-20 09:00:00] app Install parent=x64-direct exit=1 result=Failed EARLIER-CALL'
    $run = Initialize-Win32ToolkitTestRunLog -ProjectPath $p -Scenario Update -Family msi
    # The guest run: a new assertion log, a same-length rewrite, a grown file, and two exit-code lines.
    Write-RunLog $p 'UpdateAssertions.log' "ASSERT OldArpGone-PostUpdate = FAIL`r`nRESULT COMPLETE"
    Write-RunLog $p 'Same_Length.log' 'BBBB'
    Write-RunLog $p 'Grows.log' 'xyz'
    Add-Code $p '[2026-10-20 10:00:00] update Install parent=x64-direct exit=0 result=Success'
    Write-RunLog $p 'CollectLogs.done' 'collected=2'
    $before = @(Get-ChildItem -LiteralPath (Join-Path $p 'Sandbox\Logs') -File | ForEach-Object { '{0}={1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ';'
    $rel = Save-Win32ToolkitTestRunLog -Run $run
    $dir = Join-Path $p $rel
    $kept = @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object Name | Sort-Object)
    if ($rel -eq $run.RelativePath -and ($kept -join ',') -eq 'CollectLogs.done,Grows.log,PsadtExitCodes.log,Same_Length.log,UpdateAssertions.log') { Ok "kept: the new and changed files (a same-length rewrite too), not the untouched one ($($kept -join ', '))" }
    else { Bad "kept: rel=$rel files=$($kept -join ',')" }
    $runCodes = @(Get-Content -LiteralPath (Join-Path $dir 'PsadtExitCodes.log'))
    if ($runCodes.Count -eq 1 -and $runCodes[0] -like '*update Install*exit=0 result=Success') { Ok "the run's PsadtExitCodes.log holds only the lines after its marker" } else { Bad "run codes: $($runCodes -join ' | ')" }
    if ((Get-Content -LiteralPath (Join-Path $dir 'UpdateAssertions.log') -Raw) -match 'OldArpGone-PostUpdate = FAIL') { Ok 'the assertion log is copied byte for byte' } else { Bad 'assertion log content' }
    $after = @(Get-ChildItem -LiteralPath (Join-Path $p 'Sandbox\Logs') -File | ForEach-Object { '{0}={1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ';'
    if ($after -eq $before) { Ok 'the top-level Sandbox\Logs files are left as they were' } else { Bad 'top-level files changed' }
    $topCodes = @(Get-Content -LiteralPath (Join-Path $p 'Sandbox\Logs\PsadtExitCodes.log'))
    if ($topCodes.Count -eq 3 -and $topCodes[0] -like '*EARLIER-CALL' -and $topCodes[1] -ceq $run.Marker) { Ok 'the top-level PsadtExitCodes.log keeps every line (Save never clears it)' } else { Bad "top codes: $($topCodes -join ' | ')" }
    # Nothing changed and no exit code: no folder.
    $p = MakeProject 'empty'
    Write-RunLog $p 'Old.log' 'old'
    $run = Initialize-Win32ToolkitTestRunLog -ProjectPath $p -Scenario InstallUninstall
    $rel = Save-Win32ToolkitTestRunLog -Run $run
    if ($null -eq $rel -and -not (Test-Path -LiteralPath (Join-Path $p 'Sandbox\Logs\Runs'))) { Ok 'a run that left no log -> $null, no folder' } else { Bad "empty run: $rel" }
    # The marker is gone (the log was replaced): the files are still kept, without an exit-code file.
    $p = MakeProject 'nomarker'
    $run = Initialize-Win32ToolkitTestRunLog -ProjectPath $p -Scenario InstallUninstall
    Set-Content -LiteralPath (Join-Path $p 'Sandbox\Logs\PsadtExitCodes.log') -Value '[2026-10-20 10:00:00] app Install parent=x64-direct exit=0 result=Success'
    Write-RunLog $p 'InstallAssertions.log' 'RESULT COMPLETE'
    $rel = Save-Win32ToolkitTestRunLog -Run $run
    if ($rel -and (Test-Path -LiteralPath (Join-Path $p "$rel\InstallAssertions.log")) -and -not (Test-Path -LiteralPath (Join-Path $p "$rel\PsadtExitCodes.log"))) { Ok 'no marker in the exit-code log -> the files are kept, no exit-code file' }
    else { Bad "no marker: $rel" }

    # --- [3] Two runs back to back ------------------------------------------------------------------
    Write-Host '[3] The legs of a Both run: each folder holds its own logs and exit codes' -ForegroundColor Cyan
    $p = MakeProject 'both'
    $leg1 = Initialize-Win32ToolkitTestRunLog -ProjectPath $p -Scenario Update -Family msi
    Write-RunLog $p 'UpdateAssertions.log' 'LEG1 ASSERT OldArpGone-PostUpdate = PASS'
    Write-RunLog $p 'PSAppDeployToolkit_Install.log' 'LEG1 psadt'
    Add-Code $p '[2026-10-20 10:00:00] update Install parent=x64-direct exit=0 result=Success LEG1'
    $rel1 = Save-Win32ToolkitTestRunLog -Run $leg1
    Remove-Item -LiteralPath (Join-Path $p 'Sandbox\Logs\UpdateAssertions.log')   # the next run clears it first
    $leg2 = Initialize-Win32ToolkitTestRunLog -ProjectPath $p -Scenario Update -Family exe
    Write-RunLog $p 'UpdateAssertions.log' 'LEG2 ASSERT OldArpGone-PostUpdate = FAIL'
    Write-RunLog $p 'PSAppDeployToolkit_Install.log' 'LEG2 psadt'
    Add-Code $p '[2026-10-20 10:10:00] update Install parent=x64-direct exit=1603 result=Failed LEG2'
    $rel2 = Save-Win32ToolkitTestRunLog -Run $leg2
    $a1 = Get-Content -LiteralPath (Join-Path $p "$rel1\UpdateAssertions.log") -Raw
    $a2 = Get-Content -LiteralPath (Join-Path $p "$rel2\UpdateAssertions.log") -Raw
    $l1 = Get-Content -LiteralPath (Join-Path $p "$rel1\PSAppDeployToolkit_Install.log") -Raw
    $c1 = @(Get-Content -LiteralPath (Join-Path $p "$rel1\PsadtExitCodes.log"))
    $c2 = @(Get-Content -LiteralPath (Join-Path $p "$rel2\PsadtExitCodes.log"))
    if ($rel1 -ne $rel2 -and $rel1 -like '*_Update_msi*' -and $rel2 -like '*_Update_exe*' -and $a1 -match 'LEG1' -and $a2 -match 'LEG2' -and $l1 -match 'LEG1') { Ok 'leg 1 keeps its own assertion and PSADT logs after leg 2 overwrote the top-level ones' }
    else { Bad "legs: $rel1 / $rel2 / $a1 / $a2 / $l1" }
    if ($c1.Count -eq 1 -and $c1[0] -match 'LEG1' -and $c2.Count -eq 1 -and $c2[0] -match 'LEG2') { Ok 'each leg keeps only its own exit-code line' } else { Bad "codes: $($c1 -join '|') / $($c2 -join '|')" }
    $top = @(Get-Content -LiteralPath (Join-Path $p 'Sandbox\Logs\PsadtExitCodes.log'))
    if ($top.Count -eq 4 -and $top[1] -match 'LEG1' -and $top[3] -match 'LEG2') { Ok 'the top-level PsadtExitCodes.log holds both legs, each after its marker' } else { Bad "top: $($top -join ' | ')" }

    # --- [4] Wait-Win32ToolkitCollectedLog ------------------------------------------------------------
    Write-Host '[4] Wait-Win32ToolkitCollectedLog' -ForegroundColor Cyan
    $p = MakeProject 'wait'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $w0 = Wait-Win32ToolkitCollectedLog -ProjectPath $p -TimeoutSeconds 0 -SettleSeconds 0
    if ($w0 -eq $false -and $sw.Elapsed.TotalSeconds -lt 5) { Ok 'no CollectLogs.done and -TimeoutSeconds 0 -> $false at once' } else { Bad "w0=$w0 ($($sw.Elapsed.TotalSeconds) s)" }
    Write-RunLog $p 'CollectLogs.done' 'collected=1'
    $sw.Restart()
    $w1 = Wait-Win32ToolkitCollectedLog -ProjectPath $p -TimeoutSeconds 30 -SettleSeconds 0
    if ($w1 -eq $true -and $sw.Elapsed.TotalSeconds -lt 5) { Ok 'CollectLogs.done present -> $true without waiting' } else { Bad "w1=$w1" }

    # --- [5] Recording -------------------------------------------------------------------------------
    Write-Host '[5] TestResults.json records LogFolder only when given' -ForegroundColor Cyan
    $p = MakeProject 'record'
    Write-RunLog $p 'UpdateAssertions.log' "[t] ASSERT OldArpGone-PostUpdate = PASS`r`n[t] RESULT COMPLETE"
    Write-Win32ToolkitTestOutcome -ProjectPath $p -Scenario Update -Backend HyperV -Verdict $true -LogFolder 'Sandbox\Logs\Runs\20261020-100000_Update_msi'
    Write-Win32ToolkitTestOutcome -ProjectPath $p -Scenario Update -Backend HyperV -Verdict $true
    $null = Add-Win32ToolkitTestResult -ProjectPath $p -Scenario InstallUninstall -Backend Sandbox -Verdict Passed -LogFolder ''
    $recs = @(Get-Win32ToolkitTestResult -ProjectPath $p | ForEach-Object { $_ })
    if ($recs.Count -eq 3 -and $recs[0].LogFolder -eq 'Sandbox\Logs\Runs\20261020-100000_Update_msi' -and @($recs[0].Assertions).Count -eq 1 -and
        -not $recs[1].PSObject.Properties['LogFolder'] -and -not $recs[2].PSObject.Properties['LogFolder']) { Ok 'Write-Win32ToolkitTestOutcome -LogFolder -> LogFolder; omitted or empty -> no property (the old shape)' }
    else { Bad "records: $($recs | ConvertTo-Json -Compress -Depth 4)" }

    # --- [6] Get-Win32ToolkitTestRunLogFolder -----------------------------------------------------------
    Write-Host '[6] Get-Win32ToolkitTestRunLogFolder: filters, and only the Runs shape' -ForegroundColor Cyan
    $p = MakeProject 'lookup'
    $old = [datetime]::UtcNow.AddHours(-1).ToString('o')
    $now = [datetime]::UtcNow.ToString('o')
    $records = @(
        [pscustomobject]@{ Scenario = 'Update'; Verdict = 'Failed'; TimestampUtc = $old; LogFolder = 'Sandbox\Logs\Runs\OLD_Update_exe' }
        [pscustomobject]@{ Scenario = 'Update'; Verdict = 'Passed'; TimestampUtc = $now; LogFolder = 'Sandbox\Logs\Runs\20261020-100000_Update_msi' }
        [pscustomobject]@{ Scenario = 'Update'; Verdict = 'Failed'; TimestampUtc = $now; LogFolder = 'Sandbox\Logs\Runs\20261020-101000_Update_exe' }
        [pscustomobject]@{ Scenario = 'InstallUninstall'; Verdict = 'Failed'; TimestampUtc = $now; LogFolder = 'Sandbox\Logs\Runs\20261020-090000_InstallUninstall' }
        [pscustomobject]@{ Scenario = 'Update'; Verdict = 'Failed'; TimestampUtc = $now; LogFolder = 'Sandbox\Logs\Runs\..\..\..\Windows' }
        [pscustomobject]@{ Scenario = 'Update'; Verdict = 'Failed'; TimestampUtc = $now; LogFolder = 'C:\Windows\System32' }
        [pscustomobject]@{ Scenario = 'Update'; Verdict = 'Failed'; TimestampUtc = $now }
        [pscustomobject]@{ Scenario = 'Update'; Verdict = 'Failed'; TimestampUtc = $now; LogFolder = 'Sandbox\Logs\Runs\20261020-102000_Update_exe-2' }
    )
    New-Item -ItemType Directory -Path (Join-Path $p 'Documentation') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $p 'Documentation\TestResults.json'), (ConvertTo-Json -InputObject $records -Depth 4), $utf8)
    $since = [datetime]::UtcNow.AddMinutes(-5)
    $got = @(Get-Win32ToolkitTestRunLogFolder -ProjectPath $p -Scenario Update -SinceUtc $since)
    $want = @((Join-Path $p 'Sandbox\Logs\Runs\20261020-101000_Update_exe'), (Join-Path $p 'Sandbox\Logs\Runs\20261020-102000_Update_exe-2'))
    if (($got -join '|') -eq ($want -join '|')) { Ok 'Failed Update records since the start, oldest first; traversal, rooted and missing LogFolder skipped' } else { Bad "got: $($got -join ' | ')" }
    $gotIu = @(Get-Win32ToolkitTestRunLogFolder -ProjectPath $p -Scenario InstallUninstall -SinceUtc $since)
    $gotPass = @(Get-Win32ToolkitTestRunLogFolder -ProjectPath $p -Scenario Update -SinceUtc $since -Verdict Passed)
    if ($gotIu.Count -eq 1 -and $gotIu[0] -like '*_InstallUninstall' -and $gotPass.Count -eq 1 -and $gotPass[0] -like '*_Update_msi') { Ok '-Scenario and -Verdict filter the records' } else { Bad "iu=$($gotIu -join '|') pass=$($gotPass -join '|')" }
    [System.IO.File]::WriteAllText((Join-Path $p 'Documentation\TestResults.json'), '{ not json', $utf8)
    $threw = $null; $bad = $null
    try { $bad = @(Get-Win32ToolkitTestRunLogFolder -ProjectPath $p -Scenario Update -SinceUtc $since -WarningAction SilentlyContinue -ErrorAction Stop) } catch { $threw = $_ }
    if (-not $threw -and $bad.Count -eq 0) { Ok 'an unreadable TestResults.json -> nothing, no throw' } else { Bad "unreadable: $threw" }

    # --- [7] Invoke-Win32ToolkitFinalize ----------------------------------------------------------------
    Write-Host '[7] Invoke-Win32ToolkitFinalize: a failed test names the failed run''s own folder' -ForegroundColor Cyan
    . (Join-Path $repo 'Private\Invoke-Win32ToolkitFinalize.ps1')
    function Assert-Win32ToolkitPackageReady { param($ProjectPath, $Stage, [switch]$AllowLegacyScript) [pscustomobject]@{ Ready = $true } }
    function Get-Win32ToolkitTestBackend { 'Sandbox' }
    ${function:New-TargetedDocumentation} = { param($ProjectPath, $ProjectName, $AppInfo, $Backend) $false }
    function Export-Win32ToolkitIntuneWin { param($ProjectPath, [switch]$PublishIntune, [switch]$PublishUpdate, [switch]$AllowLegacyScript) }
    $script:legFolders = @()
    function Test-Win32ToolkitProject {
        param($ProjectPath, $Scenario, $SpecificVersion, $VersionsBack, $BaselineInstallerType)
        foreach ($leg in $script:legFolders) {
            $null = Add-Win32ToolkitTestResult -ProjectPath $ProjectPath -Scenario $Scenario -Backend Sandbox -Verdict $leg.Verdict -LogFolder $leg.Folder
        }
        $false
    }
    $p = MakeProject 'finalize'
    # An older failed run (before this test) must not be named.
    $null = Add-Win32ToolkitTestResult -ProjectPath $p -Scenario Update -Backend Sandbox -Verdict Failed -LogFolder 'Sandbox\Logs\Runs\20200101-000000_Update_exe'
    Start-Sleep -Milliseconds 50
    $script:legFolders = @(
        @{ Verdict = 'Failed'; Folder = 'Sandbox\Logs\Runs\20261020-100000_Update_msi' }
        @{ Verdict = 'Passed'; Folder = 'Sandbox\Logs\Runs\20261020-101000_Update_exe' }
        @{ Verdict = 'Failed'; Folder = 'Sandbox\Logs\Runs\20261020-102000_Update_msix' }
    )
    $w = @(Invoke-Win32ToolkitFinalize -ProjectPath $p -ProjectName 'P' -RunTest Update -UpdateVersionsBack 1 3>&1 6>$null | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { "$_" })
    $wantF = 'The Update test FAILED its assertions ' + [char]0x2014 + ' review ' + (Join-Path $p 'Sandbox\Logs\Runs\20261020-100000_Update_msi\UpdateAssertions.log') + ' and ' +
             (Join-Path $p 'Sandbox\Logs\Runs\20261020-102000_Update_msix\UpdateAssertions.log') + ' before publishing this package.'
    if (@($w | Where-Object { $_ -ceq $wantF }).Count -eq 1) { Ok 'a failed Both run names the UpdateAssertions.log of each failed leg (not the passed leg, not an older run)' } else { Bad "warnings: $($w -join ' | ')" }
    $script:legFolders = @()
    $w = @(Invoke-Win32ToolkitFinalize -ProjectPath $p -ProjectName 'P' -RunTest InstallUninstall 3>&1 6>$null | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { "$_" })
    $wantIu = 'The InstallUninstall test FAILED its assertions ' + [char]0x2014 + " review $p\Sandbox\Logs\InstallAssertions.log before publishing this package."
    if (@($w | Where-Object { $_ -ceq $wantIu }).Count -eq 1) { Ok 'no recorded run folder -> the top-level Sandbox\Logs log, as before' } else { Bad "warnings: $($w -join ' | ')" }

    # --- [8] Source checks ------------------------------------------------------------------------------
    Write-Host '[8] Source checks: ASCII, every catch starts with the C-2 line' -ForegroundColor Cyan
    $c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
    foreach ($f in 'Initialize-Win32ToolkitTestRunLog', 'Save-Win32ToolkitTestRunLog', 'Wait-Win32ToolkitCollectedLog', 'Get-Win32ToolkitTestRunLogFolder') {
        $file = Join-Path $repo "Private\$f.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
        $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
        if ($badCatch.Count -eq 0 -and $ascii) { Ok "${f}: ASCII, $($catches.Count) catch clause(s) with the C-2 line" } else { Bad "${f}: ascii=$ascii bad catch at line $($badCatch[0].Extent.StartLineNumber)" }
    }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestRunLog tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestRunLog test(s) FAILED." -ForegroundColor Red; exit 1 }
