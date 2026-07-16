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
    .PARAMETER ReturnSession
        Return the PSSession that proved Gate 2 instead of $true (warm-revert run path) — the proving
        connection becomes the run's session instead of being thrown away. Gate 1 runs only as the
        failure diagnostic in this mode.
    .OUTPUTS
        [bool] $true when the guest is ready — or the open PSSession with -ReturnSession (throws with a
        specific message on any gate timeout).
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

        [switch]$SkipPrep,

        # Return the PSSession that proved Gate 2 instead of $true. The warm-revert path used to prove
        # PS Direct with a throwaway ad-hoc connection and then build ANOTHER session (~1-3 s wasted per
        # run); with -ReturnSession the proving connection IS the run's session. The upfront heartbeat
        # gate is skipped in this mode (Gate 2 subsumes it — a session cannot open without a live guest);
        # on a Gate-2 timeout the heartbeat is still probed for the specific diagnostic.
        [switch]$ReturnSession
    )

    # Gate 1 — heartbeat (upfront only in bool mode; 1 s cadence — the probe is a cheap local WMI read,
    # and the old 5 s quantum added dead tail to every warm revert. Ceiling unchanged).
    if (-not $ReturnSession) {
        $hb = $null
        $deadline = (Get-Date).AddSeconds($HeartbeatTimeoutSec)
        do {
            $hb = (Get-VMIntegrationService -VMName $VMName -Name 'Heartbeat' -ErrorAction SilentlyContinue).PrimaryStatusDescription
            if ($hb -eq 'OK') { break }
            Start-Sleep -Seconds 1
        } until ((Get-Date) -gt $deadline)
        if ($hb -ne 'OK') {
            throw "Heartbeat not 'OK' within $HeartbeatTimeoutSec s (last: '$hb') — the guest may not have booted."
        }
    }

    # Gate 2 — PowerShell Direct accepts the credential (profile exists). Retry backs off 1->2->4->8->10 s
    # (was a flat 10 s: a warm memory-state revert is typically reachable in 1-2 s, and the flat quantum
    # cost up to 10 s of dead tail). The 900 s ceiling is unchanged — the cold golden-image path needs it.
    $session = $null
    $ready   = $false
    $gate2Delay = 1
    $deadline2 = (Get-Date).AddSeconds($PSDirectTimeoutSec)
    do {
        try {
            if ($ReturnSession) {
                $session = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop
                $ready   = $true
            }
            else {
                $ready = [bool](Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { $true } -ErrorAction Stop)
            }
        }
        catch {
            Start-Sleep -Seconds $gate2Delay
            $gate2Delay = [Math]::Min($gate2Delay * 2, 10)
        }
    } until ($ready -or (Get-Date) -gt $deadline2)
    if (-not $ready) {
        # Preserve the specific boot-vs-session diagnostic even though the upfront heartbeat gate is
        # skipped in -ReturnSession mode.
        $hbNow = (Get-VMIntegrationService -VMName $VMName -Name 'Heartbeat' -ErrorAction SilentlyContinue).PrimaryStatusDescription
        if ($hbNow -ne 'OK') {
            throw "PowerShell Direct did not become ready within $PSDirectTimeoutSec s and the heartbeat is '$hbNow' — the guest may not have booted."
        }
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

    if ($ReturnSession) { return $session }
    return $true
}
