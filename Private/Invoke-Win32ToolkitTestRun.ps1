function Invoke-Win32ToolkitTestRun {
    <#
    .SYNOPSIS
        Dispatches a prepared test/capture run to the selected backend and launches the environment.
    .DESCRIPTION
        The single seam the test/capture flows call to start a run, so a second backend can slot in
        without touching the flows. Today only the Sandbox backend exists: it launches the prepared .wsb
        (Start-Win32ToolkitSandbox), fire-and-forget — the caller's own Wait-* function then polls the
        mapped result file. A 'HyperV' backend is added here in Phase 3 (restore the clean-base
        checkpoint, open a PowerShell Direct session, copy the project in, run the phases, copy results
        back) behind this same call. See knowledge-base/designs/hyperv-backend-plan.md.
    .PARAMETER Backend
        'Sandbox' (default). 'HyperV' is added in Phase 3.
    .PARAMETER SandboxConfigPath
        Sandbox backend: full path to the prepared .wsb file to launch.
    .OUTPUTS
        [pscustomobject] @{ Backend = <string>; Launched = <bool> }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Sandbox')]
        [string]$Backend = 'Sandbox',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SandboxConfigPath
    )

    switch ($Backend) {
        'Sandbox' {
            $launched = Start-Win32ToolkitSandbox -ConfigPath $SandboxConfigPath
            return [pscustomobject]@{ Backend = 'Sandbox'; Launched = [bool]$launched }
        }
    }
}
