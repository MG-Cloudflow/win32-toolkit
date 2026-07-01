function Show-ProjectSelection {
    [CmdletBinding()]
    param([array]$Projects)

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host 'PSADT Project Selection'                   -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    Write-Host ("  {0,-4} {1,-22} {2}" -f '#', 'Template', 'Application') -ForegroundColor Gray
    Write-Host ("  " + ('-' * 60)) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Projects.Count; $i++) {
        $tpl   = if ($Projects[$i].PSObject.Properties.Name -contains 'Template') { $Projects[$i].Template } else { '' }
        $color = if ($i % 2 -eq 0) { 'Cyan' } else { 'White' }
        Write-Host ("  {0,-4} {1,-22} {2}" -f ($i + 1), $tpl, $Projects[$i].Name) -ForegroundColor $color
    }

    Write-Host ''
    do {
        $rawInput = Read-Host "Select project (1-$($Projects.Count))"
        $parsed   = 0
        $valid    = [int]::TryParse($rawInput.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $Projects.Count
        if (-not $valid) { Write-Host "Please enter a number between 1 and $($Projects.Count)." -ForegroundColor Red }
    } while (-not $valid)

    return $Projects[$parsed - 1]
}
