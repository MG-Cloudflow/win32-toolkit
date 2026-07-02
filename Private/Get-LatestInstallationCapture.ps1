function Get-LatestInstallationCapture {
    <#
    .SYNOPSIS
        Returns the newest InstallationChanges_*.json capture file for a project, or $null.
    .DESCRIPTION
        Shared selector for every consumer that globs the sandbox capture output, so they cannot
        drift: newest by LastWriteTime, name-descending as the deterministic tie-break (both files
        of a fast re-run can share a timestamp resolution). LastWriteTime is reliable here because
        the capture JSON is written by the sandbox directly into the host-backed mapped folder
        (host clock, no copy-back step); filename parsing would break on non-conforming names.

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
