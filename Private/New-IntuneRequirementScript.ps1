function New-IntuneRequirementScript {
    param(
        [string]$ProjectPath,
        [string]$JsonFilePath
    )
    
    try {
        # Parse JSON using exact logic from Create-IntuneRequirement.ps1
        Write-Host "Parsing JSON data..." -ForegroundColor White
        $jsonContent = Get-Content -Path $JsonFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        
        # Extract application info using exact logic
        $appEntries = @()
        $productCodes = @()
        
        # Handle different JSON structures
        if ($jsonContent.Values -and $jsonContent.Values.PSObject.Properties) {
            # Direct Values structure
            foreach ($prop in $jsonContent.Values.PSObject.Properties) {
                $entry = $prop.Value
                if ($entry.DisplayName) {
                    $appEntries += $entry
                    if ($entry.UninstallString -and $entry.UninstallString -match '\{[A-F0-9-]{36}\}') {
                        $productCodes += $matches[0]
                    }
                }
            }
        } elseif ($jsonContent.NewRegistryKeys) {
            # NewRegistryKeys structure - search for Values within registry keys
            foreach ($regItem in $jsonContent.NewRegistryKeys) {
                if ($regItem.Values -and $regItem.Values.DisplayName) {
                    $entry = $regItem.Values
                    $appEntries += $entry
                    if ($entry.UninstallString -and $entry.UninstallString -match '\{[A-F0-9-]{36}\}') {
                        $productCodes += $matches[0]
                    }
                    if ($regItem.Path -and $regItem.Path -match '\{[A-F0-9-]{36}\}') {
                        $productCodes += $matches[0]
                    }
                }
            }
        } elseif ($jsonContent.NewPrograms -and $jsonContent.NewPrograms.Count -gt 0) {
            # NewPrograms array structure
            foreach ($prog in $jsonContent.NewPrograms) {
                if ($prog.DisplayName) {
                    $appEntries += $prog
                    if ($prog.UninstallString -and $prog.UninstallString -match '\{[A-F0-9-]{36}\}') {
                        $productCodes += $matches[0]
                    }
                }
            }
        }

        # If no entries found from JSON, fall back to the YAML manifest in the Files folder
        $appName = $null; $appVersion = $null; $publisher = $null
        if ($appEntries.Count -gt 0) {
            $mainApp    = $appEntries[0]
            $appName    = $mainApp.DisplayName
            $appVersion = $mainApp.DisplayVersion
            $publisher  = $mainApp.Publisher
            Write-Host "Extracted info for: $appName" -ForegroundColor Green
            if ($appVersion) { Write-Host "  Version: $appVersion" -ForegroundColor White }
            if ($publisher)  { Write-Host "  Publisher: $publisher" -ForegroundColor White }
            Write-Host "  Registry Entries: $($appEntries.Count)" -ForegroundColor White
            if ($productCodes.Count -gt 0) { Write-Host "  Product Codes: $($productCodes.Count)" -ForegroundColor White }
        } else {
            # Fallback: parse the winget YAML in Files\
            $yamlFile = Get-ChildItem (Join-Path $ProjectPath 'Files') -Filter '*.yaml' -ErrorAction SilentlyContinue |
                        Select-Object -First 1
            if ($yamlFile) {
                $yamlText = Get-Content $yamlFile.FullName -Raw
                if ($yamlText -match 'PackageName:\s*(.+)')    { $appName    = $Matches[1].Trim() }
                if ($yamlText -match 'PackageVersion:\s*(.+)') { $appVersion = $Matches[1].Trim() }
                if ($yamlText -match 'Publisher:\s*(.+)')      { $publisher  = $Matches[1].Trim() }
                if ($yamlText -match "ProductCode:\s*'?(\{[A-F0-9-]{36}\})'?") { $productCodes += $Matches[1] }
                if ($appName) {
                    Write-Host "JSON had no program entries — using YAML manifest as fallback" -ForegroundColor Yellow
                    Write-Host "  App: $appName  Version: $appVersion" -ForegroundColor White
                    if ($productCodes.Count -gt 0) { Write-Host "  Product Code: $($productCodes[0])" -ForegroundColor White }
                }
            }
            if (-not $appName) {
                Write-Warning "No application entries found in JSON file and no YAML fallback available"
                return $false
            }
        }
        
        # Generate requirement script using exact logic from original
        Write-Host "Generating requirement script..." -ForegroundColor White
        
        $requirementScript = @"
<#
.SYNOPSIS
    Intune Win32 App Requirement Script for $appName
.DESCRIPTION
    Checks if $appName is installed on the device.
    Generated automatically from InstallationChanges data on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
.NOTES
    This script should return exit code 0 if the requirement is met (app is installed)
    and exit code 1 if the requirement is not met (app is not installed or wrong version)
#>

try {
    `$appFound = `$false
    `$installedVersion = `$null
    `$requiredVersion = '$appVersion'
    
    # Registry paths to check for installed applications
    `$registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    
"@

        # Add product code checks if available
        if ($productCodes.Count -gt 0) {
            $requirementScript += @"
    # Check specific product codes first
    `$productCodes = @(
"@
            foreach ($pc in $productCodes) {
                $requirementScript += "        '$pc'`n"
            }
            $requirementScript += @"
    )
    
    foreach (`$productCode in `$productCodes) {
        `$msiPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\`$productCode"
        if (Test-Path `$msiPath) {
            `$msiApp = Get-ItemProperty -Path `$msiPath -ErrorAction SilentlyContinue
            if (`$msiApp -and `$msiApp.DisplayName -like '*$($appName.Split(' ')[0])*') {
                `$appFound = `$true
                `$installedVersion = `$msiApp.DisplayVersion
                Write-Host "Found via MSI Product Code: `$(`$msiApp.DisplayName) v`$installedVersion"
                break
            }
        }
    }
    
"@
        }

        # Add registry search for application name
        $requirementScript += @"
    # Search by application name if not found via product code
    if (-not `$appFound) {
        foreach (`$regPath in `$registryPaths) {
            try {
                `$apps = Get-ItemProperty -Path `$regPath -ErrorAction SilentlyContinue | Where-Object {
                    `$_.DisplayName -like '*$($appName.Split(' ')[0])*' -or
                    `$_.DisplayName -eq '$appName'
                }
                
                foreach (`$app in `$apps) {
                    if (`$app.DisplayName) {
                        `$appFound = `$true
                        `$installedVersion = `$app.DisplayVersion
                        Write-Host "Found application: `$(`$app.DisplayName)"
                        if (`$installedVersion) {
                            Write-Host "Installed Version: `$installedVersion"
                        }
"@

        # Add version comparison logic if we have a version to compare
        if ($appVersion) {
            $requirementScript += @"
                        
                        # Compare versions if available
                        if (`$installedVersion -and `$requiredVersion) {
                            try {
                                `$installedVer = [System.Version]`$installedVersion
                                `$requiredVer = [System.Version]`$requiredVersion
                                
                                if (`$installedVer -ge `$requiredVer) {
                                    Write-Host "Version requirement met: `$installedVersion >= `$requiredVersion"
                                    exit 0
                                } else {
                                    Write-Host "Version requirement NOT met: `$installedVersion < `$requiredVersion"
                                    exit 1
                                }
                            } catch {
                                # Version parsing failed, assume requirement is met if app is found
                                Write-Host "Version comparison failed, but application is installed"
                                exit 0
                            }
                        } else {
                            # No version info, just check if installed
                            Write-Host "Application found (no version comparison)"
                            exit 0
                        }
"@
        } else {
            $requirementScript += @"
                        
                        # No specific version required, app is installed
                        Write-Host "Application found"
                        exit 0
"@
        }

        $requirementScript += @"
                        break
                    }
                }
            } catch {
                # Continue checking other registry paths
                continue
            }
        }
    }
    
    # Final check - if app was found but no version comparison was done
    if (`$appFound) {
        Write-Host "Application is installed"
        exit 0
    } else {
        Write-Host "Application not found - requirement NOT met"
        exit 1
    }
    
} catch {
    Write-Host "Error during requirement check: `$(`$_.Exception.Message)"
    exit 1
}
"@

        # Save requirement script using exact logic from original
        $supportFilesPath = Join-Path $ProjectPath "SupportFiles"
        if (-not (Test-Path $supportFilesPath)) {
            New-Item -Path $supportFilesPath -ItemType Directory -Force | Out-Null
            Write-Host "Created SupportFiles directory" -ForegroundColor Yellow
        }
        
        $defaultPath = Join-Path $supportFilesPath "RequirementScript.ps1"
        
        $requirementScript | Set-Content -Path $defaultPath -Encoding UTF8
        Write-Host "`n✓ SUCCESS: Requirement script saved to:" -ForegroundColor Green
        Write-Host "  $defaultPath" -ForegroundColor White
        
        Write-Host "`nUsage Instructions:" -ForegroundColor Cyan
        Write-Host "1. Copy the generated PowerShell script content" -ForegroundColor White
        Write-Host "2. In Intune, go to your Win32 app > Requirements" -ForegroundColor White
        Write-Host "3. Add requirement rule: 'Script'" -ForegroundColor White
        Write-Host "4. Paste the script content" -ForegroundColor White
        Write-Host "5. Set 'Run script as 32-bit process': No" -ForegroundColor White
        Write-Host "6. Set 'Enforce script signature check': No" -ForegroundColor White
        
        return $true
    }
    catch {
        Write-Warning "Failed to create requirement script: $($_.Exception.Message)"
        return $false
    }
}