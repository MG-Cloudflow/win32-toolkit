function Select-Win32ToolkitOlderVersion {
    <#
    .SYNOPSIS
        Filters a newest-first winget version list to the versions strictly OLDER than CurrentVersion.
    .DESCRIPTION
        Replaces the old exact-string-only filtering in Get-WingetVersions, whose miss-fallback
        returned the FULL list (so the Update test could install an equal/newer "old baseline").
        Strategy, in order:

          1. Exact match of CurrentVersion in the list (ordinal, then case-insensitive) — winget lists
             newest-first, so everything after the match is older.
          2. Numeric fallback: normalize both sides (strip a leading 'v'/'V' and any -prerelease/+build
             suffix, pad a bare integer to 'N.0') and keep entries that parse to a [version] strictly
             lower than CurrentVersion. Non-parseable entries are dropped (conservative: never risk a
             newer baseline).
          3. If CurrentVersion is not in the list AND cannot be parsed, THROW — callers must never fall
             back to an unfiltered list. The error points the operator at -SpecificVersion.

        Always returns a real array (unary-comma guarded), so a single-result list never unrolls to a
        string at the call site (that bug made '-VersionsBack 1' index into the version STRING and
        produce a one-character version).
    .PARAMETER Versions
        Version strings as listed by winget, newest first.
    .PARAMETER CurrentVersion
        The packaged version; only strictly-older entries are returned.
    .EXAMPLE
        Select-Win32ToolkitOlderVersion -Versions @('2.55.0','2.54.0','2.53.0') -CurrentVersion '2.55.0'
        # -> @('2.54.0','2.53.0')
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Versions,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CurrentVersion
    )

    function ConvertTo-ComparableVersion {
        param([string]$Value)
        $t = $Value.Trim() -replace '^[vV]', ''
        $t = ($t -split '[-+]', 2)[0].Trim()        # strip -prerelease / +build metadata
        # Right-pad numeric versions to 4 components so '1.2' == '1.2.0' == '1.2.0.0' ([version]
        # treats missing parts as -1, which would classify '1.2' as strictly older than '1.2.0'
        # and re-admit an equal-in-practice baseline under formatting drift).
        if ($t -match '^\d+(\.\d+){0,3}$') {
            $parts = @($t -split '\.')
            while ($parts.Count -lt 4) { $parts += '0' }
            $t = $parts -join '.'
        }
        $parsed = $null
        if ([version]::TryParse($t, [ref]$parsed)) { return $parsed }
        return $null
    }

    # NOTE: results are emitted plainly — call sites must wrap in @() (single results otherwise
    # unroll to a scalar string, which is exactly the -VersionsBack char-indexing bug).
    $list = @($Versions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($list.Count -eq 0) { return @() }

    # 1) Exact position in the newest-first list.
    $idx = [Array]::IndexOf([string[]]$list, $CurrentVersion)
    if ($idx -lt 0) {
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($list[$i] -ieq $CurrentVersion) { $idx = $i; break }
        }
    }
    if ($idx -ge 0) {
        if (($idx + 1) -ge $list.Count) { return @() }
        return @($list[($idx + 1)..($list.Count - 1)])
    }

    # 2) Numeric strictly-older fallback (current version pulled from winget, formatting drift, ...).
    $current = ConvertTo-ComparableVersion $CurrentVersion
    if ($current) {
        Write-Warning "Current version '$CurrentVersion' is not in the winget list — filtering numerically to strictly-older versions."
        $parseable = 0
        $older = foreach ($v in $list) {
            $pv = ConvertTo-ComparableVersion $v
            if ($pv) {
                $parseable++
                if ($pv -lt $current) { $v }
            }
            else { Write-Verbose "Dropped non-comparable version entry: '$v'" }
        }
        if ($parseable -eq 0) {
            # Older versions exist but none is comparable — say so honestly instead of letting the
            # caller report the misleading "no versions older than X are available".
            throw "None of the $($list.Count) listed versions for this package are comparable version strings, so versions older than '$CurrentVersion' cannot be identified. Use -SpecificVersion to pick the baseline explicitly."
        }
        return @($older)
    }

    # 3) No safe way to filter — refuse rather than hand back an unfiltered list.
    throw "Cannot determine which versions are older than '$CurrentVersion': it is not in the winget list and is not a comparable version string. Use -SpecificVersion to pick the baseline explicitly."
}
