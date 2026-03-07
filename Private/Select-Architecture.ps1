function Select-Architecture {
    param(
        [array]$Architectures,
        [string]$AppName,
        [string]$PreSelected = ''
    )

    # Ensure we always have ARM64 as an option if it's not already detected
    $allArchOptions = @("x64", "x86", "arm64")
    $finalArchs = @()

    # Add detected architectures first
    foreach ($arch in $Architectures) {
        if ($arch -notin $finalArchs) { $finalArchs += $arch }
    }
    # Add any missing common architectures
    foreach ($common in $allArchOptions) {
        if ($common -notin $finalArchs) { $finalArchs += $common }
    }

    # If -Architecture was passed, validate and return immediately (no menu)
    if (-not [string]::IsNullOrWhiteSpace($PreSelected)) {
        if ($PreSelected -in $finalArchs) {
            Write-Host "`nArchitecture (from -Architecture parameter): $PreSelected" -ForegroundColor Cyan
            return $PreSelected
        }
        Write-Warning "Specified architecture '$PreSelected' is not recognised. Falling back to interactive selection."
    }

    Write-Host "`nArchitecture options for $AppName :" -ForegroundColor Cyan
    Write-Host "(* indicates detected as available)" -ForegroundColor Gray
    
    for ($i = 0; $i -lt $finalArchs.Count; $i++) {
        $marker = if ($finalArchs[$i] -in $Architectures) { "*" } else { " " }
        Write-Host "  $($i + 1). $($finalArchs[$i]) $marker" -ForegroundColor White
    }
    Write-Host "  $($finalArchs.Count + 1). All detected architectures" -ForegroundColor White
    
    do {
        $selection = Read-Host "`nSelect architecture (1-$($finalArchs.Count + 1))"
        
        if ([int]$selection -ge 1 -and [int]$selection -le $finalArchs.Count) {
            return $finalArchs[$selection - 1]
        }
        elseif ([int]$selection -eq ($finalArchs.Count + 1)) {
            return "all"
        }
        
        Write-Host "Invalid selection. Please try again." -ForegroundColor Red
    } while ($true)
}