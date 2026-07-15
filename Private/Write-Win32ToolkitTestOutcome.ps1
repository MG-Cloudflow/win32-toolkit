function Write-Win32ToolkitTestOutcome {
    <#
    .SYNOPSIS
        Records a completed test run into Documentation\TestResults.json (the history the customer
        Documentation.md reports).
    .DESCRIPTION
        Maps the tri-state verdict from Wait-Win32ToolkitUpdateAssertion ($true/$false/$null) to the
        persisted enum (Passed/Failed/Inconclusive), best-effort parses the per-assertion PASS/FAIL/SKIP
        lines out of the run's assertion log, and appends one entry via Add-Win32ToolkitTestResult.

        Never throws — documenting a run must not fail the run. A recording failure is a warning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateSet('InstallUninstall', 'Update')]
        [string]$Scenario,

        [Parameter(Mandatory)]
        [ValidateSet('Sandbox', 'HyperV')]
        [string]$Backend,

        [ValidateSet('Interactive', 'Unattended')]
        [string]$Mode = 'Unattended',

        # The raw verdict object from Wait-Win32ToolkitUpdateAssertion: $true / $false / $null.
        $Verdict,

        # The assertion log for this scenario (parsed for per-assertion detail).
        [string]$LogFileName = 'UpdateAssertions.log',

        [string]$Notes = ''
    )

    $v = if ($Verdict -eq $true) { 'Passed' } elseif ($Verdict -eq $false) { 'Failed' } else { 'Inconclusive' }

    # Best-effort per-assertion detail from the log (may be absent on an early abort — that's fine).
    $assertions = @()
    $logPath = Join-Path $ProjectPath (Join-Path 'Sandbox\Logs' $LogFileName)
    if (Test-Path -LiteralPath $logPath) {
        $seen = [ordered]@{}
        foreach ($line in @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)) {
            if ($line -match 'ASSERT\s+(\S+)\s*=\s*(PASS|FAIL|SKIP)') { $seen[$Matches[1]] = $Matches[2] }
        }
        $assertions = @($seen.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Result = $_.Value } })
    }

    try {
        $null = Add-Win32ToolkitTestResult -ProjectPath $ProjectPath -Scenario $Scenario -Backend $Backend `
            -Mode $Mode -Verdict $v -Assertions $assertions -Notes $Notes
        Write-Verbose "Recorded test result: $Scenario / $Backend = $v"
    }
    catch {
        Write-Warning "Could not record the test result to Documentation\TestResults.json: $($_.Exception.Message)"
    }
}
