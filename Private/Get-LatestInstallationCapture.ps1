function Get-LatestInstallationCapture {
    <#
    .SYNOPSIS
        Returns the newest InstallationChanges_*.json capture file for a project, or $null.
    .DESCRIPTION
        Shared selector for every consumer that globs the sandbox capture output, so they cannot
        drift: newest by LastWriteTime, name-descending as the deterministic tie-break (both files
        of a fast re-run can share a timestamp resolution). Under Windows Sandbox the capture JSON is
        written directly into the host-backed mapped folder (host clock, no copy-back step). Under
        Hyper-V the copy-in keeps each carried-in file's exact host UTC write time
        (Copy-Win32ToolkitProjectToGuest) and the copy-back restores each file's guest UTC write time
        (Copy-Win32ToolkitResultsFromGuest): an earlier capture that rides along keeps its own time, and
        a new one carries the guest clock, which the Hyper-V time service keeps in step with the host (a
        guest clock that is off would misorder them). Filename parsing would break on non-conforming names.

        Replaces the old first-in-filesystem-order selection ($jsonFiles[0] / Select-Object -First 1),
        which could pick a STALE capture from a previous run and let it drive uninstall logic,
        requirement scripts, and detection rules.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder (looks in <ProjectPath>\Documentation).
    .OUTPUTS
        [System.IO.FileInfo] of the newest capture, or $null when none exist.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $docPath = Join-Path $ProjectPath 'Documentation'
    if (-not (Test-Path -LiteralPath $docPath)) { return $null }

    Get-ChildItem -Path $docPath -Filter 'InstallationChanges_*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime, Name -Descending |
        Select-Object -First 1
}
