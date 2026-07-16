function Set-PSADTDataDrivenScript {
    <#
    .SYNOPSIS
        Rewrites a scaffolded PSADT v4 Invoke-AppDeployToolkit.ps1 to be data-driven.
    .DESCRIPTION
        Applies a fixed set of patches that contain NO app-specific values, so untrusted
        winget/registry values never enter a code position. The patched script reads all
        app-specific settings from SupportFiles\AppConfig.json at runtime (as data):

          1. A loader (`$appConfig = ... ConvertFrom-Json`) is inserted before the session hashtable.
          2. AppVendor/AppName/AppVersion/AppArch/AppScriptDate/AppProcessesToClose are pointed at
             $appConfig instead of literal values.
          3. A generic install routine is placed at the '## <Perform Installation tasks here>' marker:
             msix/appx via Add-AppxProvisionedPackage (SYSTEM) / Add-AppxPackage (interactive sandbox),
             everything else non-MSI via Start-ADTProcess with the configured SilentArgs.
          4. A generic uninstall routine is placed at the '## <Perform Uninstallation tasks here>'
             marker: msi product codes, exe uninstallers, and msix identity-based removal
             (Remove-AppxProvisionedPackage + Remove-AppxPackage -AllUsers, exact Name match).
          5. An install "tattoo" is placed at the Post-Install/Post-Uninstall markers: it writes
             HKLM:\SOFTWARE\<AppScriptAuthor>\<AppVendor>\<App.DisplayName>\Version at install and
             removes it at uninstall, so the Intune detection rule can confirm install state + correct
             version. Driven from $appConfig (App.DisplayName is populated even for MSI Zero-Config,
             where App.Name is empty), so it works for both EXE and MSI.

        MSI installers keep PSADT Zero-Config (empty App.Name); the tattoo uses App.DisplayName so it
        still records the MSI. The function is idempotent — a script that already contains the loader is
        left unchanged.

        See knowledge-base/designs/data-driven-generation.md.
    .PARAMETER ScriptPath
        Full path to the project's Invoke-AppDeployToolkit.ps1.
    .EXAMPLE
        Set-PSADTDataDrivenScript -ScriptPath 'C:\...\Projects\Git_x64_2.53.0\Invoke-AppDeployToolkit.ps1'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath,

        # Hard apps: leave the Install region for the operator to author instead of
        # inserting the data-driven install routine. Uninstall stays automated.
        [switch]$ManualInstall
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-Warning "PSADT script not found: $ScriptPath"
        return $false
    }

    $content = Get-Content -LiteralPath $ScriptPath -Raw

    # Idempotent: already patched?
    if ($content -match [regex]::Escape('$appConfig =')) { return $true }

    # ---- Fixed replacement blocks (single-quoted here-strings: every $ is literal) ----

    $loader = @'
# Data-driven deployment values (win32-toolkit): read app-specific settings as DATA.
$appConfig = if (Test-Path -LiteralPath "$PSScriptRoot\SupportFiles\AppConfig.json") {
    # -Encoding UTF8: AppConfig.json is BOM-less UTF-8 and this runs under Windows PowerShell 5.1 on the
    # device, whose Get-Content default decodes a BOM-less file as ANSI (non-ASCII vendor/app names would
    # mojibake). 5.1's -Encoding UTF8 reader handles both BOM and BOM-less input.
    Get-Content -LiteralPath "$PSScriptRoot\SupportFiles\AppConfig.json" -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    [pscustomobject]@{ App = [pscustomobject]@{}; Installer = $null; Uninstall = $null; ProcessesToClose = @() }
}

