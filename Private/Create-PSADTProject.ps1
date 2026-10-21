function Create-PSADTProject {
    <#
    .SYNOPSIS
        Scaffolds a PSADT v4 project with a SUPPORTED PSAppDeployToolkit version.
    .DESCRIPTION
        Selects the PSAppDeployToolkit copy to use (Select-Win32ToolkitPsadtModule: newest installed
        in-range version, or the PreferredPsadtVersion pin), installs the newest STABLE in-range version
        from PSGallery when none is usable, optionally offers an in-range update, imports the selected
        copy by path (guarded: an already-loaded copy is reused, never re-imported), runs New-ADTTemplate
        and verifies the result (impact analysis D1/D3/L1/L4; SCF-01, SCF-03, SCF-10, PKG-08).

        PSADT 4.2 is always scaffolded with New-ADTTemplate -ZeroConfig (L1/D7: the Zero-Config MSI
        block is inert unless AppName is empty and an MSI is in Files\); 4.1.x never gets -ZeroConfig
        (the parameter does not exist there and its default template already has Zero-Config).
    .PARAMETER ProjectName
        Project folder name (<AppName>_<arch>_<version>).
    .PARAMETER ProjectPath
        Parent folder the project is created in.
    .PARAMETER Force
        Non-interactive: overwrite an existing project folder without asking and skip the update
        offer (the gallery is then only queried when no supported version is installed).
    .OUTPUTS
        [bool] $true when the project was created and verified; $false otherwise (callers turn $false
        into W32T.ProjectCreationFailed).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ProjectName,
        [string]$ProjectPath,
        [switch]$Force = $false
    )

    $ProjectFullPath = Join-Path $ProjectPath $ProjectName
    $cleanupOnFailure = $false   # set only once the scaffold is about to create the project folder

    try {
        Write-Host "`nCreating PSADT V4 project: $ProjectName" -ForegroundColor Green

        # -- Select a supported PSAppDeployToolkit (never the newest blindly: SCF-01) ----------------
        Write-Verbose 'Selecting a supported PSAppDeployToolkit module...'
        $sel = Select-Win32ToolkitPsadtModule
        if ($sel.Status -eq 'PreferredNotFound') { Write-Warning $sel.Reason; return $false }   # never install for a pin

        if ($sel.Status -in 'NoneInstalled', 'NoneInRange') {
            Write-Host $sel.Reason -ForegroundColor Yellow
            # Newest STABLE in-range version (no -AllowPrerelease, so the [version] cast is safe: SCF-06).
            $target = Find-Module -Name PSAppDeployToolkit -Repository PSGallery -AllVersions -ErrorAction Stop |
                Where-Object { Test-Win32ToolkitPsadtVersionSupported $_.Version } |
                Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
            if (-not $target) { Write-Warning "No supported PSAppDeployToolkit ($($script:PsadtSupportedRange.Display)) found on PSGallery."; return $false }
            Write-Host "Installing PSAppDeployToolkit $($target.Version) for the current user..." -ForegroundColor Cyan
            if ($PSCmdlet.ShouldProcess('PSAppDeployToolkit', "Install-Module -RequiredVersion $($target.Version)")) {
                Install-Module -Name PSAppDeployToolkit -RequiredVersion $target.Version -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            }
            $sel = Select-Win32ToolkitPsadtModule
            if ($sel.Status -ne 'Selected') { Write-Warning $sel.Reason; return $false }
        }
        elseif (-not $Force -and -not $sel.IsPinned) {
            # -- Update offer: stable, in-range only; never for a pin and never under -Force ----------
            # A copy already loaded in this session must not be overwritten underneath itself: the
            # gallery installs a prerelease into its BASE-version folder (rc2 lives in ...\4.2.0\), so
            # installing 4.2.0 GA over a loaded rc2 would replace DLLs in use (critique C2-m7).
            if (@(Get-Module -Name PSAppDeployToolkit -All).Count -gt 0) {
                Write-Host 'PSAppDeployToolkit is loaded in this session - start a new PowerShell session to check for updates' -ForegroundColor DarkGray
            }
            else {
                Write-Verbose "Installed version: $($sel.VersionText) - checking PSGallery for an in-range update..."
                $offer = $null
                try {
                    $offer = Find-Module -Name PSAppDeployToolkit -Repository PSGallery -AllVersions -ErrorAction Stop |
                        Where-Object { Test-Win32ToolkitPsadtVersionSupported $_.Version } |
                        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
                }
                catch {
                    Write-Warning "Could not reach PSGallery to check for updates: $($_.Exception.Message)"
                }

                $offerVersion = if ($offer) { [version]$offer.Version } else { $null }
                if ($offerVersion -and ($offerVersion -gt $sel.Version -or ($offerVersion -eq $sel.Version -and $sel.IsPrerelease))) {
                    Write-Host "Update available: PSAppDeployToolkit $offerVersion (installed: $($sel.VersionText))" -ForegroundColor Cyan
                    $doUpdate = Read-Host "Install PSAppDeployToolkit $offerVersion now? (y/n)"
                    $offerInstalled = $false
                    if ($doUpdate -in @('y', 'Y')) {
                        # Side by side with a pinned version, never an in-place upgrade (which could
                        # leave the supported range). The update is optional: a failed install (e.g. the
                        # target folder's DLLs are in use by another session) keeps the installed,
                        # in-range selection instead of failing the whole project creation.
                        try {
                            if ($PSCmdlet.ShouldProcess('PSAppDeployToolkit', "Install-Module -RequiredVersion $offerVersion")) {
                                Install-Module -Name PSAppDeployToolkit -RequiredVersion $offerVersion -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                                $offerInstalled = $true   # only when the install actually ran
                            }
                            else {
                                Write-Verbose "Update to $offerVersion not installed (declined or -WhatIf) - continuing with installed version $($sel.VersionText)"
                            }
                        }
                        catch {
                            Write-Warning "Could not install PSAppDeployToolkit $offerVersion ($($_.Exception.Message)); continuing with the installed $($sel.VersionText)."
                        }
                    }
                    else {
                        Write-Verbose "Skipping update - continuing with installed version $($sel.VersionText)"
                    }

                    if ($offerInstalled) {
                        Write-Host "Installed PSAppDeployToolkit $offerVersion" -ForegroundColor Green

                        # Second line of defence: an assembly ALREADY LOADED into this process cannot be
                        # unloaded, so the new version would not take effect until a fresh session. We
                        # deliberately do NOT relaunch on the user's behalf: this is a private helper, it
                        # does not know which public command the user invoked or with which arguments.
                        $loadedNow = @(Get-Module -Name PSAppDeployToolkit -All | Where-Object { $_.ModuleBase }) | Select-Object -First 1
                        if ($loadedNow -and [version]$loadedNow.Version -lt $offerVersion) {
                            Write-Warning "PSAppDeployToolkit was updated to $offerVersion, but version $($loadedNow.Version) is already loaded in this PowerShell session and cannot be reloaded in place."
                            Write-Warning 'No project was created. Please start a NEW PowerShell session and re-run your command (for example: Invoke-Win32Toolkit).'
                            return $false
                        }

                        # Nothing was loaded - re-select so the version we report and import below is
                        # the one just installed, not the stale one.
                        $sel = Select-Win32ToolkitPsadtModule
                        if ($sel.Status -ne 'Selected') { Write-Warning $sel.Reason; return $false }
                    }
                }
                else {
                    Write-Verbose "PSAppDeployToolkit $($sel.VersionText) is the newest supported version"
                }
            }
        }

        # -- Guarded import (SCF-03 / upstream #2371; host-side SCF-07) ------------------------------
        # PSADT 4.2 cannot be re-imported with -Force from a versioned folder, and refuses a second copy
        # from another folder even at the same version. So an already-loaded copy of the SELECTED
        # version is reused (whatever folder it came from), a different loaded version stops the run,
        # and a fresh import goes by PATH (the selection), never by name, never with -Force.
        # -All also sees a copy imported into THIS module's scope (a plain global Get-Module does not - probed).
        $loaded = @(Get-Module -Name PSAppDeployToolkit -All | Where-Object { $_.ModuleBase }) | Select-Object -First 1
        if ($loaded) {
            $loadedPre = ''   # nested PSModuleInfo objects may lack PrivateData: read the label from the loaded copy's psd1
            try {
                $loadedPre = [string](Import-PowerShellDataFile -LiteralPath (Join-Path $loaded.ModuleBase 'PSAppDeployToolkit.psd1')).PrivateData.PSData.Prerelease
            }
            catch {
                Write-Verbose "Could not read the loaded PSAppDeployToolkit manifest: $($_.Exception.Message)"
            }
            if ($loaded.Version -ne $sel.Version -or $loadedPre -ne $sel.Prerelease) {
                $loadedText = if ($loadedPre) { "$($loaded.Version)-$loadedPre" } else { "$($loaded.Version)" }
                Write-Warning "PSAppDeployToolkit $loadedText is already loaded in this PowerShell session; this run needs $($sel.VersionText). Start a new PowerShell session (or set PreferredPsadtVersion / `$env:W32T_PSADT_VERSION to $loadedText)."
                Write-Warning 'No project was created. Re-run your command in the new session.'
                return $false
            }
            Write-Verbose "Reusing the PSAppDeployToolkit $($sel.VersionText) already loaded in this session ($($loaded.ModuleBase))."
        }
        else {
            Import-Module -Name $sel.Module.Path -ErrorAction Stop   # by PATH, NO -Force
        }

        # Only now - the selected copy is reused or imported - announce which one this run uses: a refused run
        # ('another version is already loaded') must not first say 'Using ... a PRERELEASE' (test campaign
        # 2026-10-21, S7-F3).
        if ($sel.IsPrerelease) {
            Write-Warning "Using PSAppDeployToolkit $($sel.VersionText) - a PRERELEASE: fine for testing, not for production packages."
        }
        if (-not $sel.NewestInstalledInRange) {
            Write-Host $sel.Reason -ForegroundColor Yellow
        }
        Write-Verbose "Using PSAppDeployToolkit version: $($sel.VersionText) ($($sel.Module.Path))"

        # -- Scaffold parameters + capability check: everything that can refuse the run happens BEFORE
        #    an existing project folder is removed below (an early 4.2.0 prerelease is "in range" but may
        #    lack -ZeroConfig; the user agreed to overwrite their project, not to lose it to this check).
        $ntt = @{ Destination = $ProjectPath; Name = $ProjectName; PassThru = $true }
        if ($sel.Version -ge [version]'4.2.0') {
            if (-not (Get-Command New-ADTTemplate).Parameters.ContainsKey('ZeroConfig')) { throw 'PSAppDeployToolkit 4.2 without New-ADTTemplate -ZeroConfig is not supported.' }
            $ntt['ZeroConfig'] = $true          # L1/D7: inert unless AppName is empty and an MSI is in Files\
        }

        # Create project directory structure if it doesn't exist
        if (!(Test-Path $ProjectPath)) {
            New-Item -Path $ProjectPath -ItemType Directory -Force | Out-Null
        }

        if (Test-Path $ProjectFullPath) {
            if ($Force) {
                # A -Force rebuild is intended: an informational line, not a warning (automation that counts
                # -WarningVariable entries would see one on every rebuild; re-verification 2026-10-21 A1 sb#3).
                Write-Host "Overwriting existing project directory (-Force mode): $ProjectFullPath" -ForegroundColor Yellow
            } else {
                Write-Warning "Project directory already exists: $ProjectFullPath"
                $overwrite = Read-Host "Do you want to overwrite it? (y/n)"
                if ($overwrite -notin @('y', 'Y')) {
                    return $false
                }
            }
            if ($PSCmdlet.ShouldProcess($ProjectFullPath, 'Remove existing project directory')) {
                Remove-Item -Path $ProjectFullPath -Recurse -Force
            }
        }

        # -- Scaffold ---------------------------------------------------------------------------------
        Write-Verbose 'Creating PSADT V4 template...'
        # From here on a failure leaves a half-written folder (IO error, MAX_PATH under a deep BasePath)
        # that Get-PSADTProjects would list: the catch removes it, like the verification below (SCF-10).
        # Only a folder this call creates is cleaned up: one still present here (e.g. its removal was
        # declined under -Confirm) belongs to the user.
        $cleanupOnFailure = -not (Test-Path -LiteralPath $ProjectFullPath)
        $null = New-ADTTemplate @ntt            # never -LauncherName (PKG-08), never -Force (deletes the destination)

        # -- Post-scaffold verification (SCF-10): never report success for a project we cannot use ----
        $problems = [System.Collections.Generic.List[string]]::new()
        foreach ($required in 'Invoke-AppDeployToolkit.ps1', 'Invoke-AppDeployToolkit.exe') {
            if (-not (Test-Path -LiteralPath (Join-Path $ProjectFullPath $required) -PathType Leaf)) { $problems.Add("$required is missing") }
        }
        $bundledManifest = Join-Path $ProjectFullPath 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'
        if (Test-Path -LiteralPath $bundledManifest -PathType Leaf) {
            try {
                $bundled    = Import-PowerShellDataFile -LiteralPath $bundledManifest -ErrorAction Stop
                $bundledVer = [version]$bundled.ModuleVersion
                $bundledPre = ''
                if ($bundled.PrivateData -and $bundled.PrivateData.PSData) { $bundledPre = [string]$bundled.PrivateData.PSData.Prerelease }
                $bundledText = if ($bundledPre) { "$bundledVer-$bundledPre" } else { "$bundledVer" }
                if ($bundledVer -ne $sel.Version -or $bundledPre -ne $sel.Prerelease) {
                    $problems.Add("the bundled PSAppDeployToolkit is $bundledText, expected $($sel.VersionText)")
                }
                elseif (-not (Test-Win32ToolkitPsadtVersionSupported $bundledVer)) {
                    $problems.Add("the bundled PSAppDeployToolkit $bundledText is not supported ($($script:PsadtSupportedRange.Display))")
                }
            }
            catch {
                $problems.Add("the bundled PSAppDeployToolkit manifest could not be read: $($_.Exception.Message)")
            }
        }
        else {
            $problems.Add('PSAppDeployToolkit\PSAppDeployToolkit.psd1 is missing')
        }

        if ($problems.Count -gt 0) {
            if (Test-Path -LiteralPath $ProjectFullPath) {
                Remove-Item -LiteralPath $ProjectFullPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Warning "The scaffolded PSADT project failed verification ($($problems -join '; ')); the incomplete project folder was removed: $ProjectFullPath"
            return $false
        }

        # PSADT 4.2 creates Files\ and SupportFiles\ only when it has content for them (V2).
        foreach ($sub in 'Files', 'SupportFiles') {
            $subPath = Join-Path $ProjectFullPath $sub
            if (-not (Test-Path -LiteralPath $subPath)) { New-Item -Path $subPath -ItemType Directory -Force | Out-Null }
        }

        Write-Host "PSADT V4 project created successfully (PSAppDeployToolkit $($sel.VersionText))!" -ForegroundColor Green
        Write-Host "Project location: $ProjectFullPath" -ForegroundColor Cyan

        return $true
    }
    catch {
        $failure = $_.Exception.Message
        $cleanup = ''
        if ($cleanupOnFailure -and (Test-Path -LiteralPath $ProjectFullPath)) {
            Remove-Item -LiteralPath $ProjectFullPath -Recurse -Force -ErrorAction SilentlyContinue
            $cleanup = if (Test-Path -LiteralPath $ProjectFullPath) { "; the incomplete project folder could not be fully removed: $ProjectFullPath" } else { "; the incomplete project folder was removed: $ProjectFullPath" }
            $failure = $failure.TrimEnd(' ', '.')
        }
        Write-Warning "Failed to create PSADT project: $failure$cleanup"
        return $false
    }
}
