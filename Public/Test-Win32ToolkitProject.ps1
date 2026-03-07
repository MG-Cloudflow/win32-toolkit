function Test-Win32ToolkitProject {
<#
.SYNOPSIS
    Tests a PSADT project by running it inside Windows Sandbox.
.DESCRIPTION
    Launches a Windows Sandbox session that executes a chosen test scenario against a
    PSADT V4 project. If no ProjectPath is supplied, an interactive menu is shown
    that lists all PSADT projects found under BasePath.

    The function is designed to be scenario-driven: new test types (e.g. 'Update')
    can be added as additional switch cases without changing the overall structure.
.PARAMETER ProjectPath
    Full path to the PSADT project folder (the folder that contains
    Invoke-AppDeployToolkit.ps1). If omitted, a numbered selection menu is shown.
.PARAMETER BasePath
    Root folder to scan for PSADT projects when ProjectPath is not provided.
    Defaults to 'C:\Win32Apps'.
.PARAMETER Scenario
    The test scenario to execute.
    - InstallUninstall : Install → 2-minute countdown → Uninstall (default)
    - Update           : Reserved for a future update-over-existing-install test.
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Git_x64_2.53.0'
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Git_x64_2.53.0' -Scenario InstallUninstall
.EXAMPLE
    Test-Win32ToolkitProject -BasePath 'D:\Packaging'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProjectPath,

        [Parameter(Mandatory = $false)]
        [string]$BasePath = 'C:\Win32Apps',

        [Parameter(Mandatory = $false)]
        [ValidateSet('InstallUninstall', 'Update')]
        [string]$Scenario = 'InstallUninstall'
    )

    try {
        # Resolve the project to test
        if (-not $ProjectPath) {
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
        <Command>powershell.exe -NoExit -ExecutionPolicy Bypass -Command &quot;&amp; { C:\PSADT\Invoke-AppDeployToolkit.ps1; C:\PSADT\Sandbox\Countdown.ps1; C:\PSADT\Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall }&quot;</Command>
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
                Write-Host '  4. Keep the sandbox open for verification'  -ForegroundColor Cyan
                Write-Host '=============================================' -ForegroundColor Cyan

                Start-Process -FilePath 'WindowsSandbox.exe' -ArgumentList $sandboxConfigFile

                Write-Host "`n✓ Final demo sandbox launched successfully!" -ForegroundColor Green
                Write-Host 'Monitor the sandbox for the complete install/uninstall cycle.' -ForegroundColor White
            }

            'Update' {
                # Placeholder — drop your Update test logic here when ready.
                Write-Warning "The 'Update' scenario has not been implemented yet."
            }
        }
    }
    catch {
        Write-Error "Test-Win32ToolkitProject failed: $($_.Exception.Message)"
    }
}
