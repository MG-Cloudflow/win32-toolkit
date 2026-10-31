function Get-Win32ToolkitNotConfiguredMarker {
    <#
    .SYNOPSIS
        Reads a project's not-configured marker (Documentation\NotConfigured.json; TUI audit G4, S10-F2).
    .DESCRIPTION
        Returns $null when the project has no marker. A present file always means "marked" (fail closed): a
        marker that cannot be read or parsed gives Stage 'Unknown', ErrorId '', Reason 'the marker file could not
        be read' and TimestampUtc $null.

        Stage, ErrorId and Reason pass ConvertTo-Win32ToolkitSafeText (the file is data a person or an installer
        under test could have edited). TimestampUtc is a UTC [datetime] or $null: a [datetime] from
        ConvertFrom-Json is converted with ToUniversalTime(), a string is parsed with the invariant culture
        (AdjustToUniversal), anything else gives $null. Never throws; its catch starts with the W32T.* re-throw.
    .PARAMETER ProjectPath
        The project folder.
    .OUTPUTS
        $null, or [pscustomobject] { Path; Stage; ErrorId; Reason; TimestampUtc }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$ProjectPath)

    $markerPath = Join-Path $ProjectPath 'Documentation\NotConfigured.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $null }

    # The advisory's instant rule (Get-Win32ToolkitPackageAdvisory): a UTC instant or $null, never culture text.
    $instant = {
        param($Value)
        if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
        $parsed = [datetime]::MinValue
        if ($Value -and [datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) { return $parsed }
        return $null
    }
    $unreadable = [pscustomobject]@{ Path = $markerPath; Stage = 'Unknown'; ErrorId = ''; Reason = 'the marker file could not be read'; TimestampUtc = $null }
    try {
        $data = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data -or $data -isnot [pscustomobject]) { return $unreadable }
        $get = { param([string]$Name) if ($data.PSObject.Properties[$Name]) { $data.$Name } else { $null } }
        $stage = ConvertTo-Win32ToolkitSafeText -Text ([string](& $get 'Stage')) -MaxLength 32
        if ($stage -notin @('Download', 'Configure')) { $stage = 'Unknown' }
        $errorId = ConvertTo-Win32ToolkitSafeText -Text ([string](& $get 'ErrorId')) -MaxLength 128
        if ($errorId -notlike 'W32T.*') { $errorId = '' }
        [pscustomobject]@{
            Path         = $markerPath
            Stage        = $stage
            ErrorId      = $errorId
            Reason       = ConvertTo-Win32ToolkitSafeText -Text ([string](& $get 'Reason')) -MaxLength 1024
            TimestampUtc = & $instant (& $get 'TimestampUtc')
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Not-configured marker '$markerPath' could not be read: $($_.Exception.Message)"
        $unreadable
    }
}
