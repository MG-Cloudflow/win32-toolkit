function Confirm-Win32ToolkitGuestDesktop {
    <#
    .SYNOPSIS
        Ensures the guest is at a logged-in interactive desktop; reboots to trigger AutoLogon if not.
    .DESCRIPTION
        The interactive Hyper-V test mode runs the PSADT GUI in the logged-on user's session, so it needs
        a real desktop (explorer.exe). If a checkpoint landed on the login screen instead, this recovers:
        it reboots the guest, and — because AutoLogon is configured (Set-Win32ToolkitGuestAutoLogon) —
        Windows logs straight back into the desktop. Returns $true once explorer is running, $false if it
        could not reach a desktop within the timeout (e.g. AutoLogon isn't configured). HOST-ONLY.
    .PARAMETER VMName
        The test VM.
    .PARAMETER Credential
        The guest credential (PowerShell Direct).
    .PARAMETER TimeoutMinutes
        How long to wait for the desktop after a recovery reboot (default 5).
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$VMName,
        [Parameter(Mandatory)] [ValidateNotNull()]        [pscredential]$Credential,
        [ValidateRange(1, 30)] [int]$TimeoutMinutes = 5
    )

    $hasDesktop = {
        [bool](Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
            [bool](Get-Process -Name explorer -ErrorAction SilentlyContinue)
        } -ErrorAction SilentlyContinue)
    }

    if (& $hasDesktop) { return $true }

    Write-Host 'No interactive desktop detected (login screen?) — rebooting the guest to trigger AutoLogon...' -ForegroundColor Yellow
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 20   # let it begin shutting down before we wait for it to come back
    try { Wait-Win32ToolkitVMReady -VMName $VMName -Credential $Credential -SkipPrep -HeartbeatTimeoutSec 180 -PSDirectTimeoutSec 300 | Out-Null } catch { }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while (-not (& $hasDesktop) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
    return [bool](& $hasDesktop)
}
