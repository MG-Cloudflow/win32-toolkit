function Get-Win32ToolkitTestBackend {
    <#
    .SYNOPSIS
        Resolves the effective test/capture backend ('Sandbox' or 'HyperV').
    .DESCRIPTION
        Resolution order:
          1. An explicit -Backend override (validated) wins.
          2. Otherwise the stored 'TestBackend' config value (default 'Sandbox').
        If the resolved choice is 'HyperV' but the environment cannot support it right now
        (Test-Win32ToolkitHyperVReady returns reasons — not elevated, module/VM/checkpoint/credential
        missing), it falls back to 'Sandbox' with a warning rather than failing a run. This keeps the
        default path (Sandbox) unchanged and makes opting into Hyper-V safe. The dispatcher
        (Invoke-Win32ToolkitTestRun) gains its 'HyperV' branch in Phase 3; until then callers still get a
        correct answer, they just have no Hyper-V execution path yet.
        See knowledge-base/designs/hyperv-backend-plan.md.
    .PARAMETER Backend
        Optional per-call override: 'Sandbox' or 'HyperV'. When omitted, the stored config is used.
    .OUTPUTS
        [string] — 'Sandbox' or 'HyperV'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('Sandbox', 'HyperV')]
        [string]$Backend
    )

    $choice = if ($Backend) { $Backend } else { Get-Win32ToolkitConfigValue -Name 'TestBackend' -Default 'Sandbox' }

    if ($choice -ne 'HyperV') { return 'Sandbox' }

    $reasons = @(Test-Win32ToolkitHyperVReady)
    if ($reasons.Count -eq 0) { return 'HyperV' }

    Write-Warning ("Hyper-V test backend requested but not ready ({0}); falling back to Windows Sandbox." -f ($reasons -join '; '))
    return 'Sandbox'
}
