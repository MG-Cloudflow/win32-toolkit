function Publish-Win32ToolkitIntuneApp {
<#
.SYNOPSIS
    Uploads a packaged Win32 app (.intunewin) to Microsoft Intune via the Graph API.
.DESCRIPTION
    Authenticates to Microsoft Graph with the DeviceManagementApps.ReadWrite.All scope,
    then executes the full Win32 Lob App upload sequence:

    1. Reads app metadata (name, publisher, version, description, URL) from AppConfig.json (winget YAML fallback).
    2. Builds a detection rule (install-tattoo version rule preferred; else from the NEWEST
       InstallationChanges_*.json capture in Documentation\) BEFORE signing in to Graph. No rule at
       all stops the publish with a W32T.NoDetectionRule error unless -AllowNoDetectionRule is given.
       A project that bundles a prerelease PSAppDeployToolkit (e.g. 4.2.0-rc2) only gets a warning.
    3. Extracts encryption metadata from the .intunewin archive (metadata.xml).
    4. Creates the app shell in Intune.
    5. Registers a content version and file entry.
    6. Waits for the Azure Storage SAS URI.
    7. Uploads the encrypted content using the Azure Block Blob API (6 MB chunks).
    8. Commits the file and waits for confirmation.
    9. Links the content version to the app.

    Requires the Microsoft.Graph.Authentication module (installed automatically on prompt).

    Before the -WhatIf gate (so a dry run shows them too), Publish warns, and never stops, when the
    latest Update test of the project failed (naming the failed assertions), an Update test saw a
    technology switch (the vendor's other installer stayed registered next to this package), or the
    identity checks found something, for example winget also ships another installer technology for
    this app that no Update test has covered. It also warns UNSAFE-CLEANUP when the project's
    uninstall cleanup paths fail the check Export enforces: a package exported before that check still
    carries them, so re-export packages built before this check, then publish them. The warnings are
    shown once per action: Export-Win32ToolkitIntuneWin -PublishIntune -PublishUpdate prints them once.

    Command lines (from Get-Win32ToolkitIntuneCommandLine, the single source; the app runs as SYSTEM):

        Install   : Invoke-AppDeployToolkit.exe -DeploymentType Install
        Uninstall : Invoke-AppDeployToolkit.exe -DeploymentType Uninstall

    The package is started through PSADT's launcher, not through 'powershell.exe -File'. The Intune
    Management Extension is a 32-bit process, so a bare 'powershell.exe' resolves to the 32-bit
    (SysWOW64) Windows PowerShell on 64-bit devices: PSADT 4.2 then refuses to run (exit 60008), and
    PSADT 4.1 runs 32-bit and writes the install tattoo under HKLM\SOFTWARE\WOW6432Node, where the
    64-bit tattoo detection rule never finds it. Invoke-AppDeployToolkit.exe is AnyCPU and always starts
    the 64-bit Windows PowerShell. No -DeployMode is passed: PSADT chooses the mode itself.

    Apps published by win32-toolkit 1.1.6 or older keep their old 'powershell.exe -File' command line:
    this command always creates a NEW app and never edits an existing one. Republish those apps (and
    retire the old ones), or edit their install and uninstall command lines in the Intune portal to the
    two lines above. The update requirement (-AsUpdate) also accepts the WOW6432Node tattoo those
    32-bit installs left behind.

    With -AsUpdate the same .intunewin is published as a SECOND app of the same version whose
    requirement rule (a PowerShell presence check, built by Get-Win32ToolkitRequirementRule) makes it
    applicable only to devices that already have the app — the classic Intune "install app + update
    app" pattern. Detection stays the version-aware tattoo rule, so the update installs on machines
    with an older version and is detected once they reach this version. (Supersedence is separate.)
.PARAMETER IntuneWinPath
    Full path to the .intunewin file produced by Export-Win32ToolkitIntuneWin.
.PARAMETER ProjectPath
    Full path to the raw PSADT project folder. Used for YAML metadata and detection rules.
.PARAMETER AsUpdate
    Publish the update variant: append -UpdateNameSuffix to the display name and attach the
    "app already installed" requirement rule. Fails fast if no requirement rule can be built.
.PARAMETER UpdateNameSuffix
    Display-name suffix for the update app (default ' (Update)').
.PARAMETER TimeoutSeconds
    How long to wait for each of the two ASYNCHRONOUS Intune steps — the Azure Storage SAS URI (step 6)
    and the file commit (step 8) — before giving up. Default 300 s.

    Why 300 and not the old 60: both waits used to be a fixed 20 x 3 s loop, i.e. a hard 60-second
    ceiling that could not be raised. Intune's commit does the server-side decrypt/validate of the whole
    package, so it scales with package size; a 200 MB+ .intunewin (normal for a PSADT project with a
    bundled installer) regularly needs more than a minute, and the timeout fired AFTER the blob had
    already been uploaded — throwing away a publish that would have succeeded. 300 s covers the observed
    worst case with headroom while still failing in a reasonable time when the tenant is genuinely stuck.

    Polling backs off exponentially (2 s, doubling, capped at 15 s), so a slow tenant is polled patiently
    rather than hammered.
.PARAMETER AllowNoDetectionRule
    Publish even when no detection rule can be built (no install tattoo and no usable install capture).
    The app is created with an empty detection-rule list and you must add a rule in the Intune portal
    before assigning it - Intune cannot tell whether such an app installed. Meant for apps a capture
    cannot describe (per-user installs, some MSIX packages). Without it the publish stops before any
    Graph call with a W32T.NoDetectionRule error.
.EXAMPLE
    Publish-Win32ToolkitIntuneApp `
        -IntuneWinPath 'C:\Win32Apps\IntuneWin\Git_x64_2.53.0.intunewin' `
        -ProjectPath   'C:\Win32Apps\Projects\Git_x64_2.53.0'
.EXAMPLE
    # Publish the update app (2nd app, requirement-gated to devices that already have it)
    Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $proj -AsUpdate
.EXAMPLE
    # A per-user app with no detectable footprint: publish it, then add a detection rule in the portal
    Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $proj -AllowNoDetectionRule
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

        Write-Host ''
        Write-Host 'Intune App Upload' -ForegroundColor Cyan
        Write-Host '=================' -ForegroundColor Cyan

        # ── App metadata (AppConfig.json first, winget YAML fallback) ─────────────
        $projectName = Split-Path $ProjectPath -Leaf
        $filesPath   = Join-Path $ProjectPath 'Files'

        $appCfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $app    = if ($appCfg.PSObject.Properties.Name -contains 'App') { $appCfg.App } else { $null }

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
        if ($AsUpdate) {
            $reqRule = Get-Win32ToolkitRequirementRule -ProjectPath $ProjectPath
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

        # ── Package advisory (D1, L22) ────────────────────────────────────────────
        # Warn only, before the -WhatIf gate so a dry run shows it too: a failed Update test, a technology
        # switch, identity findings, and UNSAFE-CLEANUP for a package exported before the cleanup-path
        # check (Export refuses such a project; a standalone publish of an old .intunewin only warns).
        # Fail-open: nothing it calls raises W32T.*, so it can never stop a publish.
        try {
            $null = Write-Win32ToolkitPackageAdvisory -ProjectPath $ProjectPath -Context Publish -AppLabel $displayName -ProbeIfMissing
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Warning "Could not check the Update test and identity warnings: $($_.Exception.Message)"
        }

        # ── -WhatIf / -Confirm gate for the ENTIRE publish ────────────────────────
        # Everything from here down mutates the live tenant (auth, app shell, content version, blob upload,
        # commit) and the later steps depend on the app id from the first POST. A per-step guard is therefore
        # unsafe: skipping only step 1 under -WhatIf would still fire live requests against a null app id. Gate
        # the whole sequence once, so -WhatIf is a true dry run — no auth, no Graph writes.
        if (-not $PSCmdlet.ShouldProcess($displayName, "Publish Win32 app to Intune (version $displayVersion)")) {
            Write-Host "WhatIf: would connect to Microsoft Graph and publish '$displayName' v$displayVersion to Intune (create app shell, upload content, commit)." -ForegroundColor Yellow
            return
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
