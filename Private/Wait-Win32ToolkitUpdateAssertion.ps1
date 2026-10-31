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
    .PARAMETER SinglePass
        Read the log once, no polling, no deadline (Hyper-V speed-up PR 1, D24): a Hyper-V run's log came back
        with the copy-out and cannot change. The verdict rules are the same (a FAIL is conclusive on a partial
        log, a pass needs RESULT COMPLETE).
    .PARAMETER RequiredAssertion
        Assertion names the scenario's guest script always writes (PASS, FAIL or SKIP). A complete log without one of
        them lost lines (live run SB-ENFORCE: a Windows Sandbox guest dropped seven PostUpdate lines), so the result is
        $null (inconclusive), never a pass; a FAIL stays conclusive.
    .PARAMETER HostCheck
        Host-side assertions of the same run (installer-identity PR 3 live rows OP-BLOCK, OP-NEWER, OP-OWN, KILL-NATIVE,
        KILL-WOW, APP-RUNNING, RC2-BLOCK: the update's exit code was recorded as a failed assertion only after the summary
        had counted the guest's): called once, after the log was read; it returns zero or more @{ Name; Result; Text }.
        They are listed with the guest's, a FAIL counts in the summary (listed first, its Text printed under it) and makes
        the result $false.
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
        [string]$Label = 'UPDATE TEST',

        # Read the log once (a Hyper-V run's log came back with the copy-out): no polling, no deadline.
        [switch]$SinglePass,

        # The names the guest always writes: a complete log missing one of them is inconclusive (installer-identity PR 3).
        [string[]]$RequiredAssertion = @(),

        # Host-side assertions of the run (@{ Name; Result; Text }), counted in the summary (installer-identity PR 3).
        [scriptblock]$HostCheck
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

    $deadline  = if ($SinglePass) { [datetime]::MaxValue } else { (Get-Date).AddMinutes($TimeoutMinutes) }
    # Ordered: the summary lists the failures in the order the guest wrote them.
    $announced = [ordered]@{}
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
                if ($line -match '^\s*(?:\[[^\]]*\]\s+)?ASSERT\s+(\S+)\s*=\s*(PASS|FAIL|SKIP)\b' -and -not $announced.Contains($Matches[1])) {
                    $announced[$Matches[1]] = $Matches[2]
                    $color = switch ($Matches[2]) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkYellow' } }
                    Write-Host "  ASSERT $($Matches[1]) = $($Matches[2])" -ForegroundColor $color
                }
            }
            if (@($content | Where-Object { $_ -match '^\s*(?:\[[^\]]*\]\s+)?RESULT COMPLETE\s*$' }).Count -gt 0) { $complete = $true; break }
        }
        if ($SinglePass) { break }
        Start-Sleep -Seconds $PollSeconds
    }

    # The host's own assertions of the run (the update's exit code), read once the guest log is: listed and counted too.
    $hostRows = @()
    if ($HostCheck) {
        $hostRows = @(& $HostCheck | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['Name'] -and @('PASS', 'FAIL', 'SKIP') -ccontains [string]$_['Result'] })
    }
    $guestCount = $announced.Count
    $hostFailed = [System.Collections.Generic.List[object]]::new()
    foreach ($h in $hostRows) {
        $hn = [string]$h['Name']
        if ($announced.Contains($hn)) { continue }
        $announced[$hn] = [string]$h['Result']
        if ([string]$h['Result'] -eq 'FAIL') { $hostFailed.Add($h) }
        $color = switch ([string]$h['Result']) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'DarkYellow' } }
        Write-Host "  ASSERT $hn = $($h['Result']) (host)" -ForegroundColor $color
    }

    Write-Host ''
    if (-not $complete -and $guestCount -eq 0) {
        if ($SinglePass) {
            Write-Warning "No assertion results came back from the Hyper-V run — the assertions never ran, or the run stopped before them. Check $logPath and Sandbox\Logs."
        }
        else {
            Write-Warning "No assertion results appeared within $TimeoutMinutes minutes — the sandbox may have been closed early or the baseline install may have hung. Check $logPath and Sandbox\Logs."
        }
        if ($hostFailed.Count -eq 0) { return $null }
    }

    # Failures are conclusive even on a partial run: the host's first (what the run itself did), then the guest's in the
    # order it wrote them.
    $failedNames = @(@($hostFailed | ForEach-Object { [string]$_['Name'] }) + @($announced.GetEnumerator() | Where-Object { $_.Value -eq 'FAIL' } | ForEach-Object { [string]$_.Key }) | Select-Object -Unique)
    if ($failedNames.Count -gt 0) {
        Write-Host "✗ $Label FAILED — $($failedNames.Count) assertion(s) failed: $($failedNames -join ', ')" -ForegroundColor Red
        foreach ($h in $hostFailed) { if ([string]$h['Text']) { Write-Host "  $([string]$h['Text'])" -ForegroundColor Yellow } }
        Write-Host "  Details: $logPath" -ForegroundColor Gray
        return $false
    }

    # A pass verdict requires a COMPLETE run — a partial run with a few early PASSes proves nothing
    # about the phases that never executed.
    if (-not $complete) {
        Write-Warning 'Assertions did not complete (no RESULT COMPLETE marker) — the run is INCONCLUSIVE, not a pass. Partial results above.'
        return $null
    }

    # A complete log that lacks an assertion the guest always writes lost lines: what it would have said is unknown.
    $missing = @($RequiredAssertion | Where-Object { $_ -and -not $announced.Contains($_) } | Select-Object -Unique)
    if ($missing.Count -gt 0) {
        Write-Warning "The assertions completed, but $($missing.Count) assertion(s) the guest always writes are missing ($($missing -join ', ')): lines of the log were lost, so the run is INCONCLUSIVE, not a pass. Details: $logPath"
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
