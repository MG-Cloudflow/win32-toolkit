function Download-OldVersionInstaller {
<#
.SYNOPSIS
    Downloads a specific older version of a Winget package into
    <ProjectPath>\Sandbox\OldVersion\ and returns installer details.
.OUTPUTS
    PSCustomObject with:
      InstallerPath — full path to the downloaded installer file
      InstallerName — file name only (used to build the sandbox path)
      InstallerType — extension without dot (exe, msi, msix, appx)
      SilentArgs    — silent install switches for this installer
#>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$ProjectPath,

        [Parameter(Mandatory = $false)]
        [string]$Architecture,

        # Variant pins from the packaged project's YAML (scope/installer-type/locale) so the baseline
        # matches the packaged variant (e.g. machine-scope MSI, not the user-scope EXE). If the pinned
        # download fails (the old version may not publish that variant), we retry unpinned with a warning.
        [Parameter(Mandatory = $false)]
        [string]$Scope,

        [Parameter(Mandatory = $false)]
        [string]$InstallerType,

        [Parameter(Mandatory = $false)]
        [string]$Locale
    )

    # Fail fast (before any download) on a pinned type that has no silent installer — otherwise the
    # sandbox would launch the app itself and hang until the 30-minute assertion timeout.
    if ($InstallerType -match '^(portable|zip|pwa)$') {
        throw "The baseline for '$AppId' v$Version is a '$InstallerType' winget package — it has no silent installer (it would launch the app and hang the sandbox). Pick a different baseline with -SpecificVersion, or test with -Scenario InstallUninstall."
    }

    $oldVersionDir = Join-Path $ProjectPath 'Sandbox\OldVersion'

    # Always start fresh so we don't accidentally pick up a stale installer. -LiteralPath enumeration
    # (not a wildcard -Path) so files with [ ] etc. are removed too; a survivor is a hard error rather
    # than a silent stale baseline.
    if (Test-Path -LiteralPath $oldVersionDir) {
        Get-ChildItem -LiteralPath $oldVersionDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        if (@(Get-ChildItem -LiteralPath $oldVersionDir -Force).Count -gt 0) {
            throw "Could not clear $oldVersionDir (files in use? a sandbox still running?). Close the sandbox and retry."
        }
    } else {
        New-Item -ItemType Directory -Path $oldVersionDir -Force | Out-Null
    }

    Write-Host "Downloading v$Version of '$AppId'..." -ForegroundColor Yellow

    $downloadArgs = @(
        'download',
        '--id',                        $AppId,
        '--version',                   $Version,
        '--download-directory',        $oldVersionDir,
        '--accept-source-agreements',
        '--accept-package-agreements'
    )

    if ($Architecture -and $Architecture -ne 'all') {
        $downloadArgs += '--architecture'
        $downloadArgs += $Architecture
    }

    # Pin the packaged variant so the baseline matches (machine vs user scope, msi vs exe, locale).
    $pinArgs = @()
    if ($Scope -and $Scope -in @('machine', 'user')) { $pinArgs += '--scope';          $pinArgs += $Scope }
    if ($InstallerType)                              { $pinArgs += '--installer-type'; $pinArgs += $InstallerType }
    if ($Locale)                                     { $pinArgs += '--locale';         $pinArgs += $Locale }

    & winget @downloadArgs @pinArgs

    if ($LASTEXITCODE -ne 0 -and $pinArgs.Count -gt 0) {
        # The old version may not publish the pinned variant (or the winget build may not support a
        # pin flag) — retry unpinned rather than failing the whole test, but say so clearly.
        Write-Warning "Pinned download (scope/installer-type/locale of the packaged variant) failed for '$AppId' v$Version — retrying without pins. The baseline may be a DIFFERENT variant than the packaged app; check the installed baseline in the sandbox."
        Get-ChildItem -LiteralPath $oldVersionDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        & winget @downloadArgs
    }

    if ($LASTEXITCODE -ne 0) {
        throw "winget download exited with code $LASTEXITCODE for '$AppId' v$Version."
    }

    # Locate the downloaded installer file
    $installer = Get-ChildItem -Path $oldVersionDir -File |
        Where-Object { $_.Extension -in '.exe', '.msi', '.msix', '.appx' } |
        Select-Object -First 1

    # Read the manifest installer type first — it lets the "no installer found" message below name the
    # type (e.g. a 'zip' package downloads no .exe/.msi/.msix/.appx), and drives the silent-args choice.
    $installerTypeName = $null
    $yamlFile = Get-ChildItem -Path $oldVersionDir -Filter '*.yaml' -File | Select-Object -First 1
    if ($yamlFile) {
        $yamlContent = Get-Content -Path $yamlFile.FullName -Raw
        if ($yamlContent -match '(?m)^\s*InstallerType:\s*(\S+)') {
            $installerTypeName = $matches[1].Trim().ToLower()
        }
    }

    if (-not $installer) {
        $typeHint = if ($installerTypeName) { " (manifest InstallerType: '$installerTypeName')" } else { '' }
        throw "winget download completed but no installer file (.exe/.msi/.msix/.appx) was found in $oldVersionDir$typeHint. This baseline may be a zip/portable/store package with no silent installer — use -SpecificVersion for a different version, or test with -Scenario InstallUninstall."
    }

    $yamlInfo   = Get-YAMLInstallerInfo -FilesPath $oldVersionDir
    $yamlSilent = if ($yamlInfo) { $yamlInfo.SilentArgs } else { $null }
    $resolved = Resolve-Win32ToolkitBaselineSilentArgs `
        -InstallerTypeName $installerTypeName `
        -Extension         $installer.Extension `
        -YamlSilentArgs    $yamlSilent
    $silentArgs = $resolved.SilentArgs
    if ($resolved.Guessed) {
        Write-Warning "No silent switches found in the winget manifest for '$($installer.Name)' — guessing '/S'. If the baseline install shows UI or hangs in the sandbox, the update run will be INCONCLUSIVE; use -SpecificVersion for a version whose manifest has silent switches, or watch the sandbox."
    }

    Write-Host "✓ Downloaded    : $($installer.Name)"  -ForegroundColor Green
    Write-Host "  Installer type: $installerTypeName"  -ForegroundColor Gray
    Write-Host "  Silent args   : $silentArgs"         -ForegroundColor Gray

    return [PSCustomObject]@{
        InstallerPath = $installer.FullName
        InstallerName = $installer.Name
        InstallerType = $installer.Extension.TrimStart('.').ToLower()
        SilentArgs    = $silentArgs
    }
}
