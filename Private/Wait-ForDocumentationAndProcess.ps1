function Wait-ForDocumentationAndProcess {
    [CmdletBinding()]
    param(
        [string]$ProjectPath,
        [string]$InstallerType,

        # Exact capture file this run's sandbox will produce (returned by New-TargetedDocumentation).
        # When provided, the wait is satisfied ONLY by this file — immune to stale captures from
        # previous runs. When omitted (back-compat), the newest capture is selected
        # (Get-LatestInstallationCapture; note: filter is 'InstallationChanges_*.json', with underscore).
        [string]$ExpectedJsonPath
    )

    try {
        Write-Host "Monitoring for documentation completion..." -ForegroundColor Yellow

        $jsonFound = $false
        $jsonFile = $null
        $maxWaitMinutes = 30
        $checkIntervalSeconds = 10
        $totalChecks = ($maxWaitMinutes * 60) / $checkIntervalSeconds

        if ($ExpectedJsonPath) {
            Write-Host "Waiting for this run's capture: $(Split-Path $ExpectedJsonPath -Leaf)" -ForegroundColor Cyan
        } else {
            Write-Host "Checking for InstallationChanges JSON file every $checkIntervalSeconds seconds..." -ForegroundColor Cyan
        }
        Write-Host "Maximum wait time: $maxWaitMinutes minutes" -ForegroundColor Gray

        for ($i = 1; $i -le $totalChecks; $i++) {
            if ($ExpectedJsonPath) {
                if (Test-Path -LiteralPath $ExpectedJsonPath) {
                    $jsonFile = $ExpectedJsonPath
                    $jsonFound = $true
                    Write-Host "✓ JSON documentation file found: $(Split-Path $ExpectedJsonPath -Leaf)" -ForegroundColor Green
                    break
                }
            }
            else {
                $latest = Get-LatestInstallationCapture -ProjectPath $ProjectPath
                if ($latest) {
                    $jsonFile = $latest.FullName
                    $jsonFound = $true
                    Write-Host "✓ JSON documentation file found: $($latest.Name)" -ForegroundColor Green
                    break
                }
            }

            $minutesWaited = ($i * $checkIntervalSeconds) / 60
            Write-Host "Waiting... ($([math]::Round($minutesWaited, 1)) minutes elapsed)" -ForegroundColor Gray
            Start-Sleep -Seconds $checkIntervalSeconds
        }
        
        if (-not $jsonFound) {
            Write-Warning "Documentation JSON file not found after $maxWaitMinutes minutes. Please check the Windows Sandbox manually."
            return $false
        }
        
        Write-Host "`nProcessing documentation results..." -ForegroundColor Yellow
        
        # Generate requirement script
        Write-Host "Generating Intune requirement script..." -ForegroundColor Cyan
        $reqSuccess = New-IntuneRequirementScript -ProjectPath $ProjectPath -JsonFilePath $jsonFile
        
        if ($reqSuccess) {
            Write-Host "✓ Intune requirement script generated" -ForegroundColor Green
        } else {
            Write-Warning "Failed to generate requirement script"
        }
        
        # Uninstall generation depends on installer type: EXE from the capture, MSI via PSADT
        # Zero-Config, MSIX/APPX identity-driven (written at configure time; re-run here as
        # belt-and-braces — it is an idempotent read-modify-write of AppConfig.json).
        switch ($InstallerType) {
            'exe' {
                Write-Host "Generating uninstall logic for EXE installer..." -ForegroundColor Cyan
                $uninstallSuccess = Update-PSADTUninstallLogic -ProjectPath $ProjectPath -JsonFilePath $jsonFile
                if ($uninstallSuccess) {
                    Write-Host "✓ Uninstall logic generated for EXE installer" -ForegroundColor Green
                } else {
                    Write-Warning "Failed to generate uninstall logic"
                }
            }
            'msi' {
                Write-Host "✓ MSI installer detected - PSADT Zero-Config uninstall handles removal" -ForegroundColor Green
            }
            { $_ -in @('msix', 'appx') } {
                if (Update-PSADTMsixUninstallLogic -ProjectPath $ProjectPath) {
                    Write-Host "✓ MSIX/APPX package - uninstall via Remove-AppxPackage (identity from AppxManifest)" -ForegroundColor Green
                } else {
                    Write-Warning 'Failed to write MSIX uninstall data'
                }
            }
            default {
                Write-Warning "Unknown installer type '$InstallerType' - no uninstall logic generated."
            }
        }

        # Populate AppProcessesToClose for all installer types
        Write-Host "Detecting processes to close..." -ForegroundColor Cyan
        $procSuccess = Update-PSADTProcessesToClose -ProjectPath $ProjectPath -JsonFilePath $jsonFile
        if (-not $procSuccess) {
            Write-Warning "Could not auto-detect processes to close - AppProcessesToClose left empty"
        }
        
        return $true
    }
    catch {
        Write-Warning "Error processing documentation: $($_.Exception.Message)"
        return $false
    }
}