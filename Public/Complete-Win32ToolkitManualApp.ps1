function Complete-Win32ToolkitManualApp {
<#
.SYNOPSIS
    Finalises a scaffolded project: sandbox capture → uninstall automation → test/package/upload.
.DESCRIPTION
    The second phase of the manual (non-winget) flow — run this after New-Win32ToolkitManualApp -Advanced
    once you have written the Install logic in Invoke-AppDeployToolkit.ps1. It runs the shared finalize
    tail (Invoke-Win32ToolkitFinalize): launches the documentation sandbox (which installs via your
    project's deploy script and captures the changes), derives the uninstall / requirement script /
    processes-to-close, then optionally runs test scenarios, packages the .intunewin, and uploads to
    Intune.

    Works on any win32-toolkit project (manual or winget), so it can also re-finalise a project after
    hand edits.
.PARAMETER ProjectPath
    Full path to the PSADT project folder (must contain Invoke-AppDeployToolkit.ps1).
.PARAMETER RunTest
    Sandbox test scenario(s) to run after documentation. Only InstallUninstall applies to manual apps
    (Update needs winget version history).
.PARAMETER PackageIntune
    Package the project into a .intunewin file.
.PARAMETER PublishIntune
    Upload to Intune (implies -PackageIntune).
.EXAMPLE
    Complete-Win32ToolkitManualApp -ProjectPath 'C:\Win32Apps\Projects\Contoso\Legacy_CAD_x64_12.0' -RunTest InstallUninstall -PublishIntune
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [ValidateSet('InstallUninstall', 'Update')]
        [string[]]$RunTest,

        [switch]$PackageIntune,

        [switch]$PublishIntune,

        # Also publish the update app (2nd app, same version, requirement-gated to installed devices).
        [switch]$PublishUpdate
    )

    try {
        if (-not (Test-Path $ProjectPath)) { throw "Project path not found: $ProjectPath" }
        $scriptPath = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
        if (-not (Test-Path $scriptPath)) {
            throw "Not a PSADT project (no Invoke-AppDeployToolkit.ps1): $ProjectPath"
        }

        $projectName = Split-Path $ProjectPath -Leaf

        # App metadata for the documentation config (from AppConfig.json when present).
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $app = if ($cfg.PSObject.Properties.Name -contains 'App') { $cfg.App } else { $null }
        $appInfo = [pscustomobject]@{
            Name    = if ($app -and $app.Name)    { $app.Name }    else { $projectName }
            Version = if ($app -and $app.Version) { $app.Version } else { '' }
            Id      = if ($app -and $app.Name)    { $app.Name }    else { $projectName }
            Source  = 'manual'
        }

        Write-Host "Finalising project: $projectName" -ForegroundColor Cyan
        $finalize = @{ ProjectPath = $ProjectPath; ProjectName = $projectName; AppInfo = $appInfo }
        if ($RunTest) { $finalize['RunTest'] = $RunTest }   # omit when null (ValidateSet rejects $null)
        Invoke-Win32ToolkitFinalize @finalize -PackageIntune:$PackageIntune -PublishIntune:$PublishIntune -PublishUpdate:$PublishUpdate
    }
    catch {
        Write-Error "Complete-Win32ToolkitManualApp failed: $($_.Exception.Message)"
    }
}
