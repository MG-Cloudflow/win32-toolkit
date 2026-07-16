function Test-Win32ToolkitPS51Syntax {
    <#
    .SYNOPSIS
        Parses a .ps1/.psm1 under Windows PowerShell 5.1 and returns any syntax errors (as strings).

    .DESCRIPTION
        Org hook scripts and extension modules (A1/A3) run ON THE DEVICE under Windows PowerShell 5.1
        (Intune's powershell.exe), but this module's host is PowerShell 7. Parsing a file with the PS7
        Language.Parser is USELESS as a 5.1 check: PS7-only syntax (ternary `a ? b : c`, null-coalescing
        `??`/`??=`, pipeline chains `&&`/`||`) parses cleanly under PS7 and would never warn.

        So we shell out to the real Windows PowerShell 5.1 (powershell.exe) and parse there — its grammar
        rejects those constructs, which is exactly what we want to surface to the operator at apply time.
        The target path is passed via an environment variable to sidestep every command-line quoting
        pitfall (paths with spaces/quotes/brackets).

        Fail-OPEN: if 5.1 can't be located (non-Windows CI, stripped image) this returns no errors rather
        than blocking. The check is an operator warning, never a hard gate.

    .PARAMETER Path
        Full path to the .ps1/.psm1 to check.

    .OUTPUTS
        [string[]] parse-error messages (empty when the file is 5.1-clean or 5.1 is unavailable).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $psExe = Join-Path $env:WinDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { return @() }   # no 5.1 here → fail open

    # Parse-only in a 5.1 child. Path travels via env var (no quoting hazards). The child prints one
    # line per parse error; ParseFile never executes the script, so this is side-effect free.
    $checker = @'
$e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($env:W32T_HOOKCHECK, [ref]$null, [ref]$e)
if ($e) { $e | ForEach-Object { $_.Message } }
'@
    $prev = $env:W32T_HOOKCHECK
    try {
        $env:W32T_HOOKCHECK = $Path
        $out = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $checker 2>&1
    }
    catch {
        return @()   # couldn't run the checker → fail open
    }
    finally {
        $env:W32T_HOOKCHECK = $prev
    }

    return @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}
