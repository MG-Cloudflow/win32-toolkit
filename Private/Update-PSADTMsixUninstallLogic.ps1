function Update-PSADTMsixUninstallLogic {
    <#
    .SYNOPSIS
        Writes the AppConfig.json Uninstall section for an MSIX/APPX project (identity-driven).
    .DESCRIPTION
        MSIX packages leave no classic HKLM\...\Uninstall registry keys, so the capture-based
        uninstall writer (Update-PSADTUninstallLogic, EXE only) finds nothing for them, and PSADT
        Zero-Config MSI does not apply. Instead, the package identity is read from the .msix/.appx
        AppxManifest.xml on the HOST at packaging time (Get-Win32ToolkitMsixIdentity) and stored as
        DATA; the deploy script's fixed uninstall snippet removes the package at runtime via
        Remove-AppxProvisionedPackage / Remove-AppxPackage matched by exact identity Name.

        Called at CONFIGURE time (Configure-PSADTForInstaller / New-Win32ToolkitManualApp) — it needs
        nothing from the sandbox capture, so the uninstall works even if the capture times out.
        Wait-ForDocumentationAndProcess re-runs it as belt-and-braces (idempotent read-modify-write).
    .PARAMETER ProjectPath
        Full path to the PSADT project folder (reads Files\ and SupportFiles\AppConfig.json).
    .OUTPUTS
        [bool] $true when the Uninstall section was written.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    try {
        $filesPath = Join-Path $ProjectPath 'Files'
        $fileInfo  = Get-InstallerFileInfo -FilesPath $filesPath
        if (-not $fileInfo.FileName -or $fileInfo.Type -notin @('msix', 'appx')) {
            Write-Warning "Update-PSADTMsixUninstallLogic: no .msix/.appx installer found in $filesPath"
            return $false
        }

        $identity = Get-Win32ToolkitMsixIdentity -Path (Join-Path $filesPath $fileInfo.FileName)
        if (-not $identity) {
            Write-Warning 'Could not read the MSIX package identity — no uninstall data written. The package will have NO working uninstall until this is resolved.'
            return $false
        }

        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $app = if ($cfg.PSObject.Properties.Name -contains 'App') { $cfg.App } else { $null }
        $appName = if ($identity.PackageName) { $identity.PackageName }
                   elseif ($app -and $app.DisplayName) { $app.DisplayName }
                   else { '' }

        $uninstall = [pscustomobject]@{
            AppName      = $appName
            ProductCodes = @()
            Uninstallers = @(
                [pscustomobject]@{
                    Type        = 'msix'
                    PackageName = $identity.PackageName
                    Publisher   = $identity.Publisher
                    ProductCode = $null
                    Path        = $null
                    Args        = $null
                }
            )
            CleanupPaths = @()
        }
        $cfg | Add-Member -NotePropertyName Uninstall -NotePropertyValue $uninstall -Force
        Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg | Out-Null

        Write-Host "✓ MSIX uninstall data written (identity: $($identity.PackageName))" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Failed to write MSIX uninstall data: $($_.Exception.Message)"
        return $false
    }
}
