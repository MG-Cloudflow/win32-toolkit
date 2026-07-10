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
    - Update           : Install an older baseline → assert the update-app requirement rule detects
                         it → 2-minute countdown → run the PSADT update → assert the requirement is
                         still met and the install tattoo holds the new version. Assertion results
                         stream back to the host (Sandbox\Logs\UpdateAssertions.log) and the command
                         reports a real PASS/FAIL verdict.
.PARAMETER VersionsBack
    Update scenario only. Automatically selects the version that is X positions older
    than the currently packaged version (e.g. 1 = the immediately previous release).
    Mutually exclusive intent with SpecificVersion; SpecificVersion takes priority.
.PARAMETER SpecificVersion
    Update scenario only. Installs this exact version as the baseline. Overrides
    VersionsBack if both are supplied.
.PARAMETER SkipRequirementCheck
    Update scenario only. Skip generating/running the update-app requirement script in the sandbox
    (its assertions report SKIP); the tattoo/detection assertion still runs. Use when the project
    has no usable requirement rule yet or you only want the plain install-over-old check.
.PARAMETER BaselineProjectPath
    Update scenario only. Install a PREVIOUS toolkit package (this folder) as the baseline instead of
    downloading the old vendor installer — exercises the tattoo-overwrite path (old tattoo → new
    tattoo) and works for manual (non-winget) projects. Mutually exclusive with -VersionsBack /
    -SpecificVersion. The baseline project is mapped READ-ONLY (its raw copy is never modified).
