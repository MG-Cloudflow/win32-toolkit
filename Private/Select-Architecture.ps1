function Select-Architecture {
    [CmdletBinding()]
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

        # Parse defensively: a raw [int] cast throws on 'x', on an empty line (just pressing Enter)
        # and on a digit string too large for Int32 — which killed the whole run instead of re-prompting.
        $parsed = 0
        if ([int]::TryParse(([string]$selection).Trim(), [ref]$parsed)) {
            if ($parsed -ge 1 -and $parsed -le $finalArchs.Count) {
                return $finalArchs[$parsed - 1]
            }
            if ($parsed -eq ($finalArchs.Count + 1)) {
                return "all"
            }
        }

        Write-Host "Invalid selection. Please enter a number between 1 and $($finalArchs.Count + 1)." -ForegroundColor Red
    } while ($true)
}