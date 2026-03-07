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
        [string]$Architecture
    )

    $oldVersionDir = Join-Path $ProjectPath 'Sandbox\OldVersion'

    # Always start fresh so we don't accidentally pick up a stale installer
    if (Test-Path $oldVersionDir) {
        Remove-Item -Path "$oldVersionDir\*" -Recurse -Force -ErrorAction SilentlyContinue
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

    & winget @downloadArgs

    if ($LASTEXITCODE -ne 0) {
        throw "winget download exited with code $LASTEXITCODE for '$AppId' v$Version."
    }

    # Locate the downloaded installer file
    $installer = Get-ChildItem -Path $oldVersionDir -File |
        Where-Object { $_.Extension -in '.exe', '.msi', '.msix', '.appx' } |
        Select-Object -First 1

    if (-not $installer) {
        throw "winget download completed but no installer file (.exe/.msi/.msix/.appx) was found in: $oldVersionDir"
    }

    # Try to read installer type from the downloaded YAML manifest
    $installerTypeName = $null
    $yamlFile = Get-ChildItem -Path $oldVersionDir -Filter '*.yaml' -File | Select-Object -First 1
    if ($yamlFile) {
        $yamlContent = Get-Content -Path $yamlFile.FullName -Raw
        if ($yamlContent -match '(?m)^\s*InstallerType:\s*(\S+)') {
            $installerTypeName = $matches[1].Trim().ToLower()
        }
    }

    # Try to get silent args from the YAML (reuse existing module helper)
    $yamlInfo   = Get-YAMLInstallerInfo -FilesPath $oldVersionDir
    $silentArgs = if ($yamlInfo) { $yamlInfo.SilentArgs } else { $null }

    # Fallback: derive silent switches from installer type or file extension
    if (-not $silentArgs) {
        if ($installerTypeName) {
            $silentArgs = switch -Regex ($installerTypeName) {
                'nullsoft|nsis' { '/S';                          break }
                'inno'          { '/VERYSILENT /NORESTART /SP-'; break }
                'wix|burn'      { '/quiet /norestart';           break }
                'msi'           { '/qn /norestart';              break }
                default         { '/S' }
            }
        } else {
            $ext = $installer.Extension.ToLower()
            $silentArgs = switch ($ext) {
                '.msi'  { '/qn /norestart' }
                '.msix' { '' }
                '.appx' { '' }
                default { '/S' }
            }
        }
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
