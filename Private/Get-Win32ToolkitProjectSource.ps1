function Get-Win32ToolkitProjectSource {
    <#
    .SYNOPSIS
        Returns a project's installer source facts (AppConfig.Source), or rebuilds them in memory.
    .DESCRIPTION
        AppConfig.Source records which winget installer a project packaged and why (installer-identity PR 1,
        spec 2.6): WingetId, Version, InstallerType, Family, Scope, Architecture, Locale, PinnedBy
        (parameter | continuity | winget-default; 'operator' is reserved), RequestedInstallerType,
        WingetClient, ProductCode/UpgradeCode (MSI only, from the MSI Property table, strict GUID or '')
        and UpgradeBehavior. No tenant id, app id, operator name or free text.

        Without -Rebuild: returns the persisted AppConfig.Source when it has SchemaVersion '1.0'
        (Rebuilt = $false). Otherwise the facts are rebuilt in memory from Files\ (Rebuilt = $true): a
        winget project created before Source existed gets PinnedBy 'winget-default' (winget did choose); a
        manual project (no winget manifest) gets WingetId '', InstallerType = AppConfig.Installer.Type and
        PinnedBy 'parameter'.

        With -Rebuild: always builds from Files\ (the winget manifest via Get-YAMLInstallerInfo, the
        installer file via Get-InstallerFileInfo, the MSI properties) and the given parameters, and never
        reads AppConfig.Source; this is what Configure-PSADTForInstaller persists, so that object carries
        exactly the persisted fields (no 'Rebuilt' member - it is in-memory only).

        Never throws: an unreadable manifest, installer or AppConfig leaves the affected fields '' (Write-Verbose).
        Every string passes ConvertTo-Win32ToolkitSafeText (manifests are untrusted data).
    .PARAMETER ProjectPath
        The PSADT project folder (contains Files\ and SupportFiles\AppConfig.json).
    .PARAMETER Rebuild
        Build from Files\ and the parameters; ignore a persisted AppConfig.Source.
    .PARAMETER Architecture
        Fallback architecture when the manifest has none (then AppConfig.App.Arch).
    .PARAMETER PinnedBy
        Why this installer type was chosen. Default when rebuilding: 'winget-default' for a winget project,
        'parameter' for a manual one.
    .PARAMETER RequestedInstallerType
        The pinned type ('' when winget chose).
    .PARAMETER WingetClient
        The winget client version ('' when unknown).
    .OUTPUTS
        [pscustomobject] SchemaVersion, WingetId, Version, InstallerType, Family, Scope, Architecture, Locale,
        PinnedBy, RequestedInstallerType, WingetClient, ProductCode, UpgradeCode, UpgradeBehavior
        (+ Rebuilt [bool] without -Rebuild).
    .EXAMPLE
        $src = Get-Win32ToolkitProjectSource -ProjectPath $projectPath
        if ($src.Family -eq 'msi') { ... }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [switch]$Rebuild,

        [AllowEmptyString()]
        [string]$Architecture = '',

        [ValidateSet('parameter', 'continuity', 'winget-default', 'operator')]
        [string]$PinnedBy,

        [AllowEmptyString()]
        [string]$RequestedInstallerType = '',

        [AllowEmptyString()]
        [string]$WingetClient = ''
    )

    $safe = { param($Value) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength 128 }
    $guid = '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$'

    # AppConfig (may be absent or unreadable; a manual project's installer type and the arch fallback live here).
    $cfg = $null
    try {
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Get-Win32ToolkitProjectSource: AppConfig.json of '$ProjectPath' is unreadable: $($_.Exception.Message)"
    }

    # Persisted Source (only without -Rebuild).
    if (-not $Rebuild -and $cfg -and $cfg.PSObject.Properties['Source'] -and $cfg.Source -and
        $cfg.Source.PSObject.Properties['SchemaVersion'] -and [string]$cfg.Source.SchemaVersion -eq '1.0') {
        $p = $cfg.Source
        $read = { param([string]$Name) if ($p.PSObject.Properties[$Name]) { & $safe $p.$Name } else { '' } }
        return [pscustomobject]@{
            SchemaVersion          = '1.0'
            WingetId               = & $read 'WingetId'
            Version                = & $read 'Version'
            InstallerType          = (& $read 'InstallerType').ToLowerInvariant()
            Family                 = & $read 'Family'
            Scope                  = (& $read 'Scope').ToLowerInvariant()
            Architecture           = & $read 'Architecture'
            Locale                 = & $read 'Locale'
            PinnedBy               = & $read 'PinnedBy'
            RequestedInstallerType = (& $read 'RequestedInstallerType').ToLowerInvariant()
            WingetClient           = & $read 'WingetClient'
            ProductCode            = & $read 'ProductCode'
            UpgradeCode            = & $read 'UpgradeCode'
            UpgradeBehavior        = & $read 'UpgradeBehavior'
            Rebuilt                = $false
        }
    }

    # ---- Build from Files\ ----
    $filesPath = Join-Path $ProjectPath 'Files'
    $yaml = $null
    try {
        $yaml = Get-YAMLInstallerInfo -FilesPath $filesPath -WarningAction SilentlyContinue
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Get-Win32ToolkitProjectSource: the winget manifest in '$filesPath' is unreadable: $($_.Exception.Message)"
    }
    $fileInfo = $null
    if (Test-Path -LiteralPath $filesPath) {
        try {
            $fileInfo = Get-InstallerFileInfo -FilesPath $filesPath -WarningAction SilentlyContinue
        } catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Get-Win32ToolkitProjectSource: the installer in '$filesPath' could not be identified: $($_.Exception.Message)"
        }
    }

    $isWinget = [bool]($yaml -and ($yaml.PackageIdentifier -or $yaml.InstallerType))
    $cfgType  = if ($cfg -and $cfg.PSObject.Properties['Installer'] -and $cfg.Installer -and $cfg.Installer.PSObject.Properties['Type']) { [string]$cfg.Installer.Type } else { '' }
    $cfgArch  = if ($cfg -and $cfg.PSObject.Properties['App'] -and $cfg.App -and $cfg.App.PSObject.Properties['Arch']) { [string]$cfg.App.Arch } else { '' }
    $fileType = if ($fileInfo -and $fileInfo.Type) { [string]$fileInfo.Type } else { '' }

    $installerType = if ($isWinget -and $yaml.InstallerType) { [string]$yaml.InstallerType }
                     elseif ($cfgType) { $cfgType }
                     else { $fileType }
    $installerType = (& $safe $installerType).ToLowerInvariant()

    $family = ''
    if ($installerType) {
        try {
            $family = [string](Get-Win32ToolkitInstallerFamily -Type $installerType).Family
        } catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Get-Win32ToolkitProjectSource: no family for '$installerType': $($_.Exception.Message)"
        }
    }

    # MSI only: the codes come from the MSI's own Property table, never from the YAML (V11).
    $productCode = ''; $upgradeCode = ''
    if ($fileType -eq 'msi' -and $fileInfo.FullPath) {
        try {
            $pc = [string](Get-Win32ToolkitMsiProperty -Path $fileInfo.FullPath -Property ProductCode)
            $uc = [string](Get-Win32ToolkitMsiProperty -Path $fileInfo.FullPath -Property UpgradeCode)
            if ($pc -match $guid) { $productCode = $pc }
            if ($uc -match $guid) { $upgradeCode = $uc }
        } catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Get-Win32ToolkitProjectSource: MSI properties unreadable: $($_.Exception.Message)"
        }
    }

    $arch = if ($isWinget -and $yaml.Architecture) { [string]$yaml.Architecture }
            elseif ($Architecture) { $Architecture }
            else { $cfgArch }

    $pinned = if ($PinnedBy) { $PinnedBy } elseif ($isWinget) { 'winget-default' } else { 'parameter' }
    $requested = if ($pinned -eq 'winget-default') { '' } else { [string]$RequestedInstallerType }

    $source = [pscustomobject]@{
        SchemaVersion          = '1.0'
        WingetId               = if ($isWinget) { & $safe $yaml.PackageIdentifier } else { '' }
        Version                = if ($isWinget) { & $safe $yaml.PackageVersion } else { '' }
        InstallerType          = $installerType
        Family                 = & $safe $family
        Scope                  = if ($isWinget) { (& $safe $yaml.Scope).ToLowerInvariant() } else { '' }
        Architecture           = (& $safe $arch).ToLowerInvariant()
        Locale                 = if ($isWinget) { & $safe $yaml.InstallerLocale } else { '' }
        PinnedBy               = $pinned
        RequestedInstallerType = (& $safe $requested).ToLowerInvariant()
        WingetClient           = & $safe (([string]$WingetClient).Trim() -replace '^[vV]', '')
        ProductCode            = $productCode
        UpgradeCode            = $upgradeCode
        UpgradeBehavior        = if ($isWinget) { & $safe $yaml.UpgradeBehavior } else { '' }
    }
    if (-not $Rebuild) {
        $source | Add-Member -NotePropertyName Rebuilt -NotePropertyValue $true
    }
    return $source
}
