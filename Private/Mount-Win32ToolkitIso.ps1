function Mount-Win32ToolkitIso {
    <#
    .SYNOPSIS
        Mounts a Windows ISO robustly: hydrates/stages a local copy when the source is a OneDrive
        placeholder (or the in-place mount fails), and retries transient mount failures. Returns the
        drive letter plus the path actually mounted and any staged temp copy to clean up.
    .DESCRIPTION
        Mount-DiskImage reads the ISO through the filesystem, so a OneDrive Files-On-Demand *placeholder*
        (or slow/redirected storage — common in a Downloads folder on a Windows 365 Cloud PC) makes it
        stall and fail with "The semaphore timeout period has expired." This helper:
          1. If the file is marked Offline (a cloud placeholder), stages a hydrated local copy up front.
          2. Mounts with a small retry (dismounting any half-attached image between attempts).
          3. If an in-place mount still fails and we haven't staged yet, stages a local copy and retries.
        The caller dismounts ImagePath and deletes StagedPath (when set) in its finally. HOST-ONLY.
    .PARAMETER IsoPath
        Path to the Windows ISO.
    .PARAMETER MountRetries
        Attempts per mount target before giving up. Default 3.
    .PARAMETER StageDirectory
        Where a staged copy is written. Default: the system TEMP folder (local fixed disk).
    .PARAMETER NoStage
        Never stage a local copy (mount in place only, still with retries).
    .OUTPUTS
        PSCustomObject: DriveLetter (char), ImagePath (string, the path that is mounted), StagedPath
        (string or $null — a temp copy the caller must delete).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$IsoPath,
        [ValidateRange(1, 10)] [int]$MountRetries = 3,
        [string]$StageDirectory = ([System.IO.Path]::GetTempPath()),
        [switch]$NoStage
    )

    if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found: $IsoPath" }
    $item = Get-Item -LiteralPath $IsoPath

    # Copy the ISO to a local temp file, guarding on free space. Returns the staged path.
    $stage = {
        param([string]$src)
        $dst = Join-Path $StageDirectory ('w32iso_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.iso')
        try {
            $need = [int64]((Get-Item -LiteralPath $src).Length)
            $free = (Get-PSDrive -Name ($dst.Substring(0, 1)) -ErrorAction SilentlyContinue).Free
            # -ne $null (not truthiness): a genuinely full drive reports Free = 0, which must still trip the guard.
            if ($null -ne $free -and $free -lt ($need * 1.1)) {
                throw ("Not enough free space at '$StageDirectory' to stage the ISO (need ~{0:N1} GB, free ~{1:N1} GB)." -f ($need / 1GB), ($free / 1GB))
            }
        }
        catch { if ($_.Exception.Message -like 'Not enough free space*') { throw } }  # space error is fatal; probing errors are not
        Write-Verbose "Staging ISO to local disk ($dst)..."
        try {
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        }
        catch {
            # Copy-Item does NOT roll back a partial write. On the OneDrive/slow storage this targets, a
            # recall failure can leave a partial multi-GB temp file whose path we're about to lose (the
            # block throws before $dst is returned, so the outer catch's $staged is still $null). Delete it here.
            Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
            throw
        }
        $dst
    }

    # Mount one path with retries; dismount a half-attached image between tries. Throws if all fail.
    $mount = {
        param([string]$path)
        for ($i = 1; $i -le $MountRetries; $i++) {
            try {
                $img = Mount-DiskImage -ImagePath $path -StorageType ISO -PassThru -ErrorAction Stop
                $dl  = ($img | Get-Volume).DriveLetter
                if ($dl) { return $dl }
                throw 'ISO mounted but no drive letter was assigned.'
            }
            catch {
                Dismount-DiskImage -ImagePath $path -ErrorAction SilentlyContinue | Out-Null
                if ($i -ge $MountRetries) { throw }
                Write-Warning "ISO mount attempt $i/$MountRetries failed ($($_.Exception.Message)); retrying..."
                Start-Sleep -Seconds ([Math]::Min(10, 2 * $i))
            }
        }
    }

    $staged = $null
    $source = $IsoPath
    try {
        # A cloud placeholder will reliably time out — stage before the first attempt.
        if (-not $NoStage -and ($item.Attributes -band [System.IO.FileAttributes]::Offline)) {
            Write-Warning "ISO '$IsoPath' is a OneDrive/offline placeholder — staging a local copy first."
            $staged = & $stage $IsoPath
            $source = $staged
        }

        try {
            $drive = & $mount $source
        }
        catch {
            if (-not $staged -and -not $NoStage) {
                Write-Warning "Mounting '$IsoPath' in place failed ($($_.Exception.Message)). Staging a local copy and retrying..."
                $staged = & $stage $IsoPath
                $source = $staged
                $drive  = & $mount $source     # if this throws too, let it propagate
            }
            else {
                throw
            }
        }
    }
    catch {
        # We created a staged copy but never return the object, so the caller's finally can't clean it up.
        # Delete the (potentially multi-GB) temp copy here before resurfacing the error.
        if ($staged) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
        throw
    }

    [pscustomobject]@{
        DriveLetter = $drive
        ImagePath   = $source
        StagedPath  = $staged
    }
}
