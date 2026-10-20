function Download-WingetApp {
    <#
    .SYNOPSIS
        Downloads a winget package's installer into the project's Files\ folder.
    .DESCRIPTION
        Fixes two real defects in the original implementation:

        1. IT REPORTED SUCCESS WHEN WINGET FAILED. The old version returned $true unless PowerShell itself
           threw — and a native command failing does NOT throw. A non-zero winget exit (package not found,
           no installer for the requested architecture, network failure) therefore produced an EMPTY Files\
           folder that every downstream step treated as a valid download: the project got scaffolded, the
           sandbox "tested" nothing, and detection rules were generated from an install that never happened.
           Now: `& winget @wingetArgs`, check $LASTEXITCODE, and verify an installer actually landed.

        2. INVOKE-EXPRESSION ON AN UNTRUSTED VALUE. The command was assembled as a STRING containing $AppId
           — a winget-supplied identifier — and run through Invoke-Expression, so an id carrying shell
           metacharacters was a code-execution surface on the packaging host. The arguments are now passed
           as an ARRAY: no shell parsing, nothing to escape.

        Mirrors Download-OldVersionInstaller, which already did both correctly.

        Installer technology pin (installer-identity PR 1, spec 2.10): with -InstallerType the download is
        pinned to that type's FAMILY (Get-Win32ToolkitInstallerFamily -PinOrder: the type first, then the
        other types of its family, e.g. wix then msi; nullsoft then burn, inno, exe). Each type is tried with
        '--installer-type <type>'; winget's no-applicable-installer answer (0x8A150010) moves to the next type
        after removing only the files that attempt wrote, and one host line names the type that is tried next
        (winget's own 'No applicable installer found' line is printed just above it); any other failure is a normal download failure
        ($false). When no type of the family is offered, it throws W32T.InstallerVariantUnavailable and
        nothing is downloaded: winget never silently picks another technology. Without -InstallerType (or
        with '') the winget arguments are exactly the unpinned ones and winget chooses. '--scope' is never
        passed (the manifest scope is only reported, D30).
    .PARAMETER AppId
        winget PackageIdentifier (e.g. 'Git.Git'). Passed as an argument, never spliced into a command line.
    .PARAMETER AppName
        Display name, for progress output only.
    .PARAMETER DownloadPath
        Destination folder (the project's Files\).
    .PARAMETER Architecture
        x64 | x86 | arm64. 'all' or empty lets winget choose.
    .PARAMETER InstallerType
        The pinned installer type (msi, wix, burn, nullsoft, inno, exe, msix). '' or absent = winget chooses.
    .PARAMETER PinnedBy
        Why the type is pinned (parameter | continuity), for the error message only.
    .PARAMETER PinReason
        The pin's reason text (e.g. 'kept from Notepad++_x64_8.8.9 (published)'), for the error message only.
    .OUTPUTS
        [bool] $true ONLY if winget exited 0 AND an installer file is actually present.
        Throws W32T.InstallerVariantUnavailable when a pinned family has no installer for this version.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppId,

        [string]$AppName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DownloadPath,

        [string]$Architecture,

        [string]$InstallerType,

        [string]$PinnedBy,

        [string]$PinReason
    )

    $label = if ($AppName) { "$AppName ($AppId)" } else { $AppId }
    Write-Verbose "Downloading $label [$Architecture]..."

    if (-not (Test-Path -LiteralPath $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    # Argument ARRAY — no shell, no Invoke-Expression, nothing to escape.
    $wingetArgs = @(
        'download'
        '--id',                 $AppId
        '--download-directory', $DownloadPath
        '--accept-source-agreements'
        '--accept-package-agreements'
    )
    if ($Architecture -and $Architecture -ne 'all') {
        $wingetArgs += '--architecture'
        $wingetArgs += $Architecture
    }

    if ([string]::IsNullOrWhiteSpace($InstallerType)) {
        # Not pinned: winget chooses the installer (the arguments above, nothing added).
        try {
            # winget's console lines go to the host: in the output stream they would turn the [bool]
            # result into an array that is always truthy for the caller. $LASTEXITCODE is still set.
            & winget @wingetArgs | Out-Host
        }
        catch {
            Write-Error "Failed to run winget for $label : $($_.Exception.Message)"
            return $false
        }

        # A native command failing does NOT throw — this check is the entire point of the fix.
        if ($LASTEXITCODE -ne 0) {
            Write-Error "winget download exited with code $LASTEXITCODE for $label — no usable installer was downloaded."
            return $false
        }
    }
    else {
        # Pinned: try each type of the pinned family in order; only "no applicable installer" moves on.
        $requested = $InstallerType.Trim().ToLowerInvariant()
        $types = @(Get-Win32ToolkitInstallerFamily -PinOrder $requested)
        if ($types.Count -eq 0) { $types = @($requested) }
        $usedType = $null
        for ($i = 0; $i -lt $types.Count; $i++) {
            $t = $types[$i]
            $before = @(Get-ChildItem -LiteralPath $DownloadPath -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            try {
                & winget @wingetArgs '--installer-type' $t | Out-Host
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Error "Failed to run winget for $label : $($_.Exception.Message)"
                return $false
            }
            $code = $LASTEXITCODE
            if ($code -eq 0) { $usedType = $t; break }
            if (-not (Test-Win32ToolkitWingetNoApplicableInstaller -ExitCode $code)) {
                # Any other failure is a plain download failure, exactly as without a pin (V30).
                Write-Error "winget download exited with code $code for $label — no usable installer was downloaded."
                return $false
            }
            # No '$t' installer for this version: remove only what this attempt wrote, then the next type.
            foreach ($f in @(Get-ChildItem -LiteralPath $DownloadPath -File -Recurse -Force -ErrorAction SilentlyContinue)) {
                if ($before -notcontains $f.FullName) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
            }
            # winget has just printed its own 'No applicable installer found' line: say what the toolkit does next,
            # on the host only (never the output stream: the result stays ONE [bool]). After the last type nothing
            # is printed here - the W32T.InstallerVariantUnavailable error below explains (B1 re-verification
            # 2026-10-21: the raw winget line stood alone until the substitute warning after the download).
            if ($i + 1 -lt $types.Count) {
                Write-Host "winget offers no '$t' installer for $label (the line above is winget's); trying '$($types[$i + 1])' (same technology family)." -ForegroundColor DarkGray
            }
        }

        if (-not $usedType) {
            $family = [string](Get-Win32ToolkitInstallerFamily -Type $requested).Family
            $familyLabel = switch ($family) { 'msi' { 'MSI' } 'exe' { 'vendor EXE' } 'msix' { 'MSIX' } default { $family } }
            $archText = if ($Architecture -and $Architecture -ne 'all') { $Architecture } else { 'any architecture' }
            $why = if ($PinReason) { $PinReason } elseif ($PinnedBy) { $PinnedBy } else { 'requested' }
            $msg = "winget offers no $familyLabel installer for $AppId ($archText); tried: $($types -join ', '). " +
                   "The installer technology was pinned ($why). Nothing was downloaded. Options: " +
                   '(1) skip this version and package the next one that ships it (recommended when a vendor drops a technology for one release); ' +
                   "(2) switch technology on purpose with -InstallerType <other type> - devices that already have the $familyLabel install then get a second registration (see docs/packaging.md, Installer technology)."
            throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($msg),
                'W32T.InstallerVariantUnavailable', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $AppId)
        }
        if ($usedType -ne $requested) {
            Write-Warning "Requested $requested; winget offers $usedType for this version (same technology family) - using it."
        }
    }

    # Belt and braces: winget can exit 0 having written only a manifest (a zip/portable/store package),
    # which would leave the project with nothing to install.
    # Bundles count as installers: .msixbundle/.appxbundle install and uninstall exactly like a plain
    # package (see Get-Win32ToolkitInstallerExtension). Note winget names the file after the manifest's
    # InstallerType, NOT the URL — Microsoft.PowerShell's manifest says 'msix' while serving a
    # .msixbundle, so a bundle routinely arrives here already called '.msix'. Extension-based bundle
    # handling is therefore useless; identity is content-detected downstream.
    $produced  = @(Get-ChildItem -LiteralPath $DownloadPath -File -ErrorAction SilentlyContinue)
    $installer = @($produced | Where-Object { $_.Extension -in (Get-Win32ToolkitInstallerExtension) })

    if ($installer.Count -eq 0) {
        Write-Error "winget reported success for $label but wrote no installer (.exe/.msi/.msix/.appx/.msixbundle/.appxbundle) to '$DownloadPath'. This is usually a zip/portable/store package with no silent installer."
        return $false
    }

    Write-Host "✓ Downloaded: $($installer[0].Name)" -ForegroundColor Green
    return $true
}
