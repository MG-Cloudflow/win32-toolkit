<#
    The documentation capture records the PSADT and dependency exit codes, and the host refuses to derive
    anything from a FAILED or EMPTY capture (TST-03, spec WP-E t4/t5, Q2 default).

      (a) Wait-ForDocumentationAndProcess: a failing PsadtExitCode (60001 / 60008), a failing
          DependencyExitCode, or an empty diff (non-msix/appx) -> $false with a warning naming the problem,
          and NO writer runs (AppConfig.json - incl. its Uninstall section - is byte-identical).
          Success codes 0 / 1707 / 3010 / 1641 proceed; an msix/appx capture with an empty diff proceeds;
          a legacy capture without the exit-code fields proceeds.
      (b) New-TargetedDocumentation: the generated capture script reads $LASTEXITCODE after
          InstallDependencies.ps1, logs a failure as ERROR (never SUCCESS), and records PsadtExitCode +
          DependencyExitCode in InstallationInfo. The dependency block is executed under Windows
          PowerShell 5.1 against stub dependency scripts (exit 0 / 60008 / throw).

    Run:  pwsh -File Tests\CaptureExitCode.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Wait-ForDocumentationAndProcess.ps1')

# -- shadows: every writer the waiter can call. Each one MODIFIES AppConfig.json (as the real ones do), so
#    "nothing ran" is proven both by the call log and by the file's bytes. -----------------------------
#    The doubles are defined through the function: drive (plain test doubles; PSScriptAnalyzer's
#    ShouldProcess rule targets product code). Every test passes -ExpectedJsonPath and writes the capture
#    first, so the waiter never polls (no Start-Sleep / Get-LatestInstallationCapture double needed).
$script:calls = @()
$script:jsonSeen = @()
function Write-FakeConfig([string]$ProjectPath, [string]$Who, [string]$Json) {
    $script:calls += $Who
    if ($Json) { $script:jsonSeen += (Split-Path -Leaf $Json) }
    Add-Content -LiteralPath (Join-Path $ProjectPath 'SupportFiles\AppConfig.json') -Value " " -Encoding ASCII
    $true
}
${function:New-IntuneRequirementScript}    = { param($ProjectPath, $JsonFilePath) Write-FakeConfig $ProjectPath 'requirement' $JsonFilePath }
${function:Update-PSADTUninstallLogic}     = { param($ProjectPath, $JsonFilePath) Write-FakeConfig $ProjectPath 'uninstall' $JsonFilePath }
${function:Update-PSADTProcessesToClose}   = { param($ProjectPath, $JsonFilePath) Write-FakeConfig $ProjectPath 'processes' $JsonFilePath }
${function:Update-PSADTMsixUninstallLogic} = { param($ProjectPath) Write-FakeConfig $ProjectPath 'msix' '' }

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32cx_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root -Force | Out-Null

