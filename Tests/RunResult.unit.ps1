<#
    The Win32Toolkit.RunResult contract (TUI audit G2, S8-F3; tui-gaps-spec 6.2 / 6.3).

    Initialize-Win32ToolkitRunResult creates the mutable collector; Complete-Win32ToolkitRunResult returns a NEW
    object with the contract properties in order (arrays, not lists), the type name Win32Toolkit.RunResult first,
    the default display ProjectName / Status / Problems, and the Status rules:
      1. Failed (-Failed, even with problems)   2. Scaffolded (-Scaffolded and no problem)
      3. CompletedWithProblems (any problem)    4. Succeeded

    Pure helpers: no shadows, no disk.

    Run:  pwsh -File Tests\RunResult.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Initialize-Win32ToolkitRunResult.ps1')
. (Join-Path $repo 'Private\Complete-Win32ToolkitRunResult.ps1')

Write-Host '[1] the collector' -ForegroundColor Cyan
$c = Initialize-Win32ToolkitRunResult -Command 'Invoke-Win32Toolkit' -Mode 'Winget'
if ($c.Command -eq 'Invoke-Win32Toolkit' -and $c.Mode -eq 'Winget' -and $c.Status -eq 'Running' -and $c.Capture -eq 'NotRun' -and $c.ProjectPath -eq '' -and $c.ProjectName -eq '' -and $c.IntuneWinPath -eq '' -and
    $c.Tests -is [System.Collections.Generic.List[object]] -and $c.Published -is [System.Collections.Generic.List[object]] -and $c.Problems -is [System.Collections.Generic.List[string]]) {
    Ok 'Initialize: Status Running, Capture NotRun, empty paths, Tests/Published List[object], Problems List[string]'
} else { Bad "collector: $($c | ConvertTo-Json -Compress)" }
$m = Initialize-Win32ToolkitRunResult -Command 'New-Win32ToolkitManualApp'
if ($m.Mode -eq '') { Ok 'Initialize without -Mode -> Mode empty' } else { Bad "mode '$($m.Mode)'" }

Write-Host '[2] the Status rules' -ForegroundColor Cyan
$new = { param($Problems) $x = Initialize-Win32ToolkitRunResult -Command 'X'; foreach ($p in @($Problems)) { if ($p) { $x.Problems.Add($p) } }; $x }
$cases = @(
    @{ Name = 'no problem, no switch';            Problems = @();        Args = @{};                                  Want = 'Succeeded' }
    @{ Name = 'a problem';                        Problems = @('p1');    Args = @{};                                  Want = 'CompletedWithProblems' }
    @{ Name = '-Failed without a problem';        Problems = @();        Args = @{ Failed = $true };                  Want = 'Failed' }
    @{ Name = '-Failed wins over problems';       Problems = @('p1');    Args = @{ Failed = $true };                  Want = 'Failed' }
    @{ Name = '-Scaffolded without a problem';    Problems = @();        Args = @{ Scaffolded = $true };              Want = 'Scaffolded' }
    @{ Name = '-Scaffolded with a problem';       Problems = @('p1');    Args = @{ Scaffolded = $true };              Want = 'CompletedWithProblems' }
    @{ Name = '-Failed wins over -Scaffolded';    Problems = @();        Args = @{ Failed = $true; Scaffolded = $true }; Want = 'Failed' }
)
foreach ($k in $cases) {
    $collector = & $new $k.Problems
    $ca = $k.Args
    $r = Complete-Win32ToolkitRunResult -Result $collector @ca
    if ($r.Status -ceq $k.Want) { Ok "$($k.Name) -> $($k.Want)" } else { Bad "$($k.Name): got '$($r.Status)', want '$($k.Want)'" }
}
$blank = & $new @('   ')
if ((Complete-Win32ToolkitRunResult -Result $blank).Status -eq 'Succeeded') { Ok 'a blank problem line is not a problem' } else { Bad 'a blank problem counted' }

