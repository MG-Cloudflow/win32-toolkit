function Get-WingetAppDetails {
    param([string]$AppId)
    
    Write-Host "Getting details for: $AppId" -ForegroundColor Yellow
    
    try {
        # Get app information including available architectures
        $appInfo = winget show $AppId --accept-source-agreements | Out-String
        
        # Parse architectures from the output
        $architectures = @()
        $lines = $appInfo -split "`n"
        
        foreach ($line in $lines) {
            if ($line -match "Architecture:\s*(.+)") {
                $archList = $matches[1] -split ',' | ForEach-Object { $_.Trim() }
                $architectures += $archList
            }
        }
        
        # Remove duplicates and filter out empty values
        $architectures = $architectures | Where-Object { $_ } | Sort-Object -Unique
        
        # If no specific architectures found, try to get them from the installer info
        if ($architectures.Count -eq 0) {
            # Look for installer information that might contain architecture details
            foreach ($line in $lines) {
                if ($line -match "Installer\s+Type:\s*(.+)" -or $line -match "Package\s+Identifier:" -or $line -match "Platform:") {
                    # Check if ARM64 is mentioned anywhere in the app info
                    if ($appInfo -match "arm64|aarch64" -or $appInfo -match "ARM64") {
                        $architectures += "arm64"
                    }
                    if ($appInfo -match "x64|amd64" -or $appInfo -match "x86_64") {
                        $architectures += "x64"
                    }
                    if ($appInfo -match "x86|i386" -and $appInfo -notmatch "x86_64") {
                        $architectures += "x86"
                    }
                }
            }
            
            # Remove duplicates again after parsing
            $architectures = $architectures | Where-Object { $_ } | Sort-Object -Unique
            
            # Final fallback - provide all common architectures as options
            if ($architectures.Count -eq 0) {
                $architectures = @("x64", "x86", "arm64")
                Write-Host "No specific architectures detected. Showing common options." -ForegroundColor Yellow
            }
        }
        
        return $architectures
    }
    catch {
        Write-Warning "Could not get app details for $AppId : $($_.Exception.Message)"
        return @("x64", "x86")  # Default architectures
    }
}