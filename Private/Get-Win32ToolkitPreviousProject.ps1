function Get-Win32ToolkitPreviousProject {
    <#
    .SYNOPSIS
        Finds the earlier versions of an app in the same template folder, and the one that anchors continuity.
    .DESCRIPTION
        Installer-identity PR 1, spec 2.8 (D3, D31, V34, V44). Candidates are the project folders of
        TemplateDirectory (<BasePath>\Projects\<Template>) that hold Invoke-AppDeployToolkit.ps1 and a readable
        SupportFiles\AppConfig.json, except ExcludePath (the project being built).

        A candidate matches by the same winget id (AppConfig.Source.WingetId, else the project's manifest;
        MatchedBy 'WingetId'), else by the same non-empty Vendor AND DisplayName (MatchedBy
        'VendorDisplayName'), all case-insensitive, and only when its App.Version is strictly lower than
        -Version (both read as four numeric parts: the leading numeric run, a 'v' prefix tolerated, missing
        parts 0; an unparsable version is skipped).

        A match is anchored when it was published (Intune\Publications.json has an entry - for -TenantId
        only that tenant's; without it any entry, the template folder being the tenant boundary, Dv4) or
        its persisted AppConfig.Source.PinnedBy is 'parameter' or 'operator'. 'continuity' alone does not
        anchor, so v3 still anchors on a published v1 through an unpublished continuity v2.

        Anchor = the highest-version anchored match (tie: the newest App.ScriptDate). HighestUnanchored =
        the highest unanchored match above it (or above nothing when there is no anchor), else $null.
        AmbiguousIds = the distinct winget ids (this app's included) of projects that share this app's
        Vendor and DisplayName (PowerShell msi/msix, Chrome/Chrome.EXE).

        Never throws: an unreadable candidate is skipped (Write-Verbose). Strings from other projects pass
        ConvertTo-Win32ToolkitSafeText.
    .PARAMETER TemplateDirectory
        The template folder under Projects\.
    .PARAMETER Version
        The new app's version.
    .PARAMETER WingetId
        The new app's winget id.
    .PARAMETER Vendor
        The new app's App.Vendor (for the Vendor + DisplayName match).
    .PARAMETER DisplayName
        The new app's App.DisplayName (else App.Name).
    .PARAMETER ExcludePath
        The project being built (never its own predecessor).
    .PARAMETER TenantId
        Only publications to this tenant anchor.
    .OUTPUTS
        [pscustomobject] Anchor, HighestUnanchored, Matches, AmbiguousIds. Each match: Name, Template, Path,
        Version, WingetId, Vendor, DisplayName, ScriptAuthor, TattooKey, InstallerType, Family, PinnedBy,
        SourceRebuilt, Published, Anchored, AnchorReason ('published' | 'pinned:parameter' |
        'pinned:operator' | ''), MatchedBy.
    .EXAMPLE
        (Get-Win32ToolkitPreviousProject -TemplateDirectory $dir -Version '8.9.8.1' -WingetId 'Notepad++.Notepad++').Anchor
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateDirectory,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$WingetId = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Vendor = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$DisplayName = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExcludePath = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TenantId = ''
    )

    $result = [pscustomobject]@{ Anchor = $null; HighestUnanchored = $null; Matches = @(); AmbiguousIds = @() }
    $safe = { param($Value) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength 256 }
    # Four numeric parts from the leading numeric run ('v' prefix tolerated); $null when unparsable.
    $toKey = {
        param([string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Trim() -notmatch '^[vV]?(\d+(?:\.\d+)*)') { return $null }
        $parts = @($Matches[1].Split('.') | Select-Object -First 4)
        $nums = [long[]]::new(4)
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $n = 0L
            if (-not [long]::TryParse($parts[$i], [ref]$n)) { return $null }
            $nums[$i] = $n
        }
        , $nums
    }
    $compare = {
        param([long[]]$A, [long[]]$B)
        for ($i = 0; $i -lt 4; $i++) { if ($A[$i] -ne $B[$i]) { return [math]::Sign($A[$i] - $B[$i]) } }
        return 0
    }

    $newKey = & $toKey $Version
    $newId  = ([string]$WingetId).Trim()
    $newVendor = ([string]$Vendor).Trim()
    $newName   = ([string]$DisplayName).Trim()
    $exclude   = if ($ExcludePath) { ([string]$ExcludePath).Trim().TrimEnd('\') } else { '' }

    if (-not (Test-Path -LiteralPath $TemplateDirectory -PathType Container)) {
        Write-Verbose "Get-Win32ToolkitPreviousProject: '$TemplateDirectory' does not exist."
        return $result
    }
    if ($null -eq $newKey) {
        Write-Verbose "Get-Win32ToolkitPreviousProject: version '$Version' is not parsable; no predecessor lookup."
    }

    $folders = @(Get-ChildItem -LiteralPath $TemplateDirectory -Directory -ErrorAction SilentlyContinue)
    $matchesFound = [System.Collections.Generic.List[object]]::new()
    $ambiguous = [System.Collections.Generic.List[string]]::new()
    if ($newId -and $newVendor -and $newName) { $ambiguous.Add($newId) }

    foreach ($folder in $folders) {
        try {
            $path = $folder.FullName.TrimEnd('\')
            if ($exclude -and [string]::Equals($path, $exclude, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $path 'Invoke-AppDeployToolkit.ps1'))) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $path 'SupportFiles\AppConfig.json'))) { continue }
            $cfg = Get-Win32ToolkitAppConfig -ProjectPath $path
            if (-not $cfg) { continue }

            $app = if ($cfg.PSObject.Properties['App'] -and $cfg.App) { $cfg.App } else { $null }
            $persisted = if ($cfg.PSObject.Properties['Source'] -and $cfg.Source) { $cfg.Source } else { $null }
            $candId = ''
            if ($persisted -and $persisted.PSObject.Properties['WingetId'] -and $persisted.WingetId) { $candId = [string]$persisted.WingetId }
            else { $candId = [string](Get-WingetIdFromProject -FilesPath (Join-Path $path 'Files')) }
            $candId = ($candId.Trim() -replace "^'(.*)'$", '$1' -replace '^"(.*)"$', '$1')
            $candVendor = if ($app -and $app.PSObject.Properties['Vendor']) { ([string]$app.Vendor).Trim() } else { '' }
            $candName   = if ($app -and $app.PSObject.Properties['DisplayName'] -and $app.DisplayName) { ([string]$app.DisplayName).Trim() }
                          elseif ($app -and $app.PSObject.Properties['Name']) { ([string]$app.Name).Trim() } else { '' }
            $candAuthor = if ($app -and $app.PSObject.Properties['ScriptAuthor']) { ([string]$app.ScriptAuthor).Trim() } else { '' }
            $candVer    = if ($app -and $app.PSObject.Properties['Version']) { ([string]$app.Version).Trim() } else { '' }
            $candDate   = if ($app -and $app.PSObject.Properties['ScriptDate']) { [string]$app.ScriptDate } else { '' }

            $sameVdn = $newVendor -and $newName -and $candVendor -and $candName -and
                       [string]::Equals($candVendor, $newVendor, [System.StringComparison]::OrdinalIgnoreCase) -and
                       [string]::Equals($candName, $newName, [System.StringComparison]::OrdinalIgnoreCase)
            if ($sameVdn -and $candId -and -not ($ambiguous | Where-Object { [string]::Equals($_, $candId, [System.StringComparison]::OrdinalIgnoreCase) })) {
                $ambiguous.Add($candId)
            }

            $matchedBy = if ($newId -and $candId -and [string]::Equals($candId, $newId, [System.StringComparison]::OrdinalIgnoreCase)) { 'WingetId' }
                         elseif ($sameVdn) { 'VendorDisplayName' }
                         else { '' }
            if (-not $matchedBy -or $null -eq $newKey) { continue }

            $candKey = & $toKey $candVer
            if ($null -eq $candKey) { Write-Verbose "Get-Win32ToolkitPreviousProject: '$($folder.Name)' has an unparsable version '$candVer' - skipped."; continue }
            if ((& $compare $candKey $newKey) -ge 0) { continue }

            $pubs = if ($TenantId) { @(Get-Win32ToolkitPublication -ProjectPath $path -TenantId $TenantId) } else { @(Get-Win32ToolkitPublication -ProjectPath $path) }
            $published = $pubs.Count -ge 1
            $persistedPin = if ($persisted -and $persisted.PSObject.Properties['PinnedBy']) { ([string]$persisted.PinnedBy).Trim().ToLowerInvariant() } else { '' }
            $anchorReason = if ($published) { 'published' }
                            elseif ($persistedPin -in @('parameter', 'operator')) { "pinned:$persistedPin" }
                            else { '' }

            $src = Get-Win32ToolkitProjectSource -ProjectPath $path

            $matchesFound.Add([pscustomobject]@{
                    Name          = & $safe $folder.Name
                    Template      = & $safe (Split-Path -Path $TemplateDirectory -Leaf)
                    Path          = $path
                    Version       = & $safe $candVer
                    WingetId      = & $safe $candId
                    Vendor        = & $safe $candVendor
                    DisplayName   = & $safe $candName
                    ScriptAuthor  = & $safe $candAuthor
                    TattooKey     = & $safe ('{0}\{1}\{2}' -f $candAuthor, $candVendor, $candName)
                    InstallerType = [string]$src.InstallerType
                    Family        = [string]$src.Family
                    PinnedBy      = [string]$src.PinnedBy
                    SourceRebuilt = [bool]$src.Rebuilt
                    Published     = $published
                    Anchored      = [bool]$anchorReason
                    AnchorReason  = $anchorReason
                    MatchedBy     = $matchedBy
                    VersionKey    = $candKey
                    ScriptDate    = & $safe $candDate
                })
        } catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Get-Win32ToolkitPreviousProject: '$($folder.Name)' skipped: $($_.Exception.Message)"
        }
    }

    # Highest version first; tie -> newest ScriptDate (yyyy-MM-dd sorts as text).
    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $matchesFound) {
        $i = 0
        while ($i -lt $sorted.Count) {
            $c = & $compare $m.VersionKey $sorted[$i].VersionKey
            if ($c -gt 0 -or ($c -eq 0 -and [string]::CompareOrdinal($m.ScriptDate, $sorted[$i].ScriptDate) -gt 0)) { break }
            $i++
        }
        $sorted.Insert($i, $m)
    }

    $anchor = $sorted | Where-Object { $_.Anchored } | Select-Object -First 1
    $highestUnanchored = $null
    foreach ($m in $sorted) {
        if ($m.Anchored) { break }        # sorted descending: anything after the anchor is below it
        $highestUnanchored = $m; break
    }

    $strip = { param($m) if ($m) { $m | Select-Object -Property * -ExcludeProperty VersionKey, ScriptDate } }
    $result.Anchor            = & $strip $anchor
    $result.HighestUnanchored = & $strip $highestUnanchored
    $result.Matches           = @($sorted | ForEach-Object { & $strip $_ })
    $result.AmbiguousIds      = @($ambiguous | ForEach-Object { & $safe $_ })
    return $result
}
