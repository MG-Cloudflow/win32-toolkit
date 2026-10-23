function Test-Win32ToolkitVMConnectOpen {
    <#
    .SYNOPSIS
        Tells whether a Hyper-V console (vmconnect.exe) is attached to the test VM.
    .DESCRIPTION
        Hyper-V speed-up PR 1 (V-10). Someone at a VM console can change what a checkpoint answer depends on (sign in
        or out, start an app), so the pre-check cache and the checkpoint attestation store nothing while one is open.
        Reads the vmconnect.exe processes (Win32_Process) and looks for the VM's name as a whole command-line token
        (case-insensitive, quotes stripped) or the VM's Id (braces stripped). Fail-safe: when the query throws, or a vmconnect's command
        line cannot be read, it answers $true (a console may be open).
    .PARAMETER VMName
        The test VM's name.
    .PARAMETER VMId
        The test VM's Id (optional: vmconnect can be started with -G <Id>).
    .OUTPUTS
        [bool]
    .EXAMPLE
        if (-not (Test-Win32ToolkitVMConnectOpen -VMName 'win32tk-golden')) { 'no console attached' }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [AllowEmptyString()]
        [string]$VMId
    )

    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'vmconnect.exe'" -ErrorAction Stop)
        foreach ($proc in $procs) {
            $commandLine = [string]$proc.CommandLine
            if ([string]::IsNullOrWhiteSpace($commandLine)) { return $true }
            foreach ($token in [regex]::Matches($commandLine, '"([^"]*)"|(\S+)')) {
                $value = if ($token.Groups[1].Success) { $token.Groups[1].Value } else { $token.Groups[2].Value }
                if ([string]::Equals($value, $VMName, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
                if ($VMId -and [string]::Equals($value.Trim('{', '}'), $VMId.Trim('{', '}'), [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
        }
        return $false
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Could not read the VM console processes ($($_.Exception.Message)); a console is assumed open."
        return $true
    }
}
