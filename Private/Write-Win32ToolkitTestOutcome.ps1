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
        -Timing and -Lane (a Hyper-V run's host measurements and VM identity, speed-up PR 1) are passed through
        to Add-Win32ToolkitTestResult when given, and so is -Proof (an Update run that checked prior-install rules).

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
        [string]$LogFolder = '',

        # A Hyper-V run's Timing and Lane (Invoke-Win32ToolkitHyperVRun -RunInfo); recorded when not $null.
        [hashtable]$Timing,

        [hashtable]$Lane,

        # An Update run that checked prior-install rules (installer-identity PR 3): Add-Win32ToolkitTestResult -Proof.
        # Callers pass it only when they built one, so runs without rules keep the old record shape.
        [hashtable]$Proof,

        # Host-side assertions recorded after the guest's (@{ Name; Result }), e.g. 'UpdateExitCode-PostUpdate = FAIL' when
        # the update exited outside the success codes (live run OP-OWN). A name the guest log already holds is kept as
        # the guest wrote it.
        [object[]]$ExtraAssertion = @()
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
    foreach ($x in @($ExtraAssertion | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['Name'] -and @('PASS', 'FAIL', 'SKIP') -ccontains [string]$_['Result'] })) {
        if (@($assertions | Where-Object { [string]$_.Name -eq [string]$x['Name'] }).Count -eq 0) { $assertions += @{ Name = [string]$x['Name']; Result = [string]$x['Result'] } }
    }

    $extra = @{}
    if ($PSBoundParameters.ContainsKey('Baseline') -and $null -ne $Baseline) { $extra['Baseline'] = $Baseline }
    if ($LogFolder) { $extra['LogFolder'] = $LogFolder }
    if ($PSBoundParameters.ContainsKey('Timing') -and $null -ne $Timing) { $extra['Timing'] = $Timing }
    if ($PSBoundParameters.ContainsKey('Lane') -and $null -ne $Lane) { $extra['Lane'] = $Lane }
    if ($PSBoundParameters.ContainsKey('Proof') -and $null -ne $Proof) { $extra['Proof'] = $Proof }
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
