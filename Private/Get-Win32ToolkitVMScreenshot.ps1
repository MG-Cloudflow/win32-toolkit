function Get-Win32ToolkitVMScreenshot {
    <#
    .SYNOPSIS
        Captures the console framebuffer of a running Hyper-V VM to a PNG. HOST-ONLY, elevated.
    .DESCRIPTION
        Reads the VM's video framebuffer via Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage
        (root\virtualization\v2) and converts the raw RGB565 bytes to a PNG. No open vmconnect window and no
        interactive HOST session are required (it reads vmms.exe directly), so it can run in a Start-ThreadJob
        cadence while a PowerShell Direct call blocks the main runspace. Requires local admin (the Hyper-V WMI
        is UAC-filtered) and the VM Running with an active video mode.

        This is host tooling, not device-generated code, so PowerShell 7 syntax is fine here.
    .PARAMETER VMName
        The Hyper-V VM name.
    .PARAMETER Path
        Output PNG path. Parent directory is created if missing.
    .PARAMETER Width
        Optional width override. Default: the guest's current horizontal resolution (Msvm_VideoHead).
    .PARAMETER Height
        Optional height override. Default: the guest's current vertical resolution.
    .OUTPUTS
        [System.IO.FileInfo] of the written PNG.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$VMName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Path,
        [int]$Width,
        [int]$Height
    )

    Add-Type -AssemblyName System.Drawing.Common -ErrorAction SilentlyContinue
    $ns = 'root\virtualization\v2'

    $vmms = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService

    $vm = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$($VMName -replace "'", "''")'"
    if (-not $vm) { throw "VM '$VMName' not found in $ns (is Hyper-V present and are you elevated?)." }
    if ($vm -is [array]) { $vm = $vm[0] }
    if ($vm.EnabledState -ne 2) {   # 2 = Enabled / Running
        throw "VM '$VMName' is not running (EnabledState=$($vm.EnabledState)); there is no framebuffer to capture."
    }

    # The realized (active) settings-data instance is the TargetSystem reference the method wants.
    $setting = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData -Association Msvm_SettingsDefineState |
        Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' } |
        Select-Object -First 1
    if (-not $setting) { throw "Could not resolve the realized settings data for '$VMName'." }

    # Native resolution from Msvm_VideoHead (null right after power-on, before the guest sets a video mode).
    if (-not ($Width -and $Height)) {
        $video = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VideoHead |
            Where-Object { $_.CurrentHorizontalResolution -gt 0 } |
            Select-Object -First 1
        if (-not $video) {
            throw "No active video head for '$VMName' (the guest has not set a video mode yet). Capture once the desktop is up, or pass -Width/-Height."
        }
        $Width  = [int]$video.CurrentHorizontalResolution
        $Height = [int]$video.CurrentVerticalResolution
    }

    $out = Invoke-CimMethod -InputObject $vmms -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = [ciminstance]$setting
        WidthPixels  = [uint16]$Width
        HeightPixels = [uint16]$Height
    }
    if ($out.ReturnValue -ne 0) {
        $codes = @{ 32769 = 'Access Denied (run elevated)'; 32773 = 'Invalid parameter'; 32775 = 'Invalid state' }
        throw "GetVirtualSystemThumbnailImage failed: $($out.ReturnValue) $($codes[[int]$out.ReturnValue])"
    }
    $bytes = [byte[]]$out.ImageData

    # RGB565 wire bytes -> a Format16bppRgb565 bitmap -> PNG (factored out so it is unit-testable without
    # a Hyper-V host). Whole-buffer copy when the bitmap stride equals width*2 (every even width); else
    # row-by-row.
    ConvertFrom-Win32ToolkitRgb565Image -Bytes $bytes -Width $Width -Height $Height -Path $Path
}
