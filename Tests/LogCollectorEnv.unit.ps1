<#
    TST-07 - the Sandbox log collector (New-LogCollectorScript -> Sandbox\CollectLogs.ps1) expands a
    custom LogPath the way PSADT allows: ${env:Name}, $env:Name and PSADT's $envName aliases.

    Before: CollectLogs.ps1 only replaced three literal tokens ($envWinDir, $envProgramData,
    $envSystemDrive), so a LogPath such as '$env:ProgramData\Logs' or '${env:SystemDrive}\Logs' was
    searched literally and its logs were never collected.

      [1] the generated script parses (host parser) and is 5.1-safe (real Windows PowerShell 5.1 parse)
      [2] the old three-token Replace chain is gone; the config LogPath goes through the resolver
      [3] the resolver (extracted from the generated script by AST, never the whole script) resolves
          $envWinDir, $env:ProgramData, ${env:SystemDrive}, $envProgramFilesX86 and literal paths, and
          returns $null for unknown variables or any other '$' (path skipped, never half-expanded)
      [4] the same resolver gives the same answers under Windows PowerShell 5.1 (skipped if absent)
      [5] its last statement writes Sandbox\Logs\CollectLogs.done, which the host waits for (test campaign F2)

    The collector itself is never run (it copies from system log folders into C:\PSADT).

    Run:  pwsh -File Tests\LogCollectorEnv.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\New-LogCollectorScript.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitPS51Syntax.ps1')

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32t-lc-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $root -Force | Out-Null

try {
    $collector = New-LogCollectorScript -ProjectPath $root
    $text = [System.IO.File]::ReadAllText($collector)

    Write-Host "`n[1] Generated CollectLogs.ps1 parses and is 5.1-safe" -ForegroundColor Cyan
    $tokens = $null; $perr = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($collector, [ref]$tokens, [ref]$perr)
    if (@($perr).Count -eq 0) { Ok 'host parser: 0 errors' } else { Bad "host parse errors: $(@($perr).Message -join ' | ')" }
    $bytes = [System.IO.File]::ReadAllBytes($collector)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Ok 'written UTF-8 with BOM (read by Windows PowerShell 5.1)' } else { Bad 'no BOM' }
    $ps51 = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps51) {
        $e51 = @(Test-Win32ToolkitPS51Syntax -Path $collector)
        if ($e51.Count -eq 0) { Ok 'Windows PowerShell 5.1 parser: 0 errors' } else { Bad "5.1 parse errors: $($e51 -join ' | ')" }
    } else { Write-Host '  SKIP: Windows PowerShell 5.1 not present - 5.1 parse not run' -ForegroundColor DarkGray }
    if ($text -notmatch '\?\?|\?\.|&&|\|\|') { Ok 'no PS7-only operators (??, ?., &&, ||)' } else { Bad 'PS7-only operator in the generated script' }

    Write-Host "`n[2] The config LogPath goes through the generic resolver" -ForegroundColor Cyan
    if ($text -notmatch [regex]::Escape(".Replace('`$envWinDir'")) { Ok 'the old three-token Replace chain is gone' } else { Bad 'old Replace chain still present' }
    if ($text -match 'Resolve-W32tLogPath -Path \(\[string\]\$section\.LogPath\)' -and $text -match 'if \(\$lp\) \{ \$sources\.Add\(\$lp\) \}') { Ok 'each config LogPath is resolved, and an unresolvable one is skipped' } else { Bad 'resolver call not found' }

    Write-Host "`n[3] Resolver behaviour (function extracted from the generated script)" -ForegroundColor Cyan
    $fnAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-W32tLogPath' }, $true)
    if ($fnAst) { Ok 'Resolve-W32tLogPath is defined in CollectLogs.ps1' } else { Bad 'Resolve-W32tLogPath not found'; throw 'cannot continue without the resolver' }
    . ([scriptblock]::Create($fnAst.Extent.Text))

    $winDir = [Environment]::GetEnvironmentVariable('WinDir')
    $progData = [Environment]::GetEnvironmentVariable('ProgramData')
    $sysDrive = [Environment]::GetEnvironmentVariable('SystemDrive')
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $cpf86 = [Environment]::GetEnvironmentVariable('CommonProgramFiles(x86)')
    $cases = [ordered]@{
        '$envWinDir\Logs\Software'           = "$winDir\Logs\Software"
        '$env:ProgramData\Logs'              = "$progData\Logs"
        '${env:SystemDrive}\Logs\Apps'       = "$sysDrive\Logs\Apps"
        '$ENVWINDIR\Logs'                    = "$winDir\Logs"
        '$envProgramData\$env:WinDir'        = "$progData\$winDir"
        'D:\Logs\Software'                   = 'D:\Logs\Software'
        '$envNoSuchVarW32T\Logs'             = $null
        '${env:NoSuchVarW32T}\Logs'          = $null
        '$env:NoSuchVarW32T\Logs'            = $null
        'C:\Logs\$(Get-Date)'                = $null
        '${C:\x}\Logs'                       = $null
        'C:\Logs\$user'                      = $null
        ''                                   = $null
    }
    if ($pf86)  { $cases['$envProgramFilesX86\Vendor\Logs'] = "$pf86\Vendor\Logs" }
    if ($cpf86) { $cases['$envCommonProgramFilesX86\Logs'] = "$cpf86\Logs" }
    foreach ($in in $cases.Keys) {
        $got = Resolve-W32tLogPath -Path $in
        $want = $cases[$in]
        if ($got -eq $want -or ($null -eq $want -and $null -eq $got)) { Ok "'$in' -> $(if ($null -eq $got) { '$null (skipped)' } else { "'$got'" })" }
        else { Bad "'$in' -> [$got] (expected [$want])" }
    }

    Write-Host "`n[4] Same answers under Windows PowerShell 5.1" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $ps51) {
        # Pure function + one call per case; inputs travel base64-encoded (no quoting hazards), the
        # child prints '<index>|<result or NULL>' per case. The collector script itself is never run.
        $inputs = @($cases.Keys)
        $enc = ($inputs | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$_)) }) -join ','
        $probe = $fnAst.Extent.Text + "`r`n" + @'
