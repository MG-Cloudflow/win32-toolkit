function Create-PSADTProject {
    param(
        [string]$ProjectName,
        [string]$ProjectPath,
        [switch]$Force = $false
    )
    
    $ProjectFullPath = Join-Path $ProjectPath $ProjectName
    
    try {
        Write-Host "`nCreating PSADT V4 project: $ProjectName" -ForegroundColor Green
        
        # Check if PSADT module is installed
        Write-Host "Checking for PSAppDeployToolkit module..." -ForegroundColor Yellow
        $PSADTModule = Get-Module -Name PSAppDeployToolkit -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        
        if (-not $PSADTModule) {
            Write-Host "PSAppDeployToolkit module not found. Installing..." -ForegroundColor Yellow
            Install-Module -Name PSAppDeployToolkit -Scope CurrentUser -Force -AllowClobber
            $PSADTModule = Get-Module -Name PSAppDeployToolkit -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        }
        else {
            # Check PSGallery for a newer version
            Write-Host "Installed version: $($PSADTModule.Version) — checking PSGallery for updates..." -ForegroundColor Yellow
            try {
                $galleryModule = Find-Module -Name PSAppDeployToolkit -Repository PSGallery -ErrorAction Stop
                $galleryVersion = [System.Version]$galleryModule.Version
                $installedVersion = [System.Version]$PSADTModule.Version

                if ($galleryVersion -gt $installedVersion) {
                    Write-Host "Update available: $galleryVersion (installed: $installedVersion)" -ForegroundColor Cyan
                    if ($Force) {
                        Write-Host "Skipping update check (-Force mode)." -ForegroundColor Gray
                    } else {
                    $doUpdate = Read-Host "Update PSAppDeployToolkit to $galleryVersion now? (y/n)"
                    if ($doUpdate -in @('y', 'Y')) {
                        Write-Host "Updating PSAppDeployToolkit to $galleryVersion..." -ForegroundColor Yellow
                        Update-Module -Name PSAppDeployToolkit -Force
                        Write-Host "✓ Updated to version: $galleryVersion" -ForegroundColor Green

                        # Only an assembly ALREADY LOADED into this process is a problem — PowerShell cannot
                        # unload it, so the new version would not take effect until a fresh session. Note the
                        # bare Get-Module (NOT -ListAvailable): -ListAvailable answers "is it installed", which
                        # is a different question and is true in the ordinary case. PSADT is not imported until
                        # further down this very function, so in a fresh session nothing is loaded and we can
                        # simply pick up the new version and carry on.
                        $loaded = Get-Module -Name PSAppDeployToolkit
                        if ($loaded -and [System.Version]$loaded.Version -lt $galleryVersion) {
                            # We deliberately do NOT relaunch on the user's behalf: this is a private helper, it
                            # does not know which public command the user invoked or with which arguments, so any
                            # process we spawned would silently do something they never asked for.
                            Write-Warning "PSAppDeployToolkit was updated to $galleryVersion, but version $($loaded.Version) is already loaded in this PowerShell session and cannot be reloaded in place."
                            Write-Host "No project was created. Please start a NEW PowerShell session and re-run your command (for example: Invoke-Win32Toolkit)." -ForegroundColor Yellow
                            return $false
                        }

                        # Nothing was loaded — re-read the module so the version we report and import below is
                        # the one we just installed, not the stale one.
                        $PSADTModule = Get-Module -Name PSAppDeployToolkit -ListAvailable |
                                       Sort-Object Version -Descending | Select-Object -First 1
                    }
                    else {
                        Write-Host "Skipping update — continuing with installed version $installedVersion" -ForegroundColor Gray
                    }
                    } # end -not Force
                }
                else {
                    Write-Host "✓ PSAppDeployToolkit is up to date ($($PSADTModule.Version))" -ForegroundColor Green
                }
            }
            catch {
                Write-Host "Could not reach PSGallery to check for updates: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
        
        Write-Host "Using PSAppDeployToolkit version: $($PSADTModule.Version)" -ForegroundColor Green
        
        # Import the module
        Import-Module -Name PSAppDeployToolkit -Force
        
        # Create project directory structure if it doesn't exist
        if (!(Test-Path $ProjectPath)) {
            New-Item -Path $ProjectPath -ItemType Directory -Force | Out-Null
        }
        
        if (Test-Path $ProjectFullPath) {
            Write-Warning "Project directory already exists: $ProjectFullPath"
            if ($Force) {
                Write-Host "Overwriting existing project directory (-Force mode)." -ForegroundColor Yellow
            } else {
                $overwrite = Read-Host "Do you want to overwrite it? (y/n)"
                if ($overwrite -notin @('y', 'Y')) {
                    return $false
                }
            }
            Remove-Item -Path $ProjectFullPath -Recurse -Force
        }
        
        # Create new PSADT template using the module
        Write-Host "Creating PSADT V4 template..." -ForegroundColor Yellow
        New-ADTTemplate -Destination $ProjectPath -Name $ProjectName
        
        Write-Host "PSADT V4 project created successfully!" -ForegroundColor Green
        Write-Host "Project location: $ProjectFullPath" -ForegroundColor Cyan
        
        return $true
    }
    catch {
        Write-Error "Failed to create PSADT project: $($_.Exception.Message)"
        return $false
    }
}