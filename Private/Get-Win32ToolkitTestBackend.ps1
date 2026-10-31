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

        Pinned VM (speed-up PR 3, D11): when this session pins its test VM with W32T_HYPERV_VM, a not-ready VM (or an
        invalid pin) throws W32T.HyperVTargetNotReady instead of falling back: a pinned lane must never run a test
        outside the VM it was given.
    .PARAMETER Backend
        Optional per-call override: 'Sandbox' or 'HyperV'. When omitted, the stored config is used.
    .PARAMETER NoPinThrow
        Display only (Get-Win32ToolkitBackendInfo): a pinned VM that is not ready falls back like any other, without the
        throw; the caller reports it.
    .OUTPUTS
        [string] — 'Sandbox' or 'HyperV'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateSet('Sandbox', 'HyperV')]
        [string]$Backend,

        [switch]$NoPinThrow
    )

    $choice = if ($Backend) { $Backend } else { Get-Win32ToolkitConfigValue -Name 'TestBackend' -Default 'Sandbox' }

    if ($choice -ne 'HyperV') { return 'Sandbox' }

    $reasons = @(Test-Win32ToolkitHyperVReady)
    if ($reasons.Count -eq 0) { return 'HyperV' }

    if (-not $NoPinThrow) {
        # Fail closed under a pin (D11): an invalid pin throws here (the resolver), a pinned VM that is not ready below.
        $target = Get-Win32ToolkitHyperVTarget
        if ($target.Pinned) {
            $vmText = ConvertTo-Win32ToolkitSafeText -Text $target.VMName -MaxLength 64
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(("The test VM pinned by W32T_HYPERV_VM ('{0}') is not ready ({1}); the test was not started. Fix the VM or remove the pin." -f $vmText, ($reasons -join '; '))),
                'W32T.HyperVTargetNotReady', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $vmText)
        }
    }

    Write-Warning ("Hyper-V test backend requested but not ready ({0}); falling back to Windows Sandbox." -f ($reasons -join '; '))
    return 'Sandbox'
}
