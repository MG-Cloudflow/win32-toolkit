function Show-Win32ToolkitUiValidationSummary {
    <#
    .SYNOPSIS
        Prints a UI-validation report (from Compare-Win32ToolkitUiToTemplate) as a colored check list.
    .DESCRIPTION
        Plain Write-Host rendering (no Spectre renderables, so nothing leaks into a captured pipeline).
        Colors each check by status and prints a tally. HOST-ONLY presentation helper.
    .PARAMETER RunName
        Label for the run (Install / Defer / Uninstall).
    .PARAMETER Result
        The object returned by Invoke-Win32ToolkitUiValidation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RunName,
        [Parameter(Mandatory)] $Result
    )

    if (-not $Result) { Write-Host "  [$RunName] no result." -ForegroundColor DarkYellow; return }

    $exit = $Result.DriverExit
    $exitText = switch ("$exit") {
        '0' { 'COMPLETE' }
        '2' { 'TIMEOUT' }
        '3' { 'ERROR (driver setup)' }
        default { "exit $exit" }
    }
    $exitColor = if ($exit -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host ("  Driver result : {0}" -f $exitText) -ForegroundColor $exitColor

    $report = $Result.Report
    if (-not $report) {
        Write-Host '  No state-log came back — nothing to validate. Check the VM interactive logon.' -ForegroundColor Yellow
        return
    }

    foreach ($c in $report.Checks) {
        $tag, $color = switch ($c.Status) {
            'PASS' { 'PASS', 'Green' }
            'FAIL' { 'FAIL', 'Red' }
            'WARN' { 'WARN', 'Yellow' }
            'GAP' { 'GAP ', 'Cyan' }
            default { $c.Status, 'Gray' }
        }
        Write-Host ("    [{0}] {1}" -f $tag, $c.Name) -ForegroundColor $color
        if ($c.Status -in @('FAIL', 'WARN', 'GAP')) {
            Write-Host ("           expected: {0}" -f $c.Expected) -ForegroundColor DarkGray
            Write-Host ("           observed: {0}" -f $c.Observed) -ForegroundColor DarkGray
        }
    }

    $s = $report.Summary
    Write-Host ("  Tally: {0} pass, {1} fail, {2} warn, {3} visual-gap" -f $s.Pass, $s.Fail, $s.Warn, $s.Gap) -ForegroundColor White
}