$adtSession = @{
'@

    $installSnippet = @'
## Data-driven install (values from SupportFiles\AppConfig.json).
    if ($appConfig.Installer -and $appConfig.Installer.Type -in @('msix', 'appx')) {
        $installerPath = Join-Path $adtSession.DirFiles $appConfig.Installer.FileName
        if (Test-Path -LiteralPath $installerPath) {
            Write-ADTLogEntry -Message "Installing AppX/MSIX package from: $installerPath" -Severity 1
            # SYSTEM (Intune): provision for all users. Interactive (sandbox tests): register for the
            # current user - a provisioned-only package would be invisible to the logged-on operator.
            if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
                # -Regions 'all' is REQUIRED, not cosmetic. Per the DISM reference: "When a list of
                # regions is not specified, the package will be provisioned only if it is pinned to
                # start layout." Without it, provisioning silently no-ops for most packages: the
                # command succeeds, the tattoo is written, Intune reports Installed, and no user ever
                # gets the app.
                #
                # There is deliberately NO Add-AppxPackage fallback here. It would run AS SYSTEM and
                # register the package into SYSTEM's own profile, where no real user can ever see it -
                # and since it wouldn't throw, the tattoo would still be written and Intune would
                # report Installed for an app nobody has. A provisioning failure must fail the
                # deployment loudly. -ErrorAction Stop is what makes that happen: these Appx cmdlets
                # emit NON-TERMINATING errors by default, so without it a failure would just be logged
                # and the script would sail on to write the tattoo.
                try { Add-AppxProvisionedPackage -Online -PackagePath $installerPath -SkipLicense -Regions 'all' -ErrorAction Stop | Out-Null }
                catch {
                    Write-ADTLogEntry -Message "Provisioning failed: $($_.Exception.Message)" -Severity 3
                    throw
                }
            } else {
                Add-AppxPackage -Path $installerPath -ErrorAction Stop
            }
        } else {
            Write-ADTLogEntry -Message "Installer file not found: $installerPath" -Severity 3
            throw "Installer file not found: $installerPath"
        }
    }
    elseif ($appConfig.Installer -and $appConfig.Installer.Type -ne 'msi') {
        $installerPath = Join-Path $adtSession.DirFiles $appConfig.Installer.FileName
        if (Test-Path -LiteralPath $installerPath) {
            Write-ADTLogEntry -Message "Installing $($appConfig.App.Name) from: $installerPath" -Severity 1
            $spInstall = @{ FilePath = $installerPath; PassThru = $true }
            if ($appConfig.Installer.SilentArgs) { $spInstall['ArgumentList'] = $appConfig.Installer.SilentArgs }
            Start-ADTProcess @spInstall
        } else {
            Write-ADTLogEntry -Message "Installer file not found: $installerPath" -Severity 3
            throw "Installer file not found: $installerPath"
        }
    }
'@

    $uninstallSnippet = @'
## Data-driven uninstall (values from SupportFiles\AppConfig.json).
    if ($appConfig.Uninstall) {
        $uninstallSuccess = $false
        foreach ($pc in @($appConfig.Uninstall.ProductCodes)) {
            if (-not $pc -or $uninstallSuccess) { continue }
            $r = Start-ADTMsiProcess -Action Uninstall -ProductCode $pc -PassThru
            if ($r -and $r.ExitCode -in @(0, 3010)) { $uninstallSuccess = $true }
        }
        foreach ($u in @($appConfig.Uninstall.Uninstallers)) {
            if (-not $u -or $uninstallSuccess) { continue }
            $r = $null
            switch ($u.Type) {
                'msi' { $r = Start-ADTMsiProcess -Action Uninstall -ProductCode $u.ProductCode -PassThru }
                'exe' {
                    $spUninstall = @{ FilePath = $u.Path; PassThru = $true }
                    if ($u.Args) { $spUninstall['ArgumentList'] = $u.Args }
                    $r = Start-ADTProcess @spUninstall
                }
                'msix' {
                    # Identity-driven removal (exact Name match; Remove-AppxPackage has no exit code,
                    # so success = the package is gone for ALL users afterwards; $r stays $null).
                    if ($u.PackageName) {
                        foreach ($prov in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $u.PackageName })) {
                            try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName | Out-Null }
                            catch { Write-ADTLogEntry -Message "Deprovisioning failed: $($_.Exception.Message)" -Severity 2 }
                        }
                        foreach ($pkg in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $u.PackageName })) {
                            try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop }
                            catch { Write-ADTLogEntry -Message "Remove-AppxPackage failed: $($_.Exception.Message)" -Severity 2 }
                        }
                        if (@(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $u.PackageName }).Count -eq 0) {
                            $uninstallSuccess = $true
                        }
                    }
                }
            }
            if ($r -and $r.ExitCode -in @(0, 3010)) { $uninstallSuccess = $true }
        }
        # Fail loudly when nothing actually uninstalled. $uninstallSuccess used to be computed and then
        # never read: every uninstaller could fail and the script still returned 0, so Intune recorded a
        # successful uninstall and the post-uninstall tattoo removal then made the app UNDETECTED - the
        # app stays on the device and Intune believes it is gone. Only raise this when there was
        # something to do (an empty Uninstall section is a separate, configure-time problem).
        if (-not $uninstallSuccess -and (@($appConfig.Uninstall.ProductCodes).Count + @($appConfig.Uninstall.Uninstallers).Count) -gt 0) {
            throw 'Uninstall failed: no uninstaller reported success (see the entries above for the cause).'
        }
        foreach ($folder in @($appConfig.Uninstall.CleanupPaths)) {
            if (-not $folder) { continue }
            if (Test-Path -LiteralPath $folder) {
                try { Remove-ADTFolder -Path $folder }
                catch { Write-ADTLogEntry -Message "Cleanup failed for ${folder}: $($_.Exception.Message)" -Severity 2 }
            }
        }
    }
