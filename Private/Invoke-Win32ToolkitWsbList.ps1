function Invoke-Win32ToolkitWsbList {
    <#
    .SYNOPSIS
        Runs 'wsb list --raw' (the Windows Sandbox command line) with a timeout and returns its exit code and
        output; $null when wsb is not installed, could not start or did not finish.
    .DESCRIPTION
        The Windows Sandbox app (0.8 and later) ships wsb.exe. 'wsb list --raw' prints the running sandbox
        environments as JSON: {"WindowsSandboxEnvironments":[...]}. Get-Win32ToolkitSandboxEnvironment parses
        it; this helper only runs the process (no window, standard output and error captured), so the parser can
        be tested without a sandbox. wsb.exe itself (not its process tree: a cold 'wsb list' starts
        WindowsSandboxServer) is stopped when it does not finish within -TimeoutSeconds.

        Read-only: 'list' starts, stops or changes nothing.
    .PARAMETER TimeoutSeconds
        Max seconds to wait for wsb (default 15).
    .OUTPUTS
        [pscustomobject] ExitCode, Output (standard output), ErrorOutput; or $null.
    .EXAMPLE
        $r = Invoke-Win32ToolkitWsbList
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 15
    )

    $wsb = Get-Command -Name 'wsb.exe' -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if (-not $wsb) {
        Write-Verbose 'wsb.exe (the Windows Sandbox command line) is not installed.'
        return $null
    }

    $proc = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new([string]$wsb.Source)
        $psi.ArgumentList.Add('list')
        $psi.ArgumentList.Add('--raw')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            # wsb.exe only, never its process tree: a cold 'wsb list' starts WindowsSandboxServer, which must live on.
            try { $proc.Kill() }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Could not stop wsb list: $($_.Exception.Message)"
            }
            Write-Verbose "wsb list did not finish within $TimeoutSeconds s."
            return $null
        }
        $proc.WaitForExit()
        return [pscustomobject]@{
            ExitCode    = $proc.ExitCode
            Output      = [string]$stdout.Result
            ErrorOutput = [string]$stderr.Result
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "wsb list could not run: $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($proc) { $proc.Dispose() }
    }
}
