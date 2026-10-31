function Export-Win32ToolkitIntuneWin {
<#
.SYNOPSIS
    Checks a project and builds its .intunewin package, and can publish it to Intune.
.DESCRIPTION
    Export-Win32ToolkitIntuneWin builds the .intunewin package of a project: the file that Intune
    needs. It first runs the package check, which refuses a project that is not safe to ship and
    lists every problem with its fix. Then it builds the package from a clean copy of the project,
    without test files, Intune IDs or other data that must not reach devices.

    Use it to get the package file, or to see the package check before you publish. In the menu:
    Work with an existing project > Package to .intunewin. Unless you give -PublishIntune,
    -PublishUpdate or -NoPublishPrompt, the command asks "Upload to Microsoft Intune now? (Y/N)"
    after the build. The answer Y publishes the install app only.

    The package is <base folder>\IntuneWin\<template>\<project>.intunewin, and it replaces an older
    one. The clean copy stays in <base folder>\Staging\<template>\<project>. Building never changes
    the project. The first build downloads IntuneWinAppUtil.exe, the Microsoft tool that builds
    the package. Every run checks the Microsoft signature of this tool.

    After the build, the command shows warnings, for example about a failed test. A failed test
    only warns: it does not stop packaging or publishing.

    It stops with an error whose ID starts with W32T. when the project is not safe to build.
    W32T.ProjectNotConfigured means that the project build stopped halfway: re-create the project.
    W32T.PackageNotReady lists the problems that the package check found.
.PARAMETER ProjectPath
    The project folder: <base folder>\Projects\<template>\<project>. Without it, the command shows
    a numbered list of your projects and asks for a number.
.PARAMETER BasePath
    The base folder for this command only. It is not saved. Default: the base folder that holds
    the project, or your saved base folder when you give no -ProjectPath. You need it when the
    project is not in <base folder>\Projects\<template>\<project>.
.PARAMETER PublishIntune
    After the build, publishes the package to Intune as the install app, with
    Publish-Win32ToolkitIntuneApp. You sign in if you are not signed in yet. If no detection rule
    can be built, it stops with W32T.NoDetectionRule and publishes nothing. To publish such a
    package without a rule, use Publish-Win32ToolkitIntuneApp -AllowNoDetectionRule.
.PARAMETER PublishUpdate
    After the build, publishes the update app: a second app of the same version that applies only
    to devices that already have the app. Add -PublishIntune to publish both, the install app
    first. If the toolkit has no sure way to see that the app is installed, it skips the update app
    with a warning.
.PARAMETER NoPublishPrompt
    Removes the question "Upload to Microsoft Intune now? (Y/N)" after the build. Use it in
    scripts that only build the package.
.PARAMETER PublishTimeoutSeconds
    How many seconds to wait for Intune at two points of the upload: for the upload address, and
    for the check of the uploaded file. Default: 300 (from 5 to 7200). Raise it, for example to
    900, for a very large package or a slow tenant. Command line only: the menu does not offer
    this.
.PARAMETER AllowLegacyScript
    Builds the package even if win32-toolkit did not prepare the deploy script, or does not
    support its PSAppDeployToolkit version or layout. These problems become warnings. Projects
    from win32-toolkit 1.1.6 or older do not need it. It never overrides syntax errors, a missing
    Invoke-AppDeployToolkit.exe, unsafe uninstall cleanup folders or other checks. Command line
    only: the menu does not offer this.
.PARAMETER PassThru
    Returns a summary object instead of nothing. Use it in scripts to read the package path, the
    published apps and the problems.
.EXAMPLE
    Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'

    This builds C:\Win32Apps\IntuneWin\Contoso\Git_x64_2.53.0.intunewin. Then it asks if you want
    to upload the package to Intune.
.EXAMPLE
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Export-Win32ToolkitIntuneWin -ProjectPath $project -PublishIntune

    This builds the package and publishes it to Intune as the install app.
.EXAMPLE
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Export-Win32ToolkitIntuneWin -ProjectPath $project -PublishIntune -PublishUpdate

    This builds the package and publishes the install app first. Then it publishes the update app,
    for devices that already have the app.
.EXAMPLE
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    Export-Win32ToolkitIntuneWin -ProjectPath $project -PublishIntune -WhatIf

    This runs the package check and shows the warnings. It builds nothing and publishes nothing.
.EXAMPLE
    $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
    $result = Export-Win32ToolkitIntuneWin -ProjectPath $project -NoPublishPrompt -PassThru
    $result.IntuneWinPath

    This is the form for scripts. It builds the package without the upload question and shows the
    path of the package.
.OUTPUTS
    Nothing by default.
    With -PassThru, one object with ProjectPath, IntuneWinPath, Published and Problems.
    Published holds the published apps.
    Problems lists what went wrong without stopping the command.
    An error stops the command and returns nothing.
.NOTES
    Time: seconds to a few minutes to build. A publish usually takes a few minutes, longer for big
    packages.
.LINK
    https://win32toolkit.com/reference/Export-Win32ToolkitIntuneWin/
.LINK
    https://win32toolkit.com/build-intunewin/
.LINK
    https://win32toolkit.com/publishing/
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ProjectPath,

        [Parameter(Mandatory = $false)]
        [string]$BasePath,

        [Parameter(Mandatory = $false)]
        [switch]$PublishIntune,

        # Also (or instead) publish the update app — a 2nd Intune app of the same version whose
        # requirement rule makes it applicable only to devices that already have the app.
        # Combine with -PublishIntune to publish both the install app and the update app.
        [Parameter(Mandatory = $false)]
        [switch]$PublishUpdate,

        # Suppress the interactive "Upload to Intune now?" prompt (used by the TUI / automation).
        [Parameter(Mandatory = $false)]
        [switch]$NoPublishPrompt,

        # Forwarded to Publish-Win32ToolkitIntuneApp -TimeoutSeconds. Left unbound by default so the
        # default lives in exactly one place (Publish's own parameter) instead of being duplicated here.
        [Parameter(Mandatory = $false)]
        [ValidateRange(5, 7200)]
        [int]$PublishTimeoutSeconds,

        # Package a deploy script win32-toolkit never patched, or whose template layout it does not
        # support, as-is (the gate warns instead of stopping). Complete-Win32ToolkitManualApp -AllowLegacyScript
        # reaches it through Invoke-Win32ToolkitFinalize.
        [Parameter(Mandatory = $false)]
        [switch]$AllowLegacyScript,

        # Return { ProjectPath; IntuneWinPath; Published; Problems } instead of nothing (TUI audit G2, S8-F3:
        # the result objects of Invoke-Win32Toolkit, New- and Complete-Win32ToolkitManualApp). Declared last.
        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # Silence stock-cmdlet progress bars (Copy-Item / Remove-Item on the Staging copy) for the packaging
    # steps — they otherwise paint bars that tear an interactive (Spectre) TUI. Restored before the publish
    # step (and in finally) so the intentional Azure-upload progress bar is left untouched.
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    # Advisory run scope (L20): the package advisory below prints once per project for this whole action,
    # so the Publish calls of Step 7 (install app, then -AsUpdate) do not repeat it. A caller that already
    # opened a scope (the TUI publish action) keeps it; only the opener closes it (finally).
    $ownsAdvisoryRun = $null -eq $script:W32TAdvisoryRun
    if ($ownsAdvisoryRun) { $script:W32TAdvisoryRun = @{} }
    try {
        # -PassThru summary (TUI audit G2): the apps published and the problems that did not stop the export.
        $published      = [System.Collections.Generic.List[object]]::new()
        $exportProblems = [System.Collections.Generic.List[string]]::new()

        # Captured BEFORE the picker branch below overwrites $BasePath with the resolved/registry value:
        # only a base the CALLER actually passed may override the layout derived from the project path.
        $explicitBasePath = -not [string]::IsNullOrWhiteSpace($BasePath)

        # ── Project resolution ────────────────────────────────────────────────────
        if (-not $ProjectPath) {
            $BasePath = Get-Win32ToolkitBasePath -BasePath $BasePath
            Write-Verbose 'Scanning for PSADT projects...'
            $projects = Get-PSADTProjects -BasePath $BasePath

            if ($projects.Count -eq 0) {
                throw "No PSADT projects found under: $(Join-Path $BasePath 'Projects')`nEnsure projects were created with Invoke-Win32Toolkit."
            }

            $selectedProject = Show-ProjectSelection -Projects $projects
            $ProjectPath     = $selectedProject.Path
        }

        if (-not (Test-Path $ProjectPath)) {
            throw "Project path not found: $ProjectPath"
        }

        $setupFile = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
        if (-not (Test-Path $setupFile)) {
            throw "Setup file not found: $setupFile`nVerify this is a valid PSADT v4 project folder."
        }

        # ── Not-configured gate (TUI audit G4, S10-F2) ───────────────────────────
        # A project whose build stopped after its folder was created would ship without its org template or
        # installer configuration: W32T.ProjectNotConfigured, before the package gate and the ShouldProcess
        # (so also under -WhatIf), with no override.
        Assert-Win32ToolkitProjectConfigured -ProjectPath $ProjectPath -Operation Export

        # ── Package gate (D15 / PKG-04 / L5) ─────────────────────────────────────
        # Refuse to build (and later publish) a deploy script win32-toolkit cannot vouch for, BEFORE
        # IntuneWinAppUtil.exe is located or downloaded and before Staging is touched. Throws one
        # W32T.PackageNotReady error listing every problem; projects from older win32-toolkit versions
        # pass with a warning.
        $null = Assert-Win32ToolkitPackageReady -ProjectPath $ProjectPath -Stage Export -AllowLegacyScript:$AllowLegacyScript

        # ── Layout resolution: <BasePath>\Projects\<Template>\<ProjectName> ──────
        # An explicitly supplied -BasePath WINS — silently ignoring a parameter the caller passed and
        # writing Staging\ / IntuneWin\ somewhere else is never the right answer. Only when no -BasePath
        # was given do we derive it from the project path, and then the layout is VALIDATED: a project
        # that does not live under a Projects\<Template>\ pair fails loudly instead of scattering output
        # into a surprising directory two levels above wherever the project happens to sit.
        $resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).ProviderPath.TrimEnd('\')
        $projectName     = Split-Path $resolvedProject -Leaf
        $templateSeg     = Split-Path (Split-Path $resolvedProject -Parent) -Leaf

        if ($explicitBasePath) {
            $resolvedBase = $BasePath.Trim().TrimEnd('\')
        }
        else {
            $projectsRoot = Split-Path (Split-Path $resolvedProject -Parent) -Parent
            $derivedBase  = if ([string]::IsNullOrWhiteSpace($projectsRoot)) { $null } else { Split-Path $projectsRoot -Parent }

            if ([string]::IsNullOrWhiteSpace($derivedBase) -or
                (Split-Path $projectsRoot -Leaf) -ne 'Projects') {
                throw ("Cannot derive the BasePath from this project path: $resolvedProject" +
                       "`nThe expected layout is <BasePath>\Projects\<Template>\<ProjectName>." +
                       "`nRe-run with an explicit -BasePath so Staging\ and IntuneWin\ are created where you expect them.")
            }

            $resolvedBase = $derivedBase
        }

        $paths = Get-Win32ToolkitPaths -BasePath $resolvedBase

        # Where this run writes, and the ONE ShouldProcess for the whole package build (test campaign 2026-10-21,
        # S9-F1): under -WhatIf (or a declined -Confirm) nothing is downloaded, staged, optimised or built, and a
        # stale .intunewin from an earlier run is never reported as created.
        $stagingDir   = Join-Path $paths.Staging $templateSeg
        $stagingPath  = Join-Path $stagingDir $projectName
        $intuneWinDir = Join-Path $paths.IntuneWin $templateSeg
        $doPackage    = $PSCmdlet.ShouldProcess($projectName, "Package to '$intuneWinDir' via Staging '$stagingPath'")

        # ── Step 1: Locate IntuneWinAppUtil.exe ──────────────────────────────────
        # Module root is one level up from this Public\ script
        $moduleRoot  = Split-Path $PSScriptRoot -Parent
        $toolsFolder = Join-Path $moduleRoot 'Tools'
        $utilPath    = Join-Path $toolsFolder 'IntuneWinAppUtil.exe'

        if (-not (Test-Path $utilPath) -and -not $doPackage) {
            Write-Host "WhatIf: would download IntuneWinAppUtil.exe to $toolsFolder (and verify its Microsoft signature)." -ForegroundColor Yellow
        }
        elseif (-not (Test-Path $utilPath)) {
            Write-Verbose 'IntuneWinAppUtil.exe not found — downloading from Microsoft GitHub...'

            if (-not (Test-Path $toolsFolder)) {
                New-Item -Path $toolsFolder -ItemType Directory -Force | Out-Null
            }

            # Resolve download URL: try latest GitHub release asset first,
            # then fall back to the raw file committed in the repository root.
            $downloadUrl = $null
            try {
                $apiUrl  = 'https://api.github.com/repos/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/latest'
                $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
                $asset   = $release.assets | Where-Object { $_.name -eq 'IntuneWinAppUtil.exe' } | Select-Object -First 1
                if ($asset) {
                    $downloadUrl = $asset.browser_download_url
                    Write-Verbose "  Resolved release asset: $downloadUrl"
                }
            }
            catch {
                Write-Verbose '  GitHub Releases API not available — using raw repository file.'
            }

            if (-not $downloadUrl) {
                $downloadUrl = 'https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/master/IntuneWinAppUtil.exe'
            }

            try {
                Invoke-WebRequest -Uri $downloadUrl -OutFile $utilPath -UseBasicParsing
                Write-Host "✓ Downloaded IntuneWinAppUtil.exe to: $toolsFolder" -ForegroundColor Green
            }
            catch {
                throw "Failed to download IntuneWinAppUtil.exe: $($_.Exception.Message)`nDownload it manually from https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool and place it in: $toolsFolder"
            }

            # This binary is about to be EXECUTED on the packaging host, and the fallback URL above is a
            # MUTABLE ref (…/master/IntuneWinAppUtil.exe). Verify it is genuinely Microsoft-signed and fail
            # CLOSED — deleting it, so a rejected binary can never be silently reused by the next run.
            Assert-Win32ToolkitTrustedBinary -Path $utilPath -ExpectedSubject 'Microsoft Corporation' -RemoveOnFailure
            Write-Host '  ✓ Authenticode verified (Microsoft Corporation)' -ForegroundColor Green
        }
        else {
            # Also verify an ALREADY-PRESENT copy: a binary in Tools\ is not trustworthy merely because it
            # exists — it could be left over from a compromised download, or dropped there by something else.
            Assert-Win32ToolkitTrustedBinary -Path $utilPath -ExpectedSubject 'Microsoft Corporation' -RemoveOnFailure
            Write-Host "✓ Using IntuneWinAppUtil.exe from: $toolsFolder (Authenticode verified)" -ForegroundColor Gray
        }

        $intuneWinFile = $null
        if ($doPackage) {
            # ── Step 2: Copy raw project → Staging\<Template>\ ───────────────────────
            if (-not (Test-Path $stagingDir)) {
                New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null
            }

            # Always refresh the Staging copy so it matches the current raw project. A previous copy can hold
            # freshly-written PSADT modules that AV briefly locks, so remove with retry and fail loudly rather
            # than build the package on top of a stale, half-deleted Staging copy.
            if (Test-Path $stagingPath) {
                if (-not (Remove-Win32ToolkitPathWithRetry -Path $stagingPath)) {
                    throw "Could not clear the previous Staging copy at '$stagingPath' — a file is locked (close any process using it) and retry."
                }
            }

            # Copy ONLY what ships. Excluding the non-shipping folders (test scaffolding + Intune\ secrets) up
            # front — rather than copying everything and stripping afterwards — means there is no freshly-written,
            # AV-locked file for a later Remove-Item to choke on, the copy is smaller/faster, and the Intune\
            # Publications.json (tenant + app ids) can never leak into the package even if a strip were to fail.
            Write-Verbose 'Copying project to Staging (excluding non-shipping folders)...'
            $excludeFolders = Get-Win32ToolkitNonShippingFolders
            New-Item -Path $stagingPath -ItemType Directory -Force | Out-Null
            Get-ChildItem -LiteralPath $ProjectPath -Force |
                Where-Object { -not ($_.PSIsContainer -and $_.Name -in $excludeFolders) } |
                ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stagingPath $_.Name) -Recurse -Force }
            Write-Host "✓ Staging copy     : $stagingPath" -ForegroundColor Green

            # ── Step 3: Clean up the Staging copy ────────────────────────────────────
            Optimize-Win32ToolkitProject -ProjectPath $stagingPath

            # The package gate checked the project; the .intunewin is built from the Staging copy: its toolkit extension
            # (lean deploy script PR 2) must still be the project's, byte for byte, after the copy and the clean-up.
            $staged = @(Test-Win32ToolkitDeployExtension -ProjectPath $ProjectPath -Shape ([pscustomobject]@{ GeneratorVersion = $null }) -StagingPath $stagingPath | Where-Object { $_.Code -eq 'EXTENSION-STAGING' })
            if ($staged.Count -gt 0) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("win32-toolkit cannot vouch for the Staging copy of '$ProjectPath': $($staged[0].Message) Nothing was packaged or published."),
                    'W32T.PackageNotReady', [System.Management.Automation.ErrorCategory]::InvalidData, $stagingPath)
            }

            # ── Step 4: Ensure output folder exists (IntuneWin\<Template>\) ───────────
            if (-not (Test-Path $intuneWinDir)) {
                New-Item -Path $intuneWinDir -ItemType Directory -Force | Out-Null
            }

            # ── Step 5: Run IntuneWinAppUtil.exe ─────────────────────────────────────
            Write-Host ''
            Write-Host "Packaging project  : $projectName" -ForegroundColor Cyan
            Write-Host "  Raw project      : $ProjectPath" -ForegroundColor Gray
            Write-Host "  Staging copy     : $stagingPath" -ForegroundColor Gray
            Write-Host "  Output folder    : $intuneWinDir" -ForegroundColor Gray
            Write-Host ''

            $process = Start-Process -FilePath $utilPath `
                -ArgumentList "-c `"$stagingPath`" -s `"Invoke-AppDeployToolkit.ps1`" -o `"$intuneWinDir`" -q" `
                -Wait -PassThru -NoNewWindow

            if ($process.ExitCode -ne 0) {
                throw "IntuneWinAppUtil.exe exited with code $($process.ExitCode). Check the output above for details."
            }

            # ── Step 6: Rename output to <ProjectName>.intunewin ─────────────────────
            $defaultName  = Join-Path $intuneWinDir 'Invoke-AppDeployToolkit.intunewin'
            $renamedFile  = Join-Path $intuneWinDir "$projectName.intunewin"

            if (Test-Path $defaultName) {
                if (Test-Path $renamedFile) {
                    Remove-Item -Path $renamedFile -Force
                }
                Rename-Item -Path $defaultName -NewName "$projectName.intunewin"
            }

            $intuneWinFile = Get-Item -Path $renamedFile -ErrorAction SilentlyContinue
            if ($intuneWinFile) {
                $sizeMB = [math]::Round($intuneWinFile.Length / 1MB, 1)
                Write-Host "✓ Package created  : $($intuneWinFile.FullName)  ($sizeMB MB)" -ForegroundColor Green
            }
            else {
                Write-Warning 'IntuneWinAppUtil.exe completed but the expected .intunewin file was not found.'
                $exportProblems.Add("IntuneWinAppUtil.exe finished, but $renamedFile was not found: no package was built$(if ($PublishIntune -or $PublishUpdate) { ', so nothing was published' }).")
            }
        }
        else {
            Write-Host "WhatIf: would refresh Staging $stagingPath, optimize it and build $(Join-Path $intuneWinDir "$projectName.intunewin") (nothing was staged or packaged)." -ForegroundColor Yellow
        }

        # ── Step 6b: Package advisory (D1: warn, never block) ───────────────────
        # A failed Update test, a technology switch or an identity finding is shown next to the upload
        # prompt. Read-only and fail-open: nothing it calls raises W32T.*, so it can never stop a package.
        try {
            $null = Write-Win32ToolkitPackageAdvisory -ProjectPath $ProjectPath -Context Export -ProbeIfMissing
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Warning "Could not check the Update test and identity warnings: $($_.Exception.Message)"
        }

        # ── Step 7: Publish to Intune ─────────────────────────────────────────────
        # Restore the caller's progress preference before publishing: the Azure Storage upload bar
        # (Invoke-AzBlobUpload) is an intentional, useful progress bar and must be left to render.
        $ProgressPreference = $prevProgress

        if ($intuneWinFile) {
            $doInstall = [bool]$PublishIntune
            $doUpdate  = [bool]$PublishUpdate
            if (-not $doInstall -and -not $doUpdate -and -not $NoPublishPrompt) {
                Write-Host ''
                $answer = Read-Host 'Upload to Microsoft Intune now? (Y/N)'
                $doInstall = $answer -match '^[Yy]'
            }

            # Only forward the timeout when the caller actually supplied one — otherwise Publish's own
            # default (300 s) applies, so the value is never duplicated in two places.
            $publishArgs = @{}
            if ($PSBoundParameters.ContainsKey('PublishTimeoutSeconds')) {
                $publishArgs['TimeoutSeconds'] = $PublishTimeoutSeconds
            }

            if ($doInstall) {
                # Publish now EMITS a result object ({ AppId; DisplayName; ... }) so dependencies can be
                # related to the app it just created. Export's contract is to emit NOTHING (without -PassThru),
                # and it is called bare from the TUI — so capture it instead of leaking it into the pipeline;
                # -PassThru returns it in its summary.
                $pub = Publish-Win32ToolkitIntuneApp -IntuneWinPath $intuneWinFile.FullName -ProjectPath $ProjectPath @publishArgs
                foreach ($p in @($pub)) { if ($null -ne $p) { $published.Add($p) } }
            }
            if ($doUpdate) {
                # Pre-check: if no reliable "already installed" signal exists (e.g. an MSI with no
                # UpgradeCode), skip the update gracefully with a warning instead of throwing — which
                # matters most in "both" mode, where the install app has already uploaded.
                if (Get-Win32ToolkitRequirementRule -ProjectPath $ProjectPath -NoSave) {
                    $pub = Publish-Win32ToolkitIntuneApp -IntuneWinPath $intuneWinFile.FullName -ProjectPath $ProjectPath -AsUpdate @publishArgs
                    foreach ($p in @($pub)) { if ($null -ne $p) { $published.Add($p) } }
                }
                else {
                    Write-Warning 'Skipped the update app: this project has no reliable "already installed" signal (no install tattoo, MSI UpgradeCode, or app name). Publish the install app, or use supersedence.'
                    $exportProblems.Add("The update app was not published: this project has no reliable 'already installed' signal (no install tattoo, MSI UpgradeCode or app name).")
                }
            }
        }
        elseif (-not $doPackage -and ($PublishIntune -or $PublishUpdate)) {
            Write-Host "WhatIf: would publish to Intune after packaging ($(@($(if ($PublishIntune) { 'install app' }), $(if ($PublishUpdate) { 'update app' }) | Where-Object { $_ }) -join ' and '))." -ForegroundColor Yellow
        }

        if ($PassThru) {
            [pscustomobject]@{
                ProjectPath   = $ProjectPath
                IntuneWinPath = $(if ($intuneWinFile) { $intuneWinFile.FullName } else { '' })
                Published     = [object[]]@($published)
                Problems      = [string[]]@($exportProblems)
            }
        }
    }
    catch {
        # Fail-closed gates (W32T.PackageNotReady here, W32T.NoDetectionRule from Publish) pass through
        # unchanged, so scripted callers can catch them by FullyQualifiedErrorId.
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        # Re-throw (terminating) so failures — including the -AsUpdate "no requirement rule, refusing to
        # publish" guard — reach callers (the TUI catch, automation) instead of being downgraded to a
        # non-terminating error that looks like success.
        throw "Export-Win32ToolkitIntuneWin failed: $($_.Exception.Message)"
    }
    finally {
        # Never leak the silenced progress preference to the caller (e.g. the TUI menu loop), on any path.
        $ProgressPreference = $prevProgress
        if ($ownsAdvisoryRun) { $script:W32TAdvisoryRun = $null }
    }
}
