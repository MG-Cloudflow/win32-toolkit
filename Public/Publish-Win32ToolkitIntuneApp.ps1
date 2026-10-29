function Publish-Win32ToolkitIntuneApp {
<#
.SYNOPSIS
    Uploads a .intunewin package to Intune as a new Win32 app.
.DESCRIPTION
    Publish-Win32ToolkitIntuneApp uploads a .intunewin package to Microsoft Intune as a new Win32
    app. It takes the app name, version and settings from the project. Every publish creates a
    new app and never changes an older one.

    Use it for a package that you built before. Export-Win32ToolkitIntuneWin -PublishIntune builds
    and publishes in one step, so the package always matches the project. In the menu: Work with
    an existing project > Publish to Intune. The menu builds the package again before it publishes.

    The command checks the project and shows warnings before it signs in. These warnings appear
    once per action: Export-Win32ToolkitIntuneWin -PublishIntune -PublishUpdate prints them once.
    A warning also comes on every publish when the maximum run time
    (IntuneDefaults.MaxRuntimeMinutes in the org template) is 30 minutes or less. Keep it above 30
    minutes: the uninstall stops an EXE uninstaller after 30 minutes.

    If you are not signed in, it signs you in and saves the sign-in on disk. Run
    Connect-Win32ToolkitIntune first to keep the sign-in in this PowerShell window only. If the
    project has the tenant ID of its org template, the command refuses any other tenant before it
    creates the app. Without a tenant ID, it only warns.

    In the project, the command writes only Intune\Publications.json, the record of the install
    app. With -AsUpdate, it writes SupportFiles\UpdateRequirement.ps1 instead. win32-toolkit never
    assigns an app. You assign it in the Intune admin center.

    If an error stops the command after the line "App created", an incomplete app stays in
    Intune. Delete it in the Intune admin center, fix the cause and publish again.

    It stops with an error whose ID starts with W32T. when it cannot publish safely, before it
    signs in. W32T.ProjectNotConfigured means that the project build stopped halfway: re-create
    the project. W32T.PackageNotReady means that the package does not match the prior-install
    rules of the project: build it again. W32T.NoDetectionRule means that no detection rule can
    be built.
.PARAMETER IntuneWinPath
    The package to upload: <base folder>\IntuneWin\<template>\<project>.intunewin. It must be
    built from the project in -ProjectPath. Apart from prior-install rules, the command does not
    check this. If the command says that Detection.xml is missing, the file is not a valid package.
.PARAMETER ProjectPath
    The project that the package was built from: <base folder>\Projects\<template>\<project>.
    Never give the Staging copy. It has no install capture (the record of what the installer
    changed) and no test results.
.PARAMETER AsUpdate
    Publishes the update app: a second app of the same version, only for devices that already
    have the app. Its name ends with " (Update)". The command stops if the project gives no sign
    that the app is installed. Such a sign is the install tattoo (a registry value that the
    package writes), the MSI UpgradeCode or the app name.
.PARAMETER UpdateNameSuffix
    The text added to the name of the update app. Default: " (Update)", with a space first.
    Command line only: the menu and Export-Win32ToolkitIntuneWin always use the default.
.PARAMETER TimeoutSeconds
    How many seconds to wait for Intune at two points of the upload: for the upload address, and
    for the check of the uploaded file. Default: 300 (from 5 to 7200). Raise it, for example to
    900, for a very large package or a slow tenant. Command line only: the menu does not offer
    this.
.PARAMETER AllowNoDetectionRule
    Publishes the app even if no detection rule can be built: the project has no install tattoo
    and no usable install capture. Add a detection rule in the Intune admin center before you
    assign the app. Use it only for per-user apps and some MSIX packages. Command line only: the
    menu does not offer this.
.EXAMPLE
    $file = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'           # its project folder
    Publish-Win32ToolkitIntuneApp -IntuneWinPath $file -ProjectPath $project

    This signs you in if needed and publishes the package as a new install app. At the end, it
    prints the app ID and a link to the app in the Intune admin center.
.EXAMPLE
    $file = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'           # its project folder
    Publish-Win32ToolkitIntuneApp -IntuneWinPath $file -ProjectPath $project -WhatIf

    This runs every check that needs no sign-in and shows the warnings. It does not sign in and
    changes nothing.
.EXAMPLE
    $file = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'           # its project folder
    Publish-Win32ToolkitIntuneApp -IntuneWinPath $file -ProjectPath $project -AsUpdate

    This publishes the update app, a second app whose name ends with " (Update)". Intune installs
    it only on devices that already have the app.
.EXAMPLE
    $file = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'   # your package
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'           # its project folder
    Publish-Win32ToolkitIntuneApp -IntuneWinPath $file -ProjectPath $project -AllowNoDetectionRule

    This publishes the app without a detection rule. Add a detection rule in the Intune admin
    center before you assign the app.
.EXAMPLE
    Connect-Win32ToolkitIntune -Template 'Contoso' -Force -ErrorAction Stop
    $file = 'C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin'
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
    $app = Publish-Win32ToolkitIntuneApp -IntuneWinPath $file -ProjectPath $project
    $app.PortalUri

    This is the form for scripts. It signs in to the Contoso tenant first, so the sign-in stays in
    this PowerShell window. $app holds the app ID and the link to the app.
.OUTPUTS
    An object with AppId, DisplayName, IsUpdateApp and PortalUri.
    PortalUri is the link to the app in the Intune admin center.
    With -WhatIf, or when an error stops the command, it returns nothing.
.NOTES
    Needs: the Microsoft.Graph.Authentication module and an account that may create apps in
    Intune. In a script, run Connect-Win32ToolkitIntune -Force first to install the module. Time:
    usually a few minutes, longer for big packages.
.LINK
    https://win32toolkit.com/reference/Publish-Win32ToolkitIntuneApp/
.LINK
    https://win32toolkit.com/publishing/
.LINK
    https://win32toolkit.com/intune-connection/
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]   # { AppId; DisplayName; IsUpdateApp; PortalUri } — see the Summary block
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntuneWinPath,

        [Parameter(Mandatory = $true)]
        [string]$ProjectPath,

        # Publish this as the "update" app: a second Intune app of the same version whose requirement
        # rule (a PowerShell presence check) makes it applicable ONLY to devices that already have the
        # app — so it updates existing installs without installing on machines that shouldn't have it.
        [switch]$AsUpdate,

        # Display-name suffix that distinguishes the update app from the install app.
        [string]$UpdateNameSuffix = ' (Update)',

        # Timeout for the two asynchronous Intune waits (SAS URI, file commit). See the help above for
        # why the default is 300 s and not the 60 s these loops were previously hardcoded to.
        [ValidateRange(5, 7200)]
        [int]$TimeoutSeconds = 300,

        # Publish with an EMPTY detection-rule list instead of refusing (PKG-04). Only for apps no tattoo
        # or capture can describe; add the rule in the Intune portal before assigning the app.
        [switch]$AllowNoDetectionRule
    )

    $baseUri  = 'https://graph.microsoft.com/beta/deviceAppManagement'
    $tempFile = $null
    # Advisory run scope (L20): when Export-Win32ToolkitIntuneWin (or the TUI) already opened one, the
    # package advisory it printed is not repeated here; a standalone publish opens and closes its own.
    $ownsAdvisoryRun = $null -eq $script:W32TAdvisoryRun
    if ($ownsAdvisoryRun) { $script:W32TAdvisoryRun = @{} }

    try {
        # ── Validate inputs ───────────────────────────────────────────────────────
        if (-not (Test-Path $IntuneWinPath)) { throw "IntuneWin file not found: $IntuneWinPath" }
        if (-not (Test-Path $ProjectPath))   { throw "Project path not found: $ProjectPath" }
        # A project marked not configured (TUI audit G4, S10-F2) is refused before any metadata read, the package
        # advisory and the Graph sign-in: W32T.ProjectNotConfigured, no override.
        Assert-Win32ToolkitProjectConfigured -ProjectPath $ProjectPath -Operation Publish

        Write-Host ''
        Write-Host 'Intune App Upload' -ForegroundColor Cyan
        Write-Host '=================' -ForegroundColor Cyan

        # ── App metadata (AppConfig.json first, winget YAML fallback) ─────────────
        $projectName = Split-Path $ProjectPath -Leaf
        $filesPath   = Join-Path $ProjectPath 'Files'

        $appCfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $app    = if ($appCfg.PSObject.Properties.Name -contains 'App') { $appCfg.App } else { $null }

        # ── Prior-install rules (installer-identity PR 3, L40) ────────────────────
        # First, before the update requirement and the -WhatIf gate (no sign-in needed): a package whose rules are not
        # the ones Export checked (changed after Export, or no Staging copy to compare) is refused: W32T.PackageNotReady.
        $null = Assert-Win32ToolkitPriorInstallPackaged -ProjectPath $ProjectPath -IntuneWinPath $IntuneWinPath
        $priorRules = @(@(if ($appCfg.PSObject.Properties.Name -contains 'PriorInstalls' -and $appCfg.PriorInstalls -and $appCfg.PriorInstalls.PSObject.Properties['Entries']) { $appCfg.PriorInstalls.Entries }) |
            Where-Object { $null -ne $_ })
        $priorEnforce = @($priorRules | Where-Object { [string]$_.Mode -ceq 'Enforce' })
        # The prior-install refusals and failures the app registers as 'failed' (L17): 69103 is only logged (the install
        # goes on) and 1618 (busy, the prior app still running) stays 'retry'.
        $priorFailCodes = [int[]]@(69101, 69102, 69105, 69106, 69107, 69108, 69109, 69110, 69111, 69112)

        # Every manifest field comes from Get-YAMLInstallerInfo, which reads the RIGHT file per field (the
        # description/URL live in the *.locale* manifest, not the installer manifest). This block used to grab
        # the alphabetically-first *.yaml — always the installer manifest — so the Intune app's description and
        # information URL silently published as empty strings.
        $yamlInfo = Get-YAMLInstallerInfo -FilesPath $filesPath

        $displayName = if     ($app -and $app.Name)                      { $app.Name }
                       elseif ($yamlInfo -and $yamlInfo.PackageName)     { $yamlInfo.PackageName }
                       else                                              { $projectName }
        $publisher   = if     ($app -and $app.Vendor)                    { $app.Vendor }
                       elseif ($yamlInfo -and $yamlInfo.Publisher)       { $yamlInfo.Publisher }
                       else                                              { 'Unknown' }
        $displayVersion = if     ($app -and $app.Version)                { $app.Version }
                          elseif ($yamlInfo -and $yamlInfo.PackageVersion) { $yamlInfo.PackageVersion }
                          else                                           { '' }
        $description = if     ($app -and $app.Description)               { $app.Description }
                       elseif ($yamlInfo -and $yamlInfo.Description)     { $yamlInfo.Description }
                       else                                              { '' }
        $informationUrl = if     ($app -and $app.InformationUrl)         { $app.InformationUrl }
                          elseif ($yamlInfo -and $yamlInfo.InformationUrl) { $yamlInfo.InformationUrl }
                          else                                           { '' }

        $wingetId = ''
        if ($yamlInfo -and $yamlInfo.PackageIdentifier) { $wingetId = $yamlInfo.PackageIdentifier }

        # ── Org-template Intune defaults (D2/D3) ──────────────────────────────────
        # Persisted into AppConfig at configure time (Configure-PSADTForInstaller) from the active org
        # template. When absent — no template, or a pre-3.0 project — every value falls back to the exact
        # built-in default, so non-template projects publish byte-identically to before.
        $intuneDefaults = if ($appCfg.PSObject.Properties.Name -contains 'IntuneDefaults') { $appCfg.IntuneDefaults } else { $null }
        function Get-Win32ToolkitIntuneDefault {
            param([string]$Name, $Fallback)
            if ($intuneDefaults -and ($intuneDefaults.PSObject.Properties.Name -contains $Name) -and
                -not [string]::IsNullOrWhiteSpace([string]$intuneDefaults.$Name)) { return $intuneDefaults.$Name }
            return $Fallback
        }
        $minWinRelease   = [string](Get-Win32ToolkitIntuneDefault 'MinimumWindowsRelease' '1607')
        $restartBehavior = [string](Get-Win32ToolkitIntuneDefault 'DeviceRestartBehavior' 'suppress')
        $maxRuntime      = [int](Get-Win32ToolkitIntuneDefault 'MaxRuntimeMinutes' 60)
        if ($maxRuntime -le 0) { $maxRuntime = 60 }
        $privacyUrl      = [string](Get-Win32ToolkitIntuneDefault 'PrivacyUrl' '')
        $descBoilerplate = [string](Get-Win32ToolkitIntuneDefault 'DescriptionBoilerplate' '')
        if ($descBoilerplate) {
            $description = if ([string]::IsNullOrWhiteSpace($description)) { $descBoilerplate } else { "$description`n`n$descBoilerplate" }
        }

        # MSIX/APPX floor: the default 1607 predates MSIX entirely. The package format needs 1709, and
        # the -Regions 'all' the generated install uses needs 1803 — on an older device the deployment
        # would fail on a machine Intune said was applicable. 1809 clears both with margin. Only ever
        # raises the value: an org that deliberately set something higher keeps it.
        $installerType = if ($appCfg.PSObject.Properties.Name -contains 'Installer' -and $appCfg.Installer) { [string]$appCfg.Installer.Type } else { '' }
        if ($installerType -in @('msix', 'appx')) {
            $releaseOrder = @('1607', '1703', '1709', '1803', '1809', '1903', '1909', '2004', '20H2', '21H1', '21H2', '22H2')
            $curIdx  = [array]::IndexOf($releaseOrder, $minWinRelease)
            $floorIdx = [array]::IndexOf($releaseOrder, '1809')
            if ($curIdx -ge 0 -and $curIdx -lt $floorIdx) {
                Write-Verbose "MSIX/APPX package: raising minimumSupportedWindowsRelease from '$minWinRelease' to '1809' (MSIX needs 1709; provisioning with -Regions needs 1803)."
                $minWinRelease = '1809'
            }
        }

        # ── Architecture: AppConfig.App.Arch, else parse the project folder name ──
        # Published via allowedArchitectures, NOT applicableArchitectures. The older
        # applicableArchitectures is a windowsArchitecture flags enum whose members are
        # none/x86/x64/arm/neutral — 'arm64' is NOT one of them (the member is 'arm'), and its
        # documented values are only none/x86/x64. So every arm64 app this module published was sending
        # an undocumented enum value. allowedArchitectures is the modern property and documents
        # null/x86/x64/arm64; setting it makes Intune set applicableArchitectures to 'none' itself.
        $arch = 'x64'
        if     ($app -and $app.Arch)           { $arch = $app.Arch }
        elseif ($projectName -match '_x86_')   { $arch = 'x86'   }
        elseif ($projectName -match '_arm64_') { $arch = 'arm64' }
        elseif ($projectName -match '_x64_')   { $arch = 'x64'   }
        # Canonicalize case: the enum values are lower-case and the guard below is case-insensitive, so
        # an AppConfig 'X64' would otherwise pass through and be POSTed verbatim as an invalid value.
        $arch = "$arch".Trim().ToLowerInvariant()

        # Two properties, because neither covers every architecture:
        #  * allowedArchitectures documents null/x86/x64/arm64 — it is the ONLY way to express arm64.
        #  * 'neutral' and 'arm' are windowsArchitecture members but are NOT in allowedArchitectures'
        #    documented values, so they keep going out on applicableArchitectures (which is what this
        #    module always sent, and works). winget reports 'neutral' for plenty of MSIX packages, so
        #    collapsing it to x64 would silently make those apps not-applicable on x86/arm64 devices.
        $archField = 'allowedArchitectures'
        if ($arch -in @('neutral', 'arm')) {
            $archField = 'applicableArchitectures'
        }
        elseif ($arch -notin @('x86', 'x64', 'arm64')) {
            Write-Warning "Unrecognized architecture '$arch' — publishing as x64."
            $arch = 'x64'
        }

        # ── Update app: name suffix + requirement rule (applicable only where already installed) ──
        $requirementRules = @()
        $reqRule = $null
        if ($AsUpdate) {
            # -NoSave: built before the -WhatIf gate, so its plaintext copy is written only past the gate (below).
            $reqRule = Get-Win32ToolkitRequirementRule -ProjectPath $ProjectPath -NoSave
            if (-not $reqRule) {
                throw 'Update app requested, but no requirement rule could be built (AppConfig has no tattoo key, product code, or app name). Refusing to publish an update app that would apply to every device.'
            }
            $requirementRules = @($reqRule)
            $displayName      = "$displayName$UpdateNameSuffix"
        }

        Write-Host "  App name     : $displayName" -ForegroundColor Gray
        Write-Host "  Publisher    : $publisher"   -ForegroundColor Gray
        Write-Host "  Architecture : $arch"        -ForegroundColor Gray
        if ($AsUpdate) {
            Write-Host '  Mode         : UPDATE app (requirement: app already installed)' -ForegroundColor Gray
        }

        # ── Detection rules (PKG-04) ──────────────────────────────────────────────
        # Built from project files only, BEFORE the -WhatIf gate and before any Graph call: an app Intune can
        # never detect is refused up front (it would report failure on every device, or reinstall forever)
        # instead of after a sign-in and a large upload. -AllowNoDetectionRule publishes it anyway.
        Write-Verbose 'Building detection rules...'
        $detectionRules = @(Get-Win32DetectionRules -ProjectPath $ProjectPath)
        if ($detectionRules.Count -eq 0) {
            if (-not $AllowNoDetectionRule) {
                $noRuleMessage = ("No detection rule for '$displayName' - Intune could not tell whether it installed. " +
                    'win32-toolkit detects an app by its install tattoo (the deploy script writes HKLM:\SOFTWARE\<ScriptAuthor>\<Vendor>\<App>\Version; ' +
                    'needs App.ScriptAuthor, App.Vendor, App.DisplayName and App.Version in SupportFiles\AppConfig.json, i.e. an org template, and a tattoo-writing deploy script) ' +
                    'or, failing that, by the newest install capture (Documentation\InstallationChanges_*.json from the sandbox / Hyper-V test). ' +
                    'Neither is available: re-create the project with an org template, or run the install capture, then publish again. ' +
                    'To publish without a rule and add one by hand in the Intune portal (per-user or MSIX apps), call Publish-Win32ToolkitIntuneApp -AllowNoDetectionRule. ' +
                    'Nothing was published.')
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new($noRuleMessage), 'W32T.NoDetectionRule',
                    [System.Management.Automation.ErrorCategory]::InvalidData, $ProjectPath)
            }
            Write-Warning 'No detection rule could be built (-AllowNoDetectionRule): the app is created WITHOUT one. Add a detection rule in the Intune portal before assigning it.'
        }

        # ── Prerelease PSADT (F-05) ───────────────────────────────────────────────
        # Non-blocking, and before the -WhatIf gate so a dry run shows it too: a project scaffolded on a
        # PSAppDeployToolkit prerelease (e.g. 4.2.0-rc2, allowed for testing) must not reach production
        # devices unnoticed. Export warns once at packaging; every publish (standalone, or chained from
        # Export -PublishIntune / -PublishUpdate) repeats it once, naming the app it creates. A failure to
        # read the bundled module never blocks publishing.
        $psadtVersion = $null
        try { $psadtVersion = Get-Win32ToolkitProjectPsadtVersion -ProjectPath $ProjectPath }
        catch { Write-Verbose "Could not read the bundled PSAppDeployToolkit version: $($_.Exception.Message)" }
        if ($psadtVersion -and -not [string]::IsNullOrWhiteSpace([string]$psadtVersion.Prerelease)) {
            Write-Warning "'$displayName' bundles PSAppDeployToolkit $($psadtVersion.VersionText), a PRERELEASE (for testing only). Rebuild the project on a stable PSAppDeployToolkit before you assign it to production devices."
        }

        # ── Maximum run time (installer-identity PR 2 follow-up F4, D11) ──────────
        # Warn only, before the -WhatIf gate so a dry run shows it too: the uninstall stops an EXE uninstaller after
        # 30 minutes (exit code 69113); an Intune limit at or below that stops the deployment first, without that code.
        if ($maxRuntime -le 30) {
            $maxRuntimeText = if ($maxRuntime -eq 1) { '1 minute' } else { "$maxRuntime minutes" }
            Write-Warning ("'$displayName' is published with a maximum run time of $maxRuntimeText (IntuneDefaults.MaxRuntimeMinutes from the org template, copied into SupportFiles\AppConfig.json when the project was created). " +
                'The uninstall stops an EXE uninstaller after 30 minutes with exit code 69113; with an Intune limit of 30 minutes or less, Intune stops the deployment first and reports a timeout instead. ' +
                "Keep it above 30 minutes (default 60): change it in the org template and re-create the project, or change the app's maximum run time in the Intune portal. This only warns.")
        }

        # ── Package advisory (D1, L22) ────────────────────────────────────────────
        # Warn only, before the -WhatIf gate so a dry run shows it too: a failed Update test, a technology
        # switch, identity findings, and UNSAFE-CLEANUP for a package exported before the cleanup-path
        # check (Export refuses such a project; a standalone publish of an old .intunewin only warns).
        # Fail-open: nothing it calls raises W32T.*, so it can never stop a publish.
        $shownAdvisory = $null
        try {
            $shownAdvisory = Write-Win32ToolkitPackageAdvisory -ProjectPath $ProjectPath -Context Publish -AppLabel $displayName -ProbeIfMissing
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Warning "Could not check the Update test and identity warnings: $($_.Exception.Message)"
        }

        # Enforce rules remove another install as SYSTEM (installer-identity PR 3, spec 7.11): pilot first; the kill switch.
        # Once per call (live rows OP-EXPORT, GOAL-EXPORT): not again when the advisory just printed its PRIOR-ENFORCE-PILOT row.
        $pilotShown = $null -ne $shownAdvisory -and @(@($shownAdvisory.Findings) | Where-Object { $_ -and [string]$_.Code -eq 'PRIOR-ENFORCE-PILOT' -and [string]$_.Severity -eq 'Warning' }).Count -gt 0
        if ($priorEnforce.Count -gt 0 -and -not $pilotShown) {
            $markerAuthor = if ($app -and $app.ScriptAuthor) { [string]$app.ScriptAuthor } else { '<ScriptAuthor>' }
            Write-Warning ("'$displayName' removes another install of the app as SYSTEM before it installs ($($priorEnforce.Count) Enforce prior-install rule(s)): assign it to a pilot group first. " +
                "Kill switch: the DWORD RemovePriorDisabled = 1 under HKLM\SOFTWARE\$markerAuthor\win32-toolkit (set it with a 64-bit remediation script) makes devices refuse instead of removing (exit code 69111).")
        }

        # ── -WhatIf / -Confirm gate for the ENTIRE publish ────────────────────────
        # Everything from here down mutates the live tenant (auth, app shell, content version, blob upload,
        # commit) and the later steps depend on the app id from the first POST. A per-step guard is therefore
        # unsafe: skipping only step 1 under -WhatIf would still fire live requests against a null app id. Gate
        # the whole sequence once, so -WhatIf is a true dry run — no auth, no Graph writes.
        if (-not $PSCmdlet.ShouldProcess($displayName, "Publish Win32 app to Intune (version $displayVersion)")) {
            Write-Host "WhatIf: would connect to Microsoft Graph and publish '$displayName' v$displayVersion to Intune (create app shell, upload content, commit)." -ForegroundColor Yellow
            if (@($priorRules | Where-Object { [string]$_.Mode -cne 'Report' }).Count -gt 0) {
                Write-Host "WhatIf: the app would report the prior-install exit codes $($priorFailCodes -join ', ') as failed (1618 stays retry)." -ForegroundColor Yellow
            }
            return
        }

        # The update requirement's plaintext copy (SupportFiles\UpdateRequirement.ps1, for transparency), only now that the
        # publish goes ahead: a -WhatIf dry run (or a declined -Confirm) changes nothing in the project, whose SupportFiles
        # folder a prior-install proof is bound to (live rows OP-EXPORT, GOAL-EXPORT). The same bytes the rule carries.
        if ($AsUpdate -and $reqRule) {
            try {
                $reqDir = Join-Path $ProjectPath 'SupportFiles'
                if (-not (Test-Path -LiteralPath $reqDir)) { $null = New-Item -ItemType Directory -Path $reqDir -Force }
                [System.IO.File]::WriteAllBytes((Join-Path $reqDir 'UpdateRequirement.ps1'), [System.Convert]::FromBase64String([string]$reqRule['scriptContent']))
            }
            catch { Write-Verbose "Could not write UpdateRequirement.ps1: $($_.Exception.Message)" }
        }

        # ── Graph authentication ──────────────────────────────────────────────────
        # Pass the project's pinned tenant so a cached session for a DIFFERENT customer is torn down
        # and re-established rather than silently reused (see Connect-Win32ToolkitGraph).
        $pinnedTenant = ''
        if ($appCfg.PSObject.Properties.Name -contains 'Intune' -and $appCfg.Intune) { $pinnedTenant = [string]$appCfg.Intune.TenantId }
        if (-not $pinnedTenant -and $script:OrgTemplate -and $script:OrgTemplate.PSObject.Properties['TenantId']) {
            $pinnedTenant = [string]$script:OrgTemplate.TenantId
        }
        if ($pinnedTenant) { Connect-Win32ToolkitGraph -TenantId $pinnedTenant } else { Connect-Win32ToolkitGraph }

        # THE POINT OF NO RETURN. Everything below writes to a customer's tenant, so verify which one
        # BEFORE the app shell is created. A pinned mismatch throws here rather than uploading.
        $tenantCheck = Assert-Win32ToolkitTenant -ProjectPath $ProjectPath -Operation 'publish'
        $tenantLabel = if ($tenantCheck.DisplayName) { "$($tenantCheck.DisplayName) ($($tenantCheck.TenantId))" } else { $tenantCheck.TenantId }
        Write-Host "  Tenant       : $tenantLabel" -ForegroundColor Gray

        # Apps of this tenant that would fight the removal (installer-identity PR 3, D23, D29, L29): Enforce rules only,
        # after the sign-in and the tenant check, before anything is created. Warnings only; fail-open.
        if ($priorEnforce.Count -gt 0) {
            foreach ($conflict in @(Get-Win32ToolkitPriorConflict -ProjectPath $ProjectPath -BaseUri $baseUri)) { Write-Warning ([string]$conflict.Message) }
        }

        # ── Extract .intunewin metadata ───────────────────────────────────────────
        Write-Verbose 'Extracting .intunewin metadata...'
        $meta = Get-Win32IntuneWinMetadata -IntuneWinPath $IntuneWinPath
        Write-Host "  ✓ Unencrypted : $([math]::Round($meta.UnencryptedSize / 1MB, 2)) MB" -ForegroundColor Gray
        Write-Host "  ✓ Encrypted  : $([math]::Round($meta.SizeEncrypted   / 1MB, 2)) MB" -ForegroundColor Gray

        # ── Step 1: Create app shell ──────────────────────────────────────────────
        Write-Verbose 'Creating app in Intune...'

        # Command lines come from ONE helper (also used by Export-Win32ToolkitDocumentation): PSADT's AnyCPU
        # launcher, so the 32-bit Intune Management Extension can never start a 32-bit PowerShell (PSADT 4.2
        # exits 60008 there; PSADT 4.1 writes its tattoo to WOW6432Node). The setup file stays the .ps1.
        $intuneCommandLine = Get-Win32ToolkitIntuneCommandLine

        $appBody = @{
            '@odata.type'                      = '#microsoft.graph.win32LobApp'
            'displayName'                      = $displayName
            'displayVersion'                   = $displayVersion
            'description'                      = $description
            'publisher'                        = $publisher
            'informationUrl'                   = $informationUrl
            'privacyInformationUrl'            = $privacyUrl
            'notes'                            = (@('win32-toolkit'; if ($AsUpdate) { 'update' }; if ($wingetId) { $wingetId }) | Where-Object { $_ }) -join '; '
            'isFeatured'                       = $false
            'fileName'                         = $intuneCommandLine.Script
            'setupFilePath'                    = $intuneCommandLine.Script
            'installCommandLine'               = $intuneCommandLine.Install
            'uninstallCommandLine'             = $intuneCommandLine.Uninstall
            $archField                         = $arch
            'minimumSupportedWindowsRelease'   = $minWinRelease
            'msiInformation'                   = $null
            'installExperience' = @{
                'runAsAccount'          = 'system'
                'deviceRestartBehavior' = $restartBehavior
                'maxRunTimeInMinutes'   = $maxRuntime
            }
            'returnCodes' = @(
                @{ 'returnCode' = 0;    'type' = 'success'    }
                @{ 'returnCode' = 1707; 'type' = 'success'    }
                @{ 'returnCode' = 3010; 'type' = 'softReboot' }
                @{ 'returnCode' = 1641; 'type' = 'hardReboot' }
                @{ 'returnCode' = 1618; 'type' = 'retry'      }
            ) + @(
                # The prior-install refusals and failures (installer-identity PR 3, L17): Intune reports them as failed.
                foreach ($priorCode in $priorFailCodes) { @{ 'returnCode' = $priorCode; 'type' = 'failed' } }
            )
            'detectionRules'   = @($detectionRules)
            'requirementRules' = @($requirementRules)
        }

        # ── App tile icon (largeIcon) ─────────────────────────────────────────────
        # Attach Assets\AppIcon.png as the Intune tile icon. Bytes are normalized to a genuine PNG
        # (Get-Win32ToolkitLargeIconBytes → ConvertTo-Win32ToolkitPngBytes); with no usable icon we omit
        # largeIcon and Intune shows the generic tile. This is the ONLY place an icon reaches Intune —
        # before this, Assets\AppIcon.png (winget / manual / captured-from-install) only fed PSADT's
        # on-device dialogs and never appeared on the app tile.
        $largeIconBytes = Get-Win32ToolkitLargeIconBytes -ProjectPath $ProjectPath
        if ($largeIconBytes) {
            $appBody['largeIcon'] = [ordered]@{
                '@odata.type' = '#microsoft.graph.mimeContent'
                'type'        = 'image/png'
                'value'       = [System.Convert]::ToBase64String($largeIconBytes)
            }
            Write-Host "  Icon         : Assets\AppIcon.png ($([math]::Round($largeIconBytes.Length / 1KB, 1)) KB)" -ForegroundColor Gray
        }
        else {
            Write-Verbose 'No usable Assets\AppIcon.png — publishing without largeIcon (Intune shows the generic tile).'
        }

        # Resolve declared dependencies to real Intune app ids BEFORE creating the app shell and uploading
        # the blob — a missing dependency should be reported up front, not after a 200 MB upload. Any that
        # cannot be resolved are WARNED about and skipped: the app still publishes (nothing is ever
        # auto-published into the tenant as a side effect). Dependencies attach to the INSTALL app only —
        # the "(Update)" app is requirement-gated to devices that already have the app, and therefore the
        # dependency, so relating it would only make it undeletable.
        $resolvedDeps = @()
        if (-not $AsUpdate) {
            $tenantForResolve = try { (Get-MgContext).TenantId } catch { 'unknown' }
            $resolvedDeps = @(Resolve-Win32ToolkitDependencies -ProjectPath $ProjectPath -TenantId $tenantForResolve -BaseUri $baseUri)
        }

        # The whole publish is already gated by the single ShouldProcess check above, so this POST runs
        # unconditionally here (guarding it again would risk a null-appId cascade under -WhatIf).
        $appResponse = Invoke-MgGraphRequest -Method POST -Uri "$baseUri/mobileApps" `
            -Body ($appBody | ConvertTo-Json -Depth 10) -ContentType 'application/json' -OutputType PSObject
        $appId = $appResponse.id
        Write-Host "  ✓ App created: $appId" -ForegroundColor Green

        # ── Step 2: Create content version ────────────────────────────────────────
        Write-Verbose 'Creating content version...'
        $versionResponse = Invoke-MgGraphRequest -Method POST `
            -Uri "$baseUri/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions" `
            -Body @{} -OutputType PSObject
        $versionId = $versionResponse.id
        Write-Host "  ✓ Version: $versionId" -ForegroundColor Green

        # ── Step 3: Create file entry ─────────────────────────────────────────────
        Write-Verbose 'Registering file entry...'
        $fileBody = [ordered]@{
            '@odata.type'   = '#microsoft.graph.mobileAppContentFile'
            'name'          = [System.IO.Path]::GetFileName($IntuneWinPath)
            'size'          = [int64]$meta.UnencryptedSize
            'sizeEncrypted' = [int64]$meta.SizeEncrypted
            'manifest'      = $null
            'isDependency'  = $false
        }

        $fileUri      = "$baseUri/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$versionId/files"
        $fileResponse = Invoke-MgGraphRequest -Method POST -Uri $fileUri -Body ($fileBody | ConvertTo-Json -Depth 5) -ContentType 'application/json' -OutputType PSObject
        $fileId       = $fileResponse.id
        $fileUri      = "$fileUri/$fileId"
        Write-Host "  ✓ File entry: $fileId" -ForegroundColor Green

        # ── Step 4: Poll for Azure Storage SAS URI ────────────────────────────────
        # Both async waits (here and the commit below) go through the SAME helper, so their timeout and
        # back-off behaviour cannot drift apart.
        Write-Verbose "Waiting for Azure Storage SAS URI (timeout ${TimeoutSeconds}s)..."
        $poll = Wait-Win32ToolkitUploadState -FileUri $fileUri `
            -TargetState 'azureStorageUriRequestSuccess' `
            -Activity 'the Azure Storage SAS URI' `
            -TimeoutSeconds $TimeoutSeconds
        $sasUri = $poll.azureStorageUri
        if (-not $sasUri) { throw 'Intune reported azureStorageUriRequestSuccess but returned no azureStorageUri.' }
        Write-Host '  ✓ SAS URI received.' -ForegroundColor Green

        # ── Step 5: Extract inner encrypted file to temp ──────────────────────────
        Write-Verbose 'Extracting encrypted content file...'
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue

        $tempFile   = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($IntuneWinPath)
        try {
            $innerEntry  = $zipArchive.Entries | Where-Object { $_.FullName -eq $meta.InnerEntryName } | Select-Object -First 1
            if (-not $innerEntry) { throw "Inner content entry '$($meta.InnerEntryName)' not found in archive." }

            $entryStream = $innerEntry.Open()
            $outStream   = [System.IO.File]::Create($tempFile)
            try   { $entryStream.CopyTo($outStream) }
            finally {
                $outStream.Dispose()
                $entryStream.Dispose()
            }
        }
        finally {
            $zipArchive.Dispose()
        }
        Write-Host '  ✓ Content extracted to temp.' -ForegroundColor Green

        # ── Step 6: Upload to Azure Blob (block + blocklist) ──────────────────────
        Write-Verbose 'Uploading content to Azure Storage...'
        Invoke-AzBlobUpload -SasUri $sasUri -FilePath $tempFile

        # ── Step 7: Commit the file ───────────────────────────────────────────────
        Write-Verbose 'Committing file...'
        $commitBody = [ordered]@{
            'fileEncryptionInfo' = [ordered]@{
                'encryptionKey'        = $meta.EncryptionKey
                'macKey'               = $meta.MacKey
                'initializationVector' = $meta.InitializationVector
                'mac'                  = $meta.Mac
                'profileIdentifier'    = if ($meta.ProfileIdentifier) { $meta.ProfileIdentifier } else { 'ProfileVersion1' }
                'fileDigest'           = $meta.FileDigest
                'fileDigestAlgorithm'  = $meta.FileDigestAlgorithm
            }
        }
        Invoke-MgGraphRequest -Method POST -Uri "$fileUri/commit" -Body ($commitBody | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null

        # ── Step 8: Poll for commit success ───────────────────────────────────────
        # The commit makes Intune decrypt + validate the whole package server-side, so this wait scales
        # with package size — it is the one that used to blow the 60 s ceiling on large .intunewin files.
        Write-Verbose "Waiting for commit confirmation (timeout ${TimeoutSeconds}s)..."
        $null = Wait-Win32ToolkitUploadState -FileUri $fileUri `
            -TargetState 'commitFileSuccess' `
            -Activity 'the file commit' `
            -TimeoutSeconds $TimeoutSeconds
        Write-Host '  ✓ Commit successful.' -ForegroundColor Green

        # ── Step 9: Link content version to app ──────────────────────────────────
        Write-Verbose 'Linking content version to app...'
        $patchBody = @{
            '@odata.type'             = '#microsoft.graph.win32LobApp'
            'committedContentVersion' = $versionId
        }
        Invoke-MgGraphRequest -Method PATCH -Uri "$baseUri/mobileApps/$appId" -Body ($patchBody | ConvertTo-Json -Depth 3) -ContentType 'application/json' | Out-Null

        # ── Step 10: Remember the publication, then attach app dependencies ───────
        # Intune only allows relationships AFTER the app is added and uploaded, which is why this is last.
        $tenant = try { (Get-MgContext).TenantId } catch { 'unknown' }
        if (-not $AsUpdate) {
            $null = Set-Win32ToolkitPublication -ProjectPath $ProjectPath -AppId $appId -TenantId $tenant `
                -DisplayName $displayName -DisplayVersion $displayVersion -WingetId $wingetId

            if ($resolvedDeps.Count -gt 0) {
                Write-Host ''
                Write-Verbose "Attaching $($resolvedDeps.Count) app dependency(ies) — Intune installs them first..."
                $null = Set-Win32ToolkitAppRelationships -AppId $appId -Dependency $resolvedDeps -BaseUri $baseUri
                Write-Host "  ✓ Dependencies attached: $(($resolvedDeps | ForEach-Object { $_.Ref }) -join ', ')" -ForegroundColor Green
            }
        }

        # ── Summary ───────────────────────────────────────────────────────────────
        Write-Host ''
        Write-Host '✓ App published successfully!' -ForegroundColor Green
        Write-Host "  App ID : $appId"       -ForegroundColor Cyan
        Write-Host "  Name   : $displayName" -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  View in Intune portal:' -ForegroundColor Gray
        Write-Host "  https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$appId" -ForegroundColor DarkGray

        # EMIT the publication result. The app id previously existed only in a Write-Host line, so nothing
        # downstream could reference the app it had just created — which is exactly what an Intune
        # dependency relationship needs (you can only relate apps by id, and only AFTER the upload).
        # Emitted last so it is the sole object on the success pipeline.
        [pscustomobject]@{
            AppId        = $appId
            DisplayName  = $displayName
            IsUpdateApp  = [bool]$AsUpdate
            PortalUri    = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$appId"
        }
    }
    catch {
        # Fail-closed gates (W32T.NoDetectionRule, ...) pass through unchanged, so scripted callers and
        # Export-Win32ToolkitIntuneWin can tell them apart by FullyQualifiedErrorId.
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        $msg = "Publish-Win32ToolkitIntuneApp failed: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $msg += "`nGraph API error: $($_.ErrorDetails.Message)"
        }
        throw $msg
    }
    finally {
        if ($tempFile -and (Test-Path $tempFile)) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
        if ($ownsAdvisoryRun) { $script:W32TAdvisoryRun = $null }
    }
}
