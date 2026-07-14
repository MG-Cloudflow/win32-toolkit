function New-Win32ToolkitGoldenVhdx {
    <#
    .SYNOPSIS
        Turns a Windows 11 ISO into a bootable Generation-2 (UEFI) VHDX with a seeded unattend.xml.
    .DESCRIPTION
        HOST-ONLY (in-box DISM + Storage + Hyper-V + bcdboot). Mounts the ISO, detects install.wim/esd,
        creates + partitions the VHDX, applies the chosen edition, makes it UEFI-bootable with bcdboot,
        and seeds the answer file into \Windows\Panther\unattend.xml WHILE the VHDX is still mounted (the
        verified ordering). All mounts are released in a finally block so the build is safe to re-run.
        See knowledge-base/designs/hyperv-golden-image-build.md (§2.2–2.3).
    .PARAMETER IsoPath
        Path to a Windows 11 x64 ISO (local, or one the operator fetched from the Evaluation Center).
    .PARAMETER VhdxPath
        Output VHDX path (overwritten only with -Force).
    .PARAMETER AdminCredential
        Guest local-admin account baked into the unattend (created + auto-logon).
    .PARAMETER ImageIndex
        Explicit edition index; omit to prefer an 'Enterprise' edition, else the first image.
    .PARAMETER SizeBytes
        VHDX size (dynamic). Default 64 GB.
    .PARAMETER ComputerName / Locale
        Passed to the unattend generator.
    .PARAMETER Force
        Overwrite an existing VHDX at VhdxPath.
    .OUTPUTS
        [string] the VhdxPath.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$IsoPath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$VhdxPath,
        [Parameter(Mandatory)] [ValidateNotNull()]        [pscredential]$AdminCredential,
        [int]$ImageIndex,
        [string]$Edition,
        [uint64]$SizeBytes = 64GB,
        [string]$ComputerName = 'GOLDENBASE',
        [string]$Locale = 'en-US',
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found: $IsoPath" }
    if (Test-Path -LiteralPath $VhdxPath) {
        if (-not $Force) { throw "VHDX already exists: $VhdxPath (use -Force to rebuild)." }
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $VhdxPath -Force
    }
    $vhdxDir = Split-Path -Parent $VhdxPath
    if ($vhdxDir -and -not (Test-Path -LiteralPath $vhdxDir)) { New-Item -ItemType Directory -Path $vhdxDir -Force | Out-Null }

    $isoMount = $null
    try {
        # Robust mount: stages a local copy when the ISO is a OneDrive placeholder (or the in-place mount
        # times out — "The semaphore timeout period has expired") and retries transient failures.
        $isoMount = Mount-Win32ToolkitIso -IsoPath $IsoPath
        $isoDrive = $isoMount.DriveLetter
        if (-not $isoDrive) { throw 'Could not resolve the mounted ISO drive letter.' }

        $imgArgs = @{ SourcesPath = "${isoDrive}:\sources" }
        if ($PSBoundParameters.ContainsKey('ImageIndex') -and $ImageIndex) { $imgArgs['ImageIndex'] = $ImageIndex }
        elseif ($Edition) { $imgArgs['EditionPreference'] = @($Edition) }
        $image = Get-Win32ToolkitInstallImage @imgArgs
        Write-Verbose "Applying image [$($image.Index)] $($image.ImageName) ($($image.Format))..."

        New-VHD -Path $VhdxPath -SizeBytes $SizeBytes -Dynamic -BlockSizeBytes 32MB -ErrorAction Stop | Out-Null
        $layout = Initialize-Win32ToolkitVhdxLayout -VhdxPath $VhdxPath

        Expand-WindowsImage -ImagePath $image.ImagePath -Index $image.Index -ApplyPath "$($layout.WindowsDrive)\" -ErrorAction Stop | Out-Null

        # Use the HOST's bcdboot.exe, NOT the applied image's copy: a newer/different guest build (e.g.
        # 25H2 media on an older host) has a bcdboot.exe/bcrypt.dll that fails to load on this host with
        # a "Bad Image 0xc0e90002" error. The host bcdboot still copies the boot files FROM the guest
        # $winDir onto the ESP (host + guest are the same architecture).
        $winDir  = "$($layout.WindowsDrive)\Windows"
        $bcdboot = Join-Path $env:SystemRoot 'System32\bcdboot.exe'
        & $bcdboot $winDir /s $layout.EspDrive /f UEFI
        if ($LASTEXITCODE -ne 0) { throw "bcdboot failed (exit $LASTEXITCODE) — see the console output above." }

        # Seed the answer file BEFORE dismount (the verified ordering — W: must still be mounted).
        $panther = Join-Path $winDir 'Panther'
        New-Item -ItemType Directory -Force $panther | Out-Null
        $unattend = New-Win32ToolkitUnattendXml -AdminCredential $AdminCredential -ComputerName $ComputerName -Locale $Locale
        Set-Content -LiteralPath (Join-Path $panther 'unattend.xml') -Value $unattend -Encoding UTF8

        Write-Host "✓ Golden VHDX built: $VhdxPath" -ForegroundColor Green
    }
    finally {
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
        if ($isoMount) {
            Dismount-DiskImage -ImagePath $isoMount.ImagePath -ErrorAction SilentlyContinue
            if ($isoMount.StagedPath) { Remove-Item -LiteralPath $isoMount.StagedPath -Force -ErrorAction SilentlyContinue }
        }
        else {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
        }
    }

    return $VhdxPath
}
