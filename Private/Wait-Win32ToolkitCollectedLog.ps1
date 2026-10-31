function Wait-Win32ToolkitCollectedLog {
    <#
    .SYNOPSIS
        Waits (bounded) until the Sandbox log collector of the current run has finished; $true when it has.
    .DESCRIPTION
        Windows Sandbox only. The host reads a run's verdict as soon as the last assertion line appears in
        the mapped Sandbox\Logs folder, but the guest's Sandbox\CollectLogs.ps1 copies the PSADT and MSI
        logs AFTER that line. The collector writes Sandbox\Logs\CollectLogs.done as its last step;
        Initialize-Win32ToolkitTestRunLog removes an earlier one when a run starts. This waits for that file
        and then a few seconds more, so the mapped folder has written the copies back, before
        Save-Win32ToolkitTestRunLog keeps the run's logs (test campaign F2).

        A Hyper-V run needs no wait: its logs are copied back after every phase has finished.
    .PARAMETER ProjectPath
        The PSADT project folder under test.
    .PARAMETER TimeoutSeconds
        Max seconds to wait for the collector (default 60). 0 checks once.
    .PARAMETER SettleSeconds
        Seconds to wait after the collector finished (default 5), for the mapped-folder write-back.
    .PARAMETER PollSeconds
        Poll cadence (default 2).
    .OUTPUTS
        [bool] $true when the collector finished within the timeout, $false otherwise (the logs may then be
        incomplete).
    .EXAMPLE
        $null = Wait-Win32ToolkitCollectedLog -ProjectPath $p -TimeoutSeconds 60
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [ValidateRange(0, 600)]
        [int]$TimeoutSeconds = 60,

        [ValidateRange(0, 60)]
        [int]$SettleSeconds = 5,

        [ValidateRange(1, 30)]
        [int]$PollSeconds = 2
    )

    $done = Join-Path $ProjectPath 'Sandbox\Logs\CollectLogs.done'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $done)) {
        if ((Get-Date) -ge $deadline) {
            Write-Verbose "The Sandbox log collector did not finish within $TimeoutSeconds s; this run's logs may be incomplete."
            return $false
        }
        Start-Sleep -Seconds $PollSeconds
    }
    if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }
    return $true
}
