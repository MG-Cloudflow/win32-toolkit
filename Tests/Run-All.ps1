<#
    Local test runner for win32-toolkit.

    The suites in this folder are HAND-ROLLED .ps1 scripts (NOT Pester): each one
    dot-sources the helpers it needs, asserts, and calls `exit 1` on failure.
    This runner discovers them, launches each in its OWN child pwsh so a crash or a
    stray `exit` in one suite can't take down the run, collects the exit codes, and
    prints a PASS/FAIL summary. It exits non-zero if ANY suite failed.

    Selection (not hard-coded — discovered from Tests\*.ps1):
      * every *.unit.ps1 and the offline *.integration.ps1 / *.smoke.ps1 suites run.
      * Run-All.ps1 (this file) is excluded.
      * env-gated LIVE suites (e.g. HyperV.integration.ps1, guarded by
        `-not $env:W32T_LIVE_HYPERV`) are SKIPPED unless their gate variable is set.
        The gate is detected by reading each file, so no suite name is hard-coded.

    Run:  pwsh -File Tests\Run-All.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testsDir = $PSScriptRoot
$self     = $MyInvocation.MyCommand.Path

# pwsh to re-launch each suite with. Prefer the executable running this script.
$pwsh = (Get-Process -Id $PID).Path
if (-not $pwsh) { $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
if (-not $pwsh) { $pwsh = 'pwsh' }

# Detect an env-gate of the form:  if (-not $env:W32T_LIVE_XXX) { ... exit 0 }
# Returns the gate variable name (e.g. 'W32T_LIVE_HYPERV') or $null if ungated.
function Get-SuiteGate {
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw
    $m = [regex]::Match($text, '-not\s+\$env:(W32T_LIVE_\w+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

$suites = Get-ChildItem -LiteralPath $testsDir -Filter '*.ps1' -File |
    Where-Object { $_.FullName -ne $self } |
    Sort-Object Name

$results = @()
foreach ($suite in $suites) {
    $gate = Get-SuiteGate -Path $suite.FullName
    if ($gate -and -not (Get-Item -Path ("Env:$gate") -ErrorAction SilentlyContinue)) {
        Write-Host ("SKIP  {0}  (gated by `$env:{1})" -f $suite.Name, $gate) -ForegroundColor DarkGray
        $results += [pscustomobject]@{ Name = $suite.Name; Status = 'SKIP'; ExitCode = $null }
        continue
    }

    Write-Host ("RUN   {0}" -f $suite.Name) -ForegroundColor Cyan
    & $pwsh -NoProfile -File $suite.FullName
    $code = $LASTEXITCODE
    $status = if ($code -eq 0) { 'PASS' } else { 'FAIL' }
    $color  = if ($code -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("{0}  {1}  (exit {2})" -f $status, $suite.Name, $code) -ForegroundColor $color
    Write-Host ''
    $results += [pscustomobject]@{ Name = $suite.Name; Status = $status; ExitCode = $code }
}

Write-Host '================ SUMMARY ================' -ForegroundColor White
foreach ($r in $results) {
    $color = switch ($r.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Write-Host ("  {0,-5} {1}" -f $r.Status, $r.Name) -ForegroundColor $color
}

$passed  = @($results | Where-Object Status -eq 'PASS').Count
$failed  = @($results | Where-Object Status -eq 'FAIL').Count
$skipped = @($results | Where-Object Status -eq 'SKIP').Count
Write-Host ''
Write-Host ("Total {0}: {1} passed, {2} failed, {3} skipped" -f $results.Count, $passed, $failed, $skipped) `
    -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })

if ($failed -gt 0) { exit 1 }
exit 0
