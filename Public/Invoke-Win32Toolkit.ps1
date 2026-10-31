function Invoke-Win32Toolkit {
<#
.SYNOPSIS
    Packages an app from winget, from the download to an optional test, build and publish.
.DESCRIPTION
    Invoke-Win32Toolkit downloads the newest winget version of an app and creates a project with
    PSAppDeployToolkit (PSADT) and your org template. Then the install capture installs the
    app on a test machine (Windows Sandbox or the Hyper-V test VM) and records what the package
    needs. It can also test, build and publish the .intunewin package.

    Use it in scripts, or for options the menu does not offer, such as the update test in the same
    run. In the menu: Package an app from winget (search).

    The project is <base folder>\Projects\<template>\<project>. A new run for the same version
    deletes and re-creates the project folder: copy your own code out first. The capture also
    writes SupportFiles\RequirementScript.ps1, a reference file that nothing runs. win32-toolkit
    never assigns an app. You assign it in the Intune admin center.

    It stops with an error whose ID starts with W32T. when it cannot go on safely. For example,
    W32T.DownloadFailed means that the download failed. A run that stops during the project setup
    marks the project not configured. Package the app again before you build or publish it.
.PARAMETER SearchTerm
    The text to search for in winget, for example 'git'. The command lists the results, without
    Microsoft Store apps, and asks which one to use. Without -SearchTerm and -Id, it asks for a
    search text.
.PARAMETER Id
    The exact winget ID of the app, for example 'Git.Git'. The command then shows no list to
    choose from, so use it in scripts. For an older version than the one winget lists now, use
    New-Win32ToolkitManualApp with your own installer.
.PARAMETER TemplateName
    The org template to use, for example 'Contoso'. If no template has this name, the template
    wizard starts and creates it. Without -TemplateName, the command uses your only template, asks
    when you have several, and starts the wizard when you have none. In scripts, give an existing
    name: a run that cannot ask stops with W32T.OrgTemplateChoiceNeeded.
.PARAMETER NewTemplate
    Starts the template wizard, saves the org template and stops: it packages no app and returns
    nothing. If the -TemplateName template exists, the wizard starts from the default values and
    replaces it. To change a template, use Org templates > Edit a template in the menu.
.PARAMETER Architecture
    The processor architecture of the package: x64, x86 or arm64. Without it, the command always
    asks. Set it in scripts.
.PARAMETER Force
    Replaces an existing project of the same app, architecture and version without asking, and
    skips the offer of a newer PSADT version. The menu always does this. Use it in scripts.
.PARAMETER BasePath
    The base folder for this command only. It is not saved. Default: your saved base folder (the
    first run asks for it).
.PARAMETER Reconfigure
    Asks for the base folder again and saves your answer for later runs. The toolkit does not move
    your templates or projects to the new folder. In the menu: Settings > Change the base folder.
.PARAMETER RunTest
    The tests to run after the install capture: InstallUninstall, Update or both, in the order you
    give. They run on your test machine: Windows Sandbox, or the Hyper-V test VM when you chose it
    in Settings and it is ready. The update test installs an old version first (the console calls
    it the baseline), then this package over it.
.PARAMETER UpdateVersionsBack
    For the update test: the old version, counted back from the packaged version (1 is the version
    before it). Use it in scripts, so that the run does not ask. If you also give
    -UpdateSpecificVersion, that one wins.
.PARAMETER UpdateSpecificVersion
    For the update test: the exact old version, for example '2.52.0'. Without this and
    -UpdateVersionsBack, the command asks you to choose. An unattended test, or a window that
    cannot ask, uses the version before the packaged one, with a warning.
.PARAMETER PackageIntune
    Builds the .intunewin package in <base folder>\IntuneWin\<template> after the capture and the
    tests. The command then asks 'Upload to Microsoft Intune now? (Y/N)', and Y publishes the
    install app only. Add -NoPublishPrompt to skip the question.
.PARAMETER PublishIntune
    Builds the package and publishes it to Intune as a new app, the install app. A failed test only
    warns. It does not stop packaging or publishing.
.PARAMETER PublishUpdate
    Builds the package and publishes the update app: a second Intune app of the same version, only
    for devices that already have the app. With -PublishIntune, the install app is published
    first. If the toolkit has no sure way to see that the app is installed, it skips the update app
    with a warning.
.PARAMETER DependsOn
    Apps that Intune must install before this app, for example
    'winget:Microsoft.VCRedist.2015+.x64', 'project:<template>\<project>' or 'intune:<app ID>'. The
    toolkit installs them first in the capture and the tests, and links them to the app when you
    publish. A wrong reference stops the command before the download, with
    W32T.InvalidDependencyReference.
.PARAMETER DependencyType
    How Intune handles the apps of -DependsOn. Default: autoInstall, so Intune installs them first.
    Use detect if Intune should only check that they are already installed. Command line only: the
    menu does not offer this.
.PARAMETER InstallerType
    Pins the installer technology of the package, for example wix for a WiX MSI or nullsoft for an
    NSIS setup. Without it, the toolkit keeps the technology of an earlier version that you
    published or pinned, or winget chooses. If winget has no installer of the same kind (MSI, EXE
    or MSIX) for this version, the command stops with W32T.InstallerVariantUnavailable.
    More: https://win32toolkit.com/packaging/#installer-technology
.PARAMETER UpdateBaselineInstallerType
    For the update test: the installer technology of the old version. Default: Auto, which uses the
    other technology that winget ships for this app, or the packaged one when there is no other.
    Both runs the test once for each technology, Packaged uses only the packaged one, and a type
    such as nullsoft uses only its installer family.
    More: https://win32toolkit.com/testing/#choose-the-installer-technology-of-the-old-version
.PARAMETER NoPublishPrompt
    Skips the question 'Upload to Microsoft Intune now? (Y/N)' after -PackageIntune, so the package
    is built but not published. Use it in scripts. The menu always skips this question.
.PARAMETER CaptureSiblingTechnologies
    Also runs a sibling capture: it installs the other installer technologies of this app, such as
    an NSIS setup, and records what they register. It then proposes prior-install rules: what the
    package does on devices with that other install. Without a ready Hyper-V test VM, it runs in
    Windows Sandbox, and its proposals can only become Block or Report rules.
    More: https://win32toolkit.com/prior-installs/
.PARAMETER ApplySiblingCapture
    Default: None, which only lists the proposals of -CaptureSiblingTechnologies, each with the
    command that applies it. Block turns each clean proposal (high confidence, no flags) into a
    Block rule, so the install fails on devices that have that other install. There is no Enforce
    value: each rule that removes the other install needs your own approval with
    Set-Win32ToolkitPriorInstall.
    More: https://win32toolkit.com/prior-installs/#apply-proposals-from-the-command-line
.EXAMPLE
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -TemplateName 'Contoso'

    This creates the project Git_x64_2.53.0 (your version will differ) with the Contoso org template
    and runs the install capture. It does not test, build or publish anything.
.EXAMPLE
    Invoke-Win32Toolkit -Id 'Git.Git' -Architecture x64 -RunTest InstallUninstall -PublishIntune

    This creates the project, tests the install and uninstall, then builds the package and publishes
    the install app to Intune, even when the test fails.
.EXAMPLE
    Invoke-Win32Toolkit -Id 'Notepad++.Notepad++' -InstallerType wix -CaptureSiblingTechnologies

    This packages the WiX MSI of Notepad++ and keeps that technology for later versions. It then
    captures the vendor NSIS setup and lists the proposed prior-install rules, but writes no rule.
.EXAMPLE
    Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'

    This starts the template wizard for the org template Contoso, saves it and stops.
.EXAMPLE
    $run = @{ Id = 'Git.Git'; Architecture = 'x64'; TemplateName = 'Contoso'; Force = $true }
    $test = @{ RunTest = 'InstallUninstall', 'Update'; UpdateVersionsBack = 1 }
    $r = Invoke-Win32Toolkit @run @test -PackageIntune -NoPublishPrompt
    if ($r.Status -ne 'Succeeded') { $r.Problems }

    This is the form for scripts: the parameters answer the questions of the command. It runs both
    tests (the update test starts from the previous version), builds the package and prints any
    problems.
.OUTPUTS
    Win32Toolkit.RunResult. A W32T error stops the command and returns nothing.
    Check Status: Succeeded, CompletedWithProblems or Failed. Problems has one sentence per problem.
    Tests has one Verdict per test: Passed, Failed or Inconclusive. IntuneWinPath is the package.
    Capture is Done, Problems or NotRun. Published lists the new Intune apps.
.NOTES
    Needs: winget, and Windows Sandbox or a ready Hyper-V test VM. Publishing also needs an Intune
    sign-in and the Microsoft.Graph.Authentication module, which the command offers to install.

    Time: the install capture usually takes 5 to 20 minutes. The toolkit stops waiting after 30
    minutes.
.LINK
    https://win32toolkit.com/reference/Invoke-Win32Toolkit/
.LINK
    https://win32toolkit.com/packaging/
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
        [string]$UpdateBaselineInstallerType,

        # Installer-identity PR 3b (spec 2.17): capture the other installer technologies after the install capture.
        [Parameter(Mandatory = $false)]
        [switch]$CaptureSiblingTechnologies,

        # What to do with the capture's proposals: None or Block (there is no Enforce value, D58).
        [Parameter(Mandatory = $false)]
        [ValidateSet('None', 'Block')]
        [string]$ApplySiblingCapture = 'None',

        # No 'Upload to Microsoft Intune now?' question after packaging (TUI audit G5: the menu asks about
        # publishing itself). Declared last.
        [Parameter(Mandatory = $false)]
        [switch]$NoPublishPrompt
    )

    $runResult = $null
    # Hyper-V speed-up PR 4 (D13, A-14, V-2): this run owns asynchronous teardowns (HyperVAsyncTeardown) unless an owner
    # (the TUI) is already running; the finally waits for a background restore before the run returns.
    $w32tOwner = $null; if (-not (Get-Win32ToolkitAsyncTeardownOwner)) { $w32tOwner = [guid]::NewGuid(); $script:W32TAsyncTeardownOwner = @{ Token = $w32tOwner; Command = 'Invoke-Win32Toolkit' } }
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

        # Hyper-V speed-up PR 4 (D14; HKCU HyperVCapturePrewarm, default Off): with the Hyper-V test backend, the test VM's
        # checkpoint is restored in the background while this run searches, downloads and configures; the capture's open
        # then finds it clean. The lease it holds is released after the capture (Finalize) or in the finally below.
        $null = Start-Win32ToolkitHyperVPrewarm

        # Load (or create) org template once for this run
        $script:OrgTemplate = Get-OrgTemplate -TemplateName $TemplateName -BasePath $BasePath

        # Installer-identity PR 3b (spec 2.17, SV28): what the sibling capture will do, said before anything is downloaded.
        if ($CaptureSiblingTechnologies) {
            $siblingNotReady = @(Test-Win32ToolkitHyperVReady)
            if ($siblingNotReady.Count -eq 0) {
                Write-Host 'Sibling capture: after the install capture, each other installer technology of this app is installed on the Hyper-V test VM (about 3-5 minutes each) and proposed as a prior-install rule.' -ForegroundColor Cyan
            }
            else {
                Write-Warning ('Sibling capture: Hyper-V is not ready (' + ($siblingNotReady -join '; ') + '): the other installer technologies are captured in Windows Sandbox as a user and can only give Block-only proposals; a project whose earlier captures allow an Enforce rule is not captured there (that would make them Block-only).')
            }
        }
        elseif ($ApplySiblingCapture -ne 'None') {
            Write-Warning "-ApplySiblingCapture $ApplySiblingCapture has no effect without -CaptureSiblingTechnologies: ignored."
        }

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

        # ...and its prior-install rules, decisions and capture records (installer-identity PR 3, L4): restored after the
        # configure step below, so a rebuilt version keeps the rules it had (each one needs a new proof run).
        $priorSnapshot = Get-Win32ToolkitPriorInstallSnapshot -ProjectPath $projectFullPath

        # Create the PSADT project scaffold inside Projects\<Template>\
        $projectCreated = Create-PSADTProject -ProjectName $projectName -ProjectPath $projectsDir -Force:$Force

        if ($projectCreated) {
            # TUI audit G4 (S10-F2): Create-PSADTProject has just replaced the folder (and any earlier marker), so every
            # error from here to the end of the configure step leaves a half-built folder. The catch below marks it
            # not configured (Documentation\NotConfigured.json; Export and Publish refuse it) and re-throws the error.
            $markStage = 'Download'
            try {
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
                    $markStage = 'Configure'
                    $psadtConfigured = Configure-PSADTForInstaller -ProjectPath $projectFullPath -AppInfo $selectedApp -Architecture $selectedArch -InstallerPin $pin -BasePath $BasePath
                    if (-not $psadtConfigured) {
                        throw [System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('PSADT configuration failed - the project was NOT documented, tested, packaged or published (see the warnings above).'),
                            'W32T.PipelineAborted', [System.Management.Automation.ErrorCategory]::InvalidResult, $projectFullPath)
                    }
                    # Prior-install rules (installer-identity PR 3, spec 2.13): the rebuilt version's own (L4), else those of
                    # the highest earlier version of this app and architecture (L5), re-checked against this package.
                    $null = Copy-Win32ToolkitPriorInstallState -ProjectPath $projectFullPath -Snapshot $priorSnapshot
                    # Configured: an error after this point (icon, identity checks, dependencies, Finalize) is not marked.
                    $markStage = 'Done'

                    # Download and apply the app-specific icon from WinGet YAML
                    Write-Verbose 'Downloading app icon from WinGet...'
                    # '$null =', never '| Out-Null': a warning from a command in a pipeline does not reach this
                    # command's -WarningVariable (re-verification 2026-10-21, B1 #2).
                    $null = Get-AppIconFromWinget -ProjectPath $projectFullPath -FilesPath $downloadPath

                    # Installer identity checks (other technologies winget ships, the earlier versions in this
                    # template): warnings only, written to Documentation\IdentityDelta.json; never blocks (fail-open).
                    $null = Write-Win32ToolkitIdentityDelta -ProjectPath $projectFullPath -TenantId $tenantId -CapturingSiblings:$CaptureSiblingTechnologies

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
                    if ($NoPublishPrompt) { $finalize['NoPublishPrompt'] = $true }   # only when set (TUI audit G5)
                    # Only when set (spec 2.17): the fixed-parameter Finalize shadows of the suites keep binding.
                    if ($CaptureSiblingTechnologies) { $finalize['CaptureSiblingTechnologies'] = $true; $finalize['ApplySiblingCapture'] = $ApplySiblingCapture }
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
                    if ($CaptureSiblingTechnologies) {
                        $skipped.Add('-CaptureSiblingTechnologies: the other installer technologies were NOT captured.')
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
                        [System.InvalidOperationException]::new("Download FAILED for '$($selectedApp.Id)' ($selectedArch): nothing was configured, tested, packaged or published. The project folder was kept for a retry and marked not configured: $projectFullPath (see the warnings above)."),
                        'W32T.DownloadFailed', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $projectFullPath)
                }
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
        $null = Wait-Win32ToolkitHyperVTeardown -Prewarm
        $null = Wait-Win32ToolkitHyperVTeardown -ReleaseOwner $w32tOwner
    }
}
