<#
    Test campaign F5: an Update test with no baseline version, run from a console started with
    'pwsh -NonInteractive' (a scheduled task, a script), reached the version picker's Read-Host, which throws
    there: no verdict, and packaging went on untested. Test-Win32ToolkitHostNonInteractive does not see that
    case (UserInteractive is true, input not redirected); Test-Win32ToolkitNonInteractiveSwitch does.

      [1] the command line: -NonInteractive and the prefixes pwsh accepts (-noni ...), '-', '--' or '/', only
          before -File / -Command / -CommandWithArgs / -EncodedCommand; other switches and values are not it
      [2] only the console host honours the switch (the VS Code integrated console runs in a process started
          with -NonInteractive and can still prompt)
      [3] real child processes: 'pwsh -NonInteractive' -> $true, plain 'pwsh' -> $false
      [4] the real picker (Show-VersionSelection) under 'pwsh -NonInteractive' fails with exactly the error id
          Test-Win32ToolkitProject falls back on (InvalidOperation,Microsoft.PowerShell.Commands.ReadHostCommand)
      [5] source: C-2 catch, ASCII

    Run:  pwsh -File Tests\NonInteractiveSwitch.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'a hand-rolled test suite: coloured PASS/FAIL lines on the console')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$predicateFile = Join-Path $repo 'Private\Test-Win32ToolkitNonInteractiveSwitch.ps1'
. $predicateFile

Write-Host '[1] the command line' -ForegroundColor Cyan
$exe = 'C:\Program Files\PowerShell\7\pwsh.dll'
$cases = [ordered]@{
    '-NonInteractive -File x.ps1'                 = @{ Args = @('-NonInteractive', '-File', 'x.ps1'); Want = $true }
    '-NoProfile -noni -Command ...'               = @{ Args = @('-NoProfile', '-noni', '-Command', 'Get-Date'); Want = $true }
    '-nonin (a longer prefix)'                    = @{ Args = @('-nonin'); Want = $true }
    '/NonInteractive'                             = @{ Args = @('/NonInteractive'); Want = $true }
    '--noninteractive'                            = @{ Args = @('--noninteractive'); Want = $true }
    '-NONINTERACTIVE (case)'                      = @{ Args = @('-NONINTERACTIVE'); Want = $true }
    '-ExecutionPolicy Bypass -noni'               = @{ Args = @('-ExecutionPolicy', 'Bypass', '-noni'); Want = $true }
    'no switch'                                   = @{ Args = @('-NoProfile', '-File', 'x.ps1'); Want = $false }
    '-non (too short)'                            = @{ Args = @('-non'); Want = $false }
    '-NoProfile / -NoLogo / -NoExit'              = @{ Args = @('-NoProfile', '-NoLogo', '-NoExit'); Want = $false }
    '-NonInteractiveX (not a prefix)'             = @{ Args = @('-NonInteractiveX'); Want = $false }
    'after -File (a script argument)'             = @{ Args = @('-File', 'x.ps1', '-NonInteractive'); Want = $false }
    'after -f'                                    = @{ Args = @('-f', 'x.ps1', '-noni'); Want = $false }
    'after -Command'                              = @{ Args = @('-Command', 'x', '-noni'); Want = $false }
    'after -c'                                    = @{ Args = @('-c', 'x', '-noni'); Want = $false }
    'after -EncodedCommand / -ec / -e'            = @{ Args = @('-ec', 'AAAA', '-noni'); Want = $false }
    'after -CommandWithArgs / -cwa'               = @{ Args = @('-cwa', 'x', '-noni'); Want = $false }
    'a value that looks like the switch'          = @{ Args = @('-WorkingDirectory', 'noninteractive'); Want = $false }
    'nothing but the executable'                  = @{ Args = @(); Want = $false }
}
foreach ($name in $cases.Keys) {
    $c = $cases[$name]
    $got = Test-Win32ToolkitNonInteractiveSwitch -CommandLineArgs (@($exe) + @($c.Args)) -HostName 'ConsoleHost'
    if ($got -eq $c.Want) { Ok "${name}: $got" } else { Bad "${name}: got $got, expected $($c.Want)" }
}
# The executable itself is never read as a switch.
if (-not (Test-Win32ToolkitNonInteractiveSwitch -CommandLineArgs @('/noninteractive') -HostName 'ConsoleHost')) { Ok 'the first entry (the executable) is skipped' } else { Bad 'the executable was read as a switch' }

