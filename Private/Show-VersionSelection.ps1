function Show-VersionSelection {
<#
.SYNOPSIS
    Displays a numbered list of available versions and returns the user's selection.
#>
    param(
        [Parameter(Mandatory = $true)]
        [array]$Versions
    )

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host 'Version Selection'                         -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    Write-Host 'Available older versions (newest first):' -ForegroundColor Yellow
    Write-Host ''

    for ($i = 0; $i -lt $Versions.Count; $i++) {
        Write-Host "  $($i + 1). $($Versions[$i])" -ForegroundColor White
    }

    Write-Host ''
    do {
        $userInput = Read-Host "Select version to use as baseline (1-$($Versions.Count))"

        if ($userInput -match '^\d+$') {
            $idx = [int]$userInput
            if ($idx -ge 1 -and $idx -le $Versions.Count) {
                return $Versions[$idx - 1]
            }
        }

        Write-Host 'Invalid selection. Please try again.' -ForegroundColor Red
    } while ($true)
}
