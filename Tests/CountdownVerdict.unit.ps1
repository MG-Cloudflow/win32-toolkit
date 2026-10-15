<#
    The watched-Sandbox countdown reports the REAL install outcome (spec WP-E t9, TST-04): the generated
    Sandbox\Countdown.ps1 defines Get-W32tInstallVerdict BEFORE any WinForms code; it reads the guest
    runner's C:\PSADT\Sandbox\Logs\PsadtExitCodes.log, takes the LAST 'Install' line (any label) and
    returns @{ Known; Ok; Exit; Result }. The banner / form title then say
      INSTALLATION COMPLETED SUCCESSFULLY!                                   (Ok)
      INSTALLATION FAILED (exit <n>, <result>) - see C:\PSADT\Sandbox\Logs    (not Ok)
      INSTALLATION FINISHED (no exit code recorded)                           (no log / no Install line)

    The function and the verdict-text block are sliced out of the generated script via the AST and RUN
    under Windows PowerShell 5.1 against sample logs (the 5.1 part is skipped only when powershell.exe is
    absent). Nothing is launched with a UI.

    Run:  pwsh -File Tests\CountdownVerdict.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\New-CountdownScript.ps1')

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('w32cv_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$ps51 = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'

try {
Write-Host '[1] generated Countdown.ps1: BOM, parses (host + 5.1), verdict function before WinForms, value-free' -ForegroundColor Cyan
$proj = Join-Path $root "Proj O'Hara"
New-Item -ItemType Directory -Path $proj -Force | Out-Null
$path = New-CountdownScript -ProjectPath $proj
$bytes = [System.IO.File]::ReadAllBytes($path)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Ok 'Countdown.ps1 keeps its UTF-8 BOM' } else { Bad 'no BOM' }
$text = [System.IO.File]::ReadAllText($path)
$tok = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$perr)
if (-not $perr) { Ok 'parses (host parser)' } else { Bad "parse: $($perr[0].Message)" }
if (Test-Path -LiteralPath $ps51) {
    $env:W32T_CV_FILE = $path
    $n = (& $ps51 -NoProfile -Command '$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:W32T_CV_FILE,[ref]$null,[ref]$e); @($e).Count' | Out-String).Trim()
    Remove-Item Env:\W32T_CV_FILE -ErrorAction SilentlyContinue
    if ($n -eq '0') { Ok 'parses under Windows PowerShell 5.1 (0 errors)' } else { Bad "5.1 parse errors: $n" }
}
$fn = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-W32tInstallVerdict' }, $true) | Select-Object -First 1
$winforms = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.Extent.Text -match 'System\.Windows\.Forms' }, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
if ($fn -and $winforms -and $fn.Extent.EndOffset -lt $winforms.Extent.StartOffset) { Ok 'Get-W32tInstallVerdict is defined BEFORE any WinForms code' } else { Bad "function=$([bool]$fn) winforms=$([bool]$winforms)" }
$verdictIf = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.IfStatementAst] -and $x.Clauses[0].Item1.Extent.Text -eq '-not $installVerdict.Known' }, $true) | Select-Object -First 1
$call = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Extent.Text -match '^\$installVerdict = Get-W32tInstallVerdict$' }, $true) | Select-Object -First 1
if ($verdictIf -and $call -and $call.Extent.EndOffset -lt $verdictIf.Extent.StartOffset -and $verdictIf.Extent.EndOffset -lt $winforms.Extent.StartOffset) { Ok 'the verdict is computed (and its text chosen) before the form is built' } else { Bad 'verdict call / text block not found before WinForms' }
if ($text -notmatch [regex]::Escape("O'Hara") -and $text -notmatch [regex]::Escape($root)) { Ok 'value-free: no project name or host path in the script' } else { Bad 'project value spliced' }
$bannerIdx = $text.IndexOf('Write-Host $verdictText')
$titleIdx  = $text.IndexOf('$titleLabel.Text = $verdictText')
if ($bannerIdx -ge 0 -and $titleIdx -gt $bannerIdx) { Ok 'both the console banner and the form title show the verdict text' } else { Bad "banner=$bannerIdx title=$titleIdx" }
if (([regex]::Matches($text, 'INSTALLATION COMPLETED SUCCESSFULLY!')).Count -eq 1 -and $text -cnotmatch 'Installation Completed Successfully!') { Ok 'the success text exists only as the Ok branch of the verdict (no unconditional success banner/title)' } else { Bad 'an unconditional success text is still present' }
if ($text -match 'Uninstallation will begin automatically' -and $text -match '\$form\.ShowDialog\(\)') { Ok 'the countdown (and the following uninstall) still run on a failure' } else { Bad 'countdown form changed' }

