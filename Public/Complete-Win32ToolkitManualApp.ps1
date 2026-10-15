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
    hand edits. Before anything runs the deploy script is checked: it must carry the AppConfig loader and
    use a template layout this version supports (projects from older win32-toolkit versions pass with a
    warning). A project whose layout is not supported must be re-created - copy any hand-written Install
    code out of Invoke-AppDeployToolkit.ps1 first, because re-creating a project deletes its folder - or
    finalised unchanged with -AllowLegacyScript.
.PARAMETER ProjectPath
    Full path to the PSADT project folder (must contain Invoke-AppDeployToolkit.ps1).
.PARAMETER RunTest
    Sandbox test scenario(s) to run after documentation. Only InstallUninstall applies to manual apps
    (Update needs winget version history).
.PARAMETER PackageIntune
    Package the project into a .intunewin file.
.PARAMETER PublishIntune
    Upload to Intune (implies -PackageIntune).
.PARAMETER PublishUpdate
    Also publish the UPDATE app (a second, requirement-gated Intune app of the same version).
.PARAMETER AllowLegacyScript
    Finalise a deploy script that win32-toolkit never patched (no AppConfig loader) or whose template
    layout this version does not support; the package is built as-is. Projects patched by older
    win32-toolkit versions do not need it.
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
        [switch]$PublishUpdate,

        # D15 override: finalise a script without the AppConfig loader / with an unsupported layout as-is.
        [switch]$AllowLegacyScript
    )

    try {
        if (-not (Test-Path -LiteralPath $ProjectPath)) { throw "Project path not found: $ProjectPath" }
        # Absolute from here on: the helpers read project files through .NET, which resolves a relative
        # path against the process directory rather than the PowerShell location.
        $ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).ProviderPath
        $scriptPath = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
        if (-not (Test-Path -LiteralPath $scriptPath)) {
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
        Invoke-Win32ToolkitFinalize @finalize -PackageIntune:$PackageIntune -PublishIntune:$PublishIntune -PublishUpdate:$PublishUpdate -AllowLegacyScript:$AllowLegacyScript
    }
    catch {
        # Fail-closed errors (W32T.*, e.g. W32T.PackageNotReady) reach the caller as terminating errors.
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Error "Complete-Win32ToolkitManualApp failed: $($_.Exception.Message)"
    }
}
