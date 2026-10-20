function Get-Win32ToolkitSandboxEnvironment {
    <#
    .SYNOPSIS
        Asks the Windows Sandbox command line how many sandboxes are running; $null when it cannot tell.
    .DESCRIPTION
        Parses 'wsb list --raw' (Invoke-Win32ToolkitWsbList): {"WindowsSandboxEnvironments":[...]}. An EMPTY
        list is the authoritative "no sandbox is running" that Wait-Win32ToolkitSandboxFree needs when Windows
        Sandbox 0.8 leaves its client window open on 'The remote environment is shutting down' after the guest
        is gone (test campaign F1).

        Returns $null, and the caller keeps its process-name check, when wsb is not installed, fails (exit code
        other than 0), times out, or prints anything but that JSON object with a WindowsSandboxEnvironments
        list. Every list entry counts as a running sandbox.
    .OUTPUTS
        [pscustomobject] Count (running environments); or $null.
    .EXAMPLE
        $sb = Get-Win32ToolkitSandboxEnvironment; if ($sb -and $sb.Count -eq 0) { 'no sandbox running' }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $result = Invoke-Win32ToolkitWsbList
    if ($null -eq $result) { return $null }
    if ($result.ExitCode -ne 0) {
        Write-Verbose "wsb list exited with code $($result.ExitCode); the sandbox processes decide."
        return $null
    }

    $text = [string]$result.Output
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) {
        Write-Verbose 'wsb list printed no JSON object; the sandbox processes decide.'
        return $null
    }
    try {
        $json = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "wsb list printed JSON that could not be read ($($_.Exception.Message)); the sandbox processes decide."
        return $null
    }
    if ($null -eq $json -or $json -is [array] -or -not $json.PSObject.Properties['WindowsSandboxEnvironments'] -or
        $null -eq $json.WindowsSandboxEnvironments) {
        Write-Verbose 'wsb list printed no WindowsSandboxEnvironments list; the sandbox processes decide.'
        return $null
    }
    $environments = @($json.WindowsSandboxEnvironments | Where-Object { $null -ne $_ })
    return [pscustomobject]@{ Count = $environments.Count }
}
