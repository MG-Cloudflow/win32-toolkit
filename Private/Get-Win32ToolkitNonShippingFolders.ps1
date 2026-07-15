function Get-Win32ToolkitNonShippingFolders {
    <#
    .SYNOPSIS
        Top-level project folders that must NEVER ship inside a .intunewin (test scaffolding + secrets).
    .DESCRIPTION
        Single source of truth shared by two packaging steps so they cannot drift:
          * Export-Win32ToolkitIntuneWin excludes them from the Staging copy up front (so they never land
            in Staging — no post-copy strip to fail on a freshly-written, AV-locked file), and
          * Optimize-Win32ToolkitProject removes them as a safety net.

        'Intune' holds Publications.json — tenant ids + app ids that must NEVER travel to a device — so
        excluding it at copy time also hardens that secret against a failed strip. 'Sandbox' is the test
        scaffolding (.wsb, Countdown, OldVersion + Dependencies installers, the nested PSADT of any
        dependency); 'Documentation' is the capture folder; 'Docs'/'Examples' are PSADT v4 boilerplate.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    # Leading comma: return the array as a single object so callers get a string[] intact.
    , @('Docs', 'Examples', 'Sandbox', 'Documentation', 'Intune')
}
