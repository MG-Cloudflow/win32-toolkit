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
    - Easy  — provide -SilentArgs, or an MSI (Zero-Config), or an MSIX/APPX package (installed via
              Add-AppxPackage/provisioning, uninstalled by package identity): the install runs
              data-driven. Add -Continue (or -RunTest/-PackageIntune/-PublishIntune) to finalise.
    - Hard  — pass -Advanced (or an EXE with no -SilentArgs): the Install region of
              Invoke-AppDeployToolkit.ps1 is left for you to author. The uninstall stays automated.
              Finish later with Complete-Win32ToolkitManualApp.

    See knowledge-base/designs/manual-app-packaging.md.
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
.PARAMETER Advanced
    Hard app — leave the Install region for manual authoring.
.PARAMETER Continue
    Easy app — run the finalize phase (sandbox capture → uninstall → optional test/package/publish) inline.
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
        [string]$DependencyType = 'autoInstall'
    )

    try {
        Write-Host 'Manual Win32 App Packager (non-winget)' -ForegroundColor Cyan
        Write-Host '======================================' -ForegroundColor Cyan

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
        if (-not (Test-Path $projectsDir)) { New-Item -Path $projectsDir -ItemType Directory -Force | Out-Null }

        Write-Host "Template folder: $templateSeg" -ForegroundColor DarkGray
        Write-Host "Project name   : $projectName" -ForegroundColor Cyan

        if (-not (Create-PSADTProject -ProjectName $projectName -ProjectPath $projectsDir -Force:$Force)) {
            throw 'Failed to create PSADT project.'
        }
        $projectFullPath = Join-Path $projectsDir $projectName
        $filesPath       = Join-Path $projectFullPath 'Files'

        # ── Copy installer + detect type ──────────────────────────────────────────
        Add-Win32ToolkitInstallerFiles -SourcePath $SourcePath -FilesPath $filesPath | Out-Null
        $fileInfo = Get-InstallerFileInfo -FilesPath $filesPath
        if (-not $fileInfo.FileName) { throw "No installer (msi/exe/msix/appx) detected in: $filesPath" }
        Write-Host "Installer      : $($fileInfo.FileName) ($($fileInfo.Type.ToUpper()))" -ForegroundColor Green

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
        Set-Win32ToolkitAppConfig -ProjectPath $projectFullPath -Config $cfg | Out-Null
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
        $manual = [bool]$Advanced -or ($fileInfo.Type -eq 'exe' -and [string]::IsNullOrWhiteSpace($SilentArgs))
        $patched = Set-PSADTDataDrivenScript -ScriptPath (Join-Path $projectFullPath 'Invoke-AppDeployToolkit.ps1') -ManualInstall:$manual
        if ($patched) {
            Write-Host ("✓ Deploy script patched ({0})" -f ($(if ($manual) { 'manual install region' } else { 'data-driven install' }))) -ForegroundColor Green
        }
        else {
            Write-Warning 'Deploy-script patching did not complete cleanly (see warnings above) — review the project before packaging.'
        }

        # ── Org template + optional icon ──────────────────────────────────────────
        if ($script:OrgTemplate) {
            Write-Verbose 'Applying org template...'
            Apply-OrgTemplate -ProjectPath $projectFullPath -Template $script:OrgTemplate | Out-Null
        }
        if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
            $assets = Join-Path $projectFullPath 'Assets'
            if (-not (Test-Path $assets)) { New-Item -Path $assets -ItemType Directory -Force | Out-Null }
            Copy-Item -LiteralPath $IconPath -Destination (Join-Path $assets 'AppIcon.png') -Force
            Write-Host '✓ Applied custom icon' -ForegroundColor Green
        }

        Write-Host "`n✓ Manual app project created: $projectFullPath" -ForegroundColor Green
        $appInfo = [pscustomobject]@{ Name = $Name; Version = $Version; Id = $Name; Source = 'manual' }

        # ── Hard app: stop for manual authoring ───────────────────────────────────
        if ($manual) {
            Write-Host ''
            Write-Host 'HARD APP — next steps:' -ForegroundColor Yellow
            Write-Host "  1. Edit the Install region in:" -ForegroundColor White
            Write-Host "     $projectFullPath\Invoke-AppDeployToolkit.ps1" -ForegroundColor Gray
            Write-Host '     (write your Pre-Install / Install / Post-Install logic).' -ForegroundColor Gray
            Write-Host '  2. Then finalise (auto uninstall + test + package + upload):' -ForegroundColor White
            Write-Host "     Complete-Win32ToolkitManualApp -ProjectPath '$projectFullPath' -RunTest InstallUninstall" -ForegroundColor Cyan
            return [pscustomobject]@{ ProjectPath = $projectFullPath; ProjectName = $projectName; Mode = 'Advanced' }
        }

        # ── Easy app: finalise inline if asked ────────────────────────────────────
        if ($Continue -or $RunTest -or $PackageIntune -or $PublishIntune -or $PublishUpdate) {
            $finalize = @{ ProjectPath = $projectFullPath; ProjectName = $projectName; AppInfo = $appInfo }
            if ($RunTest) { $finalize['RunTest'] = $RunTest }   # omit when null (ValidateSet rejects $null)
            Invoke-Win32ToolkitFinalize @finalize -PackageIntune:$PackageIntune -PublishIntune:$PublishIntune -PublishUpdate:$PublishUpdate
        }
        else {
            Write-Host "`nEasy app scaffolded. Finalise with:" -ForegroundColor Cyan
            Write-Host "  Complete-Win32ToolkitManualApp -ProjectPath '$projectFullPath' -RunTest InstallUninstall" -ForegroundColor Cyan
            Write-Host '  (or re-run this command with -Continue).' -ForegroundColor Gray
        }
        return [pscustomobject]@{ ProjectPath = $projectFullPath; ProjectName = $projectName; Mode = 'Easy' }
    }
    catch {
        Write-Error "New-Win32ToolkitManualApp failed: $($_.Exception.Message)"
    }
    finally {
        # Clear the module-scoped org template so a stale value can't leak into the next
        # command in the same session. Runs on both success and failure. $null is the
        # cleared state the module initialises at load.
        $script:OrgTemplate = $null
    }
}
