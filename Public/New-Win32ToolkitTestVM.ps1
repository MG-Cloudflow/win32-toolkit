function New-Win32ToolkitTestVM {
    <#
    .SYNOPSIS
        Provisions the Hyper-V test VM: build (or attach) a golden VHDX, create a Gen2 VM, first-boot,
        wait for PowerShell Direct, and take a warm 'clean-base' standard checkpoint.
    .DESCRIPTION
        One-time setup for the Hyper-V test backend. HOST-ONLY — requires an elevated session and the
        Hyper-V PowerShell module. Two sources: build from a Windows 11 ISO (-IsoPath) or attach an
        existing bootable Gen2 VHDX (-VhdxPath, BYO). The VM is created with Secure Boot + a vTPM (Win11
        requirements), started, and driven to readiness (Wait-Win32ToolkitVMReady). Then — unless
        -Unattended — it PAUSES and hands you the VM console so you can sign in, run Windows Update and
        let all reboots finish; once you confirm, it freezes a STANDARD (memory-state) checkpoint so later
        runs revert to that warm, fully-patched, logged-in desktop with no boot. The VM name, checkpoint
        name, and guest credential are saved to config for the resolver/provider.
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
    .PARAMETER Unattended
        Skip the manual-prep pause and checkpoint the fresh first-boot desktop automatically (CI /
        automation). By default provisioning STOPS before the checkpoint, opens the VM console, and lets
        you sign in, run Windows Update, and finish all reboots — then asks you to confirm, so 'clean-base'
        captures a fully-patched, idle desktop instead of a bare first boot.
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
        [switch]$Force,
        [switch]$Unattended
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
        # Prompt with a type-it-twice confirmation — a mistyped password here gets baked into the golden
        # image (unattend + Winlogon) and then nothing can log in, forcing a full rebuild.
        $Credential = Get-Win32ToolkitGuestCredentialInteractive -Message "Guest local-admin credential for VM '$Name' — enter the password twice; it must NOT be blank."
    }
    if ([string]::IsNullOrEmpty($Credential.GetNetworkCredential().Password)) {
        throw "The guest admin password must not be empty. A blank password is blocked for PowerShell Direct (the 'Limit local account use of blank passwords to console logon only' policy) and prevents AutoLogon — the build boots to a login screen instead of an auto-logged-in desktop. Re-run with a strong password."
    }

    # Reuse the last chosen CPU/RAM (persisted by a prior provision or by Set-Win32ToolkitTestVMResource) as the
    # defaults, unless the caller passed them explicitly. So a re-provision keeps your specs without re-typing.
    if (-not $PSBoundParameters.ContainsKey('ProcessorCount')) {
        $storedCpu = Get-Win32ToolkitConfigValue -Name 'HyperVProcessorCount' -Default ''
        if ($storedCpu) { $ProcessorCount = [int]$storedCpu }
    }
    if (-not $PSBoundParameters.ContainsKey('MemoryStartupBytes')) {
        $storedMem = Get-Win32ToolkitConfigValue -Name 'HyperVMemoryStartupBytes' -Default ''
        if ($storedMem) { $MemoryStartupBytes = [uint64]$storedMem }
    }

    # --- Reuse an existing, healthy VM -------------------------------------------------------------
    $existing = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        $hasCp = Get-VMCheckpoint -VMName $Name -Name $CheckpointName -ErrorAction SilentlyContinue
        if ($hasCp -and -not $Recheckpoint) {
            # Reuse is the intended fast path on a re-run — a normal success outcome, not a problem, so keep it
            # on Write-Host (a Write-Warning here reads as a spurious alarm on the happy path).
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
        # Invalidate the process-local clean marker / readiness cache — a brand-new VM + checkpoint
        # supersede anything cached about the previous one.
        Clear-Win32ToolkitHyperVStateCache
        New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $vhdx -Path $paths.VMs -SwitchName $SwitchName -ErrorAction Stop | Out-Null
        Set-VMFirmware  -VMName $Name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
        Set-VMProcessor -VMName $Name -Count $ProcessorCount
        Set-VMMemory    -VMName $Name -DynamicMemoryEnabled $false -StartupBytes $MemoryStartupBytes
        if ($EnableTPM) {
            Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
            Enable-VMTPM       -VMName $Name
        }

        # Unplug the vNIC for the OOBE boot so Windows 11 OOBE does NOT stall on its network-dependent
        # "checking for updates" device-prep phase — with no network it fails fast and goes straight to
        # the desktop. Safe: PowerShell Direct is over the VMBus, not TCP/IP. Reconnected before the
        # checkpoint so reverts have internet for the test workload (winget).
        Disconnect-VMNetworkAdapter -VMName $Name -ErrorAction SilentlyContinue

        Write-Verbose "Starting VM '$Name' for first boot (unattended OOBE, NIC unplugged)..."
        Start-VM -Name $Name -ErrorAction Stop
        Wait-Win32ToolkitVMReady -VMName $Name -Credential $Credential | Out-Null

        # Let the first-logon reach a SETTLED desktop before checkpointing (explorer.exe = shell is up),
        # so clean-base is a real desktop, not a half-finished OOBE screen.
        Write-Verbose 'Waiting for the guest desktop to settle (explorer)...'
        $shellDeadline = (Get-Date).AddMinutes(10)
        $shellUp = $false
        do {
            Start-Sleep -Seconds 10
            $shellUp = [bool](Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock {
                [bool](Get-Process -Name explorer -ErrorAction SilentlyContinue)
            } -ErrorAction SilentlyContinue)
        } until ($shellUp -or (Get-Date) -gt $shellDeadline)
        if (-not $shellUp) { Write-Warning 'Desktop shell (explorer) not detected before timeout — checkpointing anyway.' }

        # Reconnect the NIC BEFORE configuring AutoLogon (Sysinternals Autologon needs guest internet) and
        # before the warm checkpoint (so the workload has internet on revert).
        Connect-VMNetworkAdapter -VMName $Name -SwitchName $SwitchName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 8   # let the NIC acquire an address

        # Safety net: configure guest AutoLogon so any reboot during prep (Windows Update) lands back on
        # the desktop, and so the -EnsureDesktop recovery path works later.
        try { Set-Win32ToolkitGuestAutoLogon -VMName $Name -Credential $Credential }
        catch { Write-Warning "Could not configure guest AutoLogon: $($_.Exception.Message)" }

        # --- Manual prep window (default) --------------------------------------------------------------
        # A STANDARD checkpoint freezes the LIVE state (memory + disk): every test run reverts to the
        # EXACT moment captured here. So don't snapshot a bare first-boot desktop — hand the VM to the
        # operator to sign in, run Windows Update, and let all reboots finish, then confirm. -Unattended
        # skips this and checkpoints immediately (CI / automation).
        if (-not $Unattended) {
            # Try to pop the VM console. vmconnect.exe ships with the Hyper-V GUI tools, which can be ABSENT
            # on a Server / Cloud PC that only has the Hyper-V PowerShell module — resolve it robustly and,
            # if it's missing, tell the operator how to open the VM another way (a blind pause is useless).
            $vmconnect = (Get-Command 'vmconnect.exe' -ErrorAction SilentlyContinue).Source
            if (-not $vmconnect) {
                $cand = Join-Path $env:SystemRoot 'System32\vmconnect.exe'
                if (Test-Path -LiteralPath $cand) { $vmconnect = $cand }
            }
            $consoleOpened = $false
            if ($vmconnect) {
                try { Start-Process -FilePath $vmconnect -ArgumentList 'localhost', $Name -ErrorAction Stop; $consoleOpened = $true }
                catch { }
            }

            # Windows Update needs real internet. Verify it (and repair the common nested Default-Switch DNS
            # failure) BEFORE the operator relies on it, so "Windows Update just sits there" is caught here.
            Write-Verbose 'Checking the guest has working internet (Windows Update needs it)...'
            $guestNet = Confirm-Win32ToolkitGuestInternet -VMName $Name -Credential $Credential

            $sam = $Credential.UserName.Split('\')[-1]
            Write-Host ''
            Write-Host '──────────────────────────────────────────────────────────────────────────────' -ForegroundColor Yellow
            Write-Host '  PREPARE THE VM, THEN CONFIRM — the checkpoint freezes whatever state is live' -ForegroundColor Yellow
            Write-Host '──────────────────────────────────────────────────────────────────────────────' -ForegroundColor Yellow
            Write-Host "  The VM '$Name' IS created and running right now — this prompt is only waiting for you." -ForegroundColor Green
            if ($guestNet) {
                Write-Host '  Guest internet: OK (DNS + outbound reachable) — Windows Update should work.' -ForegroundColor Green
            }
            else {
                Write-Host '  Guest internet: NOT confirmed — Windows Update will not download.' -ForegroundColor Red
                Write-Host "     Tried DHCP renew + public DNS already. Check: Get-VMSwitch 'Default Switch', and in the" -ForegroundColor Yellow
                Write-Host '     VM run  Test-NetConnection www.msftconnecttest.com -Port 80 . On a nested host the' -ForegroundColor Yellow
                Write-Host "     Default Switch NAT must be up; you can also try  Set-VMNetworkAdapter -VMName $Name -MacAddressSpoofing On." -ForegroundColor Yellow
            }
            if ($consoleOpened) {
                Write-Host "  A console window opened for '$Name'. In that window:" -ForegroundColor Cyan
            }
            else {
                Write-Host '  Could NOT auto-open the VM console (vmconnect.exe not available on this host).' -ForegroundColor Yellow
                Write-Host '  Open the VM yourself, any one of:' -ForegroundColor Yellow
                Write-Host "     - Hyper-V Manager  ->  Connect to '$Name'" -ForegroundColor Yellow
                Write-Host "     - run:  vmconnect.exe localhost $Name" -ForegroundColor Yellow
                Write-Host '     - install the console:  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-Clients -All' -ForegroundColor Yellow
                Write-Host '  Then, in the VM:' -ForegroundColor Cyan
            }
            Write-Host "    1. Sign in if you're not already (user: $sam)." -ForegroundColor Cyan
            Write-Host '    2. Run Windows Update until nothing is left; install everything.' -ForegroundColor Cyan
            Write-Host '    3. Let ALL reboots finish and return to the desktop (AutoLogon signs back in).' -ForegroundColor Cyan
            Write-Host '    4. Close first-run app windows so the desktop is idle and clean.' -ForegroundColor Cyan
            Write-Host ''
            Write-Host '  Every test run reverts to exactly this moment — make it a fully patched, idle desktop.' -ForegroundColor Gray
            Write-Host ''
            Read-Host '  When the desktop is fully ready, press Enter to capture the clean-base checkpoint' | Out-Null

            # After update reboots the guest may still be settling — re-confirm the shell before freezing.
            Write-Verbose 'Confirming the desktop is up before checkpointing...'
            $reDeadline = (Get-Date).AddMinutes(5)
            do {
                $shellUp = [bool](Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock {
                    [bool](Get-Process -Name explorer -ErrorAction SilentlyContinue)
                } -ErrorAction SilentlyContinue)
                if (-not $shellUp) { Start-Sleep -Seconds 5 }
            } until ($shellUp -or (Get-Date) -gt $reDeadline)
            if (-not $shellUp) { Write-Warning 'Desktop shell not detected (guest may be mid-reboot) — checkpointing anyway.' }
        }

        Set-VM -Name $Name -CheckpointType Standard
        Checkpoint-VM -VMName $Name -SnapshotName $CheckpointName
        Write-Host "✓ Warm '$CheckpointName' checkpoint taken." -ForegroundColor Green

        Set-Win32ToolkitConfigValue -Name 'HyperVVMName'            -Value $Name
        Set-Win32ToolkitConfigValue -Name 'HyperVCheckpoint'        -Value $CheckpointName
        Set-Win32ToolkitConfigValue -Name 'HyperVBaseVhdx'          -Value $vhdx
        Set-Win32ToolkitConfigValue -Name 'HyperVProcessorCount'    -Value $ProcessorCount
        Set-Win32ToolkitConfigValue -Name 'HyperVMemoryStartupBytes' -Value $MemoryStartupBytes
        Set-Win32ToolkitGuestCredential -Credential $Credential
    }

    return (Get-VM -Name $Name -ErrorAction SilentlyContinue)
}