function NewCase {
    param([hashtable]$Capture)
    $p = Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles'), (Join-Path $p 'Documentation') -Force | Out-Null
    $cfg = '{"SchemaVersion":"1.0","Uninstall":{"ProductCodes":["{11111111-2222-3333-4444-555555555555}"],"Uninstallers":[]}}'
    [System.IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), $cfg, (New-Object System.Text.UTF8Encoding($false)))
    $json = Join-Path $p 'Documentation\InstallationChanges_20261015_101010.json'
    [System.IO.File]::WriteAllText($json, ($Capture | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    [pscustomobject]@{ Path = $p; Json = $json; Hash = (Get-FileHash -LiteralPath (Join-Path $p 'SupportFiles\AppConfig.json')).Hash }
}
function RunCase {
    param($Case, [string]$Type)
    $script:calls = @()
    $script:warn = @()
    $r = Wait-ForDocumentationAndProcess -ProjectPath $Case.Path -InstallerType $Type -ExpectedJsonPath $Case.Json -WarningVariable w 3>$null 6>$null
    $script:warn = @($w | ForEach-Object { "$_" })
    $r
}
function Test-Untouched($Case) {
    ($script:calls.Count -eq 0) -and ((Get-FileHash -LiteralPath (Join-Path $Case.Path 'SupportFiles\AppConfig.json')).Hash -eq $Case.Hash)
}

$diff = @{ NewFiles = @(@{ Path = 'C:\Program Files\App\app.exe' }); NewRegistryKeys = @(); NewServices = @(); NewPrograms = @() }
function Cap([hashtable]$Info, [hashtable]$Body = $diff) {
    $c = @{ InstallationInfo = (@{ ProjectName = 'App'; Timestamp = '20261015_101010' } + $Info) }
    foreach ($k in $Body.Keys) { $c[$k] = $Body[$k] }
    $c
}

# == (a) the waiter gate ===========================================================================
Write-Host '[a1] failing PSADT exit code -> $false, nothing derived, AppConfig untouched' -ForegroundColor Cyan
foreach ($code in 60001, 60008, 1603) {
    $c = NewCase (Cap @{ PsadtExitCode = $code; DependencyExitCode = $null })
    $r = RunCase $c 'exe'
    if ($r -eq $false) { Ok "PsadtExitCode $code -> `$false" } else { Bad "PsadtExitCode $code returned $r" }
    if (Test-Untouched $c) { Ok "PsadtExitCode ${code}: no writer ran, AppConfig.json (Uninstall) byte-identical" } else { Bad "writers: $($script:calls -join ',')" }
    if ($script:warn -match "exit code $code") { Ok "warning names the code $code" } else { Bad "warning: $($script:warn -join ' | ')" }
}
if ($script:warn -match '1603' -and -not ($script:warn -match '60001 =')) { Ok 'a code without a known meaning gets no made-up hint' } else { Bad "warning: $($script:warn -join ' | ')" }
$c = NewCase (Cap @{ PsadtExitCode = 60001 })
$null = RunCase $c 'exe'
if ($script:warn -match '60001 = PSADT script error') { Ok '60001 explained as a PSADT script error' } else { Bad "warning: $($script:warn -join ' | ')" }
$c = NewCase (Cap @{ PsadtExitCode = 60008 })
$null = RunCase $c 'msi'
if ($script:warn -match '60008 = PSADT session/launch failure') { Ok '60008 explained as a session/launch failure' } else { Bad "warning: $($script:warn -join ' | ')" }

Write-Host '[a2] failing dependency exit code -> $false, AppConfig untouched' -ForegroundColor Cyan
$c = NewCase (Cap @{ PsadtExitCode = 0; DependencyExitCode = 60008 })
$r = RunCase $c 'exe'
if ($r -eq $false -and (Test-Untouched $c)) { Ok 'DependencyExitCode 60008 -> $false, nothing derived' } else { Bad "r=$r writers=$($script:calls -join ',')" }
if ($script:warn -match 'dependencies' -and $script:warn -match '60008') { Ok 'warning says the DEPENDENCIES failed (with the code)' } else { Bad "warning: $($script:warn -join ' | ')" }
$c = NewCase (Cap @{ PsadtExitCode = 0; DependencyExitCode = 1 })
if ((RunCase $c 'exe') -eq $false) { Ok 'DependencyExitCode 1 (script threw) -> $false' } else { Bad 'dependency throw not refused' }

Write-Host '[a3] empty diff (non-msix) -> $false, AppConfig untouched' -ForegroundColor Cyan
$empty = @{ NewFiles = @(); NewRegistryKeys = @(); NewServices = @(); NewPrograms = @() }
foreach ($t in 'exe', 'msi', '') {
    $c = NewCase (Cap @{ PsadtExitCode = 0 } $empty)
    $r = RunCase $c $t
    if ($r -eq $false -and (Test-Untouched $c)) { Ok "empty capture, type '$t' -> `$false, nothing derived" } else { Bad "type '$t': r=$r writers=$($script:calls -join ',')" }
}
if ($script:warn -match 'NO changes') { Ok 'warning says the capture recorded no changes' } else { Bad "warning: $($script:warn -join ' | ')" }
$c = NewCase (Cap @{ PsadtExitCode = 0 } @{ NewFiles = @(); NewRegistryKeys = @(@{ Path = 'HKLM\SOFTWARE\App' }) })
if ((RunCase $c 'exe') -eq $true) { Ok 'one registry key (other sections absent) is a real diff -> proceeds' } else { Bad 'registry-only capture refused' }

Write-Host '[a4] msix/appx: an empty diff is allowed (Appx installs leave no Win32 footprint)' -ForegroundColor Cyan
foreach ($t in 'msix', 'appx') {
    $c = NewCase (Cap @{ PsadtExitCode = 0 } $empty)
    $r = RunCase $c $t
    if ($r -eq $true -and ($script:calls -contains 'msix')) { Ok "$t empty diff -> proceeds (identity-driven uninstall written)" } else { Bad "$t r=$r calls=$($script:calls -join ',')" }
}
$c = NewCase (Cap @{ PsadtExitCode = 60001 } $empty)
if ((RunCase $c 'msix') -eq $false) { Ok 'msix with a FAILED exit code is still refused' } else { Bad 'msix failure accepted' }

Write-Host '[a5] success codes and legacy captures proceed' -ForegroundColor Cyan
foreach ($code in 0, 1707, 3010, 1641) {
    $c = NewCase (Cap @{ PsadtExitCode = $code; DependencyExitCode = 3010 })
    $r = RunCase $c 'exe'
    if ($r -eq $true -and ($script:calls -contains 'uninstall') -and ($script:calls -contains 'requirement')) { Ok "PsadtExitCode $code -> proceeds (writers ran)" } else { Bad "code ${code}: r=$r calls=$($script:calls -join ',')" }
}
$c = NewCase @{ InstallationInfo = @{ ProjectName = 'App'; Timestamp = '20261015_101010' }; NewFiles = @(@{ Path = 'C:\x' }); NewRegistryKeys = @() }
$r = RunCase $c 'exe'
if ($r -eq $true -and ($script:calls -contains 'uninstall')) { Ok 'legacy capture (no exit-code fields) proceeds' } else { Bad "legacy r=$r calls=$($script:calls -join ',')" }
$c = NewCase (Cap @{ PsadtExitCode = 0; DependencyExitCode = $null })
$script:jsonSeen = @()
if ((RunCase $c 'exe') -eq $true) { Ok 'DependencyExitCode null (no dependencies) proceeds' } else { Bad 'null dependency code refused' }
if (@($script:jsonSeen | Select-Object -Unique) -join ',' -eq 'InstallationChanges_20261015_101010.json') { Ok 'the writers are fed this run''s capture file' } else { Bad "json seen: $($script:jsonSeen -join ',')" }

# == (b) the capture script records the codes ======================================================
Write-Host '[b] generated capture script: $LASTEXITCODE after InstallDependencies, ERROR on failure, codes in InstallationInfo' -ForegroundColor Cyan
$ntd = Get-Content -LiteralPath (Join-Path $repo 'Private\New-TargetedDocumentation.ps1') -Raw
$hs  = [regex]::Match($ntd, "(?s)\`$documentationScript = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $hs) { Bad 'could not extract the guest here-string'; exit 1 }
$tok = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($hs, [ref]$tok, [ref]$perr)
if (-not $perr) { Ok 'capture template parses' } else { Bad "parse: $($perr[0].Message)" }
if ($hs -match 'PsadtExitCode\s*=\s*\$psadtExitCode' -and $hs -match 'DependencyExitCode\s*=\s*\$dependencyExitCode') { Ok 'InstallationInfo carries PsadtExitCode + DependencyExitCode' } else { Bad 'exit-code fields missing from InstallationInfo' }
if ($hs -match '\$psadtExitCode = \$installProcess\.ExitCode') { Ok 'PsadtExitCode = the PSADT process exit code' } else { Bad 'PsadtExitCode not taken from $installProcess' }

# Slice the dependency block (init line + the if statement that runs InstallDependencies.ps1) via the AST.
$depIf = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match 'InstallDependencies\.ps1' }, $false) | Select-Object -First 1
$ps51 = Get-Command powershell.exe -ErrorAction SilentlyContinue
if (-not $depIf) { Bad 'dependency block not found in the capture template' }
elseif (-not $ps51) { Write-Host '  SKIP: Windows PowerShell 5.1 not present for the runtime check' -ForegroundColor DarkYellow }
else {
    $stubDir = Join-Path $root 'depstub'
    New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
    $stub = Join-Path $stubDir 'InstallDependencies.ps1'
    $block = $depIf.Extent.Text.Replace('C:\PSADT\Sandbox\InstallDependencies.ps1', $stub)
    $harness = @'
$logLines = New-Object System.Collections.Generic.List[string]
function Write-Log { param([string]$Message, [string]$Level = 'INFO') $logLines.Add($Level + '|' + $Message) }
$dependencyExitCode = $null
__BLOCK__
'RESULT=' + $dependencyExitCode
foreach ($l in $logLines) { 'LOG=' + $l }
'@
    $harnessFile = Join-Path $stubDir 'harness.ps1'
    [System.IO.File]::WriteAllText($harnessFile, $harness.Replace('__BLOCK__', $block), (New-Object System.Text.UTF8Encoding($true)))
    $cases = @(
        @{ Name = 'exit 0';     Body = 'exit 0';                      Code = '0';     Level = 'SUCCESS' }
        @{ Name = 'exit 60008'; Body = 'exit 60008';                  Code = '60008'; Level = 'ERROR' }
        @{ Name = 'throws';     Body = 'throw ''Add-AppxPackage failed'''; Code = '1';     Level = 'ERROR' }
    )
    foreach ($k in $cases) {
        [System.IO.File]::WriteAllText($stub, $k.Body, (New-Object System.Text.UTF8Encoding($true)))
        $out = @(& $ps51.Source -NoProfile -ExecutionPolicy Bypass -File $harnessFile 2>&1 | ForEach-Object { "$_" })
        $res = @($out | Where-Object { $_ -like 'RESULT=*' }) -join ''
        $lvl = @($out | Where-Object { $_ -like 'LOG=*' } | Select-Object -Last 1) -join ''
        if ($res -eq "RESULT=$($k.Code)") { Ok "5.1: dependency script $($k.Name) -> DependencyExitCode $($k.Code)" } else { Bad "$($k.Name): $($out -join ' / ')" }
        if ($lvl -like "LOG=$($k.Level)|*") { Ok "5.1: dependency script $($k.Name) logged as $($k.Level)" } else { Bad "$($k.Name) log: $lvl" }
    }
    Remove-Item $stub -Force -ErrorAction SilentlyContinue
    $out = @(& $ps51.Source -NoProfile -ExecutionPolicy Bypass -File $harnessFile 2>&1 | ForEach-Object { "$_" })
    if ((@($out | Where-Object { $_ -like 'RESULT=*' }) -join '') -eq 'RESULT=') { Ok '5.1: no dependency script -> DependencyExitCode stays $null' } else { Bad "no-deps: $($out -join ' / ')" }
}

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All CaptureExitCode tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail CaptureExitCode test(s) FAILED." -ForegroundColor Red; exit 1 }
