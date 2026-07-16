function Initialize-Win32ToolkitDependencyStaging {
    <#
    .SYNOPSIS
        Stages the project's declared dependencies into Sandbox\Dependencies\ so the TEST/CAPTURE guest can
        install them BEFORE the app — mirroring what Intune does on a real device.
    .DESCRIPTION
        Intune app dependencies are a DEPLOYMENT-time relationship: the Intune Management Extension installs
        the dependency first on a managed device. The Sandbox / Hyper-V runs never touch Intune — they just
        execute PSADT — so without this the guest is a clean machine with the dependency MISSING. That is
        worst for the documentation capture: the app would install (or half-install) without its runtime and
        the detection rule / uninstall logic would be generated from a broken install.

        So each declared dependency is materialized into the project:
          winget:<id>              -> the installer is downloaded (latest) to Sandbox\Dependencies\<id>\
          project:<Template>\<Name>-> the packaged project is copied to Sandbox\Dependencies\<Name>\
          intune:<guid>            -> CANNOT be staged (we don't have the package) — warned and skipped

        Everything lands under Sandbox\, which Optimize-Win32ToolkitProject strips from the Staging copy, so
        none of it ever ships inside the .intunewin.

        It then writes:
          Sandbox\Dependencies\dependencies.json   the ordered install list (DATA)
          Sandbox\InstallDependencies.ps1          a VALUE-FREE 5.1-safe guest script that reads that JSON

        The generated script passes untrusted values (installer paths, winget silent args) to Start-Process
        as PARAMETERS read from JSON — they are never spliced into a code position. Same contract as
        designs/data-driven-generation.md.
    .PARAMETER ProjectPath
        The project whose dependencies should be staged.
    .OUTPUTS
        [int] the number of dependencies staged (0 when none are declared / none could be staged).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $deps = @(Get-Win32ToolkitDependencies -ProjectPath $ProjectPath)
    $depRoot    = Join-Path $ProjectPath 'Sandbox\Dependencies'
    $scriptPath = Join-Path $ProjectPath 'Sandbox\InstallDependencies.ps1'

    # ── Staging reuse (hash-validated, HOST-side integrity marker) ────────────────────────────────
    # A full pipeline stages the SAME dependencies 2-3 times (capture + each test), wiping and
    # re-downloading identical binaries each time. Reuse the existing staging when: the cache is on,
    # the DECLARED set is unchanged, the staging is < 6 h old (deps are unpinned 'latest' — bound the
    # staleness), and the staged tree matches the marker EXACTLY. Three properties make this safe on
    # BOTH backends (under Sandbox the whole project — including this staging — was mounted READ-WRITE
    # into a guest that ran an untrusted installer):
    #   1. the marker lives OUTSIDE the project, under <BasePath>\Cache\winget\staging\ — the guest can
    #      tamper the staged files but can never forge the record they are checked against;
    #   2. EVERY recorded file (installers, dependencies.json, AND the generated
    #      Sandbox\InstallDependencies.ps1 the guest executes) must re-hash to its recorded SHA256;
    #   3. the on-disk file SET must equal the recorded set — a guest-ADDED file is a miss, not a ride-along.
    # Any mismatch or error restages from scratch (today's behavior).
    $declaredJson = ConvertTo-Json -InputObject @($deps | ForEach-Object { "$($_.Source):$($_.Ref)" }) -Compress
    $declaredHash = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $declaredHash = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($declaredJson))) -replace '-', '') }
        finally { $sha.Dispose() }
    } catch { $declaredHash = $null }

    # Marker path: host-side cache root, keyed by the (case-normalized) project path.
    $stagedMark = $null
    try {
        $cacheRoot = Get-Win32ToolkitPipelineCacheRoot
        if ($cacheRoot -and $declaredHash) {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $projKey = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ProjectPath.ToLowerInvariant().TrimEnd('\')))) -replace '-', '').Substring(0, 16)
            } finally { $sha.Dispose() }
            $markDir = Join-Path $cacheRoot 'staging'
            if (-not (Test-Path -LiteralPath $markDir)) { New-Item -ItemType Directory -Path $markDir -Force | Out-Null }
            $stagedMark = Join-Path $markDir "$projKey.json"
        }
    } catch { $stagedMark = $null }

    # Enumerates the CURRENT staged tree as project-relative path -> SHA256 (covers the staged payloads,
    # dependencies.json, and the generated guest script — everything the guest run consumes).
    $enumerateStaged = {
        $list = @()
        if (Test-Path -LiteralPath $depRoot) {
            $list += @(Get-ChildItem -LiteralPath $depRoot -Recurse -File -ErrorAction SilentlyContinue)
        }
        if (Test-Path -LiteralPath $scriptPath) { $list += Get-Item -LiteralPath $scriptPath }
        @($list | Sort-Object FullName | ForEach-Object {
            @{ Path = $_.FullName.Substring($ProjectPath.Length + 1); Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
        })
    }

    if ($deps.Count -gt 0 -and $stagedMark -and (Test-Path -LiteralPath $stagedMark)) {
        try {
            $mark = Get-Content -LiteralPath $stagedMark -Raw | ConvertFrom-Json
            $fresh = $mark.DeclaredHash -eq $declaredHash -and
                     $mark.StagedAt -and (((Get-Date) - [datetime]$mark.StagedAt).TotalHours -lt 6)
            if ($fresh) {
                $current  = @(& $enumerateStaged)
                $expected = @($mark.Files)
                if ($current.Count -ne $expected.Count) { $fresh = $false }
                else {
                    for ($i = 0; $i -lt $current.Count; $i++) {
                        if ($current[$i].Path -ne $expected[$i].Path -or $current[$i].Sha256 -ne $expected[$i].Sha256) { $fresh = $false; break }
                    }
                }
            }
            if ($fresh) {
                Write-Host "✓ Dependencies already staged (hash-validated, $([int]$mark.Count) item(s)) — reusing." -ForegroundColor Green
                return [int]$mark.Count
            }
        }
        catch { Write-Verbose "Dependency staging reuse check failed (restaging): $($_.Exception.Message)" }
    }

    # Always start clean: a stale dependency from a previous run would silently install in the guest.
    if (Test-Path -LiteralPath $depRoot)    { Remove-Item -LiteralPath $depRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $scriptPath) { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue }
    if ($deps.Count -eq 0) { return 0 }

    New-Item -ItemType Directory -Path $depRoot -Force | Out-Null
    Write-Verbose "Staging $($deps.Count) dependency(ies) for the test/capture run..."

    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($d in $deps) {
        switch ($d.Source) {

            'winget' {
                # Folder name must be filesystem-safe; the winget ID itself is preserved verbatim as DATA.
                $safe    = ($d.Ref -replace '[\\/:*?"<>|]', '_')
                $destDir = Join-Path $depRoot $safe
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                try {
                    $dl = Download-OldVersionInstaller -AppId $d.Ref -ProjectPath $ProjectPath -DestinationDir $destDir
                    $entries.Add([pscustomobject]@{
                        Name       = $d.Ref
                        Type       = $dl.InstallerType                                          # exe|msi|msix|appx
                        Path       = "C:\PSADT\Sandbox\Dependencies\$safe\$($dl.InstallerName)" # guest path
                        SilentArgs = $dl.SilentArgs
                    })
                }
                catch {
                    Write-Warning "Could not stage the winget dependency '$($d.Ref)': $($_.Exception.Message). The test/capture run will NOT have it installed."
                }
            }

            'project' {
                $leaf = Split-Path -Leaf $d.Ref
                $src  = Join-Path (Get-Win32ToolkitPaths -BasePath (Get-Win32ToolkitBasePath)).Projects $d.Ref
                if (-not (Test-Path -LiteralPath (Join-Path $src 'Invoke-AppDeployToolkit.ps1'))) {
                    Write-Warning "Dependency project '$($d.Ref)' was not found (no Invoke-AppDeployToolkit.ps1 at $src). The test/capture run will NOT have it installed."
                    break
                }
                $destDir = Join-Path $depRoot $leaf
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                # Copy CONTENTS so the PSADT script sits directly under the dependency folder. Its own
                # Sandbox\ artifacts are excluded — we only need it to be installable.
                Copy-Item -Path (Join-Path $src '*') -Destination $destDir -Recurse -Force -Exclude 'Sandbox' -ErrorAction Stop
                $entries.Add([pscustomobject]@{
                    Name       = $d.Ref
                    Type       = 'psadt'
                    Path       = "C:\PSADT\Sandbox\Dependencies\$leaf\Invoke-AppDeployToolkit.ps1"
                    SilentArgs = $null
                })
            }

            'intune' {
                Write-Warning "Dependency 'intune:$($d.Ref)' is an app id in the tenant — the toolkit has no package for it, so it CANNOT be installed in the test/capture guest. The Intune relationship will still be created at publish time. Declare it as 'winget:' or 'project:' if you need it present during testing."
            }
        }
    }

    if ($entries.Count -eq 0) {
        Remove-Item -LiteralPath $depRoot -Recurse -Force -ErrorAction SilentlyContinue
        return 0
    }

    # ── the DATA the guest script consumes ─────────────────────────────────────────────────────────
    $manifest = Join-Path $depRoot 'dependencies.json'
    $json     = ConvertTo-Json -InputObject @($entries) -Depth 5
    [System.IO.File]::WriteAllText($manifest, $json, (New-Object System.Text.UTF8Encoding($false)))

    # ── the VALUE-FREE guest script (Windows PowerShell 5.1, UTF-8 WITH BOM) ───────────────────────
    $guest = @'
# Installs this project's declared dependencies BEFORE the app — the same thing Intune does on a real
# device (the Intune Management Extension installs a mobileAppDependency first). Generated by
# win32-toolkit: VALUE-FREE by design. Every untrusted value (installer path, winget silent args) is READ
# FROM JSON and passed to Start-Process as a PARAMETER — never spliced into a code position.
$ErrorActionPreference = 'Stop'
$manifest = 'C:\PSADT\Sandbox\Dependencies\dependencies.json'
if (-not (Test-Path -LiteralPath $manifest)) { Write-Host 'No dependencies to install.'; exit 0 }

$deps = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($d in @($deps)) {
    Write-Host ("Installing dependency: " + $d.Name) -ForegroundColor Cyan
    $rc = 0
    if ($d.Type -eq 'psadt') {
        & $d.Path -DeployMode Silent
        $rc = $LASTEXITCODE
        if ($null -eq $rc) { $rc = 0 }
    }
    elseif ($d.Type -eq 'msix' -or $d.Type -eq 'appx') {
        # Start-Process on a msix opens the App Installer GUI and blocks forever.
        Add-AppxPackage -Path $d.Path
    }
    elseif ($d.SilentArgs) {
        $p = Start-Process -FilePath $d.Path -ArgumentList $d.SilentArgs -Wait -PassThru
        $rc = $p.ExitCode
        Write-Host ("  exit code: " + $rc)
    }
    else {
        $p = Start-Process -FilePath $d.Path -Wait -PassThru
        $rc = $p.ExitCode
        Write-Host ("  exit code: " + $rc)
    }
    # PROPAGATE failure (0 = success, 3010 = success-needs-reboot; Intune installs dependencies first
    # and a failed dependency blocks the app). Exiting non-zero here is what stops the Hyper-V dep phase
    # from reporting success — and, with the deps-checkpoint feature, from FREEZING a broken image that
    # every later run of the project would silently reuse.
    if ($rc -ne 0 -and $rc -ne 3010) {
        Write-Host ("  FAILED: " + $d.Name + " (exit " + $rc + ")") -ForegroundColor Red
        exit $rc
    }
    Write-Host ("  installed: " + $d.Name) -ForegroundColor Green
}
Write-Host 'All dependencies installed.' -ForegroundColor Green
exit 0
'@
    [System.IO.File]::WriteAllText($scriptPath, $guest, (New-Object System.Text.UTF8Encoding($true)))

    # Record what was staged (declared-set hash + per-file SHA256 over EVERYTHING the guest consumes,
    # incl. the generated script) in the HOST-side marker so the next call in this pipeline can REUSE it
    # instead of wiping + re-downloading. Best-effort: a failure just means the next call restages.
    if ($stagedMark) {
        try {
            $files = @(& $enumerateStaged)
            $markJson = ConvertTo-Json -InputObject @{ DeclaredHash = $declaredHash; StagedAt = (Get-Date).ToString('o'); Count = $entries.Count; Files = $files } -Depth 4
            [System.IO.File]::WriteAllText($stagedMark, $markJson, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch { Write-Verbose "Could not record the staging marker (reuse disabled for the next call): $($_.Exception.Message)" }
    }

    Write-Host "✓ Dependencies staged: $(($entries | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Green
    return $entries.Count
}
