function Test-Win32ToolkitProject {
<#
.SYNOPSIS
    Tests a PSADT project by running it inside Windows Sandbox.
.DESCRIPTION
    Launches a Windows Sandbox session that executes a chosen test scenario against a
    PSADT V4 project. If no ProjectPath is supplied, an interactive menu is shown
    that lists all PSADT projects found under BasePath.

    The function is designed to be scenario-driven: new test types can be added as
    additional switch cases without changing the overall structure.
.PARAMETER ProjectPath
    Full path to the PSADT project folder (the folder that contains
    Invoke-AppDeployToolkit.ps1). If omitted, a numbered selection menu is shown.
.PARAMETER BasePath
    Root folder to scan for PSADT projects when ProjectPath is not provided. If omitted, the
    registry-saved value is used (see Invoke-Win32Toolkit).
.PARAMETER Scenario
    The test scenario to execute. If omitted, an interactive menu is shown.
    - InstallUninstall : Install → 2-minute countdown → Uninstall
    - Update           : Install an older baseline → 2-minute countdown → run PSADT update
.PARAMETER VersionsBack
    Update scenario only. Automatically selects the version that is X positions older
    than the currently packaged version (e.g. 1 = the immediately previous release).
    Mutually exclusive intent with SpecificVersion; SpecificVersion takes priority.
.PARAMETER SpecificVersion
    Update scenario only. Installs this exact version as the baseline. Overrides
    VersionsBack if both are supplied.
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Git_x64_2.53.0'
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Git_x64_2.53.0' -Scenario InstallUninstall
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Git_x64_2.53.0' -Scenario Update -VersionsBack 1
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Git_x64_2.53.0' -Scenario Update -SpecificVersion '2.47.0'
.EXAMPLE
    Test-Win32ToolkitProject -BasePath 'D:\Packaging' -Scenario Update
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProjectPath,

        [Parameter(Mandatory = $false)]
        [string]$BasePath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('InstallUninstall', 'Update')]
        [string]$Scenario,

        [Parameter(Mandatory = $false)]
        [int]$VersionsBack,

        [Parameter(Mandatory = $false)]
        [string]$SpecificVersion
    )

    try {
        # Prompt for scenario if not explicitly supplied
        if (-not $PSBoundParameters.ContainsKey('Scenario')) {
            $Scenario = Show-ScenarioSelection
        }

        # Resolve the project to test
        if (-not $ProjectPath) {
            $BasePath = Get-Win32ToolkitBasePath -BasePath $BasePath
            Write-Host 'Scanning for PSADT projects...' -ForegroundColor Yellow
            $projects = Get-PSADTProjects -BasePath $BasePath

            if ($projects.Count -eq 0) {
                throw "No PSADT projects found in: $BasePath. Ensure project folders contain Invoke-AppDeployToolkit.ps1."
            }

            $selectedProject = Show-ProjectSelection -Projects $projects
            $ProjectPath     = $selectedProject.Path
        }

        if (-not (Test-Path $ProjectPath)) {
            throw "Project path not found: $ProjectPath"
        }

        $projectName = Split-Path -Leaf $ProjectPath
        Write-Host "`nSelected project : $projectName"  -ForegroundColor Green
        Write-Host "Project path     : $ProjectPath"   -ForegroundColor Gray
        Write-Host "Scenario         : $Scenario"      -ForegroundColor Cyan

        switch ($Scenario) {

            'InstallUninstall' {
                Write-Host "`nScenario: Install → Countdown → Uninstall" -ForegroundColor Cyan

                # Create the countdown helper script inside Sandbox\
                Write-Host 'Creating countdown script...' -ForegroundColor Yellow
                $countdownPath = New-CountdownScript -ProjectPath $ProjectPath
                Write-Host "✓ Countdown script : $countdownPath" -ForegroundColor Green

                # Log collector — copies PSADT/MSI logs back to the project after the run
                $logCollectorPath = New-LogCollectorScript -ProjectPath $ProjectPath
                Write-Host "✓ Log collector    : $logCollectorPath" -ForegroundColor Green

                # Build sandbox configuration
                $sandboxFolder     = Join-Path $ProjectPath 'Sandbox'
                $sandboxConfigFile = Join-Path $sandboxFolder 'FinalDemo.wsb'

                $sandboxConfigContent = @"
<Configuration>
    <VGpu>Disable</VGpu>
    <Networking>Enable</Networking>
    <MappedFolders>
        <MappedFolder>
            <HostFolder>$ProjectPath</HostFolder>
            <SandboxFolder>C:\PSADT</SandboxFolder>
            <ReadOnly>false</ReadOnly>
        </MappedFolder>
    </MappedFolders>
    <LogonCommand>
        <Command>powershell.exe -NoExit -ExecutionPolicy Bypass -Command &quot;&amp; { try { C:\PSADT\Invoke-AppDeployToolkit.ps1; C:\PSADT\Sandbox\Countdown.ps1; C:\PSADT\Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall } finally { C:\PSADT\Sandbox\CollectLogs.ps1 } }&quot;</Command>
    </LogonCommand>
</Configuration>
"@
                Set-Content -Path $sandboxConfigFile -Value $sandboxConfigContent -Encoding UTF8
                Write-Host "✓ Sandbox config   : $sandboxConfigFile" -ForegroundColor Green

                # Launch Windows Sandbox
                Write-Host ''
                Write-Host 'Launching Windows Sandbox for Final Demo...' -ForegroundColor Cyan
                Write-Host '=============================================' -ForegroundColor Cyan
                Write-Host 'The sandbox will:'                            -ForegroundColor White
                Write-Host '  1. Install the application'                 -ForegroundColor Green
                Write-Host '  2. Show a 2-minute countdown for testing'   -ForegroundColor Yellow
                Write-Host '  3. Uninstall the application'               -ForegroundColor Red
                Write-Host '  4. Copy PSADT/MSI logs to project\Sandbox\Logs' -ForegroundColor Cyan
                Write-Host '  5. Keep the sandbox open for verification'  -ForegroundColor Cyan
                Write-Host '=============================================' -ForegroundColor Cyan

                Start-Process -FilePath 'WindowsSandbox.exe' -ArgumentList $sandboxConfigFile

                Write-Host "`n✓ Final demo sandbox launched successfully!" -ForegroundColor Green
                Write-Host 'Monitor the sandbox for the complete install/uninstall cycle.' -ForegroundColor White
            }

            'Update' {
                Write-Host "`nScenario: Install Old Version → Countdown → Run PSADT Update" -ForegroundColor Cyan

                # ── Step 1: Read package info from the project's Files YAML ──────────────
                $filesPath = Join-Path $ProjectPath 'Files'
                if (-not (Test-Path $filesPath)) {
                    throw "Files directory not found in: $filesPath`nEnsure this project was created with win32-toolkit."
                }

                $wingetId = Get-WingetIdFromProject -FilesPath $filesPath
                if (-not $wingetId) {
                    throw "Could not read PackageIdentifier from YAML in: $filesPath"
                }

                $yamlInfo       = Get-YAMLInstallerInfo -FilesPath $filesPath
                $currentVersion = if ($yamlInfo) { $yamlInfo.PackageVersion } else { $null }
                $architecture   = if ($yamlInfo) { $yamlInfo.Architecture }   else { $null }

                Write-Host "Package ID       : $wingetId"       -ForegroundColor Gray
                Write-Host "Packaged version : $currentVersion" -ForegroundColor Gray

                # ── Step 2: Resolve list of older versions ────────────────────────────────
                $olderVersions = Get-WingetVersions -AppId $wingetId -CurrentVersion $currentVersion

                # ── Step 3: Pick the target baseline version ──────────────────────────────
                if ($SpecificVersion) {
                    if ($olderVersions -notcontains $SpecificVersion) {
                        Write-Warning "'$SpecificVersion' was not found in the filtered older-version list but will be used as requested."
                    }
                    $targetVersion = $SpecificVersion

                } elseif ($VersionsBack -gt 0) {
                    if ($VersionsBack -gt $olderVersions.Count) {
                        throw "Requested $VersionsBack version(s) back but only $($olderVersions.Count) older version(s) are available for '$wingetId'."
                    }
                    $targetVersion = $olderVersions[$VersionsBack - 1]

                } else {
                    $targetVersion = Show-VersionSelection -Versions $olderVersions
                }

                Write-Host "Target version   : $targetVersion" -ForegroundColor Yellow

                # ── Step 4: Download the old-version installer ────────────────────────────
                $oldInstaller = Download-OldVersionInstaller `
                    -AppId        $wingetId     `
                    -Version      $targetVersion `
                    -ProjectPath  $ProjectPath  `
                    -Architecture $architecture

                # ── Step 5: Ensure Countdown.ps1 exists ──────────────────────────────────
                Write-Host 'Creating countdown script...' -ForegroundColor Yellow
                $countdownPath = New-CountdownScript -ProjectPath $ProjectPath
                Write-Host "✓ Countdown script : $countdownPath" -ForegroundColor Green

                # Log collector — copies PSADT/MSI logs back to the project after the run
                $logCollectorPath = New-LogCollectorScript -ProjectPath $ProjectPath
                Write-Host "✓ Log collector    : $logCollectorPath" -ForegroundColor Green

                # ── Step 6: Build the sandbox WSB config ──────────────────────────────────
                $sandboxFolder     = Join-Path $ProjectPath 'Sandbox'
                $sandboxConfigFile = Join-Path $sandboxFolder 'UpdateDemo.wsb'

                # Installer path as seen inside the sandbox (project maps to C:\PSADT).
                # InstallerName and SilentArgs are untrusted (winget download / YAML):
                # escape for the single-quoted PowerShell literal (ConvertTo-PSSingleQuoted),
                # then XML-encode the whole command for the .wsb <Command> (ConvertTo-XmlEncoded).
                $installerSandboxPath = "C:\PSADT\Sandbox\OldVersion\$($oldInstaller.InstallerName)"
                $installerPathSq = ConvertTo-PSSingleQuoted $installerSandboxPath
                $silentArgsSq    = ConvertTo-PSSingleQuoted $oldInstaller.SilentArgs

                $installCmd = if ($oldInstaller.SilentArgs) {
                    "Start-Process '$installerPathSq' -ArgumentList '$silentArgsSq' -Wait"
                } else {
                    "Start-Process '$installerPathSq' -Wait"
                }
                $installCmdXml = ConvertTo-XmlEncoded $installCmd

                $sandboxConfigContent = @"
<Configuration>
    <VGpu>Disable</VGpu>
    <Networking>Enable</Networking>
    <MappedFolders>
        <MappedFolder>
            <HostFolder>$ProjectPath</HostFolder>
            <SandboxFolder>C:\PSADT</SandboxFolder>
            <ReadOnly>false</ReadOnly>
        </MappedFolder>
    </MappedFolders>
    <LogonCommand>
        <Command>powershell.exe -NoExit -ExecutionPolicy Bypass -Command &quot;&amp; { try { $installCmdXml; &amp; 'C:\PSADT\Sandbox\Countdown.ps1'; &amp; 'C:\PSADT\Invoke-AppDeployToolkit.ps1' } finally { &amp; 'C:\PSADT\Sandbox\CollectLogs.ps1' } }&quot;</Command>
    </LogonCommand>
</Configuration>
"@
                Set-Content -Path $sandboxConfigFile -Value $sandboxConfigContent -Encoding UTF8
                Write-Host "✓ Sandbox config   : $sandboxConfigFile" -ForegroundColor Green

                # ── Step 7: Launch Windows Sandbox ────────────────────────────────────────
                Write-Host ''
                Write-Host 'Launching Windows Sandbox for Update Demo...'              -ForegroundColor Cyan
                Write-Host '================================================'          -ForegroundColor Cyan
                Write-Host 'The sandbox will:'                                          -ForegroundColor White
                Write-Host "  1. Silently install v$targetVersion (old baseline)"      -ForegroundColor Green
                Write-Host '  2. Show a 2-minute countdown — verify the old install'   -ForegroundColor Yellow
                Write-Host '  3. Run the PSADT package to perform the update'          -ForegroundColor Cyan
                Write-Host '  4. Copy PSADT/MSI logs to project\Sandbox\Logs'          -ForegroundColor Cyan
                Write-Host '  5. Keep the sandbox open for final verification'         -ForegroundColor White
                Write-Host '================================================'          -ForegroundColor Cyan

                Start-Process -FilePath 'WindowsSandbox.exe' -ArgumentList $sandboxConfigFile

                Write-Host "`n✓ Update demo sandbox launched successfully!" -ForegroundColor Green
                Write-Host 'Monitor the sandbox for the complete update cycle.'        -ForegroundColor White
            }
        }
    }
    catch {
        Write-Error "Test-Win32ToolkitProject failed: $($_.Exception.Message)"
    }
}