Write-Host '[2] Get-W32tInstallVerdict + verdict text, executed under Windows PowerShell 5.1' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $ps51)) {
    Write-Host '  SKIP: Windows PowerShell 5.1 (powershell.exe) not present' -ForegroundColor DarkYellow
}
elseif (-not ($fn -and $verdictIf)) { Bad 'cannot slice the verdict code' }
else {
    $ts = '[2026-10-15 10:00:00]'
    $cases = [ordered]@{
        'success'          = @{ Lines = @("$ts app Install parent=x64-direct exit=0 result=Success"); Expect = 'True|True|0|Success|INSTALLATION COMPLETED SUCCESSFULLY!' }
        'softreboot-3010'  = @{ Lines = @("$ts app Install parent=x64-direct exit=3010 result=SoftReboot"); Expect = 'True|True|3010|SoftReboot|INSTALLATION COMPLETED SUCCESSFULLY!' }
        'hardreboot-1641'  = @{ Lines = @("$ts app Install parent=x86-cmd exit=1641 result=HardReboot"); Expect = 'True|True|1641|HardReboot|INSTALLATION COMPLETED SUCCESSFULLY!' }
        'failed-60008'     = @{ Lines = @("$ts app Install parent=x64-direct exit=60008 result=Failed"); Expect = 'True|False|60008|Failed|INSTALLATION FAILED (exit 60008, Failed) - see C:\PSADT\Sandbox\Logs' }
        'timeout'          = @{ Lines = @("$ts app Install parent=x64-direct exit=1460 result=Timeout"); Expect = 'True|False|1460|Timeout|INSTALLATION FAILED (exit 1460, Timeout) - see C:\PSADT\Sandbox\Logs' }
        'no-cmdline-87'    = @{ Lines = @("$ts app Install parent=none exit=87 result=Failed (no Intune command line for Install)"); Expect = 'True|False|87|Failed|INSTALLATION FAILED (exit 87, Failed) - see C:\PSADT\Sandbox\Logs' }
        'later-uninstall'  = @{ Lines = @("$ts app Install parent=x64-direct exit=0 result=Success", "$ts app Uninstall parent=x64-direct exit=60001 result=Failed"); Expect = 'True|True|0|Success|INSTALLATION COMPLETED SUCCESSFULLY!' }
        'last-install-wins' = @{ Lines = @("$ts dep Install parent=x64-direct exit=0 result=Success", "$ts app Install parent=x64-direct exit=60001 result=Failed", "$ts app Uninstall parent=x64-direct exit=0 result=Success"); Expect = 'True|False|60001|Failed|INSTALLATION FAILED (exit 60001, Failed) - see C:\PSADT\Sandbox\Logs' }
        'update-baseline'  = @{ Lines = @("$ts baseline Install parent=x64-direct exit=0 result=Success"); Expect = 'True|True|0|Success|INSTALLATION COMPLETED SUCCESSFULLY!' }
        'only-uninstall'   = @{ Lines = @("$ts app Uninstall parent=x64-direct exit=0 result=Success"); Expect = 'False|False||' + '|INSTALLATION FINISHED (no exit code recorded)' }
        'no-log'           = @{ Lines = $null; Expect = 'False|False||' + '|INSTALLATION FINISHED (no exit code recorded)' }
    }
    $harness = $fn.Extent.Text + "`r`n" + @'
foreach ($f in $args) {
    $installVerdict = Get-W32tInstallVerdict -LogPath $f
'@ + "`r`n" + $verdictIf.Extent.Text + "`r`n" + @'
    'V=' + [string]$installVerdict.Known + '|' + [string]$installVerdict.Ok + '|' + [string]$installVerdict.Exit + '|' + [string]$installVerdict.Result + '|' + $verdictText
}
'@
    $hFile = Join-Path $root 'harness.ps1'
    [System.IO.File]::WriteAllText($hFile, $harness, $utf8Bom)
    $files = @()
    foreach ($name in $cases.Keys) {
        $f = Join-Path $root "$name.log"
        if ($null -ne $cases[$name].Lines) { [System.IO.File]::WriteAllText($f, (($cases[$name].Lines -join "`r`n") + "`r`n"), $utf8Bom) }
        $files += $f
    }
    $out = @(& $ps51 -NoProfile -ExecutionPolicy Bypass -File $hFile @files 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -like 'V=*' })
    $i = 0
    foreach ($name in $cases.Keys) {
        $got = if ($i -lt $out.Count) { $out[$i].Substring(2) } else { '<missing>' }
        if ($got -eq $cases[$name].Expect) { Ok "${name}: $got" } else { Bad "${name}: got [$got] expected [$($cases[$name].Expect)]" }
        $i++
    }
}
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All CountdownVerdict tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail CountdownVerdict test(s) FAILED." -ForegroundColor Red; exit 1 }