Write-Host '[3] the shape' -ForegroundColor Cyan
$c = Initialize-Win32ToolkitRunResult -Command 'Complete-Win32ToolkitManualApp' -Mode 'Finalize'
$c.ProjectPath = 'C:\B\Projects\T\App_x64_1.0'; $c.ProjectName = 'App_x64_1.0'; $c.Capture = 'Done'; $c.IntuneWinPath = 'C:\B\IntuneWin\T\App_x64_1.0.intunewin'
$c.Tests.Add([pscustomobject]@{ Scenario = 'InstallUninstall'; Verdict = 'Passed' })
$c.Published.Add([pscustomobject]@{ AppId = 'a'; DisplayName = 'App'; IsUpdateApp = $false; PortalUri = 'https://x' })
$c.Problems.Add('one')
$r = Complete-Win32ToolkitRunResult -Result $c
$order = 'Command,ProjectPath,ProjectName,Mode,Status,Capture,Tests,IntuneWinPath,Published,Problems'
if (($r.PSObject.Properties.Name -join ',') -ceq $order) { Ok "properties in the contract order: $order" } else { Bad "order: $($r.PSObject.Properties.Name -join ',')" }
if ($r.Tests -is [object[]] -and $r.Published -is [object[]] -and $r.Problems -is [string[]]) { Ok 'Tests and Published are [object[]], Problems is [string[]] (arrays, not lists)' } else { Bad "types: $($r.Tests.GetType().Name), $($r.Published.GetType().Name), $($r.Problems.GetType().Name)" }
$e = Complete-Win32ToolkitRunResult -Result (Initialize-Win32ToolkitRunResult -Command 'X')
if ($e.Tests -is [object[]] -and $e.Tests.Count -eq 0 -and $e.Problems -is [string[]] -and $e.Problems.Count -eq 0 -and $e.Published -is [object[]]) { Ok 'empty lists become empty arrays (never $null)' } else { Bad 'an empty list did not become an empty array' }
if ($r.PSObject.TypeNames[0] -ceq 'Win32Toolkit.RunResult') { Ok 'the first type name is Win32Toolkit.RunResult' } else { Bad "type names: $($r.PSObject.TypeNames -join ', ')" }
$dd = $r.PSStandardMembers.DefaultDisplayPropertySet.ReferencedPropertyNames
if (($dd -join ',') -ceq 'ProjectName,Status,Problems') { Ok 'the default display is ProjectName, Status, Problems' } else { Bad "default display: $($dd -join ',')" }
$json = $r | ConvertTo-Json -Depth 5
if ($json -notmatch 'PSStandardMembers' -and $json -match '"Status": "CompletedWithProblems"') { Ok 'ConvertTo-Json carries the data and no PSStandardMembers' } else { Bad "json: $json" }
if ($r.Command -eq 'Complete-Win32ToolkitManualApp' -and $r.Mode -eq 'Finalize' -and $r.Capture -eq 'Done' -and $r.IntuneWinPath -like '*.intunewin' -and $r.Tests[0].Verdict -eq 'Passed' -and $r.Published[0].AppId -eq 'a' -and $r.Problems[0] -eq 'one') { Ok 'the values are copied from the collector' } else { Bad "result: $json" }
$c.Problems.Add('two')
if ($r.Problems.Count -eq 1 -and $c.Status -eq 'Running') { Ok 'the result is a new object: a later change to the collector does not reach it, and the collector keeps Status Running' } else { Bad "result problems: $($r.Problems.Count), collector status: $($c.Status)" }
$line = ($r | Out-String)
if ($line -match 'App_x64_1\.0' -and $line -match 'CompletedWithProblems' -and $line -notmatch 'IntuneWinPath') { Ok 'the console shows the compact default display' } else { Bad "console: $line" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'RunResult unit test PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$fail FAILURE(S)" -ForegroundColor Red
exit 1
