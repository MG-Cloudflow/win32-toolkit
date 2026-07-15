function Get-WingetVersions {
<#
.SYNOPSIS
    Returns available versions for a Winget package, filtered to only those
    older than the currently packaged version.
.PARAMETER AppId
    The Winget package identifier (e.g. 'Git.Git').
.PARAMETER CurrentVersion
    The currently packaged version string. Versions equal to or newer than this
    are excluded from the returned list. If omitted, all available versions are
    returned.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $false)]
        [string]$CurrentVersion
    )

    Write-Verbose "Querying available versions for: $AppId"

    $raw = winget show $AppId --versions --accept-source-agreements 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "winget 'show --versions' failed for '$AppId' (exit code $LASTEXITCODE). Check the package ID, network, and winget source health."
    }

    # Version lines are single tokens starting with an optional 'v' + digit (also matches dotless
    # versions like '2024' and suffixed ones like '1.2.3-beta'; header/separator lines don't match).
    $versions = @(($raw -split "`r?`n") |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^v?\d[\w.\-+]*$' })

    if ($versions.Count -eq 0) {
        throw "No versions found for '$AppId'. Verify the package ID and your Winget source."
    }

    # Winget lists versions newest-first; keep only strictly-older entries. Select-Win32ToolkitOlderVersion
    # never falls back to the unfiltered list (that old behavior let the Update test install an
    # equal/NEWER baseline when the packaged version had been pulled from winget) — on an exact-match
    # miss it filters numerically, and throws when no safe comparison is possible.
    # NOTE: results are emitted plainly — call sites must wrap in @() (a single version otherwise
    # unrolls to a scalar string and indexing slices characters out of it).
    if ($CurrentVersion) {
        $older = @(Select-Win32ToolkitOlderVersion -Versions $versions -CurrentVersion $CurrentVersion)
        if ($older.Count -eq 0) {
            throw "No versions older than '$CurrentVersion' are available for '$AppId'."
        }
        return $older
    }

    return $versions
}
