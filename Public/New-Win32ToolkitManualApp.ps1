function New-Win32ToolkitManualApp {
<#
.SYNOPSIS
    Creates a project from your own installer, for an app that is not in winget.
.DESCRIPTION
    New-Win32ToolkitManualApp creates a project from an installer that you bring. An MSI, an MSIX
    or APPX package, or an EXE with silent switches becomes an Easy app: the toolkit writes the
    install. An EXE without silent switches, or any app with -Advanced, becomes an Advanced app:
    you write the install code. The console calls it a HARD APP. In both modes, the toolkit
    writes the uninstall. Always give -Publisher: the toolkit needs it to detect the installed
    version.

    For an Easy app, -Continue, -RunTest, -PackageIntune, -PublishIntune and -PublishUpdate run
    the install capture and the steps you ask for. Without them, the command only creates the
    project. For an Advanced app, the command stops after it creates the project and ignores these
    options: finish it with Complete-Win32ToolkitManualApp. In the menu: Package a manual app (not
    in winget).

    The project is <base folder>\Projects\<template>\<name>_<architecture>_<version>. If the
    installer or the org template cannot be set up, the folder is kept. The toolkit then refuses
    to build or publish it until you create the app again.

    It stops with an error whose ID starts with W32T. when a -DependsOn reference is wrong
    (W32T.InvalidDependencyReference). It also stops when it cannot create the project
    (W32T.ProjectCreationFailed), for example when you do not let it replace an existing project.
.PARAMETER Name
    The name of the app. The project name starts with it, and Intune shows it as the app name. If
    you leave it out, the command asks for it. For an MSI, Intune shows the project name instead,
    for example Contoso_Reader_x64_3.2.0. You can rename the app in the Intune admin center.
.PARAMETER Version
    The app version, for example 3.2.0. It is part of the project name. With a publisher, the
    detection rule checks for this exact version. If you leave it out, the command asks for it.
.PARAMETER Architecture
    The processor architecture of the app. It is part of the project name, and Intune uses it as
    the architecture of the app. If you leave it out, the command asks for it (Enter means x64).
.PARAMETER SourcePath
    The installer file, or a folder with the installer and the files it needs. The command copies
    it into the project. In a folder, the installer must be at the top level. An MSI wins over an
    EXE, and an EXE over an MSIX or APPX package. If you leave it out, the command asks for it.
.PARAMETER Publisher
    The publisher of the app. Always give it: the command does not ask for it. Without a
    publisher, the package does not record the installed version. Intune then uses a weaker
    detection rule from the install capture, and shows the publisher as Unknown.
.PARAMETER Description
    The description of the app in Intune.
.PARAMETER InformationUrl
    A web page with information about the app, shown in Intune.
.PARAMETER SilentArgs
    The silent switches of an EXE installer, for example /S. With them, the EXE becomes an Easy
    app. Without them, it becomes an Advanced app. The command ignores this value for an MSI, MSIX
    or APPX package.
.PARAMETER IconPath
    An image file for the app icon, for example a .png file. The toolkit uses it instead of the
    icon that the install capture finds. If the file does not exist, the command ignores it without
    a message.
.PARAMETER TemplateName
    The org template to use. If you leave it out, the command uses your only org template, or asks
    you to choose when there are several. If the name does not exist yet, the org template wizard
    starts and creates it.
.PARAMETER BasePath
    The base folder for this command only. Default: your saved base folder. The value is not saved.
.PARAMETER Reconfigure
    Asks for the base folder again and saves your answer as the new default.
.PARAMETER Advanced
    Creates an Advanced app: you write the install code in Invoke-AppDeployToolkit.ps1, between
    the '## win32-toolkit:Install:manual-install' block and the 'install-done' block. The code runs
    under Windows PowerShell 5.1 on devices and must stop with throw, never return. It must not
    assign PSADT variables such as $envTemp.
.PARAMETER Force
    Replaces an existing project with the same name, architecture and version without asking. This
    deletes the old folder with its install code, install captures, test results, dependencies and
    publication record. Prior-install rules are kept. Use it in scripts.
.PARAMETER Continue
    Runs the install capture right after the project is created. The capture records what the
    installer changes, and the toolkit builds the uninstall steps from it. Ignored for an Advanced
    app.
.PARAMETER RunTest
    The tests to run after the install capture. Default: no test. Use InstallUninstall: Update has
    no older version to start from here and ends as Inconclusive. To test an update, run
    Test-Win32ToolkitProject -BaselineProject later. Ignored for an Advanced app.
.PARAMETER PackageIntune
    Builds the package after the install capture and the tests. The command then asks whether to
    upload it to Intune, unless you also use -PublishIntune, -PublishUpdate or -NoPublishPrompt.
    Ignored for an Advanced app.
.PARAMETER PublishIntune
    Builds the package and publishes it to Intune as a new install app. You sign in to Intune if
    needed. A failed test does not stop the publish. Ignored for an Advanced app.
.PARAMETER PublishUpdate
    Publishes the update app: a second Intune app of the same version that installs only on
    devices that already have the app. Add -PublishIntune to publish the install app too. This also
    runs the install capture and builds the package. Ignored for an Advanced app.
.PARAMETER DependsOn
    The apps that Intune must install before this app: 'winget:<id>',
    'project:<template>\<project>' or 'intune:<app ID>'. The install capture and the tests also
    install winget and project dependencies first. A wrong reference stops the command before
    anything is created.
.PARAMETER DependencyType
    How Intune treats the dependencies. Default: autoInstall (Intune installs them first). With
    detect, Intune only checks that a dependency is there and does not install this app when it is
    missing. Command line only: the menu does not offer this.
.PARAMETER NoPublishPrompt
    Skips the question 'Upload to Microsoft Intune now? (Y/N)' after -PackageIntune builds the
    package. Use it in scripts.
.EXAMPLE
    $app = @{
        Name         = 'Contoso Reader'
        Version      = '3.2.0'
        Architecture = 'x64'
        SourcePath   = 'C:\Installers\ContosoReader.msi'
        Publisher    = 'Contoso Ltd'
        TemplateName = 'Contoso'
    }
    New-Win32ToolkitManualApp @app -RunTest InstallUninstall -PackageIntune -NoPublishPrompt

    This creates the Easy app project Contoso_Reader_x64_3.2.0, runs the install capture and an
    install and uninstall test, and builds the package. Nothing is published to Intune.
.EXAMPLE
    $cad = @{
        Name         = 'Fabrikam CAD'
        Version      = '12.0'
        Architecture = 'x64'
        SourcePath   = 'C:\Installers\FabrikamCAD'
        Publisher    = 'Fabrikam'
        TemplateName = 'Contoso'
    }
    New-Win32ToolkitManualApp @cad -Advanced

    This creates the Advanced app project Fabrikam_CAD_x64_12.0 from a folder and stops. Write your
    install code in Invoke-AppDeployToolkit.ps1, then run Complete-Win32ToolkitManualApp.
.EXAMPLE
    New-Win32ToolkitManualApp @app -DependsOn 'winget:Microsoft.VCRedist.2015+.x64' -Continue

    This creates Contoso Reader with the Visual C++ redistributable as a dependency ($app as in the
    first example). The install capture installs the redistributable first. Publish the
    redistributable with the toolkit before this app, so that Intune can link it.
.EXAMPLE
    $r = New-Win32ToolkitManualApp @app -RunTest InstallUninstall -PackageIntune -NoPublishPrompt
    if ($r.Status -eq 'Succeeded') {
        Publish-Win32ToolkitIntuneApp -IntuneWinPath $r.IntuneWinPath -ProjectPath $r.ProjectPath
    }

    This is the form for scripts ($app as in the first example). It publishes the package only when
    the install capture and the test had no problems. A W32T error stops the script.
.OUTPUTS
    A result object. Check Status: Succeeded, CompletedWithProblems, Failed or Scaffolded.
    Scaffolded means: finish with Complete-Win32ToolkitManualApp. Problems lists what went wrong.
    A W32T error stops the command and returns nothing.
.NOTES
    Needs: Windows Sandbox or the Hyper-V test VM for the install capture and the tests. Time: the
    install capture usually takes 5 to 20 minutes, and the toolkit stops waiting after 30 minutes.
.LINK
    https://win32toolkit.com/reference/New-Win32ToolkitManualApp/
.LINK
    https://win32toolkit.com/manual-apps/
.LINK
    https://win32toolkit.com/dependencies/
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Name,
        [string]$Version,
        [ValidateSet('x64', 'x86', 'arm64')]
        [string]$Architecture,
        [string]$SourcePath,
        [string]$Publisher,
        [string]$Description,
        [string]$InformationUrl,
        [string]$SilentArgs,
        [string]$IconPath,
        [string]$TemplateName,
        [string]$BasePath,
        [switch]$Reconfigure,
        [switch]$Advanced,
        [switch]$Force,
        [switch]$Continue,
        [ValidateSet('InstallUninstall', 'Update')]
        [string[]]$RunTest,
        [switch]$PackageIntune,
        [switch]$PublishIntune,
        # Also publish the update app (2nd app, same version, requirement-gated to installed devices).
        [switch]$PublishUpdate,

        # Apps Intune must install BEFORE this one (e.g. a Visual C++ redistributable).
        # 'winget:<id>' | 'project:<Template>\<Name>' | 'intune:<guid>' | a bare reference.
        # Declared into AppConfig.json; ALSO staged into the test/capture guest so the run installs the
        # dependency first, exactly as Intune does on a real device.
        [string[]]$DependsOn,

        [ValidateSet('autoInstall', 'detect')]
        [string]$DependencyType = 'autoInstall',

        # No 'Upload to Microsoft Intune now?' question after packaging (TUI audit G5: the menu asks about
        # publishing itself). Declared last.
        [switch]$NoPublishPrompt
    )

    $runResult = $null
    try {
        # The run's result object (TUI audit G2, S8-F3); Mode is set once the scaffold decides Easy or Advanced.
        $runResult = Initialize-Win32ToolkitRunResult -Command 'New-Win32ToolkitManualApp'

        Write-Host 'Manual Win32 App Packager (non-winget)' -ForegroundColor Cyan
        Write-Host '======================================' -ForegroundColor Cyan

        # -DependsOn is checked before any prompt and before anything is created (re-verification 2026-10-21,
        # B3 r2.1); W32T.InvalidDependencyReference is re-thrown by the catch below. The self-dependency check
        # follows once the project name is known.
        if ($DependsOn) { $null = Assert-Win32ToolkitDependencyRef -Reference $DependsOn -DependencyType $DependencyType }

        # ── Base folder + hybrid input ────────────────────────────────────────────
        $BasePath = Get-Win32ToolkitBasePath -BasePath $BasePath -Reconfigure:$Reconfigure
        Write-Host "Base folder: $BasePath" -ForegroundColor DarkGray

        if ([string]::IsNullOrWhiteSpace($Name))       { $Name = (Read-Host 'App name').Trim() }
        if ([string]::IsNullOrWhiteSpace($Version))    { $Version = (Read-Host 'Version').Trim() }
        if ([string]::IsNullOrWhiteSpace($Architecture)) {
            do {
                $Architecture = (Read-Host 'Architecture (x64/x86/arm64) [x64]').Trim()
                if ([string]::IsNullOrWhiteSpace($Architecture)) { $Architecture = 'x64' }
            } while ($Architecture -notin @('x64', 'x86', 'arm64'))
        }
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { $SourcePath = (Read-Host 'Installer path (file or folder)').Trim('"', ' ') }

        if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Version) -or [string]::IsNullOrWhiteSpace($SourcePath)) {
            throw 'Name, Version, and SourcePath are required.'
        }
        if (-not (Test-Path -LiteralPath $SourcePath)) { throw "Source path not found: $SourcePath" }

        # ── Org template ──────────────────────────────────────────────────────────
        $script:OrgTemplate = Get-OrgTemplate -TemplateName $TemplateName -BasePath $BasePath

        # ── Project scaffold under Projects\<Template>\<name> ─────────────────────
        $projectName = '{0}_{1}_{2}' -f (Sanitize-ProjectName -Name $Name),
                                        (Sanitize-ProjectName -Name $Architecture),
                                        (Sanitize-ProjectName -Name $Version)

        $paths       = Get-Win32ToolkitPaths -BasePath $BasePath
        $templateSeg = Sanitize-ProjectName -Name $script:OrgTemplate.TemplateName
        if ([string]::IsNullOrWhiteSpace($templateSeg)) { $templateSeg = 'Default' }
        $projectsDir = Join-Path $paths.Projects $templateSeg
        # A 'project:' dependency on this very app is refused before the template folder or the project is created
        # (B3 r2.1); the declaration after the scaffold re-checks it.
        if ($DependsOn) { $null = Assert-Win32ToolkitDependencyRef -Reference $DependsOn -DependencyType $DependencyType -ProjectPath (Join-Path $projectsDir $projectName) }
        if (-not (Test-Path $projectsDir)) { New-Item -Path $projectsDir -ItemType Directory -Force | Out-Null }

        Write-Host "Template folder: $templateSeg" -ForegroundColor DarkGray
        Write-Host "Project name   : $projectName" -ForegroundColor Cyan

        # A rebuilt version keeps its prior-install rules, decisions and capture records (installer-identity PR 3, L4):
        # read before Create-PSADTProject deletes the folder, restored after the org template below.
        $priorSnapshot = Get-Win32ToolkitPriorInstallSnapshot -ProjectPath (Join-Path $projectsDir $projectName)
        if (-not (Create-PSADTProject -ProjectName $projectName -ProjectPath $projectsDir -Force:$Force)) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Failed to create the PSADT project '$projectName' (see the warnings above)."),
                'W32T.ProjectCreationFailed', [System.Management.Automation.ErrorCategory]::InvalidResult, $projectName)
        }
        $projectFullPath = Join-Path $projectsDir $projectName
        $runResult.ProjectName = $projectName
        $runResult.ProjectPath = $projectFullPath
        $filesPath       = Join-Path $projectFullPath 'Files'

        # TUI audit G4 (S10-F2): Create-PSADTProject has just replaced the folder (and any earlier marker), so every
        # error from here to the end of the configure step (the org template) leaves a half-built folder. The catch
        # below marks it not configured (Documentation\NotConfigured.json; Export and Publish refuse it) and re-throws.
        $markStage = 'Download'
        try {
            # ── Copy installer + detect type ──────────────────────────────────────────
            # $null = (not | Out-Null): its warnings must reach the caller's -WarningVariable (TUI audit G6, B1 #2).
            $null = Add-Win32ToolkitInstallerFiles -SourcePath $SourcePath -FilesPath $filesPath
            $fileInfo = Get-InstallerFileInfo -FilesPath $filesPath
            if (-not $fileInfo.FileName) { throw "No installer (msi/exe/msix/appx) detected in: $filesPath" }
            Write-Host "Installer      : $($fileInfo.FileName) ($($fileInfo.Type.ToUpper()))" -ForegroundColor Green

            $markStage = 'Configure'
            # ── Write AppConfig (App + Installer) ─────────────────────────────────────
            $isMsi = ($fileInfo.Type -eq 'msi')
            $cfg = Get-Win32ToolkitAppConfig -ProjectPath $projectFullPath
            $cfg | Add-Member -NotePropertyName App -NotePropertyValue ([pscustomobject]@{
                Vendor         = if ($Publisher) { $Publisher } else { '' }
                Name           = if ($isMsi) { '' } else { $Name }   # empty ⇒ Zero-Config MSI
                DisplayName    = $Name                                # always populated (drives tattoo + detection)
                Version        = $Version
                Arch           = $Architecture
                ScriptAuthor   = if ($script:OrgTemplate -and $script:OrgTemplate.AppScriptAuthor) { $script:OrgTemplate.AppScriptAuthor } else { '' }
                ScriptDate     = (Get-Date -Format 'yyyy-MM-dd')
                Description    = if ($Description) { $Description } else { '' }
                InformationUrl = if ($InformationUrl) { $InformationUrl } else { '' }
            }) -Force
            $isAppx = $fileInfo.Type -in @('msix', 'appx')
            $cfg | Add-Member -NotePropertyName Installer -NotePropertyValue ([pscustomobject]@{
                Type       = $fileInfo.Type
                FileName   = $fileInfo.FileName
                SilentArgs = if ($isMsi -or $isAppx) { '' } elseif ($SilentArgs) { $SilentArgs } else { '' }
            }) -Force
            if (-not ($cfg.PSObject.Properties.Name -contains 'ProcessesToClose')) {
                $cfg | Add-Member -NotePropertyName ProcessesToClose -NotePropertyValue @() -Force
            }

            # ---- Org-template Intune publish defaults + doc branding (data only) ----
            # Mirrors Configure-PSADTForInstaller: a manual app never goes through that function, so without
            # this every org-template Intune default (min-OS, restart behavior, max runtime, description
            # boilerplate, privacy URL) and the doc branding were silently dropped for manual apps.
            if ($script:OrgTemplate -and $script:OrgTemplate.PSObject.Properties['IntuneDefaults'] -and $script:OrgTemplate.IntuneDefaults) {
                $cfg | Add-Member -NotePropertyName IntuneDefaults -NotePropertyValue (New-Win32ToolkitIntuneDefaults -Template $script:OrgTemplate) -Force
            }
            if ($script:OrgTemplate) {
                $companyM   = if ($script:OrgTemplate.PSObject.Properties['CompanyName']) { [string]$script:OrgTemplate.CompanyName } else { '' }
                $docFooterM = if ($script:OrgTemplate.PSObject.Properties['DocFooter'])   { [string]$script:OrgTemplate.DocFooter }   else { '' }
                if (-not [string]::IsNullOrWhiteSpace($companyM) -or -not [string]::IsNullOrWhiteSpace($docFooterM)) {
                    $cfg | Add-Member -NotePropertyName Branding -NotePropertyValue ([pscustomobject]@{
                        CompanyName = $companyM
                        DocFooter   = $docFooterM
                    }) -Force
                }
            }

            $null = Set-Win32ToolkitAppConfig -ProjectPath $projectFullPath -Config $cfg
            Write-Host '✓ Wrote SupportFiles\AppConfig.json' -ForegroundColor Green

            # Declare Intune app dependencies (data-only) now that AppConfig.json exists. They are resolved to
            # real Intune app ids at publish time, and staged into the test/capture guest so the run installs
            # them BEFORE this app — the same order Intune uses on a device.
            if ($DependsOn) {
                $declared = Set-Win32ToolkitAppDependency -ProjectPath $projectFullPath -DependsOn $DependsOn -DependencyType $DependencyType
                Write-Host "✓ Dependencies   : $((@($declared) | ForEach-Object { "$($_.Source):$($_.Ref)" }) -join ', ')" -ForegroundColor Green
            }

            # MSIX/APPX: identity-driven uninstall data, written at configure time (capture-independent).
            if ($isAppx) {
                if (-not (Update-PSADTMsixUninstallLogic -ProjectPath $projectFullPath)) {
                    Write-Warning 'MSIX uninstall data could not be written — the package would have no working uninstall.'
                }
            }

            # ── Patch deploy script. Hard app = manual install region; uninstall always automated.
            #    Only an EXE without silent args is hard (nothing to run automatically) — MSI uses
            #    Zero-Config and msix/appx install via Add-AppxPackage/provisioning, no switches needed.
            #    Critical generator problems throw W32T.* (propagated); $false = written and valid, with warnings.
            $manual = [bool]$Advanced -or ($fileInfo.Type -eq 'exe' -and [string]::IsNullOrWhiteSpace($SilentArgs))
            $patched = Set-PSADTDataDrivenScript -ScriptPath (Join-Path $projectFullPath 'Invoke-AppDeployToolkit.ps1') -ManualInstall:$manual
            if ($patched) {
                Write-Host ("✓ Deploy script patched ({0})" -f ($(if ($manual) { 'manual install region' } else { 'data-driven install' }))) -ForegroundColor Green
            }
            else {
                Write-Warning 'Deploy-script patching did not complete cleanly (see warnings above) — review the project before packaging.'
            }

            # ── Org template ──────────────────────────────────────────────────────────
            if ($script:OrgTemplate) {
                Write-Verbose 'Applying org template...'
                if (-not (Apply-OrgTemplate -ProjectPath $projectFullPath -Template $script:OrgTemplate -BasePath $BasePath)) {
                    throw [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new('The org template could not be applied - the project was NOT finalised, tested, packaged or published (see the warnings above).'),
                        'W32T.PipelineAborted', [System.Management.Automation.ErrorCategory]::InvalidResult, $projectFullPath)
                }
            }

            # Prior-install rules (installer-identity PR 3, spec 2.13): the rebuilt version's own (L4), else those of the
            # highest earlier version of this app and architecture (L5), re-checked against this package.
            $null = Copy-Win32ToolkitPriorInstallState -ProjectPath $projectFullPath -Snapshot $priorSnapshot
        }
        catch {
            # Every error between the scaffold and the end of the configure step leaves a half-built folder: mark it
            # (G4), then re-throw it unchanged (W32T.* and non-W32T alike; the outer catch decides as before).
            if ($markStage -ne 'Done') {
                $markId = if ([string]$_.FullyQualifiedErrorId -like 'W32T.*') { [string]$_.FullyQualifiedErrorId } else { '' }
                Write-Win32ToolkitNotConfiguredMarker -ProjectPath $projectFullPath -Stage $markStage -ErrorId $markId -Reason $_.Exception.Message
            }
            throw
        }

        # ── Optional icon ─────────────────────────────────────────────────────────
        if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
            $assets = Join-Path $projectFullPath 'Assets'
            if (-not (Test-Path $assets)) { New-Item -Path $assets -ItemType Directory -Force | Out-Null }
            Copy-Item -LiteralPath $IconPath -Destination (Join-Path $assets 'AppIcon.png') -Force
            # Record provenance so the capture-time icon reconcile (finalize) keeps this operator-supplied
            # icon over the one extracted from the install run.
            Set-Win32ToolkitIconSource -ProjectPath $projectFullPath -Source 'manual'
            Write-Host '✓ Applied custom icon' -ForegroundColor Green
        }

        Write-Host "`n✓ Manual app project created: $projectFullPath" -ForegroundColor Green
        $appInfo = [pscustomobject]@{ Name = $Name; Version = $Version; Id = $Name; Source = 'manual' }

        # ── Hard app: stop for manual authoring ───────────────────────────────────
        if ($manual) {
            Write-Host ''
            Write-Host 'HARD APP — next steps:' -ForegroundColor Yellow
            Write-Host "  1. In Invoke-AppDeployToolkit.ps1 write your install code between the" -ForegroundColor White
            Write-Host "     '## win32-toolkit:Install:manual-install' block and the 'install-done' block" -ForegroundColor White
            Write-Host "     (under '## MARK: Install' on PSADT 4.2, inside Install-ADTDeployment on 4.1):" -ForegroundColor White
            Write-Host "     $projectFullPath\Invoke-AppDeployToolkit.ps1" -ForegroundColor Gray
            Write-Host "     Fail with 'throw', never 'return'; never assign PSADT variable names." -ForegroundColor Gray
            # The label says exactly what the printed command does: pasting it never uploads by surprise (S8-F10).
            Write-Host '  2. Then finalise (auto uninstall + test):' -ForegroundColor White
            Write-Host "     Complete-Win32ToolkitManualApp -ProjectPath '$projectFullPath' -RunTest InstallUninstall" -ForegroundColor Cyan
            Write-Host '     Add -PackageIntune to build the .intunewin, or -PublishIntune to also upload it to Intune.' -ForegroundColor Gray
            $runResult.Mode = 'Advanced'
            return (Complete-Win32ToolkitRunResult -Result $runResult -Scaffolded)
        }

        # ── Easy app: finalise inline if asked ────────────────────────────────────
        $runResult.Mode = 'Easy'
        if ($Continue -or $RunTest -or $PackageIntune -or $PublishIntune -or $PublishUpdate) {
            # BasePath: the capture and every test stage 'project:' dependencies from this run's base folder.
            $finalize = @{ ProjectPath = $projectFullPath; ProjectName = $projectName; AppInfo = $appInfo; BasePath = $BasePath; Result = $runResult }
            if ($RunTest) { $finalize['RunTest'] = $RunTest }   # omit when null (ValidateSet rejects $null)
            if ($NoPublishPrompt) { $finalize['NoPublishPrompt'] = $true }   # only when set (TUI audit G5)
            Invoke-Win32ToolkitFinalize @finalize -PackageIntune:$PackageIntune -PublishIntune:$PublishIntune -PublishUpdate:$PublishUpdate
            return (Complete-Win32ToolkitRunResult -Result $runResult)
        }
        Write-Host "`nEasy app scaffolded. Finalise with:" -ForegroundColor Cyan
        Write-Host "  Complete-Win32ToolkitManualApp -ProjectPath '$projectFullPath' -RunTest InstallUninstall" -ForegroundColor Cyan
        Write-Host '  (or re-run this command with -Continue).' -ForegroundColor Gray
        Write-Host '  Add -PackageIntune to build the .intunewin, or -PublishIntune to also upload it to Intune.' -ForegroundColor Gray
        return (Complete-Win32ToolkitRunResult -Result $runResult -Scaffolded)
    }
    catch {
        # Fail-closed errors (W32T.*) reach the caller as terminating errors; the TUI shows them.
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        # Any other error: the result object says the run stopped (Status Failed), then the error is written.
        if ($runResult) {
            $runResult.Problems.Add([string]$_.Exception.Message)
            Complete-Win32ToolkitRunResult -Result $runResult -Failed
        }
        Write-Error "New-Win32ToolkitManualApp failed: $($_.Exception.Message)"
    }
    finally {
        # Clear the module-scoped org template so a stale value can't leak into the next
        # command in the same session. Runs on both success and failure. $null is the
        # cleared state the module initialises at load.
        $script:OrgTemplate = $null
    }
}
