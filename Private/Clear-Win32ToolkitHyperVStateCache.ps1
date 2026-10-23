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

        Two modes (Hyper-V speed-up PR 1, A-6):
          * without -MarkerOnly (every VM-management command): everything above.
          * -MarkerOnly: the clean marker only, so the next run restores the checkpoint; the readiness memo
            stays (a queue runner or a test harness that wants a fresh restore between runs).
    .PARAMETER MarkerOnly
        Clear only $script:HyperVCleanMarker.
    #>
    [CmdletBinding()]
    param(
        [switch]$MarkerOnly
    )

    $script:HyperVCleanMarker = $null
    if (-not $MarkerOnly) {
        $script:HyperVReadyCache = $null
    }
}
