function New-Win32ToolkitManualApp {
<#
.SYNOPSIS
    Creates a Win32 packaging project for an app that is NOT in winget.
.DESCRIPTION
    Scaffolds a PSADT v4 project from an operator-supplied installer, applies the org template, and
    writes the data-driven AppConfig.json — the same downstream automation (sandbox capture →
    uninstall, testing, packaging, upload) used by the winget flow then applies.

    Input is hybrid: pass what you can as parameters; you are prompted for any missing required field
    (Name, Version, Architecture, SourcePath).

    Two modes:
    - Easy  — provide -SilentArgs, or an MSI (installed by PSADT's Zero-Config block: the PSADT 4.1.x
              default template, or the PSADT 4.2 template scaffolded with New-ADTTemplate -ZeroConfig),
              or an MSIX/APPX package (installed via Add-AppxPackage/provisioning, uninstalled by package
              identity): the install runs data-driven. Add -Continue (or -RunTest/-PackageIntune/
              -PublishIntune) to finalise.
    - Hard  — pass -Advanced (or an EXE with no -SilentArgs): in Invoke-AppDeployToolkit.ps1 write your
              install code between the '## win32-toolkit:Install:manual-install' block and the
              'install-done' block (under '## MARK: Install' on PSADT 4.2, inside Install-ADTDeployment on
              PSADT 4.1). Fail with 'throw', never 'return'; never assign PSADT variable names. The
              uninstall stays automated. Finish later with Complete-Win32ToolkitManualApp.

    Fails closed: when the project cannot be created, its deploy script uses a template layout this
    version does not support, or the org template cannot be applied, the command stops with a
    terminating error. A project folder that was created but not configured (no installer found, a refused
    configuration, any error before the org template is applied) is kept and marked not configured
    (Documentation\NotConfigured.json): Export-Win32ToolkitIntuneWin and Publish-Win32ToolkitIntuneApp
    refuse it (W32T.ProjectNotConfigured) until the app is packaged again.

    Returns a result object (Win32Toolkit.RunResult): ProjectPath, ProjectName and Mode (Easy or Advanced)
    as before, plus Status (Succeeded, CompletedWithProblems, Failed, or Scaffolded when the project still
    has to be finished with Complete-Win32ToolkitManualApp), the capture state, the test verdicts, the
    package built, the apps published and one plain sentence per problem. A W32T.* error is thrown
    instead and no object is returned.
.PARAMETER Name
    Application display name (required; prompted if omitted).
.PARAMETER Version
    Application version (required; prompted if omitted).
.PARAMETER Architecture
    x64 | x86 | arm64 (required; prompted if omitted).
.PARAMETER SourcePath
    Installer file, or a folder of files, copied into the project's Files\ folder (required).
.PARAMETER Publisher
    Publisher / vendor (used for the PSADT AppVendor and the Intune app-shell publisher).
.PARAMETER Description
    App description (Intune app shell).
.PARAMETER InformationUrl
    Information URL (Intune app shell).
.PARAMETER SilentArgs
    Silent-install switches. Providing them selects the "easy" (data-driven) install.
.PARAMETER IconPath
    Optional local image copied to Assets\AppIcon.png.
.PARAMETER TemplateName
    Org template to apply (under <BasePath>\Templates).
.PARAMETER BasePath
    Base folder (registry-backed default; prompts on first run).
.PARAMETER Reconfigure
    Re-prompt for the base folder and save the new value to the registry, ignoring any stored value.
.PARAMETER Advanced
    Hard app — leave the Install region for manual authoring.
.PARAMETER Force
    Overwrite an existing project folder of the same name without prompting.
.PARAMETER Continue
    Easy app — run the finalize phase (sandbox capture → uninstall → optional test/package/publish) inline.
.PARAMETER RunTest
    Test scenario(s) to run during the finalize phase: 'InstallUninstall', 'Update', or both. Implies
    -Continue behavior for easy apps.
.PARAMETER PackageIntune
    Package the project into a .intunewin during the finalize phase.
.PARAMETER PublishIntune
    Upload the packaged app to Microsoft Intune during the finalize phase (implies packaging).
.PARAMETER PublishUpdate
    Also publish the UPDATE app (a second, requirement-gated Intune app of the same version).
.PARAMETER DependsOn
    Dependencies to declare: 'winget:<Id>', 'project:<Template>\<Name>', or 'intune:<AppGuid>'
    references. Installed first in the test guest and related to the Intune app at publish time.
    The references are checked before anything is created (their form even before any prompt): a
    'project:' reference that is not exactly '<Template>\<Name>', an 'intune:' reference that is not a
    GUID, or a reference to the app being built stops the command with the terminating error
    W32T.InvalidDependencyReference.
.PARAMETER DependencyType
    How Intune treats the declared dependencies: 'autoInstall' (default) or 'detect'.
.PARAMETER NoPublishPrompt
    With -PackageIntune and neither -PublishIntune nor -PublishUpdate, do not ask 'Upload to Microsoft
    Intune now? (Y/N)' after packaging. The menu always passes it: it asks about publishing itself.
.EXAMPLE
    # Easy app, end to end
    New-Win32ToolkitManualApp -Name 'Acme Tool' -Version '3.1.0' -Architecture x64 `
        -SourcePath 'C:\src\AcmeTool.exe' -SilentArgs '/S' -Publisher 'Acme' -TemplateName 'Contoso' `
        -Continue -RunTest InstallUninstall -PublishIntune
.EXAMPLE
    # Hard app — scaffold, then finish after editing the Install region
    New-Win32ToolkitManualApp -Name 'Legacy CAD' -Version '12.0' -Architecture x64 `
        -SourcePath 'C:\src\LegacyCAD\' -Advanced -TemplateName 'Contoso'
    Complete-Win32ToolkitManualApp -ProjectPath 'C:\Win32Apps\Projects\Contoso\Legacy_CAD_x64_12.0' -RunTest InstallUninstall
.EXAMPLE
    # Scripted: finish the project only when the scaffold worked (check .Status, not the object)
    $r = New-Win32ToolkitManualApp -Name 'Legacy CAD' -Version '12.0' -Architecture x64 -SourcePath 'C:\src\LegacyCAD\' -Advanced -TemplateName 'Contoso'
    if ($r.Status -eq 'Scaffolded') { Complete-Win32ToolkitManualApp -ProjectPath $r.ProjectPath -RunTest InstallUninstall }
.OUTPUTS
    Win32Toolkit.RunResult: Command, ProjectPath, ProjectName, Mode (Easy, Advanced; empty when the command
    stopped before the scaffold), Status (Succeeded, CompletedWithProblems, Failed or Scaffolded), Capture
    (Done, Problems or NotRun), Tests ({ Scenario; Verdict }), IntuneWinPath, Published and Problems. A W32T.*
    error is thrown instead and no object is returned. Check .Status, not whether an object came back: a
    failed run that stopped on a non-W32T error returns an object with Status Failed (and writes the error).
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
