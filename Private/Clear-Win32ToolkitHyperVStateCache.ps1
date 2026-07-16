function Clear-Win32ToolkitHyperVStateCache {
    <#
    .SYNOPSIS
        Invalidates the module's process-local Hyper-V state caches (clean marker + backend-ready cache).
    .DESCRIPTION
        Two pieces of $script: state let the pipeline avoid repeating expensive Hyper-V work:
          * $script:HyperVCleanMarker  — "this process just verified a teardown revert" (lets the next
            session open skip its then-redundant open-revert; see New/Remove-Win32ToolkitHyperVSession).
          * $script:HyperVReadyCache   — the memoized Test-Win32ToolkitHyperVReady verdict.
        Both describe the VM's state, so any VM-management action (provision, reset, resource change,
        removal — CLI or TUI, which calls the same cmdlets) must clear them. Clearing is always fail-safe:
        the worst outcome is one extra revert / one extra readiness probe.
    #>
    [CmdletBinding()]
    param()

    $script:HyperVCleanMarker = $null
    $script:HyperVReadyCache  = $null
}
