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
        [int]$PollSeconds = 10,

        # Which backend produced the log — affects the host-side wording only, never the verdict. Sandbox
        # streams the log LIVE while the sandbox runs; the Hyper-V run is already finished by the time we
        # read it (the log was copied back), so "waiting for the sandbox" would be nonsense there.
        [ValidateSet('Sandbox', 'HyperV')]
        [string]$Backend = 'Sandbox',

        # The assertion log to parse and the label used in the host-side summary. Defaults keep the Update
        # scenario byte-identical; the InstallUninstall scenario passes 'InstallAssertions.log' / 'INSTALL TEST'.
        # The ASSERT-line regex and the RESULT COMPLETE marker are shared, so nothing else changes per scenario.
        [ValidateNotNullOrEmpty()]
        [string]$LogFileName = 'UpdateAssertions.log',

        [ValidateNotNullOrEmpty()]
        [string]$Label = 'UPDATE TEST'
    )

    $logPath = Join-Path $ProjectPath (Join-Path 'Sandbox\Logs' $LogFileName)

    Write-Host ''
    if ($Backend -eq 'HyperV') {
        Write-Host 'Reading the assertions from the completed Hyper-V run...' -ForegroundColor Yellow
        Write-Host "  Log: $logPath" -ForegroundColor Gray
    }
    else {
        Write-Host "Waiting for in-sandbox assertions (up to $TimeoutMinutes min)..." -ForegroundColor Yellow
        Write-Host "  Live log: $logPath" -ForegroundColor Gray
        Write-Host '  (The sandbox keeps running independently of this wait.)' -ForegroundColor Gray
    }

    $deadline  = (Get-Date).AddMinutes($TimeoutMinutes)
    $announced = @{}
    $complete  = $false

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $logPath) {
            $content = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
            foreach ($line in $content) {
                # ANCHORED: a real assertion line is "[timestamp] ASSERT <name> = <result>" — ASSERT must be the
                # first token (after the optional timestamp). Untrusted values (e.g. an app DisplayName) are
                # echoed into DIAGNOSTIC lines by the guest; an unanchored scan would let a crafted name like
                # "Widget ASSERT Rigged = FAIL" forge a result and corrupt the verdict. The timestamp prefix is
                # optional so bare-line test fixtures still parse.
                if ($line -match '^\s*(?:\[[^\]]*\]\s+)?ASSERT\s+(\S+)\s*=\s*(PASS|FAIL|SKIP)\b' -and -not $announced.ContainsKey($Matches[1])) {
                    $announced[$Matches[1]] = $Matches[2]
                    $color = switch ($Matches[2]) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkYellow' } }
                    Write-Host "  ASSERT $($Matches[1]) = $($Matches[2])" -ForegroundColor $color
                }
            }
            if (@($content | Where-Object { $_ -match '^\s*(?:\[[^\]]*\]\s+)?RESULT COMPLETE\s*$' }).Count -gt 0) { $complete = $true; break }
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
        Write-Host "✗ $Label FAILED — $($failed.Count) assertion(s) failed: $(($failed | ForEach-Object { $_.Key }) -join ', ')" -ForegroundColor Red
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
        Write-Host "✓ $Label PASSED — $($passed.Count) assertion(s) passed$(if ($announced.Count -gt $passed.Count) { ", $($announced.Count - $passed.Count) skipped" })." -ForegroundColor Green
        return $true
    }

    Write-Warning 'All assertions were skipped — nothing was verified (no requirement script / tattoo values). Regenerate the project and re-run.'
    return $null
}
