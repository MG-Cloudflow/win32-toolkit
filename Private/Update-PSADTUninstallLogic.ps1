function Update-PSADTUninstallLogic {
    param(
        [string]$ProjectPath,
        [string]$JsonFilePath
    )
    
    try {
        $scriptPath = Join-Path $ProjectPath "Invoke-AppDeployToolkit.ps1"
        
        if (-not (Test-Path $scriptPath)) {
            Write-Warning "PSADT script not found: $scriptPath"
            return $false
        }
        
        # Parse JSON data
        $jsonContent = Get-Content -Path $JsonFilePath -Raw -Encoding UTF8
        $data = $jsonContent | ConvertFrom-Json
        
        # Extract info using exact logic from Update-PSADTForUninstall-Working.ps1
        $appName = "Unknown App"
        $productCodes = @()
        $uninstallStrings = @()
        $installPaths = @()
        
        # Get app info from registry
        if ($data.NewRegistryKeys) {
            foreach ($regKey in $data.NewRegistryKeys) {
                if ($regKey.Path -like "*Uninstall*") {
                    # Handle the Values object structure
                    if ($regKey.Values) {
                        if ($regKey.Values.DisplayName) {
                            $appName = $regKey.Values.DisplayName
                        }
                        
                        # Smart uninstall string selection
                        $selectedUninstaller = $null
                        
                        # For EXE uninstallers: Prefer QuietUninstallString over UninstallString
                        if ($regKey.Values.QuietUninstallString -and $regKey.Values.QuietUninstallString -like "*.exe*") {
                            $selectedUninstaller = $regKey.Values.QuietUninstallString
                        }
                        elseif ($regKey.Values.UninstallString -and $regKey.Values.UninstallString -like "*.exe*") {
                            $selectedUninstaller = $regKey.Values.UninstallString
                        }
                        # For MSI uninstallers: Use UninstallString (contains msiexec)
                        elseif ($regKey.Values.UninstallString -and $regKey.Values.UninstallString -like "*msiexec*") {
                            $selectedUninstaller = $regKey.Values.UninstallString
                        }
                        
                        if ($selectedUninstaller) {
                            $uninstallStrings += $selectedUninstaller
                        }
                    }
                    
                    # Extract product codes (strict GUID only — Test-Win32ToolkitProductCode)
                    if ($regKey.Path -match '\{[A-F0-9-]{36}\}') {
                        $pc = [regex]::Match($regKey.Path, '\{[A-F0-9-]{36}\}').Value
                        if ((Test-Win32ToolkitProductCode $pc) -and $pc -notin $productCodes) {
                            $productCodes += $pc
                        }
                    }
                }
            }
        }
        
        # Get install paths from files
        if ($data.NewFiles) {
            foreach ($file in $data.NewFiles) {
                if ($file.Path -like "*Program Files*") {
                    $dir = Split-Path $file.Path -Parent
                    # Only include specific app directories, not system directories
                    if ($dir -notin $installPaths -and $dir -notlike "*Program Files" -and $dir -notlike "*ProgramData" -and $dir -ne "C:\Program Files" -and $dir -ne "C:\ProgramData") {
                        $installPaths += $dir
                    }
                }
            }
        }
        
        Write-Host "Extracted info for: $appName" -ForegroundColor Green
        Write-Host "  Product Codes: $($productCodes.Count)" -ForegroundColor White
        Write-Host "  Uninstall Strings: $($uninstallStrings.Count)" -ForegroundColor White
        Write-Host "  Install Paths: $($installPaths.Count)" -ForegroundColor White
        
        # Generate uninstall code using exact logic from working script.
        # $appName is emitted into double-quoted log messages in the generated script,
        # so escape it (untrusted DisplayName must not expand/inject at runtime).
        $appNameDq = ConvertTo-PSDoubleQuoted $appName
        $codeLines = @()
        $codeLines += "        # Auto-generated uninstall code for $appNameDq"
        $codeLines += "        # Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $codeLines += ""
        $codeLines += "        Write-ADTLogEntry -Message `"Starting uninstall of $appNameDq`""
        $codeLines += "        `$uninstallSuccess = `$false"
        $codeLines += ""
        
        # Add MSI uninstall if product codes found
        if ($productCodes.Count -gt 0) {
            $codeLines += "        # Try MSI uninstall"
            $codeLines += "        if (-not `$uninstallSuccess) {"
            $codeLines += "            try {"
            $codeLines += "                Write-ADTLogEntry -Message `"Attempting MSI uninstallation`""
            
            foreach ($pc in $productCodes) {
                $codeLines += "                Write-ADTLogEntry -Message `"Uninstalling MSI with Product Code: $pc`""
                $codeLines += "                `$result = Start-ADTMsiProcess -Action 'Uninstall' -ProductCode '$pc' -PassThru"
                $codeLines += "                `$exitCode = `$result.ExitCode"
                $codeLines += "                if (`$exitCode -eq 0 -or `$exitCode -eq 3010) {"
                $codeLines += "                    Write-ADTLogEntry -Message `"MSI uninstallation completed successfully (Exit Code: `$exitCode)`""
                $codeLines += "                    `$uninstallSuccess = `$true"
                $codeLines += "                    break"
                $codeLines += "                } else {"
                $codeLines += "                    Write-ADTLogEntry -Message `"MSI uninstallation failed with exit code: `$exitCode`" -Severity 2"
                $codeLines += "                }"
            }
            
            $codeLines += "            } catch {"
            $codeLines += "                Write-ADTLogEntry -Message `"MSI uninstall failed: `$(`$_.Exception.Message)`" -Severity 2"
            $codeLines += "            }"
            $codeLines += "        }"
            $codeLines += ""
        }
        
        # Process registry uninstall strings and determine installer type
        if ($uninstallStrings.Count -gt 0) {
            foreach ($us in $uninstallStrings) {
                # Determine installer type and generate appropriate code
                if ($us -like '*msiexec*') {
                    # MSI-based uninstaller - extract product code (strict GUID only)
                    if ($us -match '\{[A-F0-9-]{36}\}' -and (Test-Win32ToolkitProductCode $matches[0])) {
                        $productCode = $matches[0]
                        $codeLines += "        # Try MSI uninstall with product code"
                        $codeLines += "        if (-not `$uninstallSuccess) {"
                        $codeLines += "            try {"
                        $codeLines += "                Write-ADTLogEntry -Message `"Attempting MSI uninstallation with product code: $productCode`""
                        $codeLines += "                `$result = Start-ADTMsiProcess -Action 'Uninstall' -ProductCode '$productCode' -PassThru"
                        $codeLines += "                `$exitCode = `$result.ExitCode"
                        $codeLines += "                if (`$exitCode -eq 0 -or `$exitCode -eq 3010) {"
                        $codeLines += "                    Write-ADTLogEntry -Message `"MSI uninstallation completed successfully (Exit Code: `$exitCode)`""
                        $codeLines += "                    `$uninstallSuccess = `$true"
                        $codeLines += "                } else {"
                        $codeLines += "                    Write-ADTLogEntry -Message `"MSI uninstallation failed with exit code: `$exitCode`" -Severity 2"
                        $codeLines += "                }"
                        $codeLines += "            } catch {"
                        $codeLines += "                Write-ADTLogEntry -Message `"MSI uninstall failed: `$(`$_.Exception.Message)`" -Severity 2"
                        $codeLines += "            }"
                        $codeLines += "        }"
                        $codeLines += ""
                    }
                }
                elseif ($us -like '*.exe*') {
                    # EXE-based uninstaller - parse path and parameters
                    $exePath = ""
                    $exeParams = ""
                    
                    if ($us -match '"([^"]*\.exe)"(.*)') {
                        $exePath = $matches[1]
                        $exeParams = $matches[2].Trim()
                    } elseif ($us -match '([^\s]*\.exe)(.*)') {
                        $exePath = $matches[1]
                        $exeParams = $matches[2].Trim()
                    } else {
                        $exePath = $us
                    }

                    # Untrusted (registry-captured) — escape for each target context.
                    $exePathSq   = ConvertTo-PSSingleQuoted $exePath
                    $exeParamsSq = ConvertTo-PSSingleQuoted $exeParams
                    $exePathDq   = ConvertTo-PSDoubleQuoted $exePath

                    $codeLines += "        # Try EXE uninstall"
                    $codeLines += "        if (-not `$uninstallSuccess) {"
                    $codeLines += "            try {"
                    $codeLines += "                Write-ADTLogEntry -Message `"Attempting EXE uninstallation: $exePathDq`""
                    $codeLines += "                `$result = Start-ADTProcess -FilePath '$exePathSq' -ArgumentList '$exeParamsSq' -PassThru"
                    $codeLines += "                `$exitCode = `$result.ExitCode"
                    $codeLines += "                if (`$exitCode -eq 0 -or `$exitCode -eq 3010) {"
                    $codeLines += "                    Write-ADTLogEntry -Message `"EXE uninstallation completed successfully (Exit Code: `$exitCode)`""
                    $codeLines += "                    `$uninstallSuccess = `$true"
                    $codeLines += "                } else {"
                    $codeLines += "                    Write-ADTLogEntry -Message `"EXE uninstallation failed with exit code: `$exitCode`" -Severity 2"
                    $codeLines += "                }"
                    $codeLines += "            } catch {"
                    $codeLines += "                Write-ADTLogEntry -Message `"EXE uninstall failed: `$(`$_.Exception.Message)`" -Severity 2"
                    $codeLines += "            }"
                    $codeLines += "        }"
                    $codeLines += ""
                }
            }
        }
        
        # Add cleanup
        if ($installPaths.Count -gt 0) {
            $codeLines += "        # Cleanup installation files"
            $codeLines += "        Write-ADTLogEntry -Message `"Performing cleanup of installation directories`""
            
            foreach ($path in $installPaths) {
                # Untrusted (captured install location) — escape for each target context.
                $pathSq = ConvertTo-PSSingleQuoted $path
                $pathDq = ConvertTo-PSDoubleQuoted $path
                $codeLines += "        if (Test-Path '$pathSq') {"
                $codeLines += "            try {"
                $codeLines += "                Write-ADTLogEntry -Message `"Removing directory: $pathDq`""
                $codeLines += "                Remove-ADTFolder -Path '$pathSq'"
                $codeLines += "                Write-ADTLogEntry -Message `"Successfully removed directory: $pathDq`""
                $codeLines += "            } catch {"
                $codeLines += "                Write-ADTLogEntry -Message `"Failed to remove directory $pathDq`: `$(`$_.Exception.Message)`" -Severity 2"
                $codeLines += "            }"
                $codeLines += "        } else {"
                $codeLines += "            Write-ADTLogEntry -Message `"Directory not found (already removed): $pathDq`""
                $codeLines += "        }"
            }
            $codeLines += ""
        }
        
        $codeLines += "        # Verify uninstallation"
        $codeLines += "        if (`$uninstallSuccess) {"
        $codeLines += "            Write-ADTLogEntry -Message `"Uninstallation completed successfully for $appNameDq`""
        $codeLines += "        } else {"
        $codeLines += "            Write-ADTLogEntry -Message `"Warning: Uninstallation may not have completed successfully - manual verification recommended`" -Severity 2"
        $codeLines += "        }"
        $codeLines += ""
        
        $uninstallCode = $codeLines -join "`r`n"
        
        # Update PSADT file using exact logic from working script
        $content = Get-Content -Path $scriptPath -Raw -Encoding UTF8
        
        # Find and replace the correct uninstall section
        $uninstallMarker = '## <Perform Uninstallation tasks here>'
        
        if ($content -match [regex]::Escape($uninstallMarker)) {
            # Find the exact position to insert the code
            $lines = $content -split "`r?`n"
            $markerIndex = -1
            
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i].Trim() -eq $uninstallMarker) {
                    $markerIndex = $i
                    break
                }
            }
            
            if ($markerIndex -ne -1) {
                # Insert the uninstall code after the marker
                $beforeMarker = $lines[0..$markerIndex]
                $afterMarker = $lines[($markerIndex + 1)..($lines.Count - 1)]
                
                # Clean up the generated code (remove any header comments)
                $cleanCode = $uninstallCode -split "`r?`n" | Where-Object { 
                    $_ -notmatch '^\s*##\*' -and 
                    $_ -notmatch '^\s*\[String\]\$installPhase' 
                }
                
                # Combine all parts
                $newLines = @()
                $newLines += $beforeMarker
                $newLines += ""
                $newLines += $cleanCode
                $newLines += $afterMarker
                
                $content = $newLines -join "`r`n"
            } else {
                throw "Could not find the uninstall marker in PSADT file."
            }
        } else {
            throw "Could not find uninstall section in PSADT file. Please ensure the file contains '## <Perform Uninstallation tasks here>' marker."
        }
        
        $content | Set-Content -Path $scriptPath -Encoding UTF8
        
        Write-Host "✓ SUCCESS: Updated PSADT for $appName" -ForegroundColor Green
        Write-Host "Methods: $(if($productCodes.Count -gt 0){'MSI '})$(if($uninstallStrings.Count -gt 0){'Registry '})Cleanup" -ForegroundColor White
        return $true
        
    } catch {
        Write-Warning "Failed to update uninstall logic: $($_.Exception.Message)"
        return $false
    }
}