function Show-ProjectSelection {
    param([array]$Projects)

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host 'PSADT Project Selection'                   -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    Write-Host 'Available PSADT Projects:' -ForegroundColor Yellow
    Write-Host ''

    for ($i = 0; $i -lt $Projects.Count; $i++) {
        Write-Host "  $($i + 1). $($Projects[$i].Name)" -ForegroundColor White
    }

    Write-Host ''
    do {
        $selection = Read-Host "Select project to test (1-$($Projects.Count))"

        if ([int]$selection -ge 1 -and [int]$selection -le $Projects.Count) {
            return $Projects[$selection - 1]
        }

        Write-Host 'Invalid selection. Please try again.' -ForegroundColor Red
    } while ($true)
}
