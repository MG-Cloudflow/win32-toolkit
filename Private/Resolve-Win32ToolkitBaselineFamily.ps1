function Resolve-Win32ToolkitBaselineFamily {
    <#
    .SYNOPSIS
        Decides which installer technology (family) the Update test's old-version baseline must use.
    .DESCRIPTION
        Installer-identity PR 1, spec 2.11 (D5, L2, L13, L19, V22, V29). Returns one or more legs; the Update test
        runs once per leg. Every leg pins an installer type (never an unpinned download) and never a locale.

          Packaged   the packaged installer type (its pin value), family and the packaged manifest's explicit
                     scope (a soft preference, L19). No fallback.
          Auto       (1) the first AppConfig.PriorInstalls.Entries item with Mode Enforce and UninstallerType
                         nullsoft or inno (Origin Entry; no project has such entries before PR 3);
                     (2) else the highest-precedence testable sibling family from Documentation\IdentityDelta.json
                         (Origin Sibling, with the packaged type and scope as the pinned fallback, L2);
                     (3) else the packaged leg.
          Both       the packaged leg plus one leg per testable sibling family (that family's highest-precedence
                     testable type); only the packaged leg when there is none.
          <type>     msi, wix, burn, nullsoft, inno, exe or msix (Origin Explicit, no fallback). The scope comes
                     from a testable sibling with that pin value when its scope is explicit, or from the packaged
                     manifest when the type is the packaged one.

        Siblings are the 'Siblings' of Documentation\IdentityDelta.json with Testable = true (registering,
        downloadable, not zip-wrapped). An untestable sibling only adds a Note. For Auto and Both a missing
        IdentityDelta.json is written first with Write-Win32ToolkitIdentityDelta -Quiet (one sibling probe),
        unless -NoProbe; a stored probe with Status Unavailable (offline, HTTP 429, ...) is retried the same way
        once per call (the per-process probe memo bounds the requests). When the probe still did not succeed
        (or the file is missing or unreadable), the packaged leg of Auto and Both carries the Note 'Other
        installer technologies could not be checked (<reason>), so the packaged technology is used; ...', so a
        packaged-over-packaged run never looks like a sibling check that found nothing. The file is read
        leniently: a missing or unreadable file, unknown fields or a newer SchemaVersion never throw.

        Every leg: Family, InstallerType (a -BaselineInstallerType value), Scope ('' = winget's choice), Origin
        (Entry | Sibling | Packaged | Explicit), FallbackInstallerType, FallbackScope, Label
        ('<type label> (<origin>)', printed before the version picker) and Note ('' or extra information).
    .PARAMETER ProjectPath
        The project under test.
    .PARAMETER Mode
        Auto, Both, Packaged or an installer type (msi, wix, burn, nullsoft, inno, exe, msix).
    .PARAMETER NoProbe
        Never write Documentation\IdentityDelta.json (no sibling probe request).
    .OUTPUTS
        [pscustomobject[]] the legs (at least one).
    .EXAMPLE
        $legs = @(Resolve-Win32ToolkitBaselineFamily -ProjectPath $p -Mode Auto)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateSet('Auto', 'Both', 'Packaged', 'msi', 'wix', 'burn', 'nullsoft', 'inno', 'exe', 'msix')]
        [string]$Mode,

        [switch]$NoProbe
    )

    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $null } }
    $safe = { param($Value) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength 64 }
    $lower = { param($Value) ([string]$Value).Trim().ToLowerInvariant() }
    $origins = @{
        Entry    = 'prior install to replace'
        Sibling  = 'other technology winget ships for this app'
        Packaged = 'packaged technology'
        Explicit = 'requested with -BaselineInstallerType'
    }
    $newLeg = {
        param([string]$Type, [string]$Scope, [string]$Origin, [string]$FallbackType = '', [string]$FallbackScope = '', [string]$Note = '')
        $row = Get-Win32ToolkitInstallerFamily -Type $Type
        $label = if ($Type) { '{0} ({1})' -f $row.Label, $origins[$Origin] } else { 'unknown installer type ({0})' -f $origins[$Origin] }
        [pscustomobject]@{
            Family                = if ($Type) { [string]$row.Family } else { '' }
            InstallerType         = $Type
            Scope                 = $Scope
            Origin                = $Origin
            FallbackInstallerType = $FallbackType
            FallbackScope         = $FallbackScope
            Label                 = $label
            Note                  = $Note
        }
    }
    # Only an explicit machine/user scope is a preference; anything else means "winget's choice".
    $scopeOf = { param($Value) $s = & $lower $Value; if ($s -in @('machine', 'user')) { $s } else { '' } }

    # ---- Packaged technology ----
    $src = Get-Win32ToolkitProjectSource -ProjectPath $ProjectPath
    $packagedRaw   = & $lower (& $prop $src 'InstallerType')
    $packagedRow   = Get-Win32ToolkitInstallerFamily -Type $packagedRaw
    $packagedType  = [string]$packagedRow.PinValue
    $packagedScope = & $scopeOf (& $prop $src 'Scope')
    $packagedNote  = if ($packagedRaw -and -not $packagedType) {
        "The packaged installer type '{0}' cannot be pinned for a baseline download." -f (& $safe $packagedRaw)
    } elseif (-not $packagedRaw) {
        'The packaged installer type is unknown, so the baseline technology cannot be pinned.'
    } else { '' }

    # ---- Siblings from Documentation\IdentityDelta.json ----
    $deltaPath = Join-Path $ProjectPath 'Documentation\IdentityDelta.json'
    $useSiblings = $Mode -in @('Auto', 'Both')
    $mayProbe = $useSiblings -and -not $NoProbe
    $probed = $false
    if ($mayProbe -and -not (Test-Path -LiteralPath $deltaPath)) {
        $null = Write-Win32ToolkitIdentityDelta -ProjectPath $ProjectPath -Quiet
        $probed = $true
    }
    $readDelta = {
        if (-not (Test-Path -LiteralPath $deltaPath)) { return $null }
        try {
            return (Get-Content -LiteralPath $deltaPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        } catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Resolve-Win32ToolkitBaselineFamily: IdentityDelta.json is unreadable: $($_.Exception.Message)"
            return $null
        }
    }
    $delta = & $readDelta
    # A stored probe that could not run (offline, HTTP 429, ...) is retried once, so one failed lookup does not
    # disable the sibling check for good. The per-process probe memo bounds the requests.
    if ($mayProbe -and -not $probed -and [string](& $prop (& $prop $delta 'Probe') 'Status') -eq 'Unavailable') {
        $null = Write-Win32ToolkitIdentityDelta -ProjectPath $ProjectPath -Quiet
        $delta = & $readDelta
    }
    # Auto and Both must never look like a sibling check that found nothing when it did not run (V22, C-7).
    $probeNote = ''
    if ($useSiblings) {
        $probe = & $prop $delta 'Probe'
        $probeStatus = [string](& $prop $probe 'Status')
        if ($probeStatus -ne 'Ok') {
            $why = if ($null -eq $delta) { 'Documentation\IdentityDelta.json is missing or unreadable' }
                   elseif ($null -eq $probe) { 'no lookup result stored' }
                   elseif ([string](& $prop $probe 'Reason')) { [string](& $prop $probe 'Reason') }
                   elseif ($probeStatus) { $probeStatus }
                   else { 'no lookup result stored' }
            $probeNote = ('Other installer technologies could not be checked ({0}), so the packaged technology is used; ' +
                          'pass -BaselineInstallerType <type> to choose one.') -f (ConvertTo-Win32ToolkitSafeText -Text $why -MaxLength 64)
        }
    }
    $testable = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @(& $prop $delta 'Siblings')) {
        if ($null -eq $s) { continue }
        $eff = & $lower (& $prop $s 'EffectiveType')
        if (-not $eff) { $eff = & $lower (& $prop $s 'InstallerType') }
        $row = Get-Win32ToolkitInstallerFamily -Type $eff
        $fam = & $lower (& $prop $s 'Family')
        if (-not $fam) { $fam = [string]$row.Family }
        $pin = & $lower (& $prop $s 'PinValue')
        if (-not $pin) { $pin = [string]$row.PinValue }
        $registers = (& $prop $s 'Registers') -ne $false
        if ((& $prop $s 'Testable') -eq $true -and $registers -and $pin -and $fam -and $fam -ne $packagedRow.Family) {
            $prec = & $prop $s 'Precedence'
            $testable.Add([pscustomobject]@{
                    Family     = $fam
                    PinValue   = $pin
                    Scope      = & $scopeOf (& $prop $s 'Scope')
                    Precedence = if ($null -ne $prec -and "$prec" -match '^\d+$') { [int]$prec } else { [int]$row.Precedence }
                })
        } elseif ($registers -and (& $prop $s 'Testable') -ne $true) {
            $label = & $prop $s 'Label'
            if (-not $label) { $label = $row.Label }
            $line = '{0} cannot be used as an Update baseline' -f (ConvertTo-Win32ToolkitSafeText -Text ([string]$label) -MaxLength 128)
            if (-not $notes.Contains($line)) { $notes.Add($line) }
        }
    }
    # One entry per family: its highest-precedence testable type; families in precedence order.
    $byFamily = [ordered]@{}
    foreach ($t in @($testable | Sort-Object -Stable -Property Precedence)) {
        if (-not $byFamily.Contains($t.Family)) { $byFamily[$t.Family] = $t }
    }
    $families = @($byFamily.Values)
    $untestableNote = $notes -join '; '
    $joinNote = { param([string[]]$Parts) (@($Parts | Where-Object { $_ }) -join '; ') }

    switch ($Mode) {
        'Packaged' {
            return & $newLeg $packagedType $packagedScope 'Packaged' '' '' (& $joinNote @($packagedNote, $untestableNote))
        }
        'Both' {
            $legs = [System.Collections.Generic.List[object]]::new()
            $firstNote = @($packagedNote, $untestableNote)
            if ($families.Count -eq 0) {
                $firstNote += if ($probeNote) { $probeNote } else { 'no other installer technology that can be tested' }
            }
            $legs.Add((& $newLeg $packagedType $packagedScope 'Packaged' '' '' (& $joinNote $firstNote)))
            foreach ($f in $families) { $legs.Add((& $newLeg $f.PinValue $f.Scope 'Sibling')) }
            return $legs.ToArray()
        }
        'Auto' {
            # (1) A PriorInstalls Enforce entry of a vendor EXE technology (dormant until PR 3 writes entries).
            $cfg = $null
            try {
                $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
            } catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Resolve-Win32ToolkitBaselineFamily: AppConfig.json is unreadable: $($_.Exception.Message)"
            }
            foreach ($e in @(& $prop (& $prop $cfg 'PriorInstalls') 'Entries')) {
                $uType = & $lower (& $prop $e 'UninstallerType')
                if ([string](& $prop $e 'Mode') -eq 'Enforce' -and $uType -in @('nullsoft', 'inno')) {
                    return & $newLeg $uType '' 'Entry' '' '' $untestableNote
                }
            }
            # (2) The other technology winget ships, falling back (pinned, loudly) to the packaged one (L2).
            if ($families.Count -gt 0) {
                $f = $families[0]
                return & $newLeg $f.PinValue $f.Scope 'Sibling' $packagedType $packagedScope $untestableNote
            }
            # (3) The packaged technology (saying so when the other technologies could not be checked).
            return & $newLeg $packagedType $packagedScope 'Packaged' '' '' (& $joinNote @($packagedNote, $untestableNote, $probeNote))
        }
        default {
            $type = & $lower $Mode
            $scope = ''
            $match = @($testable | Where-Object { $_.PinValue -eq $type -and $_.Scope } | Sort-Object -Stable -Property Precedence | Select-Object -First 1)
            if ($match.Count -gt 0) { $scope = $match[0].Scope }
            elseif ($type -eq $packagedType) { $scope = $packagedScope }
            return & $newLeg $type $scope 'Explicit' '' '' $untestableNote
        }
    }
}
