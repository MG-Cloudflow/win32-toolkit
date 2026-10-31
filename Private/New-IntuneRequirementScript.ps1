function New-IntuneRequirementScript {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$ProjectPath,
        [string]$JsonFilePath
    )

    try {
        # Parse JSON using exact logic from Create-IntuneRequirement.ps1
        Write-Verbose "Parsing JSON data..."
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
            Write-Verbose "Extracted info for: $appName"
            if ($appVersion) { Write-Verbose "  Version: $appVersion" }
            if ($publisher)  { Write-Verbose "  Publisher: $publisher" }
            Write-Verbose "  Registry Entries: $($appEntries.Count)"
            if ($productCodes.Count -gt 0) { Write-Verbose "  Product Codes: $($productCodes.Count)" }
        } else {
            # Fallback: read the winget manifest via the shared resolver.
            # This used to hand-pick the alphabetically-FIRST *.yaml, which is the *.installer.yaml — and the
            # installer manifest carries no PackageName/Publisher (they live in the version/locale manifest).
            # So $appName stayed $null, the function returned $false, and NO requirement script was written at
            # all whenever the capture produced no program entries. Get-YAMLInstallerInfo reads the right file
            # for each field (and with an explicit encoding).
            $yamlInfo = Get-YAMLInstallerInfo -FilesPath (Join-Path $ProjectPath 'Files')
            if ($yamlInfo) {
                if ($yamlInfo.PackageName)    { $appName    = $yamlInfo.PackageName }
                if ($yamlInfo.PackageVersion) { $appVersion = $yamlInfo.PackageVersion }
                if ($yamlInfo.Publisher)      { $publisher  = $yamlInfo.Publisher }
                if ($yamlInfo.ProductCode)    { $productCodes += $yamlInfo.ProductCode }
                if ($appName) {
                    Write-Warning "JSON had no program entries — using the winget manifest as fallback"
                    Write-Verbose "  App: $appName  Version: $appVersion"
                    if ($productCodes.Count -gt 0) { Write-Verbose "  Product Code: $($productCodes[0])" }
                }
            }
            if (-not $appName) {
                Write-Warning "No application entries found in JSON file and no YAML fallback available"
                return $false
            }
        }
        
        # Generate requirement script using exact logic from original
        Write-Verbose "Generating requirement script..."

        # Untrusted values (DisplayName/version from the capture JSON or YAML) are emitted
        # into single-quoted literals in the generated requirement script — escape them
        # (ConvertTo-PSSingleQuoted), and keep only strict-GUID product codes.
        #
        # Matching is on the FULL DisplayName (exact equality) and the MSI product code — never on the
        # first token of the name. The old `-like "*$($appName.Split(' ')[0])*"` made "Microsoft Teams"
        # match ANY Add/Remove-Programs entry containing "Microsoft" (Edge, Office, Visual C++ …), i.e. a
        # false-positive "installed". Same discipline as Get-Win32ToolkitRequirementRule.
        $appNameSq    = ConvertTo-PSSingleQuoted $appName
        $appVersionSq = ConvertTo-PSSingleQuoted $appVersion
        # One entry per product code, case-insensitively, first occurrence kept: a capture names the same MSI
        # product code in the key path AND in its UninstallString (Select-Object -Unique is case-sensitive).
        $seenProductCodes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $productCodes = @($productCodes | Where-Object { (Test-Win32ToolkitProductCode $_) -and $seenProductCodes.Add([string]$_) })

        # A COMMENT is a code context too. ConvertTo-PSSingleQuoted protects a single-quoted LITERAL; it does
        # nothing for text emitted inside <# ... #>. A DisplayName containing '#>' would CLOSE the comment block
        # and everything after it would become top-level code in a script Intune runs as SYSTEM. Neutralise the
        # comment terminator and flatten newlines before the name goes anywhere near the header.
        $appNameCmt = (($appName -replace '#>', '#_>') -replace '[\r\n]+', ' ').Trim()

        $requirementScript = @"
<#
.SYNOPSIS
    Intune Win32 App Requirement Script for $appNameCmt
.DESCRIPTION
    Checks if $appNameCmt is installed on the device.
    Generated automatically from InstallationChanges data on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
