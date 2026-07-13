function Invoke-Win32ToolkitGuestPhase {
    <#
    .SYNOPSIS
        Runs one test/capture phase inside the guest over PowerShell Direct and returns its exit code.
    .DESCRIPTION
        Runs the phase command with the guest's Windows PowerShell 5.1 (powershell.exe) so it matches how
        the scripts run on a real device under Intune, exactly as the Sandbox .wsb LogonCommand does — but
        host-driven and synchronous, so we get the real exit code instead of polling a file. The command
        string is passed as an argument to the guest scriptblock (not string-spliced into code), so
        untrusted values never reach a code position — a security improvement over the .wsb path.
    .PARAMETER Session
        An open PowerShell Direct PSSession.
    .PARAMETER Command
        A 5.1-safe PowerShell command string to execute in the guest (e.g. '& C:\PSADT\Invoke-AppDeployToolkit.ps1').
    .PARAMETER Label
        Short label for progress output.
    .OUTPUTS
        [int] the guest command's exit code (0 = success).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Command,
        [string]$Label = 'phase'
    )

    Write-Host "  [guest] $Label" -ForegroundColor Gray
    # Return ONLY the exit code. The command's stdout/stderr is discarded ($null = ...) so it does not
    # become part of the returned value — otherwise the whole output stream comes back and the [int]
    # cast fails ("Cannot convert System.Object[] to System.Int32"). $LASTEXITCODE survives the
    # assignment (it reflects powershell.exe, the last native command). PSADT writes its own logs, which
    # CollectLogs copies back, so the console stream isn't needed here.
    $exit = Invoke-Command -Session $Session -ScriptBlock {
        param($cmd)
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
        if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    } -ArgumentList $Command

    return [int](@($exit) | Select-Object -Last 1)
}
