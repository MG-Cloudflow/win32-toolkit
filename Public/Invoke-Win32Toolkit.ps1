function Invoke-Win32Toolkit {
<#
.SYNOPSIS
    End-to-end Win32 app packaging automation.
.DESCRIPTION
    Searches Winget for an application, downloads it, creates a PSADT V4 project,
    configures the installer, generates Intune requirement scripts, and launches
    a Windows Sandbox session for targeted installation documentation.

    Fails closed: when the PSADT project cannot be created, when its deploy script uses a template
    layout this version does not support ("Unsupported PSADT template shape: ..."), when the
    configuration or the org template cannot be applied, or when the winget download fails
    (W32T.DownloadFailed; the warnings name every option that was skipped and the project folder is
    kept for a retry), the command stops with a terminating error and the project is NOT documented,
    tested, packaged or published.

    Returns a result object (Win32Toolkit.RunResult): Status (Succeeded, CompletedWithProblems or Failed),
    the capture state, the test verdicts, the .intunewin built, the apps published and one plain sentence
    per problem (a failed or inconclusive test, an incomplete capture, no package built, the update app
    skipped, or the error that stopped the run). A W32T.* error is thrown instead and no object is
    returned. -NewTemplate returns nothing.
.PARAMETER SearchTerm
    Term to search for in the Winget repository.
.PARAMETER Id
    Winget package ID to use directly (skips search). Example: 'Git.Git'
.PARAMETER TemplateName
    Name of the org template to load/create. Skips the interactive template picker.
    If the template does not exist yet, the wizard is pre-filled with this name.
.PARAMETER NewTemplate
    Run the org template wizard, save the template, and exit without packaging any app.
.PARAMETER Architecture
    Architecture to use for download and project creation (x64, x86, arm64).
    Skips the interactive architecture selection menu.
.PARAMETER Force
    Skip the PSGallery update prompt and the project overwrite prompt.
    Useful for unattended / automated runs.
    PSAppDeployToolkit is only ever selected and installed inside the supported range (4.1.x and 4.2.x).
    With -Force an installed supported version is used without querying the gallery; without it, only
    newer STABLE versions inside that range are offered. When no supported version is installed, the
    newest stable supported version is installed (with or without -Force).
.PARAMETER BasePath
    Base folder for all output (Templates, Projects, Staging, IntuneWin). If omitted, the value
    saved in the registry (HKCU:\Software\CloudFlow\win32-toolkit) is used; on first run you are
    prompted for it and the choice is saved. An explicit value overrides but is not persisted.
.PARAMETER Reconfigure
    Re-prompt for the base folder and save the new value to the registry, ignoring any stored value.
.PARAMETER RunTest
    Test scenario(s) to run right after the project is built and documented: 'InstallUninstall',
    'Update', or both (array — scenarios run in the order given). Each runs in the configured test
    backend (Windows Sandbox by default, Hyper-V when configured and ready). A failed scenario is
    reported with a warning but does not stop packaging/publishing.
.PARAMETER UpdateVersionsBack
    For -RunTest Update: automatically use the version N releases older than the packaged one as the
    update baseline (1 = the immediately previous release), so a scripted pipeline never blocks on
    the interactive version picker. Ignored when -UpdateSpecificVersion is also supplied.
.PARAMETER UpdateSpecificVersion
    For -RunTest Update: use this exact older version as the update baseline. Takes precedence over
    -UpdateVersionsBack when both are supplied. Omit both to pick interactively; an unattended test run
    (the SandboxTestMode / HyperVTestMode config value) or a host that cannot prompt (a service,
    redirected input, or a console started with pwsh -NonInteractive) then uses the previous version,
    with a warning.
.PARAMETER PackageIntune
    After creating the project, package it into a .intunewin file using IntuneWinAppUtil.exe.
.PARAMETER PublishIntune
    After packaging, upload the .intunewin file to Microsoft Intune via Graph API.
    Implies -PackageIntune. Requires the Microsoft.Graph.Authentication module.
.PARAMETER PublishUpdate
    Also publish the UPDATE app: a second Intune app of the same version whose requirement rule makes
    it applicable only to devices that already have the app installed. Implies packaging.
.PARAMETER DependsOn
    Dependencies to declare for this app before packaging: 'winget:<Id>', 'project:<Template>\<Name>',
    or 'intune:<AppGuid>' references (array). Declared dependencies install first in the test guest
    and are related to the Intune app at publish time. The references are checked before anything is
    searched, downloaded or created: a 'project:' reference that is not exactly '<Template>\<Name>', an
    'intune:' reference that is not a GUID, or a reference to the app being built stops the command
    with the terminating error W32T.InvalidDependencyReference.
.PARAMETER DependencyType
    How Intune should treat the declared dependencies: 'autoInstall' (default) installs them
    automatically; 'detect' only requires their presence.
.PARAMETER InstallerType
    Pin the installer technology of the package: the winget installer type to download (msi, wix, burn,
    nullsoft, inno, exe or msix). winget may answer with another type of the same family (msi and wix are
    one family; burn, nullsoft, inno and exe are another) and says so. Without it, rebuilding a version
    that is itself published or pinned keeps its own technology; otherwise the technology of the
    highest earlier version of this app (same winget id) in the template folder that was published, or
    pinned with this parameter, is kept; otherwise winget chooses. When winget offers no installer of the
    pinned family for this version, the command stops with W32T.InstallerVariantUnavailable and nothing is
    downloaded. The choice and its reason are recorded in SupportFiles\AppConfig.json (Source); the
    identity checks after the download warn when the app ships another technology too.
.PARAMETER UpdateBaselineInstallerType
    For -RunTest Update: the installer technology of the old-version baseline (see
    Test-Win32ToolkitProject -BaselineInstallerType). Auto (the default when omitted) starts from the other
    technology winget ships for this app when there is one, and falls back to the packaged technology with
    a warning when the old version does not ship it; Both runs the Update test once per technology (one
    record each); Packaged uses the packaged technology only; a type (msi, wix, burn, nullsoft, inno, exe,
    msix) pins that technology.
.EXAMPLE
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force
.EXAMPLE
    Invoke-Win32Toolkit -SearchTerm 'visual studio code' -BasePath 'D:\Packaging'
.EXAMPLE
    Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
.EXAMPLE
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -PackageIntune -PublishIntune
.EXAMPLE
    # Fully scripted pipeline incl. both tests; the Update baseline is the previous release
    Invoke-Win32Toolkit -Id 'Mozilla.Firefox' -Architecture x64 -Force -RunTest InstallUninstall, Update -UpdateVersionsBack 1 -PackageIntune
.EXAMPLE
    # Package the vendor EXE (NSIS) installer instead of winget's default MSI, and keep it for later versions
    Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -Force -InstallerType nullsoft
.EXAMPLE
    # Update test from each installer technology winget ships (one run and one test record per technology)
    Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -Architecture x64 -Force -RunTest Update -UpdateVersionsBack 1 -UpdateBaselineInstallerType Both
.EXAMPLE
    # Check what happened without reading the console
    $r = Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -Force -RunTest InstallUninstall -PackageIntune
    if ($r.Status -ne 'Succeeded') { $r.Problems }
.OUTPUTS
    Win32Toolkit.RunResult: Command, ProjectPath, ProjectName, Mode (Winget), Status (Succeeded,
    CompletedWithProblems or Failed), Capture (Done, Problems or NotRun), Tests ({ Scenario; Verdict }
    per -RunTest scenario), IntuneWinPath, Published (the objects Publish-Win32ToolkitIntuneApp returned)
    and Problems. A W32T.* error is thrown instead and no object is returned. Check .Status, not whether an
    object came back: a failed run that stopped on a non-W32T error returns an object with Status Failed
    (and writes the error).
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchTerm,

        [Parameter(Mandatory = $false)]
        [string]$Id,

        [Parameter(Mandatory = $false)]
        [string]$TemplateName,

        [Parameter(Mandatory = $false)]
        [switch]$NewTemplate,

        [Parameter(Mandatory = $false)]
        [string]$Architecture,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$BasePath,

        [Parameter(Mandatory = $false)]
        [switch]$Reconfigure,

        [Parameter(Mandatory = $false)]
        [ValidateSet('InstallUninstall', 'Update')]
        [string[]]$RunTest,

        # Update-test baseline selection for -RunTest Update: pick the Nth-older release (or an exact
        # version) up front, so a scripted pipeline never blocks on the interactive version picker
        # mid-run. Omit both to keep the interactive picker. SpecificVersion wins over VersionsBack.
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 1000)]
        [int]$UpdateVersionsBack,

        [Parameter(Mandatory = $false)]
        [string]$UpdateSpecificVersion,

        [Parameter(Mandatory = $false)]
        [switch]$PackageIntune,

        [Parameter(Mandatory = $false)]
        [switch]$PublishIntune,

        # Also publish the update app (2nd app, same version, requirement-gated to installed devices).
        [Parameter(Mandatory = $false)]
        [switch]$PublishUpdate,

        # Apps that Intune must install BEFORE this one (e.g. a Visual C++ redistributable).
        # Accepts 'winget:<id>', 'project:<Template>\<Name>', 'intune:<guid>', or a bare reference.
        # Declared into AppConfig.json; resolved to real Intune app ids and attached as
        # mobileAppDependency relationships at publish time.
        [string[]]$DependsOn,

        [ValidateSet('autoInstall', 'detect')]
        [string]$DependencyType = 'autoInstall',

        # Installer technology pin for the package download (family-aware: wix <-> msi substitute).
        # Declared last so the positions of the earlier parameters do not move.
        [Parameter(Mandatory = $false)]
        [ValidateSet('msi', 'wix', 'burn', 'nullsoft', 'inno', 'exe', 'msix')]
        [string]$InstallerType,

        # Update-test baseline technology; passed on to Finalize -> Test-Win32ToolkitProject only when bound.
        [Parameter(Mandatory = $false)]
        [ValidateSet('Auto', 'Both', 'Packaged', 'msi', 'wix', 'burn', 'nullsoft', 'inno', 'exe', 'msix')]
        [string]$UpdateBaselineInstallerType
    )

    $runResult = $null
    try {
        # The run's result object (TUI audit G2, S8-F3): filled by this command and Finalize, returned at the end.
        $runResult = Initialize-Win32ToolkitRunResult -Command 'Invoke-Win32Toolkit' -Mode 'Winget'

        Write-Host 'Winget App Downloader + PSADT Project Creator' -ForegroundColor Cyan
        Write-Host '===========================================' -ForegroundColor Cyan

        # -DependsOn is checked before anything is resolved, searched, downloaded or created (re-verification
        # 2026-10-21, B3 r2.1: a bad reference was refused only after the download and the scaffold, as a
        # non-terminating error that left a half-configured project). W32T.InvalidDependencyReference is re-thrown by
        # the catch below; the self-dependency check follows once the project name is known.
        if ($DependsOn) { $null = Assert-Win32ToolkitDependencyRef -Reference $DependsOn -DependencyType $DependencyType }

        # Check if winget is installed
        if (-not (Test-WingetInstalled)) {
            throw 'Winget is not installed or not available in PATH'
        }

        # Resolve the base folder (registry-backed; prompts and saves on first run)
        $BasePath = Get-Win32ToolkitBasePath -BasePath $BasePath -Reconfigure:$Reconfigure
        Write-Host "Base folder: $BasePath" -ForegroundColor DarkGray

        # -NewTemplate: create/update a template then exit, without packaging anything
        if ($NewTemplate) {
            $newTpl = New-OrgTemplate -TemplateName $TemplateName -BasePath $BasePath
            if ($newTpl) {
                Write-Host "`n✓ Template '$($newTpl.TemplateName)' created successfully." -ForegroundColor Green
            }
            return
        }

        # Load (or create) org template once for this run
        $script:OrgTemplate = Get-OrgTemplate -TemplateName $TemplateName -BasePath $BasePath

        # -Id fast path: skip search entirely. Resolution is locale-independent (existence by exit code,
        # Name/Version from the column-parsed search table) so it works on non-English winget (issue #60).
        if ($Id) {
            Write-Verbose "Resolving package ID: $Id"
            $selectedApp = Resolve-Win32ToolkitWingetId -Id $Id
            if (-not $selectedApp) {
                $runResult.Problems.Add("Package ID '$Id' was not found in winget.")
                Write-Error "Package ID '$Id' not found in winget. Verify the ID and try again."
                return (Complete-Win32ToolkitRunResult -Result $runResult -Failed)
            }
            Write-Host "`nSelected: $($selectedApp.Name) v$($selectedApp.Version)" -ForegroundColor Cyan
        }
        else {
            # Get search term if not provided
            if (-not $SearchTerm) {
                $SearchTerm = Read-Host 'Enter search term for applications'
                if ([string]::IsNullOrWhiteSpace($SearchTerm)) {
                    throw 'Search term is required'
                }
            }

            # Search for apps and exclude Microsoft Store results
            $apps = Search-WingetApps -SearchTerm $SearchTerm
            $apps = $apps | Where-Object { $_.Source -ne 'msstore' }

            if ($apps.Count -eq 0) {
                Write-Warning "No applications found matching: $SearchTerm"
                $runResult.Problems.Add("No applications found matching: $SearchTerm")
                return (Complete-Win32ToolkitRunResult -Result $runResult -Failed)
            }

            Write-Host "Found $($apps.Count) applications" -ForegroundColor Green

            # Display apps as a numbered list with alternating row colours
            Write-Host ''
            Write-Host ("  {0,-3} {1,-28} {2,-32} {3,-10} {4}" -f '#', 'Name', 'Id', 'Version', 'Source') -ForegroundColor Gray
            Write-Host ("  " + '-' * 82) -ForegroundColor DarkGray

            for ($i = 0; $i -lt $apps.Count; $i++) {
                $color = if ($i % 2 -eq 0) { 'Cyan' } else { 'White' }
                Write-Host ("  {0,-3} {1,-28} {2,-32} {3,-10} {4}" -f ($i + 1), $apps[$i].Name, $apps[$i].Id, $apps[$i].Version, $apps[$i].Source) -ForegroundColor $color
            }
            Write-Host ''

            do {
                $rawInput = Read-Host "Select application (1-$($apps.Count))"
                $parsed   = 0
                $valid    = [int]::TryParse($rawInput.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $apps.Count
                if (-not $valid) {
                    Write-Host "Invalid selection. Please enter a number between 1 and $($apps.Count)." -ForegroundColor Red
                }
            } while (-not $valid)

            $selectedApp = $apps[$parsed - 1]

            if (-not $selectedApp) {
                Write-Warning 'No application selected'
                $runResult.Problems.Add('No application selected.')
                return (Complete-Win32ToolkitRunResult -Result $runResult -Failed)
            }

            Write-Host "`nSelected: $($selectedApp.Name) v$($selectedApp.Version)" -ForegroundColor Cyan
        }

        # Get available architectures for the selected app. A -Architecture of x64/x86/arm64 never depends on the
        # detection (Select-Architecture always offers all three), so the 'winget show' scrape - and its misleading
        # 'No specific architectures detected' warning - is skipped (test campaign 2026-10-21, S7-F5).
        $availableArchs = if ($Architecture -in @('x64', 'x86', 'arm64')) { @($Architecture) } else { Get-WingetAppDetails -AppId $selectedApp.Id }

        # Let user select architecture (single selection for project creation)
        $selectedArch = Select-Architecture -Architectures $availableArchs -AppName $selectedApp.Name -PreSelected $Architecture

        if ($selectedArch -eq 'all') {
            if ($Architecture) {
                Write-Warning "'-Architecture all' is not valid — defaulting to x64."
                $selectedArch = 'x64'
            }
            else {
                Write-Warning 'For project creation, please select a specific architecture.'
                $selectedArch = Select-Architecture -Architectures $availableArchs -AppName $selectedApp.Name
            }
        }

        # Create project name using AppName_Architecture_Version format
        $appNameClean = Sanitize-ProjectName -Name $selectedApp.Name
        $versionClean = Sanitize-ProjectName -Name $selectedApp.Version
        $archClean    = Sanitize-ProjectName -Name $selectedArch
        $projectName  = "${appNameClean}_${archClean}_${versionClean}"
        $runResult.ProjectName = $projectName

        Write-Host "`nProject name will be: $projectName" -ForegroundColor Cyan

        # Ensure the template-scoped Projects tier exists before scaffolding:
        #   <BasePath>\Projects\<Template>\<Project>
        $paths       = Get-Win32ToolkitPaths -BasePath $BasePath
        $templateSeg = Sanitize-ProjectName -Name $script:OrgTemplate.TemplateName
        if ([string]::IsNullOrWhiteSpace($templateSeg)) { $templateSeg = 'Default' }
        $projectsDir = Join-Path $paths.Projects $templateSeg
        # A 'project:' dependency on this very app ('<Template>\<ProjectName>' or the same full path) is refused
        # before the template folder or the project is created (B3 r2.1); the declaration below re-checks it.
        if ($DependsOn) { $null = Assert-Win32ToolkitDependencyRef -Reference $DependsOn -DependencyType $DependencyType -ProjectPath (Join-Path $projectsDir $projectName) }
        if (-not (Test-Path $projectsDir)) {
            New-Item -Path $projectsDir -ItemType Directory -Force | Out-Null
        }
        Write-Host "Template folder: $templateSeg" -ForegroundColor DarkGray

        # Rebuilding an existing version: Create-PSADTProject deletes its folder, so read what anchors its
        # installer technology FIRST (published or explicitly pinned, Get-Win32ToolkitSelfAnchor), and keep
        # its Intune\Publications.json (the Intune app it records still exists) so the rebuilt version still
        # anchors later versions and dependency lookups.
        $projectFullPath   = Join-Path $projectsDir $projectName
        $runResult.ProjectPath = $projectFullPath
        $tenantId          = if ($script:OrgTemplate -and $script:OrgTemplate.PSObject.Properties['TenantId'] -and $script:OrgTemplate.TenantId) { [string]$script:OrgTemplate.TenantId } else { '' }
        $selfAnchor        = Get-Win32ToolkitSelfAnchor -ProjectPath $projectFullPath -TenantId $tenantId
        # Absolute (a relative -BasePath is used as-is): [System.IO.File] resolves against the process directory.
        $publicationFile   = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $projectFullPath 'Intune\Publications.json'))
        $publicationBackup = $null
        if (Test-Path -LiteralPath $publicationFile -PathType Leaf) {
            try { $publicationBackup = [System.IO.File]::ReadAllBytes($publicationFile) }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Warning "Could not keep '$publicationFile' for the rebuild ($($_.Exception.Message)): republish the rebuilt version so later versions keep its installer technology."
            }
        }

        # Create the PSADT project scaffold inside Projects\<Template>\
        $projectCreated = Create-PSADTProject -ProjectName $projectName -ProjectPath $projectsDir -Force:$Force

        if ($projectCreated) {
            $downloadPath    = Join-Path $projectFullPath 'Files'

            if (!(Test-Path $downloadPath)) {
                New-Item -Path $downloadPath -ItemType Directory -Force | Out-Null
            }

            if ($null -ne $publicationBackup -and -not (Test-Path -LiteralPath $publicationFile)) {
                try {
                    $null = New-Item -ItemType Directory -Path (Split-Path -Path $publicationFile -Parent) -Force
                    [System.IO.File]::WriteAllBytes($publicationFile, $publicationBackup)
                    Write-Verbose "Kept the Intune publication record of the rebuilt project: $publicationFile"
                }
                catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    Write-Warning "Could not restore '$publicationFile' after the rebuild ($($_.Exception.Message)): republish the rebuilt version so later versions keep its installer technology."
                }
            }

            # Installer technology (installer-identity PR 1): an explicit -InstallerType, else the technology of
            # the version being rebuilt when it is itself published or pinned, else that of the highest
            # published/pinned earlier version of this winget id in the template folder, else winget's choice.
            # A pinned family with no installer for this version throws W32T.InstallerVariantUnavailable from
            # the download (re-thrown by the catch below).
            $pin = Resolve-Win32ToolkitInstallerPin -TemplateDirectory $projectsDir -WingetId $selectedApp.Id -Version $selectedApp.Version -InstallerType $InstallerType -ExcludePath $projectFullPath -TenantId $tenantId -SelfAnchor $selfAnchor
            $techText = if ($pin.InstallerType) { "$($pin.InstallerType) ($($pin.Reason))" } else { "winget's choice" }
            Write-Host "Installer technology: $techText" -ForegroundColor DarkGray

            Write-Verbose 'Downloading application to project Files directory...'
            $downloadSuccess = Download-WingetApp -AppId $selectedApp.Id -AppName $selectedApp.Name -DownloadPath $downloadPath -Architecture $selectedArch -InstallerType $pin.InstallerType -PinnedBy $pin.PinnedBy -PinReason $pin.Reason

            if ($downloadSuccess) {
                Write-Host "`n✓ App downloaded successfully!" -ForegroundColor Green

                # Normalize the installer filename to AppName_arch_version.ext
                Write-Verbose 'Normalizing installer filename...'
                Rename-InstallerFile -FilesPath $downloadPath -AppName $selectedApp.Name -Version $selectedApp.Version -Architecture $selectedArch

                # Configure PSADT based on downloaded installer type
                Write-Verbose 'Configuring PSADT for installer type...'
                # Critical generator problems throw W32T.* (propagated by the catch below); $false means
                # the project is not configured - never document, test, package or publish it then.
                $psadtConfigured = Configure-PSADTForInstaller -ProjectPath $projectFullPath -AppInfo $selectedApp -Architecture $selectedArch -InstallerPin $pin -BasePath $BasePath
                if (-not $psadtConfigured) {
                    throw [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new('PSADT configuration failed - the project was NOT documented, tested, packaged or published (see the warnings above).'),
                        'W32T.PipelineAborted', [System.Management.Automation.ErrorCategory]::InvalidResult, $projectFullPath)
                }

                # Download and apply the app-specific icon from WinGet YAML
                Write-Verbose 'Downloading app icon from WinGet...'
                # '$null =', never '| Out-Null': a warning from a command in a pipeline does not reach this
                # command's -WarningVariable (re-verification 2026-10-21, B1 #2).
                $null = Get-AppIconFromWinget -ProjectPath $projectFullPath -FilesPath $downloadPath

                # Installer identity checks (other technologies winget ships, the earlier versions in this
                # template): warnings only, written to Documentation\IdentityDelta.json; never blocks (fail-open).
                $null = Write-Win32ToolkitIdentityDelta -ProjectPath $projectFullPath -TenantId $tenantId

                Write-Host "`n✓ SUCCESS: Project created, app downloaded, and PSADT configured!" -ForegroundColor Green

                Write-Host "Project location: $projectFullPath" -ForegroundColor Cyan
                Write-Host "Downloaded files:  $downloadPath"   -ForegroundColor Cyan

                # Declare Intune app dependencies (data-only). Written AFTER Configure-PSADTForInstaller so
                # AppConfig.json already exists, and BEFORE finalize so publishing can resolve + attach them.
                # The references were validated before the download; this re-check is the second line of defence.
                if ($DependsOn) {
                    $declared = Set-Win32ToolkitAppDependency -ProjectPath $projectFullPath -DependsOn $DependsOn -DependencyType $DependencyType
                    Write-Host "✓ Dependencies   : $((@($declared) | ForEach-Object { "$($_.Source):$($_.Ref)" }) -join ', ')" -ForegroundColor Green
                }

                # Documentation capture, uninstall automation, and optional test/package/publish
                # (shared with the manual-app flow — see Invoke-Win32ToolkitFinalize).
                # BasePath: the capture and every test stage 'project:' dependencies from this run's base folder.
                $finalize = @{ ProjectPath = $projectFullPath; ProjectName = $projectName; AppInfo = $selectedApp; BasePath = $BasePath; Result = $runResult }
                if ($RunTest) { $finalize['RunTest'] = $RunTest }   # omit when null (ValidateSet rejects $null)
                if ($UpdateVersionsBack)    { $finalize['UpdateVersionsBack']    = $UpdateVersionsBack }
                if ($UpdateSpecificVersion) { $finalize['UpdateSpecificVersion'] = $UpdateSpecificVersion }
                if ($PSBoundParameters.ContainsKey('UpdateBaselineInstallerType')) { $finalize['UpdateBaselineInstallerType'] = $UpdateBaselineInstallerType }
                Invoke-Win32ToolkitFinalize @finalize -PackageIntune:$PackageIntune -PublishIntune:$PublishIntune -PublishUpdate:$PublishUpdate
                return (Complete-Win32ToolkitRunResult -Result $runResult)

            }
            else {
                # The download failed, so Rename/Configure/Finalize above were all skipped. Anything the
                # user asked for downstream (test, package, publish, dependencies) did NOT happen.
                # Name the options they actually supplied — a failed run must never look like a published one.
                # The warnings come first; then the run stops with W32T.DownloadFailed (TUI audit G2, S10-F6 a).
                # The project folder is deliberately kept so the run can be retried.
                Write-Warning "Download FAILED for '$($selectedApp.Id)' ($selectedArch) - no installer was placed in the project's Files folder."

                $skipped = [System.Collections.Generic.List[string]]::new()
                if ($PSBoundParameters.ContainsKey('RunTest') -and $RunTest) {
                    $skipped.Add("-RunTest ($($RunTest -join ', ')): the package was NOT tested - no Sandbox/Hyper-V run happened.")
                }
                if ($PSBoundParameters.ContainsKey('PackageIntune') -and $PackageIntune) {
                    $skipped.Add('-PackageIntune: NOTHING was packaged - no .intunewin file was produced.')
                }
                if ($PSBoundParameters.ContainsKey('PublishIntune') -and $PublishIntune) {
                    $skipped.Add('-PublishIntune: NOTHING was published - no app was uploaded to Intune.')
                }
                if ($PSBoundParameters.ContainsKey('PublishUpdate') -and $PublishUpdate) {
                    $skipped.Add('-PublishUpdate: no update app was published to Intune.')
                }
                if ($PSBoundParameters.ContainsKey('DependsOn') -and $DependsOn) {
                    $skipped.Add("-DependsOn ($($DependsOn -join ', ')): no dependencies were declared on the project.")
                }

                if ($skipped.Count -gt 0) {
                    Write-Warning 'The following options you passed were SKIPPED because the download failed:'
                    foreach ($item in $skipped) { Write-Warning "  * $item" }
                }

                Write-Warning "The project folder was still created: $projectFullPath"
                Write-Warning "Next: if winget reported a transient error (network, timeout), re-run the same command. An authentication or 'no package found' error shown above fails the same way on a re-run."
                # Do NOT tell the user to drop an installer into Files\ and re-run: Create-PSADTProject removes
                # and recreates the project directory on every run, so anything placed there by hand is deleted
                # before the (still failing) download is retried. Supplying your own installer is the MANUAL
                # flow's job.
                Write-Warning "To package an installer you supply yourself, use the manual flow instead:"
                Write-Warning "  New-Win32ToolkitManualApp -Name '$($selectedApp.Name)' -Version '$($selectedApp.Version)' -Architecture $selectedArch -SourcePath <path-to-your-installer>"
                Write-Warning "Do not copy files into '$downloadPath' and re-run this command — the project folder is recreated from scratch each run, which would delete them."
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("Download FAILED for '$($selectedApp.Id)' ($selectedArch): nothing was configured, tested, packaged or published. The project folder was kept for a retry: $projectFullPath (see the warnings above)."),
                    'W32T.DownloadFailed', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $projectFullPath)
            }
        }
        else {
            if ($null -ne $publicationBackup -and -not (Test-Path -LiteralPath $publicationFile)) {
                Write-Warning "The Intune publication record of '$projectName' (Intune\Publications.json) went with the old project folder: after you re-create the project, republish it so later versions keep its installer technology."
            }
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Failed to create the PSADT project '$projectName' (see the warnings above) - nothing was downloaded, documented, tested, packaged or published."),
                'W32T.ProjectCreationFailed', [System.Management.Automation.ErrorCategory]::InvalidResult, $projectName)
        }
    }
    catch {
        # Fail-closed errors (W32T.*) reach the caller as terminating errors; the TUI shows them.
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        # Any other error: the result object says the run stopped (Status Failed), then the error is written.
        if ($runResult) {
            $runResult.Problems.Add([string]$_.Exception.Message)
            Complete-Win32ToolkitRunResult -Result $runResult -Failed
        }
        Write-Error "Script execution failed: $($_.Exception.Message)"
    }
    finally {
        # Clear the module-scoped org template so a stale value can't leak into the next
        # command in the same session. Runs on both success and failure. $null is the
        # cleared state the module initialises at load.
        $script:OrgTemplate = $null
    }
}