Write-Host '[2] only the console host honours the switch' -ForegroundColor Cyan
foreach ($h in 'Visual Studio Code Host', 'ServerRemoteHost', 'Default Host', '') {
    if (-not (Test-Win32ToolkitNonInteractiveSwitch -CommandLineArgs @($exe, '-NonInteractive') -HostName $h)) { Ok "host '$h' -> `$false (it can still prompt)" } else { Bad "host '$h' -> `$true" }
}

Write-Host '[3] real child processes' -ForegroundColor Cyan
$pwsh = (Get-Process -Id $PID).Path
$probe = ". '$($predicateFile.Replace("'", "''"))'; [string](Test-Win32ToolkitNonInteractiveSwitch)"
$withSwitch = @(& $pwsh -NoProfile -NonInteractive -Command $probe 2>&1 | ForEach-Object { "$_" })
if ($withSwitch[-1] -eq 'True') { Ok "pwsh -NoProfile -NonInteractive -Command ... -> True" } else { Bad "with -NonInteractive: $($withSwitch -join ' | ')" }
$withoutSwitch = @(& $pwsh -NoProfile -Command $probe 2>&1 | ForEach-Object { "$_" })
if ($withoutSwitch[-1] -eq 'False') { Ok "pwsh -NoProfile -Command ... -> False" } else { Bad "without -NonInteractive: $($withoutSwitch -join ' | ')" }

Write-Host '[4] the real picker under pwsh -NonInteractive fails with the ReadHostCommand error id' -ForegroundColor Cyan
$pickerFile = Join-Path $repo 'Private\Show-VersionSelection.ps1'
$pickerProbe = ". '$($pickerFile.Replace("'", "''"))'; try { `$null = Show-VersionSelection -Versions @('2.0', '1.0') 6>`$null; 'NO-THROW' } catch { `$_.FullyQualifiedErrorId }"
$pickerOut = @(& $pwsh -NoProfile -NonInteractive -Command $pickerProbe 2>&1 | ForEach-Object { "$_" })
if ($pickerOut[-1] -eq 'InvalidOperation,Microsoft.PowerShell.Commands.ReadHostCommand') { Ok "Show-VersionSelection throws '$($pickerOut[-1])' (the id Test-Win32ToolkitProject falls back on)" } else { Bad "picker: $($pickerOut -join ' | ')" }
$tpSrc = [System.IO.File]::ReadAllText((Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1'))
if ($tpSrc.Contains("-notlike '*,Microsoft.PowerShell.Commands.ReadHostCommand'") -and $tpSrc -match '\(Test-Win32ToolkitNonInteractiveSwitch\)') { Ok 'Test-Win32ToolkitProject checks the switch and falls back on that error id' } else { Bad 'Test-Win32ToolkitProject does not use the switch check / the error id' }

Write-Host '[5] source' -ForegroundColor Cyan
$ast = [System.Management.Automation.Language.Parser]::ParseFile($predicateFile, [ref]$null, [ref]$null)
$catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
$ascii = @([System.IO.File]::ReadAllBytes($predicateFile) | Where-Object { $_ -gt 127 }).Count -eq 0
if ($catches.Count -eq 1 -and ($catches[0].Body.Statements[0].Extent.Text -replace '\s+', ' ') -eq $c2 -and $ascii) { Ok 'one catch with the C-2 line; ASCII' } else { Bad "catches=$($catches.Count) ascii=$ascii" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All NonInteractiveSwitch tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail NonInteractiveSwitch test(s) FAILED." -ForegroundColor Red; exit 1 }
