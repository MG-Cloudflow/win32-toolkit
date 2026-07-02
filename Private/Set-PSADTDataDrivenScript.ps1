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
          3. A generic install routine is placed at the '## <Perform Installation tasks here>' marker.
          4. A generic uninstall routine is placed at the '## <Perform Uninstallation tasks here>' marker.
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
    Get-Content -LiteralPath "$PSScriptRoot\SupportFiles\AppConfig.json" -Raw | ConvertFrom-Json
} else {
    [pscustomobject]@{ App = [pscustomobject]@{}; Installer = $null; Uninstall = $null; ProcessesToClose = @() }
}

$adtSession = @{
'@

    $installSnippet = @'
## Data-driven install (values from SupportFiles\AppConfig.json).
    if ($appConfig.Installer -and $appConfig.Installer.Type -ne 'msi') {
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
            }
            if ($r -and $r.ExitCode -in @(0, 3010)) { $uninstallSuccess = $true }
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

    # ---- Apply patches with ordinal String.Replace (no regex/$-token pitfalls) ----
    $content = $content.Replace('$adtSession = @{', $loader)
    $content = $content.Replace("AppVendor = ''",  'AppVendor = $appConfig.App.Vendor')
    $content = $content.Replace("AppName = ''",    'AppName = $appConfig.App.Name')
    $content = $content.Replace("AppVersion = ''", 'AppVersion = $appConfig.App.Version')
    $content = $content.Replace("AppArch = ''",    'AppArch = $appConfig.App.Arch')
    $content = $content.Replace('AppProcessesToClose = @()', 'AppProcessesToClose = @($appConfig.ProcessesToClose | Where-Object { $_ })')

    # AppScriptDate default varies per scaffold — extract the literal, then ordinal-replace it.
    $dateMatch = [regex]::Match($content, "AppScriptDate = '\d{4}-\d{2}-\d{2}'")
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

    # Match the module's existing encoding for this file (UTF-8 w/ BOM — safe for PS 5.1 on-device).
    Set-Content -LiteralPath $ScriptPath -Value $content -Encoding UTF8

    # Sanity: confirm the result still parses.
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs) | Out-Null
    if ($errs -and $errs.Count) {
        Write-Warning "Data-driven patch produced parse errors in $ScriptPath : $($errs[0].Message)"
        return $false
    }
    return $true
}
