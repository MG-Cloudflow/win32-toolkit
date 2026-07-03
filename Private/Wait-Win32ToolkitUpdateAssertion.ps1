function Wait-Win32ToolkitUpdateAssertion {
    <#
    .SYNOPSIS
        Waits for the Update test's in-sandbox assertions and reports a real pass/fail verdict.
    .DESCRIPTION
        Polls <project>\Sandbox\Logs\UpdateAssertions.log (written live by the generated
        UpdateAssertions.ps1 running inside Windows Sandbox — the project folder is mapped
        read/write). Streams each 'ASSERT <name> = PASS|FAIL|SKIP' line as it appears (Requirement-*,
        Tattoo-PostUpdate, OldArpGone-PostUpdate, and TattooBaseline-PreUpdate in -BaselineProjectPath
        mode), stops at 'RESULT COMPLETE' (or the timeout), and prints a summary verdict. The regex is
        name-agnostic, so new assertion names need no change here.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder.
    .PARAMETER TimeoutMinutes
        How long to wait for the sandbox run to finish (default 30 — old install + 2-min countdown +
        PSADT update can be slow on first sandbox boot).
    .OUTPUTS
        $true  — assertions completed, none failed.
        $false — at least one assertion FAILED.
        $null  — timed out / no assertion data (e.g. the sandbox was closed early).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [ValidateRange(0, 240)]
        [double]$TimeoutMinutes = 30,

        # Poll interval; short values are used by the unit tests.
        [ValidateRange(1, 60)]
        [int]$PollSeconds = 10
    )

    $logPath = Join-Path $ProjectPath 'Sandbox\Logs\UpdateAssertions.log'

    Write-Host ''
    Write-Host "Waiting for in-sandbox update assertions (up to $TimeoutMinutes min)..." -ForegroundColor Yellow
    Write-Host "  Live log: $logPath" -ForegroundColor Gray
    Write-Host '  (The sandbox keeps running independently of this wait.)' -ForegroundColor Gray

    $deadline  = (Get-Date).AddMinutes($TimeoutMinutes)
    $announced = @{}
    $complete  = $false

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $logPath) {
            $content = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
            foreach ($line in $content) {
                if ($line -match 'ASSERT\s+(\S+)\s*=\s*(PASS|FAIL|SKIP)' -and -not $announced.ContainsKey($Matches[1])) {
                    $announced[$Matches[1]] = $Matches[2]
                    $color = switch ($Matches[2]) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkYellow' } }
                    Write-Host "  ASSERT $($Matches[1]) = $($Matches[2])" -ForegroundColor $color
                }
            }
            if ($content -match 'RESULT COMPLETE') { $complete = $true; break }
        }
        Start-Sleep -Seconds $PollSeconds
    }

    Write-Host ''
    if (-not $complete -and $announced.Count -eq 0) {
        Write-Warning "No assertion results appeared within $TimeoutMinutes minutes — the sandbox may have been closed early or the baseline install may have hung. Check $logPath and Sandbox\Logs."
        return $null
    }

    # Failures are conclusive even on a partial run.
    $failed = @($announced.GetEnumerator() | Where-Object { $_.Value -eq 'FAIL' })
    if ($failed.Count -gt 0) {
        Write-Host "✗ UPDATE TEST FAILED — $($failed.Count) assertion(s) failed: $(($failed | ForEach-Object { $_.Key }) -join ', ')" -ForegroundColor Red
        Write-Host "  Details: $logPath" -ForegroundColor Gray
        return $false
    }

    # A pass verdict requires a COMPLETE run — a partial run with a few early PASSes proves nothing
    # about the phases that never executed.
    if (-not $complete) {
        Write-Warning 'Assertions did not complete (no RESULT COMPLETE marker) — the run is INCONCLUSIVE, not a pass. Partial results above.'
        return $null
    }

    $passed = @($announced.GetEnumerator() | Where-Object { $_.Value -eq 'PASS' })
    if ($passed.Count -gt 0) {
        Write-Host "✓ UPDATE TEST PASSED — $($passed.Count) assertion(s) passed$(if ($announced.Count -gt $passed.Count) { ", $($announced.Count - $passed.Count) skipped" })." -ForegroundColor Green
        return $true
    }

    Write-Warning 'All assertions were skipped — nothing was verified (no requirement script / tattoo values). Regenerate the project and re-run.'
    return $null
}
