function Test-Win32ToolkitNonInteractiveSwitch {
    <#
    .SYNOPSIS
        $true when this PowerShell console was started with -NonInteractive, where Read-Host throws.
    .DESCRIPTION
        Test-Win32ToolkitHostNonInteractive sees a service, a CI job or redirected input, but not
        'pwsh -NonInteractive' started with a console (a scheduled task, a script): UserInteractive is true and
        the input is not redirected, yet every Read-Host throws 'PowerShell is in NonInteractive mode'
        (InvalidOperation,Microsoft.PowerShell.Commands.ReadHostCommand). An Update test with no baseline
        version reached the version picker there and ended with no verdict (test campaign F5).

        Reads the PowerShell command line up to -File, -Command, -CommandWithArgs or -EncodedCommand (what
        follows belongs to the script or command) and looks for -NonInteractive or a prefix of it that pwsh
        accepts (at least -noni), written with '-', '--' or '/'. Only the console host (ConsoleHost) honours
        that switch: another host can still prompt (the VS Code integrated console runs in a process started
        with -NonInteractive), so the answer there is $false. Never throws.

        Not used by Get-Win32ToolkitTestMode (that would change which test mode a -NonInteractive console
        gets); only by the Update test's baseline-version choice.
    .PARAMETER CommandLineArgs
        The command line to read, first entry the executable (test seam). Default:
        [Environment]::GetCommandLineArgs().
    .PARAMETER HostName
        The host to check (test seam). Default: $Host.Name.
    .OUTPUTS
        [bool]
    .EXAMPLE
        if (Test-Win32ToolkitNonInteractiveSwitch) { 'Read-Host would throw here' }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$CommandLineArgs,

        [string]$HostName
    )

    try {
        $name = if ($PSBoundParameters.ContainsKey('HostName')) { $HostName } else { [string]$Host.Name }
        if ($name -ne 'ConsoleHost') { return $false }
        $argv = if ($PSBoundParameters.ContainsKey('CommandLineArgs')) { @($CommandLineArgs) } else { @([Environment]::GetCommandLineArgs()) }
        # The script or command starts at these switches (full names and the aliases pwsh accepts).
        $endOfHostSwitches = @('f', 'file', 'c', 'command', 'cwa', 'commandwithargs', 'e', 'ec', 'encodedcommand')
        foreach ($a in @($argv | Select-Object -Skip 1)) {
            $m = [regex]::Match([string]$a, '^(?:--?|/)([A-Za-z]+)$')
            if (-not $m.Success) { continue }   # a value, such as -ExecutionPolicy Bypass
            $switchName = $m.Groups[1].Value.ToLowerInvariant()
            if ($endOfHostSwitches -contains $switchName) { return $false }
            if ($switchName.Length -ge 4 -and 'noninteractive'.StartsWith($switchName, [System.StringComparison]::Ordinal)) { return $true }
        }
        return $false
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Could not read the PowerShell command line: $($_.Exception.Message)"
        return $false
    }
}
