function New-Win32ToolkitTestVM {
    <#
    .SYNOPSIS
        Builds the Hyper-V test VM once, from a Windows 11 ISO or your own virtual disk.
    .DESCRIPTION
        New-Win32ToolkitTestVM builds the Hyper-V test VM, a Windows 11 virtual machine (VM) on
        your PC, from a Windows 11 ISO or your own virtual disk. Tests can then use it instead of
        Windows Sandbox.

        After the first start, the command opens the VM window if it can, and waits. In the VM,
        run Windows Update until nothing is left and let every restart finish. Then press Enter in
        PowerShell to take the checkpoint clean-base: a saved state of the signed-in desktop that
        every test starts from.

        In the menu: Settings > Hyper-V test VM > Provision the test VM from a Windows 11 ISO. The
        menu uses the default name and edition. If a VM or its disk already exists, the menu asks
        "Delete it and rebuild from scratch?" and the default answer is Yes.

        From an ISO, the disk goes to <base folder>\HyperV\Golden\<name>.vhdx. Unless
        W32T_HYPERV_VM pins this VM, the command saves the VM and checkpoint names, processors,
        memory and password in your settings. It does not make the VM your default test machine
        and changes nothing in Intune.
    .PARAMETER IsoPath
        The Windows 11 x64 ISO file to build the VM from. Give -IsoPath or -VhdxPath, not both. A
        path in double quotes, as Copy as path gives it, also works.
    .PARAMETER VhdxPath
        Your own Windows virtual disk (.vhdx) to build the VM on. It must start in a Generation 2
        VM, with Windows setup done, a local administrator and automatic sign-in. The VM uses and
        changes this file, so copy it first if you need the original. Command line only: the menu
        does not offer this.
    .PARAMETER Name
        The name of the VM in Hyper-V. Default: win32tk-golden, even when your saved test VM has
        another name.
    .PARAMETER Credential
        The user name and password of the administrator account in the VM. Without it, the
        command asks: press Enter for the user name w32admin, then type the password twice. The
        password must not be blank. Use a lab-only password: the VM stores it in clear text.
    .PARAMETER MemoryStartupBytes
        The memory of the VM, for example 8GB. The VM holds all of it while it runs. Default: the
        last value that this command or Set-Win32ToolkitTestVMResource saved, else 4 GB. Give the
        VM 6 to 8 GB if your PC has the memory.
    .PARAMETER ProcessorCount
        The number of virtual processors of the VM, from 1 to 64. Default: the last value that
        this command or Set-Win32ToolkitTestVMResource saved, else 2.
    .PARAMETER SwitchName
        The Hyper-V virtual switch that connects the VM to the network. Default: Default Switch,
        which shares the internet connection of your PC. Use another switch only if your PC has no
        Default Switch.
    .PARAMETER CheckpointName
        The name of the clean checkpoint. Default: clean-base. Keep the default.
    .PARAMETER ImageIndex
        The number of the Windows edition in the ISO. It wins over -Edition. If the number does not
        exist, the error lists every edition of the ISO with its number. Command line only: the
        menu does not offer this.
    .PARAMETER Edition
        Part of the Windows edition name, for example 'Enterprise'. Without it, the command tries
        Windows 11 Pro, then Windows 10 Pro, then Enterprise, then Pro. If nothing matches, it
        takes the first edition of the ISO (this can be Home) and warns. Command line only: the
        menu does not offer this.
    .PARAMETER EnableTPM
        Adds a virtual Trusted Platform Module (TPM), the security chip that Windows 11 expects.
        Default: $true. Keep the default.
    .PARAMETER Recheckpoint
        This switch does not re-take the checkpoint of an existing VM. Do not use it. To re-take the
        checkpoint, use the Hyper-V commands in the guide.
        More: https://win32toolkit.com/hyperv-vm/#re-take-the-checkpoint
    .PARAMETER Force
        Deletes an existing VM with this name and all its checkpoints, then builds the VM again.
        With -IsoPath it also builds the virtual disk again. Without -Force, an existing VM with
        its checkpoint is used again, and the command saves the password you typed without
        testing it.
    .PARAMETER Unattended
        Takes the checkpoint right after the first start, with no pause to update Windows. It opens
        no VM window and does not check the internet in the VM. Use it for automation only.
        Command line only: the menu does not offer this.
    .EXAMPLE
        New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso'

        This builds the test VM from the ISO, asks for a user name and password, and pauses so
        that you can update Windows in the VM. It does not make the VM your default test machine.
    .EXAMPLE
        New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso' -MemoryStartupBytes 8GB

        This builds the test VM with 8 GB of memory. The command saves 8 GB as your default for
        the next build.
    .EXAMPLE
        New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso' -Edition 'Enterprise'

        This builds the test VM with the first Enterprise edition of the ISO. If the ISO has no
        Enterprise edition, the command takes the first edition and warns.
    .EXAMPLE
        New-Win32ToolkitTestVM -VhdxPath 'D:\VM\Win11-base.vhdx' -Credential (Get-Credential)

        This builds the test VM on your own prepared disk: the VM runs on that file, not on a copy.
        Get-Credential asks for the user name and password of the administrator account on the
        disk.
    .EXAMPLE
        New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso' -Force

        This deletes the existing VM, its checkpoints and its disk, and builds them again from the
        ISO. It takes the full build time again.
    .OUTPUTS
        The VM object from Hyper-V, as Get-VM shows it.
    .NOTES
        Needs: PowerShell 7 run as administrator, and Hyper-V with its PowerShell module (Windows
        Home does not have Hyper-V). Time: about 30 to 60 minutes, plus Windows Update time. Only
        one PowerShell window at a time can use the test VM.
    .LINK
        https://win32toolkit.com/reference/New-Win32ToolkitTestVM/
    .LINK
        https://win32toolkit.com/hyperv-vm/
    .LINK
        https://win32toolkit.com/hyperv-vm-care/
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
    # Paths are usually pasted from Explorer's "Copy as path", which wraps them in double quotes —
    # strip them (a literal " is illegal in a Windows path) so Test-Path / Mount-DiskImage see the
    # real file instead of failing with a confusing not-found (issue #66). Same normalization the
    # manual-app prompts already apply. Runs BEFORE the guards so a quoted-blank paste counts as
    # "not supplied".
    if ($IsoPath)  { $IsoPath  = $IsoPath.Trim().Trim('"') }
    if ($VhdxPath) { $VhdxPath = $VhdxPath.Trim().Trim('"') }
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
            # Adopting a VM changes exactly what the readiness probe checks (name/checkpoint/credential):
            # a stale cached verdict for the PREVIOUS configuration must not survive this.
            Clear-Win32ToolkitHyperVStateCache
            # Not for the VM this session pins with W32T_HYPERV_VM (speed-up PR 3, A-10): a process-scoped pin never
            # repoints the user's defaults; the guest credential is stored only when none is.
            $pin = Get-Win32ToolkitHyperVTarget -NoThrow
            if ($pin.Pinned -and -not $pin.Problem -and $pin.VMName -eq $Name) {
                Write-Host "VM '$(ConvertTo-Win32ToolkitSafeText -Text $Name -MaxLength 64)' is pinned by W32T_HYPERV_VM for this session only: its name, checkpoint and size were not saved as your defaults." -ForegroundColor Yellow
                if (-not (Get-Win32ToolkitGuestCredential)) { Set-Win32ToolkitGuestCredential -Credential $Credential }
            }
            else {
                Set-Win32ToolkitConfigValue -Name 'HyperVVMName'     -Value $Name
                Set-Win32ToolkitConfigValue -Name 'HyperVCheckpoint' -Value $CheckpointName
                Set-Win32ToolkitGuestCredential -Credential $Credential
            }
            return $existing
        }
    }
    if ($existing -and $Force) {
        if ($PSCmdlet.ShouldProcess($Name, 'Remove existing VM before rebuild')) {
            # One process at a time on the VM (speed-up PR 3, D10): never remove it under a running test.
            $lease = Enter-Win32ToolkitHyperVLease -VMName $Name -VMId ([string]$existing.Id) -Purpose 'provisioning'
            try {
                # Clear BEFORE the destruction: if the rebuild aborts mid-way, a <=60 s-old 'ready' verdict
                # must not steer backend resolution at a VM that no longer exists.
                Clear-Win32ToolkitHyperVStateCache
                Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
                Get-VMCheckpoint -VMName $Name -ErrorAction SilentlyContinue | Remove-VMCheckpoint -ErrorAction SilentlyContinue
                Remove-VM -Name $Name -Force -ErrorAction SilentlyContinue
            }
            finally { $null = Exit-Win32ToolkitHyperVLease -Lease $lease }
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
        $newVm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $vhdx -Path $paths.VMs -SwitchName $SwitchName -ErrorAction Stop
        # One process at a time on the new VM (speed-up PR 3, D10), from its creation to its checkpoint and settings.
        $lease = Enter-Win32ToolkitHyperVLease -VMName $Name -VMId $(if ($newVm -and $newVm.Id) { [string]$newVm.Id } else { '' }) -Purpose 'provisioning'
        try {
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

            # Automatic checkpoints off before the first start (speed-up PR 1, D5): with them on, Hyper-V takes an
            # 'Automatic Checkpoint' at every start from Off, and the clean-base checkpoint would keep the setting on.
            $null = Set-VM -Name $Name -AutomaticCheckpointsEnabled $false -ErrorAction Stop

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

            # The checkpoint keeps the VM's settings: Standard type, automatic checkpoints off (D5).
            $null = Set-VM -Name $Name -CheckpointType Standard -AutomaticCheckpointsEnabled $false
            # A failed checkpoint stops here (speed-up PR 2, V-Fe11): no success line and no settings for a VM without one.
            Checkpoint-VM -VMName $Name -SnapshotName $CheckpointName -ErrorAction Stop
            Write-Host "✓ Warm '$CheckpointName' checkpoint taken." -ForegroundColor Green

            # Not for the VM this session pins with W32T_HYPERV_VM (speed-up PR 3, A-10): a process-scoped pin never
            # repoints the user's defaults; the guest credential is stored only when none is.
            $pin = Get-Win32ToolkitHyperVTarget -NoThrow
            if ($pin.Pinned -and -not $pin.Problem -and $pin.VMName -eq $Name) {
                Write-Host "VM '$(ConvertTo-Win32ToolkitSafeText -Text $Name -MaxLength 64)' is pinned by W32T_HYPERV_VM for this session only: its name, checkpoint and size were not saved as your defaults." -ForegroundColor Yellow
                if (-not (Get-Win32ToolkitGuestCredential)) { Set-Win32ToolkitGuestCredential -Credential $Credential }
            }
            else {
                Set-Win32ToolkitConfigValue -Name 'HyperVVMName'            -Value $Name
                Set-Win32ToolkitConfigValue -Name 'HyperVCheckpoint'        -Value $CheckpointName
                Set-Win32ToolkitConfigValue -Name 'HyperVBaseVhdx'          -Value $vhdx
                Set-Win32ToolkitConfigValue -Name 'HyperVProcessorCount'    -Value $ProcessorCount
                Set-Win32ToolkitConfigValue -Name 'HyperVMemoryStartupBytes' -Value $MemoryStartupBytes
                Set-Win32ToolkitGuestCredential -Credential $Credential
            }
        }
        finally { $null = Exit-Win32ToolkitHyperVLease -Lease $lease }
    }

    return (Get-VM -Name $Name -ErrorAction SilentlyContinue)
}