.EXAMPLE
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Git_x64_2.53.0' -Scenario Update -VersionsBack 1 -SkipRequirementCheck
.EXAMPLE
    # Baseline with a previous toolkit package (tattoo-overwrite test)
    Test-Win32ToolkitProject -ProjectPath 'C:\Win32Apps\Contoso\Git_x64_2.55.0' -Scenario Update -BaselineProjectPath 'C:\Win32Apps\Contoso\Git_x64_2.53.0'
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
        [ValidateRange(1, 1000)]
        [int]$VersionsBack,

        [Parameter(Mandatory = $false)]
        [string]$SpecificVersion,

        # Update scenario only: don't generate/run the update-app requirement script in the sandbox —
        # its assertions are reported as SKIP. The tattoo/detection assertion still runs.
        [Parameter(Mandatory = $false)]
        [switch]$SkipRequirementCheck,

        # Update scenario only: install a PREVIOUS toolkit package (this project folder) as the baseline
        # instead of downloading the old vendor installer — exercises the tattoo-overwrite path. Mutually
        # exclusive with -VersionsBack / -SpecificVersion, and works for manual (non-winget) projects.
        [Parameter(Mandatory = $false)]
        [string]$BaselineProjectPath
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

        # -BaselineProjectPath validation runs FIRST (before the sandbox pre-flight) so parameter
        # errors are deterministic regardless of whether a sandbox is open.
        $baselineApp = $null
        if ($Scenario -eq 'Update' -and $BaselineProjectPath) {
            if ($VersionsBack -or $SpecificVersion) {
                throw '-BaselineProjectPath is mutually exclusive with -VersionsBack / -SpecificVersion (the baseline IS the supplied project).'
            }
            if (-not (Test-Path -LiteralPath $BaselineProjectPath)) {
                throw "Baseline project not found: $BaselineProjectPath"
            }
            if (-not (Test-Path -LiteralPath (Join-Path $BaselineProjectPath 'Invoke-AppDeployToolkit.ps1'))) {
                throw "Not a PSADT project (no Invoke-AppDeployToolkit.ps1): $BaselineProjectPath"
            }
            if ((Resolve-Path -LiteralPath $BaselineProjectPath).Path -eq (Resolve-Path -LiteralPath $ProjectPath).Path) {
                throw '-BaselineProjectPath must be a DIFFERENT project than the one under test.'
            }
            $baseCfg     = Get-Win32ToolkitAppConfig -ProjectPath $BaselineProjectPath
            $baselineApp = if ($baseCfg.PSObject.Properties.Name -contains 'App') { $baseCfg.App } else { $null }
            if (-not ($baselineApp -and $baselineApp.Version)) {
                throw "Baseline project has no App.Version in SupportFiles\AppConfig.json (it predates AppConfig — regenerate it): $BaselineProjectPath"
            }
        }

        # Windows Sandbox allows a single running instance — fail fast (before any download work)
        # instead of launching a doomed sandbox and waiting on assertions that will never come.
        if (Test-Win32ToolkitSandboxRunning) {
            throw 'Another Windows Sandbox is already running (only one instance is allowed). Close it — e.g. the documentation-capture sandbox from a previous step — and re-run the test.'
        }

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

                $logonCommandXml = 'powershell.exe -NoExit -ExecutionPolicy Bypass -Command &quot;&amp; { try { C:\PSADT\Invoke-AppDeployToolkit.ps1; C:\PSADT\Sandbox\Countdown.ps1; C:\PSADT\Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall } finally { C:\PSADT\Sandbox\CollectLogs.ps1 } }&quot;'
                $sandboxConfigContent = New-Win32ToolkitSandboxConfig `
                    -Mount @{ HostPath = $ProjectPath; GuestPath = 'C:\PSADT'; ReadOnly = $false } `
                    -LogonCommandXml $logonCommandXml
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

                if ((Invoke-Win32ToolkitTestRun -Backend Sandbox -SandboxConfigPath $sandboxConfigFile).Launched) {
                    Write-Host "`n✓ Final demo sandbox launched successfully!" -ForegroundColor Green
                    Write-Host 'Monitor the sandbox for the complete install/uninstall cycle.' -ForegroundColor White
                } else {
                    Write-Host 'The sandbox did NOT auto-launch — start it manually by double-clicking:' -ForegroundColor Yellow
                    Write-Host "  $sandboxConfigFile" -ForegroundColor Yellow
                }
            }

            'Update' {
                $useBaselineProject = [bool]$BaselineProjectPath
                Write-Host "`nScenario: Install Old Version → Countdown → Run PSADT Update" -ForegroundColor Cyan

                if ($useBaselineProject) {
                    # ── Baseline = a previous TOOLKIT package (no winget) ──────────────────
                    $targetVersion = $baselineApp.Version
                    Write-Host "Baseline project : $BaselineProjectPath" -ForegroundColor Gray
                    Write-Host "Baseline version : $targetVersion (from its AppConfig)" -ForegroundColor Yellow

                    # Warn if the baseline is a different app (the tattoo-overwrite test would be meaningless).
                    $cfgU = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
                    $appU = if ($cfgU.PSObject.Properties.Name -contains 'App') { $cfgU.App } else { $null }
                    $idU  = "$($appU.ScriptAuthor)|$($appU.Vendor)|$(if ($appU.DisplayName) { $appU.DisplayName } else { $appU.Name })"
                    $idB  = "$($baselineApp.ScriptAuthor)|$($baselineApp.Vendor)|$(if ($baselineApp.DisplayName) { $baselineApp.DisplayName } else { $baselineApp.Name })"
                    if ($idU -ne $idB) {
                        Write-Warning "The baseline project's tattoo identity ($idB) differs from the project under test ($idU) — the tattoo-overwrite assertions may FAIL because it is a different app."
                    }
                    # The baseline is mapped ReadOnly; a LogPath that is relative or points inside the
                    # baseline project folder would make its install fail — warn (best-effort; PSADT
                    # variable paths like $envWinDir\... are left alone). The config always stores a HOST
                    # path, so match the risky host shapes — NOT the C:\PSADTOld sandbox mount.
                    $baseConfigPsd1 = Join-Path $BaselineProjectPath 'Config\config.psd1'
                    if (Test-Path -LiteralPath $baseConfigPsd1) {
                        if ((Get-Content -LiteralPath $baseConfigPsd1 -Raw) -match "(?m)LogPath\s*=\s*'([^']*)'") {
                            $lp = $matches[1]
                            $isVar = $lp -match '^\s*[\$%]'
                            if ($lp -and -not $isVar -and ((-not [System.IO.Path]::IsPathRooted($lp)) -or ($lp -like "$BaselineProjectPath*"))) {
                                Write-Warning "The baseline project's LogPath ('$lp') is relative or inside the project folder, which is mapped READ-ONLY — its install may fail. Use a template with an absolute default LogPath (e.g. C:\Windows\Logs\Software)."
                            }
                        }
                    }
                }
                else {
                    # ── Step 1: Read package info from the project's Files YAML ──────────────
                    $filesPath = Join-Path $ProjectPath 'Files'
                    if (-not (Test-Path $filesPath)) {
                        throw "Files directory not found in: $filesPath`nEnsure this project was created with win32-toolkit."
                    }

                    $wingetId = Get-WingetIdFromProject -FilesPath $filesPath
                    if (-not $wingetId) {
                        throw "No winget PackageIdentifier found in: $filesPath`nThe Update scenario needs a winget-based project (it downloads the older baseline from winget). For a manual project, pass -BaselineProjectPath, or use -Scenario InstallUninstall."
                    }

                    $yamlInfo       = Get-YAMLInstallerInfo -FilesPath $filesPath
                    $currentVersion = if ($yamlInfo) { $yamlInfo.PackageVersion } else { $null }
                    $architecture   = if ($yamlInfo) { $yamlInfo.Architecture }   else { $null }

                    Write-Host "Package ID       : $wingetId"       -ForegroundColor Gray
                    Write-Host "Packaged version : $currentVersion" -ForegroundColor Gray

                    # ── Step 2-3: Pick the target baseline version ────────────────────────────
                    if ($SpecificVersion) {
                        # Explicit baseline: usable even when winget lists no (or no older) versions —
                        # the older-version lookup is advisory only here.
                        $targetVersion = $SpecificVersion
                        try {
                            $known = @(Get-WingetVersions -AppId $wingetId -CurrentVersion $currentVersion)
                            if ($known -notcontains $SpecificVersion) {
                                Write-Warning "'$SpecificVersion' was not found in the filtered older-version list but will be used as requested."
                            }
                        }
                        catch { Write-Verbose "Older-version lookup skipped: $($_.Exception.Message)" }

                    } else {
                        # @() guard: a single older version must stay an array, or indexing below would
                        # slice characters out of the version STRING.
                        $olderVersions = @(Get-WingetVersions -AppId $wingetId -CurrentVersion $currentVersion)

                        if ($VersionsBack -gt 0) {
                            if ($VersionsBack -gt $olderVersions.Count) {
                                throw "Requested $VersionsBack version(s) back but only $($olderVersions.Count) older version(s) are available for '$wingetId'."
                            }
                            $targetVersion = $olderVersions[$VersionsBack - 1]
                        } else {
                            $targetVersion = Show-VersionSelection -Versions $olderVersions
                        }
                    }

                    Write-Host "Target version   : $targetVersion" -ForegroundColor Yellow

                    # ── Step 4: Download the old-version installer (pinned to the packaged variant) ──
                    $dl = @{
                        AppId        = $wingetId
                        Version      = $targetVersion
                        ProjectPath  = $ProjectPath
                        Architecture = $architecture
                    }
                    if ($yamlInfo) {
                        if ($yamlInfo.Scope)           { $dl['Scope']         = $yamlInfo.Scope }
                        if ($yamlInfo.InstallerType)   { $dl['InstallerType'] = $yamlInfo.InstallerType }
                        if ($yamlInfo.InstallerLocale) { $dl['Locale']        = $yamlInfo.InstallerLocale }
                    }
                    $oldInstaller = Download-OldVersionInstaller @dl
                }

                # ── Step 5: Ensure Countdown.ps1 exists ──────────────────────────────────
                Write-Host 'Creating countdown script...' -ForegroundColor Yellow
                $countdownPath = New-CountdownScript -ProjectPath $ProjectPath
                Write-Host "✓ Countdown script : $countdownPath" -ForegroundColor Green

                # Log collector — copies PSADT/MSI logs back to the project after the run
                $logCollectorPath = New-LogCollectorScript -ProjectPath $ProjectPath
                Write-Host "✓ Log collector    : $logCollectorPath" -ForegroundColor Green

                # ── Step 5b: Requirement script + in-sandbox assertions ──────────────────
                # Generate the update app's requirement script now (Get-Win32ToolkitRequirementRule
                # writes SupportFiles\UpdateRequirement.ps1 as a side effect) so the sandbox can prove
                # it detects a REAL old install: PreUpdate = requirement met on the old baseline,
                # PostUpdate = still met + tattoo holds the NEW version (the Intune detection rule).
                # With -SkipRequirementCheck the requirement assertions are SKIPped (tattoo still runs).
                if (-not $SkipRequirementCheck) {
                    $reqRule = Get-Win32ToolkitRequirementRule -ProjectPath $ProjectPath
                    if (-not $reqRule) {
                        Write-Warning 'No update requirement rule could be built for this project — the requirement assertions will be SKIPPED in the sandbox.'
                        # Remove a stale UpdateRequirement.ps1 from an earlier packaging so the sandbox
                        # doesn't assert against a rule that will not ship.
                        $staleReq = Join-Path $ProjectPath 'SupportFiles\UpdateRequirement.ps1'
                        if (Test-Path -LiteralPath $staleReq) {
                            Remove-Item -LiteralPath $staleReq -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                else {
                    Write-Host 'Requirement check disabled (-SkipRequirementCheck).' -ForegroundColor DarkYellow
                }
                $assertionPath = New-UpdateAssertionScript -ProjectPath $ProjectPath `
                    -SkipRequirement:$SkipRequirementCheck -OldVersion $targetVersion `
                    -ExpectBaselineTattoo:$useBaselineProject
                Write-Host "✓ Assertion script : $assertionPath" -ForegroundColor Green

                # Fresh run: clear the assertions log and the ARP snapshot state from any previous run.
                $logsDir = Join-Path $ProjectPath 'Sandbox\Logs'
                foreach ($f in 'UpdateAssertions.log', 'PreBaselineArp.json', 'PreUpdateArpBaseline.json') {
                    $fp = Join-Path $logsDir $f
                    if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue }
                }

                # ── Step 6: Build the sandbox WSB config ──────────────────────────────────
                $sandboxFolder     = Join-Path $ProjectPath 'Sandbox'
                $sandboxConfigFile = Join-Path $sandboxFolder 'UpdateDemo.wsb'

                # Baseline install command. Vendor baseline: exe/msi via Start-Process, msix/appx via
                # Add-AppxPackage (untrusted values escaped + argv-safe). Toolkit-package baseline: run
                # its Invoke-AppDeployToolkit.ps1 from the second (read-only) mapped folder — a fixed
                # sandbox-side path, no untrusted splice. Then XML-encode for the .wsb <Command>.
                $installCmd = if ($useBaselineProject) {
                    "& 'C:\PSADTOld\Invoke-AppDeployToolkit.ps1' -DeployMode Silent"
                } else {
                    Get-Win32ToolkitBaselineInstallCommand `
                        -InstallerSandboxPath "C:\PSADT\Sandbox\OldVersion\$($oldInstaller.InstallerName)" `
                        -InstallerType $oldInstaller.InstallerType `
                        -SilentArgs    $oldInstaller.SilentArgs
                }
                $installCmdXml = ConvertTo-XmlEncoded $installCmd

                # Mapped folders: project (RW) + optional read-only baseline (never mutate the raw
                # Projects\ copy). Order preserved: project first, then baseline (C:\PSADTOld).
                $mounts = @(@{ HostPath = $ProjectPath; GuestPath = 'C:\PSADT'; ReadOnly = $false })
                if ($useBaselineProject) {
                    $mounts += @{ HostPath = $BaselineProjectPath; GuestPath = 'C:\PSADTOld'; ReadOnly = $true }
                }

                # $installCmdXml is already XML-encoded (ConvertTo-XmlEncoded above); the rest of the
                # LogonCommand is static, XML-safe text. The builder XML-encodes the host paths.
                $logonCommandXml = "powershell.exe -NoExit -ExecutionPolicy Bypass -Command &quot;&amp; { try { &amp; 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PreBaseline; $installCmdXml; &amp; 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PreUpdate; &amp; 'C:\PSADT\Sandbox\Countdown.ps1'; &amp; 'C:\PSADT\Invoke-AppDeployToolkit.ps1'; &amp; 'C:\PSADT\Sandbox\UpdateAssertions.ps1' -Phase PostUpdate } finally { &amp; 'C:\PSADT\Sandbox\CollectLogs.ps1' } }&quot;"
                $sandboxConfigContent = New-Win32ToolkitSandboxConfig -Mount $mounts -LogonCommandXml $logonCommandXml
                Set-Content -Path $sandboxConfigFile -Value $sandboxConfigContent -Encoding UTF8
                Write-Host "✓ Sandbox config   : $sandboxConfigFile" -ForegroundColor Green

                # ── Step 7: Launch Windows Sandbox ────────────────────────────────────────
                Write-Host ''
                Write-Host 'Launching Windows Sandbox for the Update test...'           -ForegroundColor Cyan
                Write-Host '================================================'          -ForegroundColor Cyan
                Write-Host 'The sandbox will:'                                          -ForegroundColor White
                Write-Host '  0. Snapshot existing Add/Remove Programs entries (baseline)' -ForegroundColor DarkGray
                if ($useBaselineProject) {
                Write-Host "  1. Install the PREVIOUS toolkit package v$targetVersion (writes its tattoo)" -ForegroundColor Green
                } else {
                Write-Host "  1. Silently install v$targetVersion (old vendor baseline)" -ForegroundColor Green
                }
                if ($useBaselineProject) {
                Write-Host '  2. ASSERT: baseline tattoo = old version; requirement detects the old install' -ForegroundColor Cyan
                } elseif ($SkipRequirementCheck) {
                Write-Host '  2. (requirement-rule check skipped by request)'          -ForegroundColor DarkYellow
                } else {
                Write-Host '  2. ASSERT: update requirement rule detects the old install' -ForegroundColor Cyan
                }
                Write-Host '  3. Show a 2-minute countdown — verify the old install'   -ForegroundColor Yellow
                Write-Host '  4. Run the PSADT package to perform the update'          -ForegroundColor Cyan
                Write-Host '  5. ASSERT: requirement still met; tattoo = new version; old ARP entry gone' -ForegroundColor Cyan
                Write-Host '  6. Copy PSADT/MSI logs to project\Sandbox\Logs'          -ForegroundColor Cyan
                Write-Host '  7. Keep the sandbox open for final verification'         -ForegroundColor White
                Write-Host '================================================'          -ForegroundColor Cyan

                if ((Invoke-Win32ToolkitTestRun -Backend Sandbox -SandboxConfigPath $sandboxConfigFile).Launched) {
                    Write-Host "`n✓ Update test sandbox launched." -ForegroundColor Green
                } else {
                    Write-Host "The sandbox did NOT auto-launch — start it manually by double-clicking: $sandboxConfigFile" -ForegroundColor Yellow
                }

                # ── Step 8: Wait for the in-sandbox assertions and report pass/fail ──────
                # The verdict is RETURNED ($true pass / $false fail / $null inconclusive) so callers
                # (finalize pipeline, TUI, automation) can gate on a failed update test.
                return (Wait-Win32ToolkitUpdateAssertion -ProjectPath $ProjectPath)
            }
        }
    }
    catch {
        Write-Error "Test-Win32ToolkitProject failed: $($_.Exception.Message)"
    }
}
