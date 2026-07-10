function Initialize-Win32ToolkitVhdxLayout {
    <#
    .SYNOPSIS
        Mounts a VHDX and lays down a UEFI/GPT layout (ESP FAT32 + MSR + Windows NTFS) via diskpart.
    .DESCRIPTION
        HOST-ONLY (runs diskpart). Mounts the VHDX, derives the disk number FROM the VHDX and asserts it
        is file-backed (Assert-Win32ToolkitVhdxDisk — the data-loss guard) BEFORE any `clean`, then
        partitions per the MS UEFI layout. Leaves the VHDX mounted (the caller applies the image and then
        dismounts). Returns the disk number + the ESP and Windows drive letters.
        See knowledge-base/designs/hyperv-golden-image-build.md (§2.2 Step 5).
    .PARAMETER VhdxPath
        Path to the VHDX to partition (created by the caller with New-VHD).
    .PARAMETER EspLetter
        Drive letter to assign the EFI System Partition (default 'S').
    .PARAMETER WindowsLetter
        Drive letter to assign the Windows partition (default 'W').
    .OUTPUTS
        PSCustomObject with: DiskNumber, EspDrive (e.g. 'S:'), WindowsDrive (e.g. 'W:').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VhdxPath,

        [ValidatePattern('^[C-Z]$')]
        [string]$EspLetter = 'S',

        [ValidatePattern('^[C-Z]$')]
        [string]$WindowsLetter = 'W'
    )

    Mount-VHD -Path $VhdxPath -ErrorAction Stop | Out-Null
    $disk       = Get-DiskImage -ImagePath $VhdxPath | Get-Disk
    $diskNumber = Assert-Win32ToolkitVhdxDisk -Disk $disk   # throws unless 'File Backed Virtual'

    $script = @"
select disk $diskNumber
clean
convert gpt
create partition efi size=260
format quick fs=fat32 label=System
assign letter=$EspLetter
create partition msr size=16
create partition primary
format quick fs=ntfs label=Windows
assign letter=$WindowsLetter
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
        EspDrive     = "${EspLetter}:"
        WindowsDrive = "${WindowsLetter}:"
    }
}
