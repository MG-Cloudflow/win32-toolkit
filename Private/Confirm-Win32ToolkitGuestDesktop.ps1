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

    Write-Warning 'No interactive desktop detected (login screen?) — rebooting the guest to trigger AutoLogon...'
    Write-Warning "This recovery costs 1-3 minutes on EVERY interactive run — re-take the checkpoint at a logged-in desktop to fix it durably (Reset-Win32ToolkitTestVM, log in via vmconnect, then re-checkpoint from the TUI's Hyper-V screen)."
    Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue

    # Wait for the shutdown to actually BEGIN (heartbeat leaves 'OK') before waiting for the guest to come
    # back — polling at 1 s replaces the old blind 20 s sleep; the 20 s CAP keeps the worst case identical
    # (if the heartbeat never dips we proceed exactly as before and the ready-wait below sorts it out).
    $dipDeadline = (Get-Date).AddSeconds(20)
    do {
        $hb = (Get-VMIntegrationService -VMName $VMName -Name 'Heartbeat' -ErrorAction SilentlyContinue).PrimaryStatusDescription
        if ($hb -ne 'OK') { break }
        Start-Sleep -Seconds 1
    } until ((Get-Date) -gt $dipDeadline)
    try { Wait-Win32ToolkitVMReady -VMName $VMName -Credential $Credential -SkipPrep -HeartbeatTimeoutSec 180 -PSDirectTimeoutSec 300 | Out-Null } catch { }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while (-not (& $hasDesktop) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
    return [bool](& $hasDesktop)
}
