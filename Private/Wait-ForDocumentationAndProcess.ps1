function Wait-ForDocumentationAndProcess {
    [CmdletBinding()]
    param(
        [string]$ProjectPath,
        [string]$InstallerType,

        # Exact capture file this run's sandbox will produce (returned by New-TargetedDocumentation).
        # When provided, the wait is satisfied ONLY by this file — immune to stale captures from
        # previous runs. When omitted (back-compat), the newest capture is selected
        # (Get-LatestInstallationCapture; note: filter is 'InstallationChanges_*.json', with underscore).
        [string]$ExpectedJsonPath
    )

    try {
        Write-Host "Monitoring for documentation completion..." -ForegroundColor Yellow

        $jsonFound = $false
        $jsonFile = $null
        $maxWaitMinutes = 30
        # 2 s cadence (was 10 s): a Test-Path + small-file read on a local/VSMB path is trivial, and the
        # 10 s quantum added ~5 s of dead tail to every capture. The 30-min CEILING is unchanged — it is
        # the correct bound for an unobservable guest.
        $checkIntervalSeconds = 2
        $totalChecks = ($maxWaitMinutes * 60) / $checkIntervalSeconds

        if ($ExpectedJsonPath) {
            Write-Host "Waiting for this run's capture: $(Split-Path $ExpectedJsonPath -Leaf)" -ForegroundColor Cyan
        } else {
            Write-Verbose "Checking for InstallationChanges JSON file every $checkIntervalSeconds seconds..."
        }
        Write-Verbose "Maximum wait time: $maxWaitMinutes minutes"

        for ($i = 1; $i -le $totalChecks; $i++) {
            $candidate = $null
            if ($ExpectedJsonPath) {
                if (Test-Path -LiteralPath $ExpectedJsonPath) { $candidate = $ExpectedJsonPath }
            }
            else {
                $latest = Get-LatestInstallationCapture -ProjectPath $ProjectPath
                if ($latest) { $candidate = $latest.FullName }
            }

            if ($candidate) {
                # The guest writes the JSON over VSMB / to the mapped folder while we poll — the faster
                # cadence raises the odds of catching it MID-WRITE. Only accept a capture that parses as
                # complete JSON; a torn read simply stays in the loop and is retried next tick (a partial
                # capture feeding requirement/uninstall generation would corrupt the package quietly).
                $parsed = $null
                try { $parsed = Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
                if ($parsed) {
                    $jsonFile = $candidate
                    $jsonFound = $true
                    Write-Host "✓ JSON documentation file found: $(Split-Path $candidate -Leaf)" -ForegroundColor Green
                    break
                }
                Write-Verbose "Capture file present but not yet complete JSON — still being written; retrying..."
            }

            $minutesWaited = ($i * $checkIntervalSeconds) / 60
            Write-Verbose "Waiting... ($([math]::Round($minutesWaited, 1)) minutes elapsed)"
            Start-Sleep -Seconds $checkIntervalSeconds
        }

        if (-not $jsonFound) {
            Write-Warning "Documentation JSON file not found after $maxWaitMinutes minutes. Please check the Windows Sandbox manually."
            return $false
        }
        
        # ── Refuse a capture of a FAILED or EMPTY install BEFORE anything is derived from it (TST-03) ──
        # Detection, requirement and uninstall data generated from a broken install would ship a package
        # that "works" in the pipeline and fails on devices. Nothing below runs in these cases, so
        # AppConfig.Uninstall (and every other writer's section) stays untouched. Captures written by an
        # older toolkit lack the exit-code fields and are judged on the diff only. Packaging itself is not
        # blocked here (Finalize warns; the export/publish gates stop a no-op package).
        $successCodes = @(0, 1707, 3010, 1641)
        $info = $parsed.InstallationInfo
        foreach ($field in 'PsadtExitCode', 'DependencyExitCode') {
            if ($info -and $info.PSObject.Properties[$field] -and $null -ne $info.$field) {
                $code = $info.$field
                if ($successCodes -notcontains $code) {
                    $what = if ($field -eq 'PsadtExitCode') { 'The PSADT install in the capture run' } else { 'The declared dependencies in the capture run' }
                    $hint = switch ($code) { 60001 { ' (60001 = PSADT script error)' } 60008 { ' (60008 = PSADT session/launch failure)' } default { '' } }
                    Write-Warning "$what failed with exit code $code$hint - no requirement, uninstall or processes-to-close data was generated from it. Check $(Split-Path $jsonFile -Leaf), the PSADT log under Sandbox\Logs, then re-run the capture."
                    return $false
                }
            }
        }
        if ($InstallerType -notin @('msix', 'appx')) {
            $diffCount = 0
            foreach ($section in 'NewFiles', 'NewRegistryKeys', 'NewServices', 'NewPrograms') {
                if ($parsed.PSObject.Properties[$section]) { $diffCount += @($parsed.$section | Where-Object { $null -ne $_ }).Count }
            }
            if ($diffCount -eq 0) {
                Write-Warning "The capture recorded NO changes (no new files, registry keys, services or programs) - the install did nothing in the guest, so no requirement, uninstall or processes-to-close data was generated. Check $(Split-Path $jsonFile -Leaf) and the PSADT log under Sandbox\Logs."
                return $false
            }
        }

        Write-Host "`nProcessing documentation results..." -ForegroundColor Yellow

        # Generate requirement script
        Write-Verbose "Generating Intune requirement script..."
        $reqSuccess = New-IntuneRequirementScript -ProjectPath $ProjectPath -JsonFilePath $jsonFile
        
        if ($reqSuccess) {
            Write-Host "✓ Intune requirement script generated" -ForegroundColor Green
        } else {
            Write-Warning "Failed to generate requirement script"
        }
        
        # Uninstall generation depends on installer type: EXE from the capture, MSI via PSADT
        # Zero-Config, MSIX/APPX identity-driven (written at configure time; re-run here as
        # belt-and-braces — it is an idempotent read-modify-write of AppConfig.json).
        switch ($InstallerType) {
            'exe' {
                Write-Verbose "Generating uninstall logic for EXE installer..."
                $uninstallSuccess = Update-PSADTUninstallLogic -ProjectPath $ProjectPath -JsonFilePath $jsonFile
                if ($uninstallSuccess) {
                    Write-Host "✓ Uninstall logic generated for EXE installer" -ForegroundColor Green
                } else {
                    Write-Warning "Failed to generate uninstall logic"
                }
            }
            'msi' {
                Write-Host "✓ MSI installer - PSADT's Zero-Config block in the deploy script uninstalls it (4.1.8 default template; 4.2 scaffolded with -ZeroConfig)" -ForegroundColor Green
            }
            { $_ -in @('msix', 'appx') } {
                if (Update-PSADTMsixUninstallLogic -ProjectPath $ProjectPath) {
                    Write-Host "✓ MSIX/APPX package - uninstall via Remove-AppxPackage (identity from AppxManifest)" -ForegroundColor Green
                } else {
                    Write-Warning 'Failed to write MSIX uninstall data'
                }
            }
            default {
                Write-Warning "Unknown installer type '$InstallerType' - no uninstall logic generated."
            }
        }

        # Populate AppProcessesToClose for all installer types
        Write-Verbose "Detecting processes to close..."
        $procSuccess = Update-PSADTProcessesToClose -ProjectPath $ProjectPath -JsonFilePath $jsonFile
        if (-not $procSuccess) {
            Write-Warning "Could not auto-detect processes to close - AppProcessesToClose left empty"
        }
        
        return $true
    }
    catch {
        Write-Warning "Error processing documentation: $($_.Exception.Message)"
        return $false
    }
}