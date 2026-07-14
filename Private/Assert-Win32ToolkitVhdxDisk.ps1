function Assert-Win32ToolkitVhdxDisk {
    <#
    .SYNOPSIS
        Asserts a Disk object is a mounted VHDX before any destructive partitioning — the data-loss guard.
    .DESCRIPTION
        The golden-image build partitions a freshly-mounted VHDX with `diskpart ... clean`. Deriving the
        wrong disk number and cleaning a PHYSICAL disk is the classic catastrophic bug, so every caller
        must pass the disk (obtained via `Get-DiskImage -ImagePath <vhdx> | Get-Disk`) through here first.
        A mounted VHDX reports BusType 'File Backed Virtual'; anything else is refused.
        See knowledge-base/designs/hyperv-golden-image-build.md (§2.2 Step 5 / §2.6).
    .PARAMETER Disk
        A disk object (from Get-Disk) with .Number and .BusType.
    .OUTPUTS
        [int] the safe disk number (throws if the disk is not a mounted VHDX).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Disk
    )

    if ($Disk.BusType -ne 'File Backed Virtual') {
        throw "Refusing to partition disk $($Disk.Number): BusType is '$($Disk.BusType)', not a mounted VHDX ('File Backed Virtual'). Aborting to avoid touching a physical disk."
    }
    return [int]$Disk.Number
}
