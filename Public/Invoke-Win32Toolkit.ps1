function Invoke-Win32Toolkit {
<#
.SYNOPSIS
    End-to-end Win32 app packaging automation.
.DESCRIPTION
    Searches Winget for an application, downloads it, creates a PSADT V4 project,
    configures the installer, generates Intune requirement scripts, and launches
    a Windows Sandbox session for targeted installation documentation.
.PARAMETER SearchTerm
    Term to search for in the Winget repository.
.PARAMETER Id
    Winget package ID to use directly (skips search). Example: 'Git.Git'
.PARAMETER TemplateName
    Name of the org template to load/create. Skips the interactive template picker.
    If the template does not exist yet, the wizard is pre-filled with this name.
.PARAMETER NewTemplate
    Run the org template wizard, save the template, and exit without packaging any app.
.PARAMETER Architecture
    Architecture to use for download and project creation (x64, x86, arm64).
    Skips the interactive architecture selection menu.
.PARAMETER Force
    Skip the PSGallery update prompt and the project overwrite prompt.
    Useful for unattended / automated runs.
.PARAMETER BasePath
    Base path where downloads, PSADT projects, and documentation will be created.
.EXAMPLE
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force
.EXAMPLE
    Invoke-Win32Toolkit -SearchTerm 'visual studio code' -BasePath 'D:\Packaging'
.EXAMPLE
    Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchTerm,

        [Parameter(Mandatory = $false)]
        [string]$Id,

        [Parameter(Mandatory = $false)]
        [string]$TemplateName,

        [Parameter(Mandatory = $false)]
        [switch]$NewTemplate,

        [Parameter(Mandatory = $false)]
        [string]$Architecture,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$BasePath = 'C:\Win32Apps',

        [Parameter(Mandatory = $false)]
        [ValidateSet('InstallUninstall', 'Update')]
        [string[]]$RunTest,

        [Parameter(Mandatory = $false)]
        [switch]$PackageIntune
    )

    try {
        Write-Host 'Winget App Downloader + PSADT Project Creator' -ForegroundColor Cyan
        Write-Host '===========================================' -ForegroundColor Cyan

        # Check if winget is installed
        if (-not (Test-WingetInstalled)) {
            throw 'Winget is not installed or not available in PATH'
        }

        # -NewTemplate: create/update a template then exit, without packaging anything
        if ($NewTemplate) {
            $newTpl = New-OrgTemplate -TemplateName $TemplateName
            if ($newTpl) {
                Write-Host "`n✓ Template '$($newTpl.TemplateName)' created successfully." -ForegroundColor Green
            }
            return
        }

        # Load (or create) org template once for this run
        $script:OrgTemplate = Get-OrgTemplate -TemplateName $TemplateName

        # -Id fast path: skip search entirely
        if ($Id) {
            Write-Host "Resolving package ID: $Id" -ForegroundColor Yellow
            $showOutput = winget show --id "$Id" --exact --accept-source-agreements | Out-String
            if ($LASTEXITCODE -ne 0 -or $showOutput -notmatch 'Found') {
                Write-Host "Package ID '$Id' not found in winget. Verify the ID and try again." -ForegroundColor Red
                return
            }
            $resolvedName    = if ($showOutput -match '(?m)^Found\s+(.+?)\s+\[') { $matches[1].Trim() } else { $Id }
            $resolvedVersion = if ($showOutput -match '(?m)^\s*Version:\s*(.+)')  { $matches[1].Trim() } else { 'Unknown' }
            $selectedApp = [PSCustomObject]@{
                Name    = $resolvedName
                Id      = $Id
                Version = $resolvedVersion
                Source  = 'winget'
            }
            Write-Host "`nSelected: $($selectedApp.Name) v$($selectedApp.Version)" -ForegroundColor Cyan
        }
        else {
            # Get search term if not provided
            if (-not $SearchTerm) {
                $SearchTerm = Read-Host 'Enter search term for applications'
                if ([string]::IsNullOrWhiteSpace($SearchTerm)) {
                    throw 'Search term is required'
                }
            }

            # Search for apps and exclude Microsoft Store results
            $apps = Search-WingetApps -SearchTerm $SearchTerm
            $apps = $apps | Where-Object { $_.Source -ne 'msstore' }

            if ($apps.Count -eq 0) {
                Write-Host "No applications found matching: $SearchTerm" -ForegroundColor Yellow
                return
            }

            Write-Host "Found $($apps.Count) applications" -ForegroundColor Green

            # Display apps as a numbered list with alternating row colours
            Write-Host ''
            Write-Host ("  {0,-3} {1,-28} {2,-32} {3,-10} {4}" -f '#', 'Name', 'Id', 'Version', 'Source') -ForegroundColor Gray
            Write-Host ("  " + '-' * 82) -ForegroundColor DarkGray

            for ($i = 0; $i -lt $apps.Count; $i++) {
                $color = if ($i % 2 -eq 0) { 'Cyan' } else { 'White' }
                Write-Host ("  {0,-3} {1,-28} {2,-32} {3,-10} {4}" -f ($i + 1), $apps[$i].Name, $apps[$i].Id, $apps[$i].Version, $apps[$i].Source) -ForegroundColor $color
            }
            Write-Host ''

            do {
                $rawInput = Read-Host "Select application (1-$($apps.Count))"
                $parsed   = 0
                $valid    = [int]::TryParse($rawInput.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $apps.Count
                if (-not $valid) {
                    Write-Host "Invalid selection. Please enter a number between 1 and $($apps.Count)." -ForegroundColor Red
                }
            } while (-not $valid)

            $selectedApp = $apps[$parsed - 1]

            if (-not $selectedApp) {
                Write-Host 'No application selected' -ForegroundColor Yellow
                return
            }

            Write-Host "`nSelected: $($selectedApp.Name) v$($selectedApp.Version)" -ForegroundColor Cyan
        }

        # Get available architectures for the selected app
        $availableArchs = Get-WingetAppDetails -AppId $selectedApp.Id

        # Let user select architecture (single selection for project creation)
        $selectedArch = Select-Architecture -Architectures $availableArchs -AppName $selectedApp.Name -PreSelected $Architecture

        if ($selectedArch -eq 'all') {
            if ($Architecture) {
                Write-Host "'-Architecture all' is not valid — defaulting to x64." -ForegroundColor Yellow
                $selectedArch = 'x64'
            }
            else {
                Write-Host 'For project creation, please select a specific architecture.' -ForegroundColor Yellow
                $selectedArch = Select-Architecture -Architectures $availableArchs -AppName $selectedApp.Name
            }
        }

        # Create project name using AppName_Architecture_Version format
        $appNameClean = Sanitize-ProjectName -Name $selectedApp.Name
        $versionClean = Sanitize-ProjectName -Name $selectedApp.Version
        $archClean    = Sanitize-ProjectName -Name $selectedArch
        $projectName  = "${appNameClean}_${archClean}_${versionClean}"

        Write-Host "`nProject name will be: $projectName" -ForegroundColor Cyan

        # Ensure the Projects tier exists before scaffolding
        $paths       = Get-Win32ToolkitPaths -BasePath $BasePath
        $projectsDir = $paths.Projects
        if (-not (Test-Path $projectsDir)) {
            New-Item -Path $projectsDir -ItemType Directory -Force | Out-Null
        }

        # Create the PSADT project scaffold inside Projects\
        $projectCreated = Create-PSADTProject -ProjectName $projectName -ProjectPath $projectsDir -Force:$Force

        if ($projectCreated) {
            $projectFullPath = Join-Path $projectsDir $projectName
            $downloadPath    = Join-Path $projectFullPath 'Files'

            if (!(Test-Path $downloadPath)) {
                New-Item -Path $downloadPath -ItemType Directory -Force | Out-Null
            }

            Write-Host "`nDownloading application to project Files directory..." -ForegroundColor Yellow
            $downloadSuccess = Download-WingetApp -AppId $selectedApp.Id -AppName $selectedApp.Name -DownloadPath $downloadPath -Architecture $selectedArch

            if ($downloadSuccess) {
                Write-Host "`n✓ App downloaded successfully!" -ForegroundColor Green

                # Normalize the installer filename to AppName_arch_version.ext
                Write-Host 'Normalizing installer filename...' -ForegroundColor Yellow
                Rename-InstallerFile -FilesPath $downloadPath -AppName $selectedApp.Name -Version $selectedApp.Version -Architecture $selectedArch

                # Configure PSADT based on downloaded installer type
                Write-Host 'Configuring PSADT for installer type...' -ForegroundColor Yellow
                $psadtConfigured = Configure-PSADTForInstaller -ProjectPath $projectFullPath -AppInfo $selectedApp -Architecture $selectedArch

                # Download and apply the app-specific icon from WinGet YAML
                Write-Host 'Downloading app icon from WinGet...' -ForegroundColor Cyan
                Get-AppIconFromWinget -ProjectPath $projectFullPath -FilesPath $downloadPath | Out-Null

                if ($psadtConfigured) {
                    Write-Host "`n✓ SUCCESS: Project created, app downloaded, and PSADT configured!" -ForegroundColor Green
                }
                else {
                    Write-Host "`n✓ SUCCESS: Project created and app downloaded!" -ForegroundColor Green
                    Write-Warning 'PSADT configuration had issues - please review manually'
                }

                Write-Host "Project location: $projectFullPath" -ForegroundColor Cyan
                Write-Host "Downloaded files:  $downloadPath"   -ForegroundColor Cyan

                # Generate targeted installation documentation and launch Windows Sandbox
                Write-Host "`nGenerating targeted installation documentation..." -ForegroundColor Yellow
                $docSuccess = New-TargetedDocumentation -ProjectPath $projectFullPath -ProjectName $projectName -AppInfo $selectedApp

                if ($docSuccess) {
                    Write-Host '✓ Targeted documentation setup completed!' -ForegroundColor Green
                    Write-Host 'Use the generated Windows Sandbox configuration to document installation changes.' -ForegroundColor Cyan

                    Write-Host "`nWaiting for documentation completion..." -ForegroundColor Yellow
                    $fileInfo      = Get-InstallerFileInfo -FilesPath $downloadPath
                    $jsonProcessed = Wait-ForDocumentationAndProcess -ProjectPath $projectFullPath -InstallerType $fileInfo.Type

                    if ($jsonProcessed) {
                        Write-Host '✓ Documentation processing completed successfully!' -ForegroundColor Green
                    }
                    else {
                        Write-Warning 'Documentation processing had issues - please review manually'
                    }
                }
                else {
                    Write-Warning 'Documentation generation had issues - please review manually'
                }

                # Run test scenarios if requested
                if ($RunTest) {
                    foreach ($scenario in $RunTest) {
                        Test-Win32ToolkitProject -ProjectPath $projectFullPath -Scenario $scenario
                    }
                }

                # Package as .intunewin if requested
                if ($PackageIntune) {
                    Export-Win32ToolkitIntuneWin -ProjectPath $projectFullPath
                }


            }
            else {
                Write-Warning 'Project was created but download failed. You can manually add the application files to the Files directory.'
            }
        }
        else {
            Write-Error 'Failed to create PSADT project'
        }
    }
    catch {
        Write-Error "Script execution failed: $($_.Exception.Message)"
    }
}
