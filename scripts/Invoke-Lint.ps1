<#
    PSScriptAnalyzer lint gate for win32-toolkit.

    Analyses Private\, Public\ and the module manifest/loader (.psd1 / .psm1) with the
    repo's PSScriptAnalyzerSettings.psd1 (which already excludes the intentional
    Write-Host UX rule). Prints every finding, but only FAILS the build (exit 1) on
    severity Error. Warnings are reported for visibility and do not fail the gate.

    Run:  pwsh -File scripts\Invoke-Lint.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo     = Split-Path -Parent $PSScriptRoot
$settings = Join-Path $repo 'PSScriptAnalyzerSettings.psd1'

# Install PSScriptAnalyzer only if it isn't already available (no-op otherwise).
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host 'PSScriptAnalyzer not found; installing to CurrentUser scope...' -ForegroundColor Yellow
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module PSScriptAnalyzer -ErrorAction Stop

# Targets: the two source folders (recursed) plus the top-level manifest and loader.
$targets = @(
    Join-Path $repo 'Private'
    Join-Path $repo 'Public'
    Join-Path $repo 'win32-toolkit.psm1'
    Join-Path $repo 'win32-toolkit.psd1'
) | Where-Object { Test-Path -LiteralPath $_ }

$findings = @()
foreach ($t in $targets) {
    $findings += Invoke-ScriptAnalyzer -Path $t -Recurse -Settings $settings
}

if ($findings.Count -eq 0) {
    Write-Host 'PSScriptAnalyzer: no findings.' -ForegroundColor Green
    exit 0
}

# Show everything, grouped for readability.
$findings |
    Sort-Object Severity, ScriptName, Line |
    Format-Table -AutoSize Severity, RuleName,
        @{ Name = 'File'; Expression = { Split-Path -Leaf $_.ScriptName } }, Line, Message |
    Out-String -Width 200 | Write-Host

$errors   = @($findings | Where-Object Severity -eq 'Error')
$warnings = @($findings | Where-Object Severity -eq 'Warning')

Write-Host ("PSScriptAnalyzer: {0} error(s), {1} warning(s)." -f $errors.Count, $warnings.Count) `
    -ForegroundColor $(if ($errors.Count -gt 0) { 'Red' } else { 'Yellow' })

if ($errors.Count -gt 0) {
    Write-Host 'Lint FAILED: Error-severity findings must be fixed.' -ForegroundColor Red
    exit 1
}

Write-Host 'Lint passed (warnings do not fail the gate).' -ForegroundColor Green
exit 0
