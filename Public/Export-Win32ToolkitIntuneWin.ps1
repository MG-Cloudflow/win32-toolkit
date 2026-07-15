function Export-Win32ToolkitIntuneWin {
<#
.SYNOPSIS
    Packages a PSADT project into a .intunewin file for Intune deployment.
.DESCRIPTION
    Works with the win32-toolkit 3-tier folder layout:

        <BasePath>\
          Projects\    raw PSADT projects — never modified
          Staging\     cleaned copy produced during packaging (kept for re-runs)
          IntuneWin\   finished .intunewin files

    Steps performed:
    1. Resolves the target project (interactive picker if ProjectPath is omitted).
    2. Locates or auto-downloads IntuneWinAppUtil.exe into the module's Tools\ folder.
    3. Copies the raw project into Staging\<ProjectName>\ (re-copies if already present
       so the Staging copy always reflects the latest raw project state).
    4. Runs Optimize-Win32ToolkitProject against the Staging copy — removes Docs\,
       Examples\, *.md, Sandbox\, Documentation\, and empty dirs.
       The original Projects\ folder is untouched.
    5. Runs IntuneWinAppUtil.exe against the Staging copy, outputting to IntuneWin\.
    6. Renames the produced Invoke-AppDeployToolkit.intunewin → <ProjectName>.intunewin.

.PARAMETER ProjectPath
    Full path to the raw PSADT project folder under Projects\.
    If omitted, an interactive numbered list is shown.
.PARAMETER BasePath
    Root folder containing the Templates\, Projects\, Staging\, and IntuneWin\ tiers. If omitted,
    the registry-saved value is used (see Invoke-Win32Toolkit).

    When -ProjectPath is supplied, an explicit -BasePath is honoured: Staging\ and IntuneWin\ are
    written under it. If -BasePath is omitted, the base is derived from the project path, which must
    follow the <BasePath>\Projects\<Template>\<ProjectName> layout — a project stored anywhere else
    is an error telling you to pass -BasePath (rather than silently creating Staging\ and IntuneWin\
    in an unexpected place).
.EXAMPLE
    Export-Win32ToolkitIntuneWin
.EXAMPLE
    Export-Win32ToolkitIntuneWin -BasePath 'D:\Packaging'
.EXAMPLE
    Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0'
.PARAMETER PublishIntune
    After packaging, upload the .intunewin file directly to Microsoft Intune via Graph API.
    Requires the Microsoft.Graph.Authentication module. You will be prompted to authenticate
    interactively on the first run.
.EXAMPLE
    Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -PublishIntune
.PARAMETER PublishUpdate
    Also (or instead of -PublishIntune) publish the update app — a 2nd Intune app of the same version
    with an "app already installed" requirement rule. Use with -PublishIntune to publish both.
.EXAMPLE
    # Publish both the install app and the requirement-gated update app
    Export-Win32ToolkitIntuneWin -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0' -PublishIntune -PublishUpdate
.PARAMETER PublishTimeoutSeconds
    Passed straight to Publish-Win32ToolkitIntuneApp -TimeoutSeconds: how long to wait for Intune's two
    asynchronous steps (Azure Storage SAS URI, file commit). Omit to use that command's default (300 s).
    Raise it for very large packages or a slow tenant.
.EXAMPLE
    # A big package on a slow tenant — wait up to 15 minutes for the commit
    Export-Win32ToolkitIntuneWin -ProjectPath $proj -PublishIntune -PublishTimeoutSeconds 900
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
        [int]$PublishTimeoutSeconds
    )

    # Silence stock-cmdlet progress bars (Copy-Item / Remove-Item on the Staging copy) for the packaging
    # steps — they otherwise paint bars that tear an interactive (Spectre) TUI. Restored before the publish
    # step (and in finally) so the intentional Azure-upload progress bar is left untouched.
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
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

        # ── Step 1: Locate IntuneWinAppUtil.exe ──────────────────────────────────
        # Module root is one level up from this Public\ script
        $moduleRoot  = Split-Path $PSScriptRoot -Parent
        $toolsFolder = Join-Path $moduleRoot 'Tools'
        $utilPath    = Join-Path $toolsFolder 'IntuneWinAppUtil.exe'

        if (-not (Test-Path $utilPath)) {
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

        # ── Step 2: Copy raw project → Staging\<Template>\ ───────────────────────
        $stagingDir  = Join-Path $paths.Staging $templateSeg
        $stagingPath = Join-Path $stagingDir $projectName

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

        # ── Step 4: Ensure output folder exists (IntuneWin\<Template>\) ───────────
        $intuneWinDir = Join-Path $paths.IntuneWin $templateSeg
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

        if ($PSCmdlet.ShouldProcess($projectName, 'Build .intunewin package')) {
            $process = Start-Process -FilePath $utilPath `
                -ArgumentList "-c `"$stagingPath`" -s `"Invoke-AppDeployToolkit.ps1`" -o `"$intuneWinDir`" -q" `
                -Wait -PassThru -NoNewWindow

            if ($process.ExitCode -ne 0) {
                throw "IntuneWinAppUtil.exe exited with code $($process.ExitCode). Check the output above for details."
            }
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
                # related to the app it just created. Export's contract is to emit NOTHING, and it is called
                # bare from Invoke-Win32ToolkitFinalize and the TUI — so capture it instead of leaking it
                # into their pipelines.
                $null = Publish-Win32ToolkitIntuneApp -IntuneWinPath $intuneWinFile.FullName -ProjectPath $ProjectPath @publishArgs
            }
            if ($doUpdate) {
                # Pre-check: if no reliable "already installed" signal exists (e.g. an MSI with no
                # UpgradeCode), skip the update gracefully with a warning instead of throwing — which
                # matters most in "both" mode, where the install app has already uploaded.
                if (Get-Win32ToolkitRequirementRule -ProjectPath $ProjectPath) {
                    $null = Publish-Win32ToolkitIntuneApp -IntuneWinPath $intuneWinFile.FullName -ProjectPath $ProjectPath -AsUpdate @publishArgs
                }
                else {
                    Write-Warning 'Skipped the update app: this project has no reliable "already installed" signal (no install tattoo, MSI UpgradeCode, or app name). Publish the install app, or use supersedence.'
                }
            }
        }
    }
    catch {
        # Re-throw (terminating) so failures — including the -AsUpdate "no requirement rule, refusing to
        # publish" guard — reach callers (the TUI catch, automation) instead of being downgraded to a
        # non-terminating error that looks like success.
        throw "Export-Win32ToolkitIntuneWin failed: $($_.Exception.Message)"
    }
    finally {
        # Never leak the silenced progress preference to the caller (e.g. the TUI menu loop), on any path.
        $ProgressPreference = $prevProgress
    }
}
