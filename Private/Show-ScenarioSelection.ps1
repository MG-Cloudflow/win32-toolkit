function Show-ScenarioSelection {
<#
.SYNOPSIS
    Displays a menu of available test scenarios and returns the user's choice.
#>
    [CmdletBinding()]
    param()

    $scenarios = @(
        [PSCustomObject]@{ Name = 'InstallUninstall'; Description = 'Install → 2-min countdown → Uninstall' }
        [PSCustomObject]@{ Name = 'Update';           Description = 'Install old version → 2-min countdown → Run PSADT update' }
    )

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host 'Test Scenario Selection'                   -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    Write-Host 'Available test scenarios:' -ForegroundColor Yellow
    Write-Host ''

    for ($i = 0; $i -lt $scenarios.Count; $i++) {
        Write-Host "  $($i + 1). $($scenarios[$i].Name)" -ForegroundColor White -NoNewline
        Write-Host " — $($scenarios[$i].Description)"    -ForegroundColor Gray
    }

    Write-Host ''
    do {
        $userInput = Read-Host "Select scenario (1-$($scenarios.Count))"

        # TryParse, not [int] on a '^\d+$' match: '99999999999999999999' IS all digits but overflows Int32,
        # so the cast threw straight out of the loop.
        $idx = 0
        if ([int]::TryParse(([string]$userInput).Trim(), [ref]$idx)) {
            if ($idx -ge 1 -and $idx -le $scenarios.Count) {
                return $scenarios[$idx - 1].Name
            }
        }

        Write-Host "Invalid selection. Please enter a number between 1 and $($scenarios.Count)." -ForegroundColor Red
    } while ($true)
}
