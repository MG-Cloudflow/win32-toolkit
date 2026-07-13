function Set-Win32ToolkitGuestAutoLogon {
    <#
    .SYNOPSIS
        Configures Windows AutoLogon in the guest (Winlogon registry) over PowerShell Direct.
    .DESCRIPTION
        Safety net for the interactive Hyper-V test mode: with AutoLogon configured, any BOOT of the
        guest lands directly on the logged-in `w32admin` desktop — so if a checkpoint (or a reboot) ever
        shows the login screen, the guest can recover to a usable desktop without anyone typing a
        password (see Confirm-Win32ToolkitGuestDesktop, which reboots to trigger this). Sets
        AutoAdminLogon=1 + DefaultUserName/DefaultPassword/DefaultDomainName and clears any
        AutoLogonCount limit. HOST-ONLY.

        SECURITY: DefaultPassword is stored in cleartext under HKLM\...\Winlogon — acceptable for a
        throwaway lab VM (the base VHDX is already treated as a secret), but do not reuse this account
        or image elsewhere.
    .PARAMETER VMName
        The test VM.
    .PARAMETER Credential
        The guest local-admin credential to auto-log-on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$VMName,
        [Parameter(Mandatory)] [ValidateNotNull()]        [pscredential]$Credential
    )

    $sam = $Credential.UserName.Split('\')[-1]
    $pw  = $Credential.GetNetworkCredential().Password

    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        param($user, $pass)

        # 1) Registry baseline (works offline).
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $k -Name 'AutoAdminLogon'    -Value '1'               -Type String
        Set-ItemProperty -Path $k -Name 'DefaultUserName'   -Value $user             -Type String
        Set-ItemProperty -Path $k -Name 'DefaultPassword'   -Value $pass             -Type String
        Set-ItemProperty -Path $k -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -Type String
        Remove-ItemProperty -Path $k -Name 'AutoLogonCount' -ErrorAction SilentlyContinue

        # Windows 11 ships "passwordless" ON (DevicePasswordLessBuildVersion=2), which SUPPRESSES classic
        # username/password AutoLogon even with AutoAdminLogon=1. Set it to 0.
        $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
        if (-not (Test-Path $pl)) { New-Item -Path $pl -Force | Out-Null }
        Set-ItemProperty -Path $pl -Name 'DevicePasswordLessBuildVersion' -Value 0 -Type DWord

        # Full token for remote/PS-Direct local admins so these HKLM writes (and Autologon.exe) do not
        # silently fail at MEDIUM integrity — the most likely reason earlier attempts didn't stick. NOTE:
        # it only takes effect for the NEXT PS-Direct session, so it's ALSO baked into the golden image
        # (unattend) — this in-guest write is for VMs provisioned before that.
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord -ErrorAction SilentlyContinue

        # 2) Sysinternals Autologon — configures AutoLogon and stores the password as the LSA 'DefaultPassword'
        # secret. Best-effort HARDENING only (not more reboot-proof than the registry values — Winlogon
        # checks the LSA secret then falls back to plaintext). Needs guest internet AND a full token.
        try {
            $exe = Join-Path $env:TEMP 'Autologon64.exe'
            New-Item -Path 'HKCU:\Software\Sysinternals\Autologon' -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path 'HKCU:\Software\Sysinternals\Autologon' -Name 'EulaAccepted' -Value 1 -Type DWord -ErrorAction SilentlyContinue
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://live.sysinternals.com/Autologon64.exe' -OutFile $exe -UseBasicParsing -ErrorAction Stop
            & $exe -accepteula $user $env:COMPUTERNAME $pass 2>&1 | Out-Null
            if ($LASTEXITCODE) { Write-Warning "Autologon returned $LASTEXITCODE (740 = still token-filtered; needs a fresh session after LocalAccountTokenFilterPolicy)." }
        }
        catch {
            Write-Warning "Sysinternals Autologon step skipped ($($_.Exception.Message)); using the registry method only."
        }
    } -ArgumentList $sam, $pw -ErrorAction Stop
}
