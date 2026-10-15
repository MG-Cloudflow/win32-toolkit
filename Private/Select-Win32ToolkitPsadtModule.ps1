function Select-Win32ToolkitPsadtModule {
    <#
    .SYNOPSIS
        Picks the installed PSAppDeployToolkit copy win32-toolkit should use (pure selection).
    .DESCRIPTION
        The one place that decides WHICH installed PSAppDeployToolkit a new project is scaffolded with
        (impact analysis D1/L4; spec section 2.3). It never installs, imports, prompts or queries the
        gallery - callers (Create-PSADTProject, the health check, the org-template wizard) act on the
        result.

        Rules:
          1. Candidates = Get-Module -Name PSAppDeployToolkit -ListAvailable. Only .Version, .Path,
             .ModuleBase and .PrivateData.PSData.Prerelease are read, so tests can pass doubles.
          2. Order: Version descending, then a stable build before a prerelease of the same version,
             then the prerelease label descending (ordinal), then PSModulePath order.
          3. A preferred version, first non-empty of: -PreferredVersion, $env:W32T_PSADT_VERSION, the
             PreferredPsadtVersion registry value (Get-Win32ToolkitConfigValue). An exact version text
             ('4.1.8', '4.2.0-rc2'; case-insensitive) or a Major.Minor value ('4.1' = the best installed
             in-range 4.1.x). A preference that is not installed or not in range gives
             Status 'PreferredNotFound' and no module - never a silent fallback.
          4. Without a preference: the first in-range candidate. Nothing installed -> 'NoneInstalled';
             only out-of-range copies installed -> 'NoneInRange'.
          5. An in-range prerelease is selectable (L4); callers warn about it.
    .PARAMETER PreferredVersion
        Optional pin for this call; wins over the environment variable and the registry value.
    .OUTPUTS
        [pscustomobject] with Status, Module, Version, Prerelease, VersionText, IsPrerelease, IsPinned,
        PreferredSource, NewestInstalled, NewestInstalledText, NewestInstalledInRange, Candidates, Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$PreferredVersion
    )

    $range = $script:PsadtSupportedRange
    if ($null -eq $range) {
        throw [System.InvalidOperationException]::new('win32-toolkit internal error: PsadtSupportedRange is not initialised')
    }

    # -- 1. Candidates -----------------------------------------------------------------------------
    $rows = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($m in @(Get-Module -Name PSAppDeployToolkit -ListAvailable -ErrorAction SilentlyContinue)) {
        if ($null -eq $m) { continue }
        $ver = $null
        if ($m.Version -is [version]) { $ver = $m.Version }
        elseif (-not [version]::TryParse(([string]$m.Version -replace '[-+].*$', ''), [ref]$ver)) { $index++; continue }

        $pre = ''
        try { $pre = [string]$m.PrivateData.PSData.Prerelease } catch { $pre = '' }
        $pre = $pre.Trim()

        $rows.Add([pscustomobject]@{
            Module       = $m
            Version      = $ver
            Prerelease   = $pre
            VersionText  = if ($pre) { "$ver-$pre" } else { "$ver" }
            IsPrerelease = [bool]$pre
            InRange      = (Test-Win32ToolkitPsadtVersionSupported -Version $ver)
            Path         = [string]$m.Path
            Index        = $index
        })
        $index++
    }

    # -- 2. Order ------------------------------------------------------------------------------------
    $rows.Sort([System.Comparison[object]] {
        param($a, $b)
        $c = $b.Version.CompareTo($a.Version)                                   # newest first
        if ($c -ne 0) { return $c }
        if ($a.IsPrerelease -ne $b.IsPrerelease) { return $(if ($a.IsPrerelease) { 1 } else { -1 }) }   # stable first
        $c = [string]::CompareOrdinal($b.Prerelease, $a.Prerelease)             # label descending
        if ($c -ne 0) { return $c }
        return $a.Index.CompareTo($b.Index)                                     # PSModulePath order
    })

    $candidates = @(foreach ($r in $rows) {
        [pscustomobject]@{ VersionText = $r.VersionText; Path = $r.Path; InRange = $r.InRange; IsPrerelease = $r.IsPrerelease }
    })
    $newest = if ($rows.Count -gt 0) { $rows[0] } else { $null }

    # -- 3. Preferred version ------------------------------------------------------------------------
    $pref = ''; $prefSource = ''
    if (-not [string]::IsNullOrWhiteSpace($PreferredVersion)) {
        $pref = $PreferredVersion.Trim(); $prefSource = 'Parameter'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:W32T_PSADT_VERSION)) {
        $pref = $env:W32T_PSADT_VERSION.Trim(); $prefSource = 'Environment'
    }
    else {
        $regPref = Get-Win32ToolkitConfigValue -Name 'PreferredPsadtVersion'
        if (-not [string]::IsNullOrWhiteSpace($regPref)) { $pref = ([string]$regPref).Trim(); $prefSource = 'Registry' }
    }

    $chosen = $null
    $status = 'Selected'
    if ($pref) {
        if ($pref -match '^(\d+)\.(\d+)$') {
            $maj = [int]$Matches[1]; $min = [int]$Matches[2]
            $chosen = $rows | Where-Object { $_.InRange -and $_.Version.Major -eq $maj -and $_.Version.Minor -eq $min } |
                Select-Object -First 1
        }
        else {
            $chosen = $rows | Where-Object { $_.InRange -and [string]::Equals($_.VersionText, $pref, [System.StringComparison]::OrdinalIgnoreCase) } |
                Select-Object -First 1
        }
        if (-not $chosen) { $status = 'PreferredNotFound' }
    }
    else {
        $chosen = $rows | Where-Object { $_.InRange } | Select-Object -First 1
        if (-not $chosen) { $status = if ($rows.Count -eq 0) { 'NoneInstalled' } else { 'NoneInRange' } }
    }

    # -- Reason (one line, used verbatim by callers) -------------------------------------------------
    $display = $range.Display
    $sourceText = switch ($prefSource) {
        'Parameter'   { 'from -PreferredVersion' }
        'Environment' { 'from $env:W32T_PSADT_VERSION' }
        'Registry'    { 'from the registry' }
        default       { '' }
    }
    $reason = switch ($status) {
        'NoneInstalled' { "No PSAppDeployToolkit installed (supported: $display)." }
        'NoneInRange' {
            "PSAppDeployToolkit $($newest.VersionText) is installed but not supported by this win32-toolkit version (supported: $display); no supported version is installed."
        }
        'PreferredNotFound' {
            "PreferredPsadtVersion '$pref' ($sourceText) is not installed or not supported (supported: $display)."
        }
        default {
            $pinNote = if ($pref) { " (pinned by PreferredPsadtVersion '$pref', $sourceText)" } else { '' }
            if ($newest -and -not $newest.InRange) {
                "PSAppDeployToolkit $($newest.VersionText) is installed but not supported by this win32-toolkit version (supported: $display); using $($chosen.VersionText)$pinNote."
            }
            else {
                "Using PSAppDeployToolkit $($chosen.VersionText)$pinNote (supported: $display)."
            }
        }
    }

    [pscustomobject]@{
        Status                 = $status
        Module                 = if ($chosen) { $chosen.Module } else { $null }
        Version                = if ($chosen) { $chosen.Version } else { $null }
        Prerelease             = if ($chosen) { $chosen.Prerelease } else { '' }
        VersionText            = if ($chosen) { $chosen.VersionText } else { '' }
        IsPrerelease           = if ($chosen) { $chosen.IsPrerelease } else { $false }
        IsPinned               = [bool]$pref
        PreferredSource        = $prefSource
        NewestInstalled        = if ($newest) { $newest.Module } else { $null }
        NewestInstalledText    = if ($newest) { $newest.VersionText } else { '' }
        NewestInstalledInRange = if ($newest) { [bool]$newest.InRange } else { $false }
        Candidates             = $candidates
        Reason                 = $reason
    }
}
