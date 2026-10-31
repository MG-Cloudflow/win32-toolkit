function Find-Win32ToolkitNotConfiguredProject {
    <#
    .SYNOPSIS
        Finds the project folders a wizard run just left marked not configured (TUI audit G4, tui-gaps-spec 7.3).
    .DESCRIPTION
        The wizards call it after a failed build to name the kept, marked folder in their panel, without guessing the
        folder name (the two winget searches may name the app differently).

        Candidates: when -ProjectPath is a direct child of -TemplateDirectory (full paths, case-insensitive), only
        that project (the error's own TargetObject: W32T.PipelineAborted and W32T.DownloadFailed carry it, and so
        does a Failed result's ProjectPath); otherwise every folder of the template directory.

        A candidate is named only when its marker (Get-Win32ToolkitNotConfiguredMarker) has a TimestampUtc with
        SinceUtc <= t <= now + 1 minute AND the marker file's LastWriteTimeUtc >= SinceUtc - 2 s: a marker from an
        earlier run, one with no parsable time, or a future-dated (hand-made or copied) one is never named. The 2 s
        allow for file times being coarser than [datetime]::UtcNow (about 16 ms on NTFS, 2 s on FAT): a marker written
        in the same clock tick as the run start can carry a write time just before it. Limit: during the scan, a
        marker another session writes in the same template folder during this run is named too.

        Never throws: its catch starts with the W32T.* re-throw, then returns nothing.
    .PARAMETER TemplateDirectory
        Projects\<Template> of the run.
    .PARAMETER SinceUtc
        When the run started (UTC).
    .PARAMETER ProjectPath
        The error's TargetObject or the result's ProjectPath, when there is one.
    .OUTPUTS
        [string] full project paths.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TemplateDirectory,
        [Parameter(Mandatory)][datetime]$SinceUtc,
        [AllowEmptyString()][AllowNull()][string]$ProjectPath
    )

    try {
        if ([string]::IsNullOrWhiteSpace($TemplateDirectory) -or -not (Test-Path -LiteralPath $TemplateDirectory -PathType Container)) { return }
        $since = if ($SinceUtc.Kind -eq [System.DateTimeKind]::Local) { $SinceUtc.ToUniversalTime() } else { $SinceUtc }
        $tplFull = [System.IO.Path]::GetFullPath($TemplateDirectory).TrimEnd('\', '/')

        $own = $null
        if (-not [string]::IsNullOrWhiteSpace($ProjectPath) -and [System.IO.Path]::IsPathRooted($ProjectPath)) {
            $full = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd('\', '/')
            $parent = [System.IO.Path]::GetDirectoryName($full)
            if ($parent -and [string]::Equals($parent.TrimEnd('\', '/'), $tplFull, [System.StringComparison]::OrdinalIgnoreCase)) { $own = $full }
        }
        $candidates = if ($own) { @($own) } else { @(Get-ChildItem -LiteralPath $tplFull -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }

        foreach ($candidate in $candidates) {
            $marker = Get-Win32ToolkitNotConfiguredMarker -ProjectPath $candidate
            if (-not $marker -or $marker.TimestampUtc -isnot [datetime]) { continue }
            $now = [datetime]::UtcNow
            if ($marker.TimestampUtc -lt $since -or $marker.TimestampUtc -gt $now.AddMinutes(1)) { continue }
            $file = Get-Item -LiteralPath $marker.Path -ErrorAction SilentlyContinue
            if (-not $file -or $file.LastWriteTimeUtc -lt $since.AddSeconds(-2)) { continue }
            $candidate
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Not-configured projects could not be listed: $($_.Exception.Message)"
    }
}
