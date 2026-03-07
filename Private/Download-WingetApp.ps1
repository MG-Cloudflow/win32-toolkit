function Download-WingetApp {
    param(
        [string]$AppId,
        [string]$AppName,
        [string]$DownloadPath,
        [string]$Architecture = $null
    )
    
    Write-Host "Downloading $AppName ($AppId) [$Architecture]..." -ForegroundColor Green
    
    try {
        # Build download command
        $downloadCmd = "winget download --id `"$AppId`" --download-directory `"$DownloadPath`" --accept-source-agreements --accept-package-agreements"
        
        # Add architecture if specified
        if ($Architecture -and $Architecture -ne "all") {
            $downloadCmd += " --architecture `"$Architecture`""
        }
        
        Write-Host "Executing: $downloadCmd" -ForegroundColor Gray
        Invoke-Expression $downloadCmd
        
        Write-Host "Successfully downloaded to: $DownloadPath" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Failed to download $AppName : $($_.Exception.Message)"
        return $false
    }
}