function Initialize-Win32ToolkitVhdxLayout {
    <#
    .SYNOPSIS
        Mounts a VHDX and lays down a UEFI/GPT layout (ESP FAT32 + MSR + Windows NTFS) via diskpart.
    .DESCRIPTION
        HOST-ONLY (runs diskpart). Mounts the VHDX, derives the disk number FROM the VHDX and asserts it
        is file-backed (Assert-Win32ToolkitVhdxDisk — the data-loss guard) BEFORE any `clean`, then
        partitions per the MS UEFI layout. Drive letters for the ESP and Windows partitions are chosen
        from the letters actually FREE on this host (Windows 365 / corporate machines commonly already use
        S:/W:, which broke a hard-coded assignment). Leaves the VHDX mounted (the caller applies the image
        and then dismounts). Returns the disk number + the ESP and Windows drive letters.
        See knowledge-base/designs/hyperv-golden-image-build.md (§2.2 Step 5).
    .PARAMETER VhdxPath
        Path to the VHDX to partition (created by the caller with New-VHD).
    .PARAMETER EspLetter
        Preferred ESP drive letter; used only if free, else an unused letter is chosen automatically.
    .PARAMETER WindowsLetter
        Preferred Windows drive letter; used only if free, else an unused letter is chosen automatically.
    .OUTPUTS
        PSCustomObject with: DiskNumber, EspDrive (e.g. 'S:'), WindowsDrive (e.g. 'W:').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VhdxPath,

        [string]$EspLetter,
        [string]$WindowsLetter
    )

    Mount-VHD -Path $VhdxPath -ErrorAction Stop | Out-Null
    $disk       = Get-DiskImage -ImagePath $VhdxPath | Get-Disk
    $diskNumber = Assert-Win32ToolkitVhdxDisk -Disk $disk   # throws unless 'File Backed Virtual'

    try {
        # Letters currently in use on the host (mounted volumes + mapped/network drives).
        $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
        # Free letters, Z down to D (skip A/B/C).
        $free = [System.Collections.Generic.List[string]]::new()
        foreach ($code in 90..68) { $ch = [string][char]$code; if ($ch -notin $used) { $free.Add($ch) } }
        if ($free.Count -lt 2) { throw 'Fewer than two free drive letters are available for the VHDX build.' }

        $esp = if ($EspLetter -and ($EspLetter.ToUpper() -notin $used)) { $EspLetter.ToUpper() } else { $free[0] }
        $win = if ($WindowsLetter -and ($WindowsLetter.ToUpper() -notin $used) -and ($WindowsLetter.ToUpper() -ne $esp)) { $WindowsLetter.ToUpper() }
               else { @($free | Where-Object { $_ -ne $esp })[0] }

        $script = @"
select disk $diskNumber
clean
convert gpt
create partition efi size=260
format quick fs=fat32 label=System
assign letter=$esp
create partition msr size=16
create partition primary
format quick fs=ntfs label=Windows
assign letter=$win
exit
"@

        $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("w32vhdx_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        try {
            Set-Content -LiteralPath $scriptFile -Value $script -Encoding ASCII
            $out = & diskpart /s $scriptFile 2>&1
            if ($LASTEXITCODE -ne 0) { throw "diskpart failed (exit $LASTEXITCODE): $out" }
        }
        finally {
            Remove-Item -LiteralPath $scriptFile -ErrorAction SilentlyContinue
        }

        [pscustomobject]@{
            DiskNumber   = $diskNumber
            EspDrive     = "${esp}:"
            WindowsDrive = "${win}:"
        }
    }
    catch {
        # Release the mount so a re-run (or -Force rebuild) isn't blocked by a half-partitioned VHDX.
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
        throw
    }
}
