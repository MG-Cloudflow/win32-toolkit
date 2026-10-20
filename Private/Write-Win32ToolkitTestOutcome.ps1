function Write-Win32ToolkitTestOutcome {
    <#
    .SYNOPSIS
        Records a completed test run into Documentation\TestResults.json (the history the customer
        Documentation.md reports).
    .DESCRIPTION
        Maps the tri-state verdict from Wait-Win32ToolkitUpdateAssertion ($true/$false/$null) to the
        persisted enum (Passed/Failed/Inconclusive), best-effort parses the per-assertion PASS/FAIL/SKIP
        lines out of the run's assertion log, and appends one entry via Add-Win32ToolkitTestResult.

        For the Update scenario it also records the baseline variant (-Baseline, passed through) and the
        old-version ARP entries named by a failed OldArpGone-PostUpdate line (ConvertFrom-Win32ToolkitArpSurvivor),
        so a technology switch can be reported later (installer-identity PR 1, spec 2.11 and 2.12).

        -LogFolder records where the run's own logs were kept (Sandbox\Logs\Runs\<run>, test campaign F2); the
        assertions are still read from the top-level log, which is this run's until the next run starts.

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

        [string]$Notes = '',

        # Update scenario: the baseline variant of this run (Add-Win32ToolkitTestResult -Baseline).
        [hashtable]$Baseline,

        # The run's own log folder, relative to the project (Sandbox\Logs\Runs\<run>, Save-Win32ToolkitTestRunLog).
        # Recorded as LogFolder when not empty.
        [AllowEmptyString()]
        [string]$LogFolder = ''
    )

    $v = if ($Verdict -eq $true) { 'Passed' } elseif ($Verdict -eq $false) { 'Failed' } else { 'Inconclusive' }

    # Best-effort per-assertion detail from the log (may be absent on an early abort — that's fine).
    $assertions = @()
    $arpFailLine = $null
    $logPath = Join-Path $ProjectPath (Join-Path 'Sandbox\Logs' $LogFileName)
    if (Test-Path -LiteralPath $logPath) {
        $seen = [ordered]@{}
        foreach ($line in @(Get-Content -LiteralPath $logPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line -match 'ASSERT\s+(\S+)\s*=\s*(PASS|FAIL|SKIP)') {
                $seen[$Matches[1]] = $Matches[2]
                if ($Matches[1] -eq 'OldArpGone-PostUpdate') { $arpFailLine = if ($Matches[2] -eq 'FAIL') { $line } else { $null } }
            }
        }
        $assertions = @($seen.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Result = $_.Value } })
    }

    $extra = @{}
    if ($PSBoundParameters.ContainsKey('Baseline') -and $null -ne $Baseline) { $extra['Baseline'] = $Baseline }
    if ($LogFolder) { $extra['LogFolder'] = $LogFolder }
    if ($Scenario -eq 'Update' -and $arpFailLine) {
        # The old version's ARP entries that survived the update (host-side parse of the guest line, L5).
        try {
            $survivors = @(ConvertFrom-Win32ToolkitArpSurvivor -Line $arpFailLine)
            if ($survivors.Count -gt 0) { $extra['OldArpSurvivors'] = $survivors }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Could not read the surviving ARP entries: $($_.Exception.Message)"
        }
    }

    try {
        $null = Add-Win32ToolkitTestResult -ProjectPath $ProjectPath -Scenario $Scenario -Backend $Backend `
            -Mode $Mode -Verdict $v -Assertions $assertions -Notes $Notes @extra
        Write-Verbose "Recorded test result: $Scenario / $Backend = $v"
    }
    catch {
        Write-Warning "Could not record the test result to Documentation\TestResults.json: $($_.Exception.Message)"
    }
}
