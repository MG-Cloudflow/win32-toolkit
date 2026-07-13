function Confirm-Win32ToolkitGuestInternet {
    <#
    .SYNOPSIS
        Verifies (and best-effort repairs) that the guest has working outbound internet, over PowerShell
        Direct. Returns $true once the guest can resolve DNS and fetch Microsoft's connectivity probe.
    .DESCRIPTION
        Windows Update in the guest needs real internet. On a NESTED Hyper-V guest using the 'Default
        Switch' (NAT/ICS) — the toolkit's default — outbound routing usually works but the switch's DNS
        proxy is flaky, so name resolution fails and Windows Update sits idle. This checks connectivity and,
        if it's not working, repairs the guest side: renews DHCP, sets a public DNS resolver on the active
        adapter, and flushes the cache — then re-tests, up to a timeout. HOST-ONLY; all guest work runs
        inside the VM via Invoke-Command over the VMBus (5.1-safe cmdlets only).
    .PARAMETER VMName
        The test VM.
    .PARAMETER Credential
        Guest local-admin credential for PowerShell Direct.
    .PARAMETER TimeoutSeconds
        Overall budget for reach-or-repair-and-retry. Default 120.
    .PARAMETER FallbackDns
        Public resolvers set on the guest adapter during repair. Default Cloudflare + Google.
    .OUTPUTS
        [bool] $true if the guest reached the internet (possibly after repair), else $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$VMName,
        [Parameter(Mandatory)] [ValidateNotNull()]        [pscredential]$Credential,
        [int]$TimeoutSeconds = 120,
        [string[]]$FallbackDns = @('1.1.1.1', '8.8.8.8')
    )

    # Runs in the guest: true only if there's a default gateway, DNS resolves, and the MS probe returns
    # its known body. Kept 5.1-safe (the PS-Direct endpoint is Windows PowerShell 5.1).
    $probe = {
        $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway }
        if (-not $cfg) { return $false }
        try { $null = Resolve-DnsName 'www.msftconnecttest.com' -Type A -ErrorAction Stop } catch { return $false }
        try {
            $r = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            return ([string]$r.Content -match 'Microsoft Connect Test')
        }
        catch { return $false }
    }

    $deadline = (Get-Date).AddSeconds([Math]::Max(15, $TimeoutSeconds))
    $attempt  = 0
    while ($true) {
        $attempt++
        $ok = [bool](Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $probe -ErrorAction SilentlyContinue)
        if ($ok) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }

        Write-Verbose "Guest internet not confirmed (attempt $attempt) — repairing DHCP/DNS in the guest..."
        Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
            param($dns)
            & ipconfig /renew   | Out-Null
            & ipconfig /flushdns | Out-Null
            $ad = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
            if ($ad -and $dns) {
                try { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $dns -ErrorAction Stop } catch { }
            }
        } -ArgumentList (, $FallbackDns) -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 8
    }
}
