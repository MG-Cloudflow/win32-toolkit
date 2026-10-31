function Get-Win32ToolkitAsyncTeardownOwner {
    <#
    .SYNOPSIS
        Returns the command that may let a Hyper-V teardown restore finish in the background, or $null.
    .DESCRIPTION
        Hyper-V speed-up PR 4 (D13, A-14, V-2, V-16). An asynchronous teardown (HyperVAsyncTeardown) needs an owner: a
        command that is sure to wait for the background restore before it returns, so a PowerShell process never ends in
        the middle of a restore. The owners are exactly Show-Win32Toolkit (the TUI session) and Invoke-Win32Toolkit;
        each registers $script:W32TAsyncTeardownOwner = @{ Token; Command } right before its try (unless an owner is
        already live) and joins in its finally (Wait-Win32ToolkitHyperVTeardown -ReleaseOwner).

        Stale-token guard (V-2): a recorded owner whose command is not on the call stack any more (its finally never ran)
        is treated as absent, with one verbose line: it neither stops the next owner from registering nor enables a
        background teardown outside an owner. The record itself is left as it is (the next owner overwrites it).
        Pure; never throws.
    .OUTPUTS
        The live owner record (Token, Command), or $null.
    .EXAMPLE
        if (Get-Win32ToolkitAsyncTeardownOwner) { 'a background teardown restore is allowed here' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $owner = $script:W32TAsyncTeardownOwner
    if ($owner -isnot [hashtable] -or [string]::IsNullOrEmpty([string]$owner['Command'])) { return $null }
    $onStack = $false
    try {
        foreach ($frame in @(Get-PSCallStack)) {
            if ([string]$frame.Command -eq [string]$owner['Command']) { $onStack = $true; break }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        $onStack = $false
    }
    if (-not $onStack) {
        Write-Verbose "The async-teardown owner '$($owner['Command'])' is not running any more (stale record): no owner."
        return $null
    }
    return $owner
}
