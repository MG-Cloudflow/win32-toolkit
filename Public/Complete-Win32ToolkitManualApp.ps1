function Complete-Win32ToolkitManualApp {
<#
.SYNOPSIS
    Runs the install capture of a project again, then the tests, build and publish you ask for.
.DESCRIPTION
    Complete-Win32ToolkitManualApp runs the install capture of a project on your test machine. From
    the new capture, it updates the uninstall steps, the processes to close and the requirement
    script of the project. Then it runs the tests, the build and the publish that you ask for.

    Use it to finish an Advanced app after you wrote its install code. Also use it after you
    changed a project by hand or changed its dependencies. It works on projects from winget too. In
    the menu: Work with an existing project > Finalize / refresh, which runs the install capture
    only. Right after you create an Advanced app in the menu, Finish setup now runs this command
    with your test, package and publish choices.

    It never changes your install code. First it checks the deploy script
    (Invoke-AppDeployToolkit.ps1). If the script has a syntax error, nothing runs. If it uses a
    PSAppDeployToolkit (PSADT) layout or version that the toolkit does not support, re-create the
    project or add the -AllowLegacyScript switch. Copy your install code out first, because
    re-creating deletes the project folder.

    It stops with an error whose ID starts with W32T. when the deploy script cannot be used
    (W32T.PackageNotReady). It also stops when a dependency cannot be prepared for the test
    machine (W32T.DependencyNotStaged).
.PARAMETER ProjectPath
    The project folder, for example <base folder>\Projects\<template>\<project>. It must contain
    Invoke-AppDeployToolkit.ps1. The command finds project dependencies under your saved base
    folder, because it has no -BasePath.
.PARAMETER RunTest
    The tests to run after the install capture. Default: no test. For an app that is not in winget,
    use InstallUninstall only: Update has no older winget version to start from and ends as
    Inconclusive. To test an update of such an app, use Test-Win32ToolkitProject -BaselineProject.
.PARAMETER PackageIntune
    Builds the package after the install capture and the tests. The command then asks whether to
    upload it to Intune, unless you also use -PublishIntune, -PublishUpdate or -NoPublishPrompt.
.PARAMETER PublishIntune
    Builds the package and publishes it to Intune as a new install app. You sign in to Intune if
    needed. A failed test does not stop the publish.
.PARAMETER PublishUpdate
    Publishes the update app: a second Intune app of the same version that installs only on
    devices that already have the app. Add -PublishIntune to publish the install app too. This also
    builds the package.
.PARAMETER AllowLegacyScript
    Accepts a deploy script that the toolkit never changed, or whose PSADT layout or version it
    does not support, and uses it as it is. A script with a syntax error still stops the command.
    Projects from win32-toolkit 1.1.6 or older do not need it. Command line only: the menu
    does not offer this.
.PARAMETER NoPublishPrompt
    Skips the question 'Upload to Microsoft Intune now? (Y/N)' after -PackageIntune builds the
    package. Use it in scripts.
.EXAMPLE
    $project = 'C:\Win32Apps\Projects\Contoso\Fabrikam_CAD_x64_12.0'   # your project folder
    Complete-Win32ToolkitManualApp -ProjectPath $project -RunTest InstallUninstall

    This finishes the Advanced app after you wrote its install code. It runs the install capture
    and an install and uninstall test, and does not build or publish anything.
.EXAMPLE
    Complete-Win32ToolkitManualApp -ProjectPath $project -RunTest InstallUninstall -PublishIntune

    This also builds the package and publishes it to Intune as a new install app ($project as in
    the first example). A failed test does not stop the publish.
.EXAMPLE
    Complete-Win32ToolkitManualApp -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'

    This runs the install capture again for a project from winget, for example after you changed
    its dependencies. It updates the uninstall steps and runs no test.
.EXAMPLE
    $project = 'C:\Win32Apps\Projects\Contoso\Contoso_Reader_x64_3.2.0'   # your project folder
    $old = 'Contoso\Contoso_Reader_x64_3.1.0'   # the older project you packaged before
    Complete-Win32ToolkitManualApp -ProjectPath $project -RunTest InstallUninstall
    Test-Win32ToolkitProject -ProjectPath $project -Scenario Update -BaselineProject $old

    This tests an app that is not in winget, then tests an update from the older version 3.1.0.
    Complete-Win32ToolkitManualApp -RunTest Update cannot do this for such an app.
.OUTPUTS
    A result object. Check Status: Succeeded, CompletedWithProblems or Failed.
    Problems lists what went wrong. Tests gives each test result: Passed, Failed or Inconclusive.
    A W32T error stops the command and returns nothing.
.NOTES
    Needs: Windows Sandbox or the Hyper-V test VM. Time: the install capture usually takes 5 to 20
    minutes, and the toolkit stops waiting after 30 minutes.
.LINK
    https://win32toolkit.com/reference/Complete-Win32ToolkitManualApp/
.LINK
    https://win32toolkit.com/projects/
.LINK
    https://win32toolkit.com/manual-apps/
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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
        [switch]$AllowLegacyScript,

        # No 'Upload to Microsoft Intune now?' question after packaging (TUI audit G5: the menu asks about
        # publishing itself). Declared last.
        [switch]$NoPublishPrompt
    )

    $runResult = $null
    try {
        # The run's result object (TUI audit G2, S8-F3): filled by Finalize, returned at the end.
        $runResult = Initialize-Win32ToolkitRunResult -Command 'Complete-Win32ToolkitManualApp' -Mode 'Finalize'

        if (-not (Test-Path -LiteralPath $ProjectPath)) { throw "Project path not found: $ProjectPath" }
        # Absolute from here on: the helpers read project files through .NET, which resolves a relative
        # path against the process directory rather than the PowerShell location.
        $ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).ProviderPath
        $scriptPath = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "Not a PSADT project (no Invoke-AppDeployToolkit.ps1): $ProjectPath"
        }

        $projectName = Split-Path $ProjectPath -Leaf
        $runResult.ProjectName = $projectName
        $runResult.ProjectPath = $ProjectPath

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
        $finalize = @{ ProjectPath = $ProjectPath; ProjectName = $projectName; AppInfo = $appInfo; Result = $runResult }
        if ($RunTest) { $finalize['RunTest'] = $RunTest }   # omit when null (ValidateSet rejects $null)
        if ($NoPublishPrompt) { $finalize['NoPublishPrompt'] = $true }   # only when set (TUI audit G5)
        Invoke-Win32ToolkitFinalize @finalize -PackageIntune:$PackageIntune -PublishIntune:$PublishIntune -PublishUpdate:$PublishUpdate -AllowLegacyScript:$AllowLegacyScript
        return (Complete-Win32ToolkitRunResult -Result $runResult)
    }
    catch {
        # Fail-closed errors (W32T.*, e.g. W32T.PackageNotReady) reach the caller as terminating errors.
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        # Any other error: the result object says the run stopped (Status Failed), then the error is written.
        if ($runResult) {
            $runResult.Problems.Add([string]$_.Exception.Message)
            Complete-Win32ToolkitRunResult -Result $runResult -Failed
        }
        Write-Error "Complete-Win32ToolkitManualApp failed: $($_.Exception.Message)"
    }
}
