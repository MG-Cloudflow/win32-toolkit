function New-Win32ToolkitTestVM {
    <#
    .SYNOPSIS
        Provisions the Hyper-V test VM: build (or attach) a golden VHDX, create a Gen2 VM, first-boot,
        wait for PowerShell Direct, and take a warm 'clean-base' standard checkpoint.
    .DESCRIPTION
        One-time setup for the Hyper-V test backend. HOST-ONLY — requires an elevated session and the
        Hyper-V PowerShell module. Two sources: build from a Windows 11 ISO (-IsoPath) or attach an
        existing bootable Gen2 VHDX (-VhdxPath, BYO). The VM is created with Secure Boot + a vTPM (Win11
        requirements), started, driven to readiness (Wait-Win32ToolkitVMReady), and frozen as a STANDARD
        (memory-state) checkpoint so later runs revert to a warm, logged-in desktop with no boot. The VM
        name, checkpoint name, and guest credential are saved to config for the resolver/provider.
        See knowledge-base/designs/hyperv-golden-image-build.md.
    .PARAMETER IsoPath
        Build the golden VHDX from this Windows 11 x64 ISO. Mutually exclusive with -VhdxPath.
    .PARAMETER VhdxPath
        Attach this existing bootable Gen2 VHDX (BYO). Mutually exclusive with -IsoPath.
    .PARAMETER Name
        VM name (default 'win32tk-golden').
    .PARAMETER Credential
        Guest local-admin credential (baked into the unattend when building; used for PowerShell Direct).
        Prompted if omitted.
    .PARAMETER MemoryStartupBytes / ProcessorCount / SwitchName
        VM hardware. Defaults: 4 GB, 2 vCPU, 'Default Switch' (NAT).
    .PARAMETER CheckpointName
        Warm checkpoint name (default 'clean-base').
    .PARAMETER ImageIndex
        Explicit edition index when building from ISO. Overrides -Edition.
    .PARAMETER Edition
        Edition name substring to pick when building from ISO (e.g. 'Pro', 'Enterprise', 'Home'). When
        omitted, the default preference is used: Windows 11 Pro first, Enterprise as a fallback. Pro is
        the right choice for a consumer multi-edition ISO (which has no Enterprise).
    .PARAMETER EnableTPM
        Attach a virtual TPM (default $true — Windows 11 requires it).
    .PARAMETER Recheckpoint
        Re-take the checkpoint on an existing VM.
    .PARAMETER Force
        Overwrite an existing VHDX / rebuild an existing VM.
    .EXAMPLE
        New-Win32ToolkitTestVM -IsoPath 'C:\iso\Win11_x64.iso'
    .EXAMPLE
        New-Win32ToolkitTestVM -VhdxPath 'D:\vm\win11-base.vhdx' -Credential (Get-Credential)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [string]$IsoPath,
        [string]$VhdxPath,
        [string]$Name = 'win32tk-golden',
        [pscredential]$Credential,
        [uint64]$MemoryStartupBytes = 4GB,
        [ValidateRange(1, 64)] [int]$ProcessorCount = 2,
        [string]$SwitchName = 'Default Switch',
        [string]$CheckpointName = 'clean-base',
        [int]$ImageIndex,
        [string]$Edition,
        [bool]$EnableTPM = $true,
        [switch]$Recheckpoint,
        [switch]$Force
    )

    # --- Preconditions -----------------------------------------------------------------------------
    if (-not (Test-Win32ToolkitElevated)) {
        throw 'New-Win32ToolkitTestVM requires an elevated (Administrator) session — Hyper-V + PowerShell Direct need it.'
    }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw 'The Hyper-V PowerShell module is not installed/enabled on this host.'
    }
    if (-not $IsoPath -and -not $VhdxPath) {
        throw 'Supply -IsoPath (build the golden VHDX from an ISO) or -VhdxPath (attach an existing VHDX).'
    }
    if ($IsoPath -and $VhdxPath) {
        throw '-IsoPath and -VhdxPath are mutually exclusive.'
    }
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Guest local-admin credential for VM '$Name' (e.g. w32admin)"
    }

    # --- Reuse an existing, healthy VM -------------------------------------------------------------
    $existing = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        $hasCp = Get-VMCheckpoint -VMName $Name -Name $CheckpointName -ErrorAction SilentlyContinue
        if ($hasCp -and -not $Recheckpoint) {
            Write-Host "VM '$Name' already exists with checkpoint '$CheckpointName' — reusing." -ForegroundColor Yellow
            Set-Win32ToolkitConfigValue -Name 'HyperVVMName'     -Value $Name
            Set-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Value $CheckpointName
            Set-Win32ToolkitGuestCredential -Credential $Credential
            return $existing
        }
    }
    if ($existing -and $Force) {
        if ($PSCmdlet.ShouldProcess($Name, 'Remove existing VM before rebuild')) {
            Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
            Get-VMCheckpoint -VMName $Name -ErrorAction SilentlyContinue | Remove-VMCheckpoint -ErrorAction SilentlyContinue
            Remove-VM -Name $Name -Force -ErrorAction SilentlyContinue
        }
    }

    # --- Resolve the VHDX (build from ISO or BYO) --------------------------------------------------
    $paths = Get-Win32ToolkitHyperVPaths -BasePath (Get-Win32ToolkitBasePath)
    foreach ($dir in @($paths.Golden, $paths.VMs)) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    if ($IsoPath) {
        $vhdx = Join-Path $paths.Golden "$Name.vhdx"
        if ($PSCmdlet.ShouldProcess($vhdx, "Build golden VHDX from '$IsoPath'")) {
            $buildArgs = @{ IsoPath = $IsoPath; VhdxPath = $vhdx; AdminCredential = $Credential; Force = [bool]$Force }
            if ($PSBoundParameters.ContainsKey('ImageIndex') -and $ImageIndex) { $buildArgs['ImageIndex'] = $ImageIndex }
            if ($Edition) { $buildArgs['Edition'] = $Edition }
            New-Win32ToolkitGoldenVhdx @buildArgs | Out-Null
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $VhdxPath)) { throw "BYO VHDX not found: $VhdxPath" }
        if ([IO.Path]::GetExtension($VhdxPath) -ne '.vhdx') { throw "BYO VHDX must be a .vhdx file: $VhdxPath" }
        $vhdx = $VhdxPath
    }

    # --- Create + configure the Gen2 VM ------------------------------------------------------------
    if ($PSCmdlet.ShouldProcess($Name, 'Create Gen2 VM + take clean-base checkpoint')) {
        New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $vhdx -Path $paths.VMs -SwitchName $SwitchName -ErrorAction Stop | Out-Null
        Set-VMFirmware  -VMName $Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
        Set-VMProcessor -VMName $Name -Count $ProcessorCount
        Set-VMMemory    -VMName $Name -DynamicMemoryEnabled $false -StartupBytes $MemoryStartupBytes
        if ($EnableTPM) {
            Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
            Enable-VMTPM       -VMName $Name
        }

        Write-Host "Starting VM '$Name' for first boot (unattended OOBE)..." -ForegroundColor Cyan
        Start-VM -Name $Name -ErrorAction Stop
        Wait-Win32ToolkitVMReady -VMName $Name -Credential $Credential | Out-Null

        Set-VM -Name $Name -CheckpointType Standard
        Checkpoint-VM -VMName $Name -SnapshotName $CheckpointName
        Write-Host "✓ Warm '$CheckpointName' checkpoint taken." -ForegroundColor Green

        Set-Win32ToolkitConfigValue -Name 'HyperVVMName'     -Value $Name
        Set-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Value $CheckpointName
        Set-Win32ToolkitConfigValue -Name 'HyperVBaseVhdx'   -Value $vhdx
        Set-Win32ToolkitGuestCredential -Credential $Credential
    }

    return (Get-VM -Name $Name -ErrorAction SilentlyContinue)
}
