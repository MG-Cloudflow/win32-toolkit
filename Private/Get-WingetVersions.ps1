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
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $false)]
        [string]$CurrentVersion
    )

    Write-Host "Querying available versions for: $AppId" -ForegroundColor Yellow

    $raw = winget show $AppId --versions --accept-source-agreements 2>&1 | Out-String

    # Version lines start with a digit (optionally prefixed by 'v')
    $versions = ($raw -split "`r?`n") |
        Where-Object { $_ -match '^\s*v?\d+\.' } |
        ForEach-Object { $_.Trim() }

    if ($versions.Count -eq 0) {
        throw "No versions found for '$AppId'. Verify the package ID and your Winget source."
    }

    # Winget lists versions newest-first; filter to only those after (older than) CurrentVersion
    if ($CurrentVersion) {
        $idx = [Array]::IndexOf([string[]]$versions, $CurrentVersion)

        if ($idx -ge 0) {
            if (($idx + 1) -ge $versions.Count) {
                throw "No versions older than '$CurrentVersion' are available for '$AppId'."
            }
            $versions = $versions[($idx + 1)..($versions.Count - 1)]
        } else {
            # CurrentVersion not in the list — may be abbreviated differently; return all
            Write-Warning "Current version '$CurrentVersion' was not found in the version list for '$AppId'. Returning all available versions."
        }
    }

    return $versions
}
