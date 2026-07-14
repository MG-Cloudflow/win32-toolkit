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
    Base folder for all output (Templates, Projects, Staging, IntuneWin). If omitted, the value
    saved in the registry (HKCU:\Software\CloudFlow\win32-toolkit) is used; on first run you are
    prompted for it and the choice is saved. An explicit value overrides but is not persisted.
.PARAMETER Reconfigure
    Re-prompt for the base folder and save the new value to the registry, ignoring any stored value.
.EXAMPLE
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force
.EXAMPLE
    Invoke-Win32Toolkit -SearchTerm 'visual studio code' -BasePath 'D:\Packaging'
.EXAMPLE
    Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
.PARAMETER PackageIntune
    After creating the project, package it into a .intunewin file using IntuneWinAppUtil.exe.
.PARAMETER PublishIntune
    After packaging, upload the .intunewin file to Microsoft Intune via Graph API.
    Implies -PackageIntune. Requires the Microsoft.Graph.Authentication module.
.EXAMPLE
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PackageIntune -PublishIntune
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
        [string]$BasePath,

        [Parameter(Mandatory = $false)]
        [switch]$Reconfigure,

        [Parameter(Mandatory = $false)]
        [ValidateSet('InstallUninstall', 'Update')]
        [string[]]$RunTest,

        [Parameter(Mandatory = $false)]
        [switch]$PackageIntune,

        [Parameter(Mandatory = $false)]
        [switch]$PublishIntune,

        # Also publish the update app (2nd app, same version, requirement-gated to installed devices).
        [Parameter(Mandatory = $false)]
        [switch]$PublishUpdate,

        # Apps that Intune must install BEFORE this one (e.g. a Visual C++ redistributable).
        # Accepts 'winget:<id>', 'project:<Template>\<Name>', 'intune:<guid>', or a bare reference.
        # Declared into AppConfig.json; resolved to real Intune app ids and attached as
        # mobileAppDependency relationships at publish time.
        [string[]]$DependsOn,

        [ValidateSet('autoInstall', 'detect')]
        [string]$DependencyType = 'autoInstall'
    )

    try {
        Write-Host 'Winget App Downloader + PSADT Project Creator' -ForegroundColor Cyan
        Write-Host '===========================================' -ForegroundColor Cyan

        # Check if winget is installed
        if (-not (Test-WingetInstalled)) {
            throw 'Winget is not installed or not available in PATH'
        }

        # Resolve the base folder (registry-backed; prompts and saves on first run)
        $BasePath = Get-Win32ToolkitBasePath -BasePath $BasePath -Reconfigure:$Reconfigure
        Write-Host "Base folder: $BasePath" -ForegroundColor DarkGray

        # -NewTemplate: create/update a template then exit, without packaging anything
        if ($NewTemplate) {
            $newTpl = New-OrgTemplate -TemplateName $TemplateName -BasePath $BasePath
            if ($newTpl) {
                Write-Host "`n✓ Template '$($newTpl.TemplateName)' created successfully." -ForegroundColor Green
            }
            return
        }

        # Load (or create) org template once for this run
        $script:OrgTemplate = Get-OrgTemplate -TemplateName $TemplateName -BasePath $BasePath

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

        # Ensure the template-scoped Projects tier exists before scaffolding:
        #   <BasePath>\Projects\<Template>\<Project>
        $paths       = Get-Win32ToolkitPaths -BasePath $BasePath
        $templateSeg = Sanitize-ProjectName -Name $script:OrgTemplate.TemplateName
        if ([string]::IsNullOrWhiteSpace($templateSeg)) { $templateSeg = 'Default' }
        $projectsDir = Join-Path $paths.Projects $templateSeg
        if (-not (Test-Path $projectsDir)) {
            New-Item -Path $projectsDir -ItemType Directory -Force | Out-Null
        }
        Write-Host "Template folder: $templateSeg" -ForegroundColor DarkGray

        # Create the PSADT project scaffold inside Projects\<Template>\
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

                # Declare Intune app dependencies (data-only). Written AFTER Configure-PSADTForInstaller so
                # AppConfig.json already exists, and BEFORE finalize so publishing can resolve + attach them.
                if ($DependsOn) {
                    $declared = Set-Win32ToolkitAppDependency -ProjectPath $projectFullPath -DependsOn $DependsOn -DependencyType $DependencyType
                    Write-Host "✓ Dependencies   : $((@($declared) | ForEach-Object { "$($_.Source):$($_.Ref)" }) -join ', ')" -ForegroundColor Green
                }

                # Documentation capture, uninstall automation, and optional test/package/publish
                # (shared with the manual-app flow — see Invoke-Win32ToolkitFinalize).
                $finalize = @{ ProjectPath = $projectFullPath; ProjectName = $projectName; AppInfo = $selectedApp }
                if ($RunTest) { $finalize['RunTest'] = $RunTest }   # omit when null (ValidateSet rejects $null)
                Invoke-Win32ToolkitFinalize @finalize -PackageIntune:$PackageIntune -PublishIntune:$PublishIntune -PublishUpdate:$PublishUpdate


            }
            else {
                # The download failed, so Rename/Configure/Finalize above were all skipped. Anything the
                # user asked for downstream (test, package, publish, dependencies) silently did NOT happen.
                # Name the options they actually supplied — a failed run must never look like a published one.
                # This stays a WARNING: the project folder is deliberately kept so the run can be retried.
                Write-Warning "Download FAILED for '$($selectedApp.Id)' ($selectedArch) - no installer was placed in the project's Files folder."

                $skipped = [System.Collections.Generic.List[string]]::new()
                if ($PSBoundParameters.ContainsKey('RunTest') -and $RunTest) {
                    $skipped.Add("-RunTest ($($RunTest -join ', ')): the package was NOT tested - no Sandbox/Hyper-V run happened.")
                }
                if ($PSBoundParameters.ContainsKey('PackageIntune') -and $PackageIntune) {
                    $skipped.Add('-PackageIntune: NOTHING was packaged - no .intunewin file was produced.')
                }
                if ($PSBoundParameters.ContainsKey('PublishIntune') -and $PublishIntune) {
                    $skipped.Add('-PublishIntune: NOTHING was published - no app was uploaded to Intune.')
                }
                if ($PSBoundParameters.ContainsKey('PublishUpdate') -and $PublishUpdate) {
                    $skipped.Add('-PublishUpdate: no update app was published to Intune.')
                }
                if ($PSBoundParameters.ContainsKey('DependsOn') -and $DependsOn) {
                    $skipped.Add("-DependsOn ($($DependsOn -join ', ')): no dependencies were declared on the project.")
                }

                if ($skipped.Count -gt 0) {
                    Write-Warning 'The following options you passed were SKIPPED because the download failed:'
                    foreach ($item in $skipped) { Write-Warning "  * $item" }
                }

                Write-Warning "The project folder was still created: $projectFullPath"
                Write-Warning "Next: re-run the same command to retry a transient download failure."
                # Do NOT tell the user to drop an installer into Files\ and re-run: Create-PSADTProject removes
                # and recreates the project directory on every run, so anything placed there by hand is deleted
                # before the (still failing) download is retried. Supplying your own installer is the MANUAL
                # flow's job.
                Write-Warning "To package an installer you supply yourself, use the manual flow instead:"
                Write-Warning "  New-Win32ToolkitManualApp -Name '$($selectedApp.Name)' -Version '$($selectedApp.Version)' -Architecture $selectedArch -SourcePath <path-to-your-installer>"
                Write-Warning "Do not copy files into '$downloadPath' and re-run this command — the project folder is recreated from scratch each run, which would delete them."
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
