function Wait-Win32ToolkitVMReady {
    <#
    .SYNOPSIS
        Waits for a Hyper-V guest to be reachable over PowerShell Direct, then applies + verifies guest
        prep (three gates), so a warm checkpoint captures a fully-ready VM.
    .DESCRIPTION
        Gate 1 — Heartbeat: poll (Get-VMIntegrationService … Heartbeat).PrimaryStatusDescription -eq 'OK'
        (guest OS is running; necessary but not sufficient).
        Gate 2 — PowerShell Direct: retry Invoke-Command -VMName -Credential until it succeeds (early
        "credential invalid / remote session ended" errors are normal while the profile is created).
        Gate 3 — Provisioning: because Win11 FirstLogonCommands are not awaited, apply + verify the guest
        execution policy host-side over PS-Direct before the caller checkpoints (don't race the answer
        file). Skippable with -SkipPrep.

        Designed to be testable: the Hyper-V cmdlets / Invoke-Command / Start-Sleep are all shadowable,
        and the timeouts are parameters. See knowledge-base/designs/hyperv-golden-image-build.md (§2.4).
    .PARAMETER VMName
        The VM to wait on.
    .PARAMETER Credential
        The guest local-admin credential for PowerShell Direct.
    .PARAMETER HeartbeatTimeoutSec
        Max seconds to wait for the heartbeat (default 300).
    .PARAMETER PSDirectTimeoutSec
        Max seconds to wait for PowerShell Direct to accept the credential (default 900).
    .PARAMETER SkipPrep
        Skip Gate 3 (the host-side execution-policy prep + verify).
    .OUTPUTS
        [bool] $true when the guest is ready (throws with a specific message on any gate timeout).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscredential]$Credential,

        [ValidateRange(0.01, 3600)]
        [double]$HeartbeatTimeoutSec = 300,

        [ValidateRange(0.01, 3600)]
        [double]$PSDirectTimeoutSec = 900,

        [switch]$SkipPrep
    )

    # Gate 1 — heartbeat.
    $hb = $null
    $deadline = (Get-Date).AddSeconds($HeartbeatTimeoutSec)
    do {
        $hb = (Get-VMIntegrationService -VMName $VMName -Name 'Heartbeat' -ErrorAction SilentlyContinue).PrimaryStatusDescription
        if ($hb -eq 'OK') { break }
        Start-Sleep -Seconds 5
    } until ((Get-Date) -gt $deadline)
    if ($hb -ne 'OK') {
        throw "Heartbeat not 'OK' within $HeartbeatTimeoutSec s (last: '$hb') — the guest may not have booted."
    }

    # Gate 2 — PowerShell Direct accepts the credential (profile exists).
    $ready = $false
    $deadline2 = (Get-Date).AddSeconds($PSDirectTimeoutSec)
    do {
        try { $ready = [bool](Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { $true } -ErrorAction Stop) }
        catch { Start-Sleep -Seconds 10 }
    } until ($ready -or (Get-Date) -gt $deadline2)
    if (-not $ready) {
        throw "PowerShell Direct did not become ready within $PSDirectTimeoutSec s — the guest booted but no interactive admin session appeared (check the unattend AutoLogon/OOBE-skip)."
    }

    # Gate 3 — apply + verify guest prep host-side (don't rely on FirstLogonCommands having finished).
    if (-not $SkipPrep) {
        Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
            Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force
        } -ErrorAction Stop
        $ep = [string](Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { (Get-ExecutionPolicy -Scope LocalMachine).ToString() } -ErrorAction Stop)
        if ($ep -notin 'RemoteSigned', 'Unrestricted', 'Bypass') {
            throw "Guest execution policy was not applied (got '$ep') — refusing to checkpoint a half-prepped VM."
        }
    }

    return $true
}
