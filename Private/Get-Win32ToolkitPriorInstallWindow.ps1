function Get-Win32ToolkitPriorInstallWindow {
    <#
    .SYNOPSIS
        The version window of a captured prior-install identity, re-derived from its hash-verified capture records.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.8 rule 5, 2.15.1, 2.15.5; SV3, SV14, L36, D61). The ONE implementation of
        the window of a capture-lineage rule, used when a proposal is applied, by the raise after a new capture
        (Update-Win32ToolkitPriorInstallWindow) and at Export (PRIOR-CAPTURE-RECORD):

          VersionMin = the observed DisplayVersion of the floor capture (the record named by -FloorCaptureId, the rule's
                       CaptureId; without it the lowest observed version of the identity), padded to 4 parts;
          VersionMax = the highest observed DisplayVersion among the captures with the same identity (Tuple hash),
                       padded to 4 parts.
        Never rounded: '26.02' is 26.2.0.0, '8.7.9' is 8.7.9.0 (the device parser). -Below keeps only observed versions
        lower than it (a sibling of the package's own family: S3's strict window, VersionMax < App.Version).

        Found is $false when no capture has the identity, or the named floor record is not one of them (the record
        was removed, changed, or re-derives another identity). Pure.
    .PARAMETER Captures
        The per-capture rows of ConvertTo-Win32ToolkitSiblingProposal (.Captures): CaptureId, Tuple, ObservedVersion,
        SiblingVersion, Role.
    .PARAMETER Tuple
        The identity: Get-Win32ToolkitPriorInstallHash -Kind Tuple of the rule or proposal.
    .PARAMETER FloorCaptureId
        The rule's CaptureId (the floor record), when the rule exists.
    .PARAMETER Below
        Keep only observed versions lower than this version (the package version of a same-family sibling).
    .OUTPUTS
        [pscustomobject] Found, VersionMin, VersionMax, FloorCaptureId, CaptureIds (the floor first), Reason.
    .EXAMPLE
        Get-Win32ToolkitPriorInstallWindow -Captures $sib.Captures -Tuple $hash -FloorCaptureId $entry.CaptureId
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Captures,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Tuple,

        [AllowEmptyString()]
        [string]$FloorCaptureId = '',

        [AllowEmptyString()]
        [string]$Below = ''
    )

    $none = { param([string]$Why) [pscustomobject]@{ Found = $false; VersionMin = ''; VersionMax = ''; FloorCaptureId = ''; CaptureIds = [string[]]@(); Reason = $Why } }
    if (-not $Tuple) { return (& $none 'no identity') }
    $limit = if ($Below) { ConvertTo-Win32ToolkitPriorVersion -Text $Below } else { $null }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @($Captures | Where-Object { $null -ne $_ })) {
        if ([string]$c.Tuple -cne $Tuple) { continue }
        $v = ConvertTo-Win32ToolkitPriorVersion -Text ([string]$c.ObservedVersion)
        if ($null -eq $v) { continue }
        if ($null -ne $limit -and $v -ge $limit) { continue }
        $rows.Add([pscustomobject]@{ CaptureId = [string]$c.CaptureId; Version = $v; Floor = ([string]$c.Role -eq 'Floor') })
    }
    if ($rows.Count -eq 0) { return (& $none 'no capture record observed this identity') }
    $ordered = @($rows | Sort-Object -Property @{ Expression = 'Version' }, @{ Expression = { -not $_.Floor } }, @{ Expression = 'CaptureId' })
    $floor = $null
    if ($FloorCaptureId) {
        $floor = @($ordered | Where-Object { $_.CaptureId -ceq $FloorCaptureId }) | Select-Object -First 1
        if ($null -eq $floor) { return (& $none "the floor record $FloorCaptureId does not observe this identity") }
    }
    else { $floor = $ordered[0] }
    $max = @($ordered | ForEach-Object { $_.Version } | Sort-Object)[-1]
    $ids = [string[]]@(@($floor.CaptureId) + @($ordered | Where-Object { $_.CaptureId -cne $floor.CaptureId } | ForEach-Object { $_.CaptureId }))
    return [pscustomobject]@{
        Found          = $true
        VersionMin     = $floor.Version.ToString()
        VersionMax     = $max.ToString()
        FloorCaptureId = $floor.CaptureId
        CaptureIds     = $ids
        Reason         = ''
    }
}