$i = 0
foreach ($b in $env:W32T_LC_CASES.Split(',')) {
    $s = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))
    $r = Resolve-W32tLogPath -Path $s
    if ($null -eq $r) { $r = 'NULL' }
    Write-Output ('{0}|{1}' -f $i, $r)
    $i++
}
'@
        $probeFile = Join-Path $root 'probe51.ps1'
        [System.IO.File]::WriteAllText($probeFile, $probe, (New-Object System.Text.UTF8Encoding($true)))
        $prevCases = $env:W32T_LC_CASES
        try {
            $env:W32T_LC_CASES = $enc
            $lines = @(& $ps51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probeFile 2>&1 | ForEach-Object { "$_" })
        }
        finally { $env:W32T_LC_CASES = $prevCases }
        $same = $true
        for ($i = 0; $i -lt $inputs.Count; $i++) {
            $line = $lines | Where-Object { $_ -like "$i|*" } | Select-Object -First 1
            $got51 = if ($line) { $line.Substring($line.IndexOf('|') + 1) } else { '<missing>' }
            $want = $cases[$inputs[$i]]
            $wantText = if ($null -eq $want) { 'NULL' } else { $want }
            if ($got51 -ne $wantText) { $same = $false; Bad "5.1: '$($inputs[$i])' -> [$got51] (expected [$wantText])" }
        }
        if ($same) { Ok "Windows PowerShell 5.1 resolves all $($inputs.Count) cases identically" }
    } else { Write-Host '  SKIP: Windows PowerShell 5.1 not present' -ForegroundColor DarkGray }

    Write-Host "`n[5] The last statement writes Sandbox\Logs\CollectLogs.done (test campaign F2)" -ForegroundColor Cyan
    $last = @($ast.EndBlock.Statements)[-1].Extent.Text
    if ($last -ceq "Set-Content -LiteralPath (Join-Path `$dest 'CollectLogs.done') -Value ('collected=' + `$collected) -Encoding ASCII") {
        Ok 'CollectLogs.done (collected=<n>) is written last, after every copy: the host waits for it before keeping the run''s logs'
    } else { Bad "last statement: $last" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All LogCollectorEnv tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail LogCollectorEnv test(s) FAILED." -ForegroundColor Red; exit 1 }
