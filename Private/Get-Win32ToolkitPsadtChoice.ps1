function Get-Win32ToolkitPsadtChoice {
    <#
    .SYNOPSIS
        Builds the choices of the menu's PSAppDeployToolkit version screen (pure).
    .DESCRIPTION
        Menu selectors design section 3.2 (knowledge-base/designs/menu-selectors.md). From a Select-Win32ToolkitPsadtModule
        result it returns one row per choice the screen offers, in this order:
          * Default: no pin (Value ''), the newest supported version that is installed;
          * Minor:   'Always the newest installed <major>.<minor>.x' (Value '<major>.<minor>'), one per major.minor of an
                     installed copy inside the supported range, newest first (derived from the data, never hard-coded);
          * Exact:   'Exactly <VersionText>' (Value = the VersionText), one per installed copy inside the range; a
                     prerelease is marked as testing only (L4).
        Out-of-range copies are never offered. ResolvesTo is what each choice gives today, computed from Candidates
        (already in Select-Win32ToolkitPsadtModule's order), so a '4.2' that resolves to a prerelease says so; for
        Default it is the first in-range candidate (an empty -PreferredVersion would fall through to the environment
        variable and the registry). IsCurrent marks the row whose Value equals -SavedValue (the registry value the
        screen controls; case-insensitive; '' = Default). Nothing is installed, imported, queried or written.
    .PARAMETER Selection
        The object Select-Win32ToolkitPsadtModule returned (only Candidates is read).
    .PARAMETER SavedValue
        The saved PreferredPsadtVersion value ('' or $null = no pin).
    .OUTPUTS
        [pscustomobject[]] Kind, Value, Label, ResolvesTo, IsCurrent, IsPrerelease.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [object]$Selection,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$SavedValue
    )

    $saved = ([string]$SavedValue).Trim()
    $inRange = @(@($Selection.Candidates) | Where-Object { $null -ne $_ -and $_.InRange })
    $parse = {
        param([string]$Text)
        $v = $null
        if ([version]::TryParse(($Text -replace '[-+].*$', ''), [ref]$v)) { $v } else { $null }
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Kind, [string]$Value, [string]$Label, [string]$ResolvesTo, [bool]$IsPrerelease)
        $rows.Add([pscustomobject]@{
            Kind         = $Kind
            Value        = $Value
            Label        = $Label
            ResolvesTo   = $ResolvesTo
            IsCurrent    = [string]::Equals($Value, $saved, [System.StringComparison]::OrdinalIgnoreCase)
            IsPrerelease = $IsPrerelease
        })
    }

    $first = $inRange | Select-Object -First 1
    & $add 'Default' '' 'Use the newest supported version (no pin)' $(if ($first) { [string]$first.VersionText } else { '' }) $false

    $minors = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $inRange) {
        $v = & $parse ([string]$c.VersionText)
        if ($null -eq $v) { continue }
        $key = "$($v.Major).$($v.Minor)"
        if ($minors.Contains($key)) { continue }
        $minors.Add($key)
        # The first candidate of this major.minor is what Select-Win32ToolkitPsadtModule picks for '<major>.<minor>'.
        & $add 'Minor' $key "Always the newest installed $key.x" ([string]$c.VersionText) $false
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $inRange) {
        $text = [string]$c.VersionText
        if (-not $text -or -not $seen.Add($text)) { continue }   # the same version in two PSModulePath roots: one choice
        $label = if ($c.IsPrerelease) { "Exactly $text (prerelease: testing only)" } else { "Exactly $text" }
        & $add 'Exact' $text $label $text ([bool]$c.IsPrerelease)
    }

    return $rows.ToArray()
}