'@

    # Install "tattoo": write HKLM:\SOFTWARE\<Author>\<Vendor>\<Name>\Version at install and remove it at
    # uninstall. The Intune detection rule keys off this value (installed AND correct version). Values come
    # from $appConfig (App.DisplayName is always populated — including MSI Zero-Config, where App.Name is
    # empty), so the key is byte-identical to what Get-Win32DetectionRules computes and every empty-segment
    # case is guarded out. Works for both EXE and MSI (no UseDefaultMsi exclusion).
    $postInstallTattoo = @'
## <Perform Post-Installation tasks here>

    ## win32-toolkit install tattoo - records install state + version for the Intune detection rule.
    $w32tName = if ($appConfig.App.DisplayName) { $appConfig.App.DisplayName } else { $appConfig.App.Name }
    if ($w32tName -and $appConfig.App.Vendor -and $appConfig.App.Version -and $appConfig.App.ScriptAuthor) {
        Set-ADTRegistryKey -Key "HKLM:\SOFTWARE\$($appConfig.App.ScriptAuthor)\$($appConfig.App.Vendor)\$w32tName" -Name 'Version' -Value "$($appConfig.App.Version)" -Type 'String'
    }
'@

    $postUninstallTattoo = @'
## <Perform Post-Uninstallation tasks here>

    ## win32-toolkit install tattoo - remove the key written during install.
    $w32tName = if ($appConfig.App.DisplayName) { $appConfig.App.DisplayName } else { $appConfig.App.Name }
    if ($w32tName -and $appConfig.App.Vendor -and $appConfig.App.ScriptAuthor) {
        Remove-ADTRegistryKey -Key "HKLM:\SOFTWARE\$($appConfig.App.ScriptAuthor)\$($appConfig.App.Vendor)\$w32tName" -Recurse
    }
