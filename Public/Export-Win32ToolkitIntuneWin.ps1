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
    the registry-saved value is used (see Invoke-Win32Toolkit). Ignored when ProjectPath is supplied
    — the BasePath and template are derived from the path.
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
#>
    [CmdletBinding()]
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
        [switch]$NoPublishPrompt
    )

    try {
        # ── Project resolution ────────────────────────────────────────────────────
        if (-not $ProjectPath) {
            $BasePath = Get-Win32ToolkitBasePath -BasePath $BasePath
            Write-Host 'Scanning for PSADT projects...' -ForegroundColor Yellow
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

        # Derive layout from ProjectPath: <BasePath>\Projects\<Template>\<ProjectName>
        $projectName   = Split-Path $ProjectPath -Leaf
        $templateSeg   = Split-Path (Split-Path $ProjectPath -Parent) -Leaf
        $projectsRoot  = Split-Path (Split-Path $ProjectPath -Parent) -Parent
        $derivedBase   = Split-Path $projectsRoot -Parent
        $paths         = Get-Win32ToolkitPaths -BasePath $derivedBase

        # ── Step 1: Locate IntuneWinAppUtil.exe ──────────────────────────────────
        # Module root is one level up from this Public\ script
        $moduleRoot  = Split-Path $PSScriptRoot -Parent
        $toolsFolder = Join-Path $moduleRoot 'Tools'
        $utilPath    = Join-Path $toolsFolder 'IntuneWinAppUtil.exe'

        if (-not (Test-Path $utilPath)) {
            Write-Host 'IntuneWinAppUtil.exe not found — downloading from Microsoft GitHub...' -ForegroundColor Yellow

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
                    Write-Host "  Resolved release asset: $downloadUrl" -ForegroundColor Gray
                }
            }
            catch {
                Write-Host '  GitHub Releases API not available — using raw repository file.' -ForegroundColor Gray
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
        }
        else {
            Write-Host "✓ Using IntuneWinAppUtil.exe from: $toolsFolder" -ForegroundColor Gray
        }

        # ── Step 2: Copy raw project → Staging\<Template>\ ───────────────────────
        $stagingDir  = Join-Path $paths.Staging $templateSeg
        $stagingPath = Join-Path $stagingDir $projectName

        if (-not (Test-Path $stagingDir)) {
            New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null
        }

        # Always refresh the Staging copy so it matches the current raw project
        if (Test-Path $stagingPath) {
            Remove-Item -Path $stagingPath -Recurse -Force
        }

        Write-Host "Copying project to Staging..." -ForegroundColor Yellow
        Copy-Item -Path $ProjectPath -Destination $stagingPath -Recurse -Force
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
        }

        # ── Step 7: Publish to Intune ─────────────────────────────────────────────
        if ($intuneWinFile) {
            $doInstall = [bool]$PublishIntune
            $doUpdate  = [bool]$PublishUpdate
            if (-not $doInstall -and -not $doUpdate -and -not $NoPublishPrompt) {
                Write-Host ''
                $answer = Read-Host 'Upload to Microsoft Intune now? (Y/N)'
                $doInstall = $answer -match '^[Yy]'
            }
            if ($doInstall) {
                Publish-Win32ToolkitIntuneApp -IntuneWinPath $intuneWinFile.FullName -ProjectPath $ProjectPath
            }
            if ($doUpdate) {
                # Pre-check: if no reliable "already installed" signal exists (e.g. an MSI with no
                # UpgradeCode), skip the update gracefully with a warning instead of throwing — which
                # matters most in "both" mode, where the install app has already uploaded.
                if (Get-Win32ToolkitRequirementRule -ProjectPath $ProjectPath) {
                    Publish-Win32ToolkitIntuneApp -IntuneWinPath $intuneWinFile.FullName -ProjectPath $ProjectPath -AsUpdate
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
}
