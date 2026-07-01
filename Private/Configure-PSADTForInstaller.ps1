function Configure-PSADTForInstaller {
    param(
        [string]$ProjectPath,
        [PSCustomObject]$AppInfo,
        [string]$Architecture
    )
    
    try {
        $filesPath = Join-Path $ProjectPath "Files"
        $scriptPath = Join-Path $ProjectPath "Invoke-AppDeployToolkit.ps1"
        
        if (-not (Test-Path $scriptPath)) {
            Write-Warning "PSADT script not found: $scriptPath"
            return $false
        }
        
        # Detect installer type
        $fileInfo = Get-InstallerFileInfo -FilesPath $filesPath
        if (-not $fileInfo.FileName) {
            Write-Warning "No installer files detected in Files folder"
            return $false
        }
        
        Write-Host "Detected installer: $($fileInfo.FileName) ($($fileInfo.Type.ToUpper()))" -ForegroundColor Green
        
        # Get YAML info if available
        $yamlInfo = Get-YAMLInstallerInfo -FilesPath $filesPath
        
        # Read current script content
        $scriptContent = Get-Content $scriptPath -Raw
        
        # Prepare app variables.
        # Every value below is emitted into a single-quoted literal inside the generated
        # Invoke-AppDeployToolkit.ps1, so it must be quote-escaped (ConvertTo-PSLiteral).
        $appVendor  = ConvertTo-PSLiteral $yamlInfo.Publisher
        $verRaw     = if ($yamlInfo.PackageVersion) { $yamlInfo.PackageVersion } elseif ($AppInfo.Version) { $AppInfo.Version } else { '' }
        $appVersion = ConvertTo-PSLiteral $verRaw
        $appArch    = ConvertTo-PSLiteral $Architecture
        
        # Configure based on installer type
        if ($fileInfo.Type -eq 'msi') {
            Write-Host "Configuring for MSI installer (Zero-Config MSI)" -ForegroundColor Yellow
            
            # For MSI: Keep AppName empty to enable Zero-Config MSI
            $appName = "''"
            
            # Update app variables
            $scriptContent = $scriptContent -replace "AppVendor = ''", "AppVendor = $appVendor"
            $scriptContent = $scriptContent -replace "AppVersion = ''", "AppVersion = $appVersion"
            $scriptContent = $scriptContent -replace "AppArch = ''", "AppArch = $appArch"
            
            Write-Host "✓ MSI Zero-Config enabled (AppName left empty)" -ForegroundColor Green
        }
        elseif ($fileInfo.Type -eq 'exe') {
            Write-Host "Configuring for EXE installer" -ForegroundColor Yellow
            
            # For EXE: Set AppName to disable Zero-Config and add install logic
            $appName = if ($yamlInfo.PackageName) { ConvertTo-PSLiteral $yamlInfo.PackageName } else { ConvertTo-PSLiteral $AppInfo.Name }
            
            # Update app variables  
            $scriptContent = $scriptContent -replace "AppVendor = ''", "AppVendor = $appVendor"
            $scriptContent = $scriptContent -replace "AppName = ''", "AppName = $appName"
            $scriptContent = $scriptContent -replace "AppVersion = ''", "AppVersion = $appVersion"
            $scriptContent = $scriptContent -replace "AppArch = ''", "AppArch = $appArch"
            
            # Add EXE installation logic using proven approach from Update-PSADTForEXE.ps1.
            # These values are untrusted (winget YAML): $silentArgs and the installer file
            # name are emitted into single-quoted literals; $packageName is emitted into
            # double-quoted log messages — escape each for its target context so it cannot
            # break out of the literal or expand a variable/subexpression at runtime.
            $silentArgsRaw   = if ($yamlInfo.SilentArgs) { $yamlInfo.SilentArgs } else { "/S" }
            $packageNameRaw  = if ($yamlInfo.PackageName) { $yamlInfo.PackageName } else { $AppInfo.Name }
            $silentArgs      = ConvertTo-PSSingleQuoted $silentArgsRaw
            $packageName     = ConvertTo-PSDoubleQuoted $packageNameRaw
            $installerFileSq = ConvertTo-PSSingleQuoted $fileInfo.FileName

            $installLogic = @"

    ## Install EXE Application
    `$installerPath = Join-Path `$adtSession.DirFiles '$installerFileSq'
    if (Test-Path `$installerPath) {
        Write-ADTLogEntry -Message "Installing $packageName from: `$installerPath" -Severity 1

        # Silent installation
        `$installArgs = '$silentArgs'
        Start-ADTProcess -FilePath `$installerPath -ArgumentList `$installArgs

        Write-ADTLogEntry -Message "$packageName installation completed" -Severity 1
    } else {
        Write-ADTLogEntry -Message "Installer file not found: `$installerPath" -Severity 3
        throw "Installer file not found"
    }
"@
            
            # Replace installation section - handle both new and existing installations  
            if ($scriptContent -match [regex]::Escape('## <Perform Installation tasks here>')) {
                $scriptContent = $scriptContent -replace [regex]::Escape('## <Perform Installation tasks here>'), $installLogic
                Write-Host "✓ EXE installation logic added" -ForegroundColor Green
            }
            elseif ($scriptContent -match '## Install EXE Application') {
                # Find and replace the entire EXE installation block
                $pattern = '## Install EXE Application[\s\S]*?(?=\n\s*##\s*=|\z)'
                $scriptContent = $scriptContent -replace $pattern, ($installLogic + "`n")
                Write-Host "✓ EXE installation logic updated" -ForegroundColor Green
            }
        }
        else {
            Write-Host "Configuring for $($fileInfo.Type.ToUpper()) installer" -ForegroundColor Yellow
            
            # For other types: Set AppName and basic variables
            $appName = if ($yamlInfo.PackageName) { ConvertTo-PSLiteral $yamlInfo.PackageName } else { ConvertTo-PSLiteral $AppInfo.Name }
            
            $scriptContent = $scriptContent -replace "AppVendor = ''", "AppVendor = $appVendor"
            $scriptContent = $scriptContent -replace "AppName = ''", "AppName = $appName"
            $scriptContent = $scriptContent -replace "AppVersion = ''", "AppVersion = $appVersion"
            $scriptContent = $scriptContent -replace "AppArch = ''", "AppArch = $appArch"
            
            Write-Host "✓ Basic app variables configured" -ForegroundColor Green
        }
        
        # Update script date
        $currentDate = Get-Date -Format 'yyyy-MM-dd'
        $scriptContent = $scriptContent -replace "AppScriptDate = '2025-09-23'", "AppScriptDate = '$currentDate'"
        
        # Write updated content back to file
        Set-Content -Path $scriptPath -Value $scriptContent -Encoding UTF8

        # Apply org template branding and dialog settings
        if ($script:OrgTemplate) {
            Write-Host 'Applying org template...' -ForegroundColor Cyan
            Apply-OrgTemplate -ProjectPath $ProjectPath -Template $script:OrgTemplate | Out-Null
        }

        Write-Host "✓ PSADT script configured successfully!" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Failed to configure PSADT: $($_.Exception.Message)"
        return $false
    }
}