'@

    # ---- Verify every anchor BEFORE patching (PSADT template drift protection) ----
    # A missed String.Replace is a silent no-op: the project would LOOK configured but isn't.
    # CRITICAL anchors abort without writing (a half-patched script whose snippets reference an
    # undefined $appConfig, or that installs nothing, must never ship). Non-critical misses still
    # write but warn + return $false so callers surface "did not complete cleanly".
    # NOTE: verification only runs on first patch — the idempotency early-return above means a
    # previously patched script is not re-validated on re-runs.
    $anchors = @(
        @{ Anchor = '$adtSession = @{';                          Label = 'session loader';           Critical = $true }
        @{ Anchor = '## <Perform Installation tasks here>';      Label = 'Install marker';           Critical = $true }
        @{ Anchor = "AppVendor = ''";                            Label = 'AppVendor';                Critical = $false }
        @{ Anchor = "AppName = ''";                              Label = 'AppName';                  Critical = $false }
        @{ Anchor = "AppVersion = ''";                           Label = 'AppVersion';               Critical = $false }
        @{ Anchor = "AppArch = ''";                              Label = 'AppArch';                  Critical = $false }
        @{ Anchor = 'AppProcessesToClose = @()';                 Label = 'AppProcessesToClose';      Critical = $false }
        @{ Anchor = '## <Perform Uninstallation tasks here>';    Label = 'Uninstall marker';         Critical = $false }
        @{ Anchor = '## <Perform Post-Installation tasks here>'; Label = 'Post-Install marker (tattoo)';   Critical = $false }
        @{ Anchor = '## <Perform Post-Uninstallation tasks here>'; Label = 'Post-Uninstall marker (tattoo)'; Critical = $false }
    )
    $missed = @($anchors | Where-Object { -not $content.Contains($_.Anchor) })
    $dateMatch = [regex]::Match($content, "AppScriptDate = '\d{4}-\d{2}-\d{2}'")
    if (-not $dateMatch.Success) {
        $missed += @{ Anchor = "AppScriptDate = '<date>'"; Label = 'AppScriptDate'; Critical = $false }
    }
    foreach ($m in $missed) {
        Write-Warning "Data-driven patch anchor not found: $($m.Label) — the installed PSADT template may have drifted from what this module expects."
    }
    if (@($missed | Where-Object { $_.Critical }).Count -gt 0) {
        Write-Warning "Critical anchor(s) missing — leaving $ScriptPath UNCHANGED. Update the module for this PSADT version, or pin the PSADT template version."
        return $false
    }

    # ---- Apply patches with ordinal String.Replace (no regex/$-token pitfalls) ----
    $content = $content.Replace('$adtSession = @{', $loader)
    $content = $content.Replace("AppVendor = ''",  'AppVendor = $appConfig.App.Vendor')
    $content = $content.Replace("AppName = ''",    'AppName = $appConfig.App.Name')
    $content = $content.Replace("AppVersion = ''", 'AppVersion = $appConfig.App.Version')
    $content = $content.Replace("AppArch = ''",    'AppArch = $appConfig.App.Arch')
    $content = $content.Replace('AppProcessesToClose = @()', 'AppProcessesToClose = @($appConfig.ProcessesToClose | Where-Object { $_ })')

    # AppScriptDate default varies per scaffold — extract the literal, then ordinal-replace it.
    if ($dateMatch.Success) {
        $content = $content.Replace($dateMatch.Value, 'AppScriptDate = $appConfig.App.ScriptDate')
    }

    if ($ManualInstall) {
        # Hard app — leave the Install region markers for the operator to author.
        $content = $content.Replace(
            '## <Perform Installation tasks here>',
            "## <Perform Installation tasks here>`r`n    ## MANUAL APP: write your Pre-Install / Install / Post-Install logic in these regions.`r`n    ## The uninstall is auto-generated from the sandbox capture — no action needed there.")
    }
    else {
        $content = $content.Replace('## <Perform Installation tasks here>', $installSnippet)
    }
    $content = $content.Replace('## <Perform Uninstallation tasks here>', $uninstallSnippet)

    # Install tattoo (both install modes, incl. manual/hard apps) — value-free, safe to splice.
    $content = $content.Replace('## <Perform Post-Installation tasks here>',   $postInstallTattoo)
    $content = $content.Replace('## <Perform Post-Uninstallation tasks here>', $postUninstallTattoo)

    # UTF-8 WITH BOM: this script runs under Windows PowerShell 5.1 on the device (Intune's
    # powershell.exe), which decodes a BOM-less file as ANSI — non-ASCII branding/vendor/app names would
    # mojibake silently. PS7's Set-Content -Encoding UTF8 writes NO BOM, so write the bytes ourselves.
    [System.IO.File]::WriteAllText($ScriptPath, $content, (New-Object System.Text.UTF8Encoding($true)))

    # Sanity: confirm the result still parses.
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs) | Out-Null
    if ($errs -and $errs.Count) {
        Write-Warning "Data-driven patch produced parse errors in $ScriptPath : $($errs[0].Message)"
        return $false
    }
    # Non-critical anchor misses: the file was written, but signal "not cleanly configured".
    return ($missed.Count -eq 0)
}
