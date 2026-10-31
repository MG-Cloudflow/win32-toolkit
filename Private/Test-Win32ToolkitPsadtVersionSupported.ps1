function Test-Win32ToolkitPsadtVersionSupported {
    <#
    .SYNOPSIS
        Returns $true when a PSAppDeployToolkit version lies inside the supported range.
    .DESCRIPTION
        The single range check for PSAppDeployToolkit versions (impact analysis D1/D3, L4): $true iff
        $script:PsadtSupportedRange.Min <= version < $script:PsadtSupportedRange.MaxExclusive. The range
        constant lives in win32-toolkit.psm1; unit tests that dot-source this file set it themselves.

        Accepts a [version], a version string such as '4.2.0', or a prerelease string such as
        '4.2.0-rc2' (the label after '-' and any '+build' suffix are ignored, so a prerelease of an
        in-range version is in range). Missing components count as 0 ('4.1' -> 4.1.0). $null, an empty
        string or anything unparsable returns $false. Nothing is installed, imported or queried.

        Fails closed when the range constant is missing: that signals a loader or test bug, not a user
        condition, so it throws a plain InvalidOperationException (not a W32T.* error).
    .PARAMETER Version
        The version to test ([version], [string] or anything whose string form is a version).
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [object]$Version
    )

    if ($null -eq $script:PsadtSupportedRange) {
        throw [System.InvalidOperationException]::new('win32-toolkit internal error: PsadtSupportedRange is not initialised')
    }
    if ($null -eq $Version) { return $false }

    if ($Version -is [version]) {
        $parsed = $Version
    }
    else {
        # Drop a SemVer prerelease label / build metadata: '4.2.0-rc2' -> '4.2.0'.
        $text = ([string]$Version).Trim() -replace '[-+].*$', ''
        $parsed = $null
        if (-not [version]::TryParse($text, [ref]$parsed)) { return $false }
    }

    # Normalise a missing Build to 0 so '4.1' compares as 4.1.0 (a [version] with Build -1 sorts BELOW
    # 4.1.0 and would otherwise fall out of the range).
    if ($parsed.Build -lt 0) { $parsed = [version]::new($parsed.Major, $parsed.Minor, 0) }
    return ($parsed -ge $script:PsadtSupportedRange.Min -and $parsed -lt $script:PsadtSupportedRange.MaxExclusive)
}