.NOTES
    This script should return exit code 0 if the requirement is met (app is installed)
    and exit code 1 if the requirement is not met (app is not installed or wrong version)
#>

try {
    `$appFound = `$false
    `$installedVersion = `$null
    `$requiredVersion = '$appVersionSq'
    
    # Registry paths to check for installed applications
    `$registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    
"@ + "`r`n"

        # Add product code checks if available
        if ($productCodes.Count -gt 0) {
            $requirementScript += @"
    # Check specific product codes first
    `$productCodes = @(
"@ + "`r`n"
            foreach ($pc in $productCodes) {
                $requirementScript += "        '$(ConvertTo-PSSingleQuoted $pc)'`r`n"
            }
            $requirementScript += @"
    )
    
    foreach (`$productCode in `$productCodes) {
        # The product code IS the identity - an Uninstall key under it means THIS product is installed.
        # (-LiteralPath: never treat the key path as a wildcard pattern.)
        `$msiPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\`$productCode"
        if (Test-Path -LiteralPath `$msiPath) {
            `$msiApp = Get-ItemProperty -LiteralPath `$msiPath -ErrorAction SilentlyContinue
            if (`$msiApp) {
                `$appFound = `$true
                `$installedVersion = `$msiApp.DisplayVersion
                Write-Host "Found via MSI Product Code: `$(`$msiApp.DisplayName) v`$installedVersion"
                break
            }
        }
    }
    
"@ + "`r`n"
        }

        # Add registry search for application name
        $requirementScript += @"
    # Search by application name if not found via product code.
    # EXACT DisplayName equality on the FULL name - a substring/first-token match would report e.g.
    # 'Microsoft Edge' as a hit for 'Microsoft Teams'. Equality also needs no wildcard escaping, so a
    # name containing [ ] * ? still matches literally.
    if (-not `$appFound) {
        foreach (`$regPath in `$registryPaths) {
            try {
                `$apps = Get-ItemProperty -Path `$regPath -ErrorAction SilentlyContinue | Where-Object {
                    `$_.DisplayName -eq '$appNameSq'
                }

                foreach (`$app in `$apps) {
                    if (`$app.DisplayName) {
                        `$appFound = `$true
                        `$installedVersion = `$app.DisplayVersion
                        Write-Host "Found application: `$(`$app.DisplayName)"
                        if (`$installedVersion) {
                            Write-Host "Installed Version: `$installedVersion"
                        }
"@ + "`r`n"

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
"@ + "`r`n"
        } else {
            $requirementScript += @"
                        
                        # No specific version required, app is installed
                        Write-Host "Application found"
                        exit 0
"@ + "`r`n"
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
            Write-Verbose "Created SupportFiles directory"
        }
        
        $defaultPath = Join-Path $supportFilesPath "RequirementScript.ps1"

        # UTF-8 WITH BOM: Intune runs requirement scripts with Windows PowerShell 5.1, which decodes a
        # BOM-less file as ANSI — a non-ASCII DisplayName ('Café', 'Nagüi') would mojibake and the
        # DisplayName comparison would silently never match. PS7's Set-Content -Encoding UTF8 writes NO
        # BOM, so write the bytes ourselves (same as Get-Win32ToolkitRequirementRule).
        [System.IO.File]::WriteAllText($defaultPath, ($requirementScript + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        # A neutral note, never "paste this as a requirement" (test campaign 2026-10-21, H5-F7): the script is
        # detection-shaped (met only when this exact app is installed at or above this version), so as a
        # requirement of the INSTALL app it would keep the app off every device that does not have it yet.
        Write-Host "`nReference script saved (not uploaded): $defaultPath" -ForegroundColor Gray
        Write-Host '  It is detection-shaped: met only when this exact DisplayName is installed at or above this version.' -ForegroundColor Gray
        Write-Host '  Do not add it as a requirement of the install app (new devices would never get the app).' -ForegroundColor Gray
        Write-Host '  Publishing sets the detection rule itself, plus a presence requirement for an Update app.' -ForegroundColor Gray
        
        return $true
    }
    catch {
        Write-Warning "Failed to create requirement script: $($_.Exception.Message)"
        return $false
    }
}