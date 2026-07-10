function Test-Win32ToolkitSandboxRunning {
    <#
    .SYNOPSIS
        Returns $true if a Windows Sandbox instance is currently running.
    .DESCRIPTION
        Windows Sandbox permits only one running instance, so the test/capture flows fail fast when one
        is already open (e.g. a leftover documentation-capture sandbox) rather than launching a doomed
        second one. Extracted as a predicate (Sandbox test-backend availability check) so the seam and
        the tests can reason about it without inlining the process list.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $procs = @(Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue)
    return $procs.Count -gt 0
}
