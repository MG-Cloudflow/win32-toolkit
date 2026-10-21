function Get-Win32ToolkitIdentityDelta {
    <#
    .SYNOPSIS
        Compares a package's installer identity with its anchored predecessor and with winget's sibling installers.
    .DESCRIPTION
        Installer-identity PR 1, spec 2.9. Two parameter sets:

        Data (pure comparison): -Source (Get-Win32ToolkitProjectSource), -Predecessor (the result of
        Get-Win32ToolkitPreviousProject, or one match object), -Probe (Get-Win32ToolkitSiblingInstaller, or a
        reused probe) and -TattooKey (this package's '<ScriptAuthor>\<Vendor>\<DisplayName>').

        Project (gathers the inputs, then Data): Source = Get-Win32ToolkitProjectSource; the predecessor is
        looked up in the project's template folder (winget id or Vendor + DisplayName, below App.Version,
        excluding the project itself; -TenantId, else AppConfig.Intune.TenantId); the probe is the sibling
        probe for the packaged type, unless -NoProbe. With -ReuseProbe, the probe stored in
        Documentation\IdentityDelta.json is reused (no request) when it has the same WingetId, Version and
        Architecture and either succeeded (Status Ok) or -NoProbe is set; a stored failure is retried when
        probing is allowed. No winget id (a manual project) -> Probe Status 'Skipped'.

        Findings (Code, Severity Warning|Info, Message, Data):
          ID-SIBLING-FAMILY        Warning  winget ships another registering, testable technology for this arch
          ID-SIBLING-UNTESTABLE    Info     ... one that cannot be packaged or tested (zip-wrapped, Store only)
          ID-NO-ANCHOR             Warning  winget chose the type, a testable sibling exists, nothing anchors it
          ID-PROBE-UNAVAILABLE     Warning  the sibling probe could not run
          ID-FAMILY                Warning  the anchored predecessor is another technology family
          ID-TATTOO                Warning  the detection (tattoo) key changed from the anchored predecessor's
          ID-SCOPE                 Warning  the manifest labels the installer user-scope
          ID-PREDECESSOR-AMBIGUOUS Warning  several winget ids in the template look like this product
          ID-VARIANT-SUBSTITUTE    Info     the family pin packaged another type of the requested family
        Messages are ASCII templates; every untrusted value passes ConvertTo-Win32ToolkitSafeText. The
        result holds no host path (Predecessor and HighestUnanchored drop Path).
    .PARAMETER Source
        The package's Source facts.
    .PARAMETER Predecessor
        The predecessor lookup result (Anchor, HighestUnanchored, Matches, AmbiguousIds) or one match.
    .PARAMETER Probe
        The sibling probe result.
    .PARAMETER TattooKey
        This package's '<ScriptAuthor>\<Vendor>\<DisplayName>' (for ID-TATTOO).
    .PARAMETER ProjectPath
        The project to evaluate (Project set). A relative, '~' or PSDrive path is resolved against the
        current PowerShell location.
    .PARAMETER NoProbe
        Make no probe request (a stored probe may still be reused with -ReuseProbe).
    .PARAMETER ReuseProbe
        Reuse the probe stored in Documentation\IdentityDelta.json when it matches.
    .PARAMETER TenantId
        Only publications to this tenant anchor (default: AppConfig.Intune.TenantId).
    .OUTPUTS
        [pscustomobject] SchemaVersion, GeneratedUtc, Source, Predecessor, HighestUnanchored, Probe, Siblings,
        SameFamilyOther, NotRegistering, Findings.
    .EXAMPLE
        (Get-Win32ToolkitIdentityDelta -ProjectPath $p -ReuseProbe -NoProbe).Findings
    #>
    [CmdletBinding(DefaultParameterSetName = 'Data')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Data')]
        [ValidateNotNull()]
        [object]$Source,

        [Parameter(ParameterSetName = 'Data')]
        [AllowNull()]
        [object]$Predecessor,

        [Parameter(ParameterSetName = 'Data')]
        [AllowNull()]
        [object]$Probe,

        [Parameter(ParameterSetName = 'Data')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$TattooKey = '',

        [Parameter(Mandatory, ParameterSetName = 'Project')]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(ParameterSetName = 'Project')]
        [switch]$NoProbe,

        [Parameter(ParameterSetName = 'Project')]
        [switch]$ReuseProbe,

        [Parameter(ParameterSetName = 'Project')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$TenantId = ''
    )

    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $null } }
    $same = { param($A, $B) [string]::Equals([string]$A, [string]$B, [System.StringComparison]::OrdinalIgnoreCase) }
    # ConvertFrom-Json turns a stored ISO timestamp into [datetime]: keep it ISO 8601 (UTC) when it comes back.
    $iso  = { param($Value) if ($Value -is [datetime]) { $Value.ToUniversalTime().ToString('o') } else { [string]$Value } }

    if ($PSCmdlet.ParameterSetName -eq 'Project') {
        # Absolute first: '.' or a bare folder name has no parent for Split-Path (the template folder), and
        # .NET resolves a relative path against the process directory, not the PowerShell location.
        try { $ProjectPath = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Get-Win32ToolkitIdentityDelta: could not resolve '$ProjectPath': $($_.Exception.Message)"
        }
        $src = Get-Win32ToolkitProjectSource -ProjectPath $ProjectPath
        $cfg = $null
        try {
            $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        } catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Get-Win32ToolkitIdentityDelta: AppConfig.json of '$ProjectPath' is unreadable: $($_.Exception.Message)"
        }
        $app     = & $prop $cfg 'App'
        $vendor  = [string](& $prop $app 'Vendor')
        $display = if (& $prop $app 'DisplayName') { [string]$app.DisplayName } else { [string](& $prop $app 'Name') }
        $author  = [string](& $prop $app 'ScriptAuthor')
        $version = if (& $prop $app 'Version') { [string]$app.Version } else { [string]$src.Version }
        $tenant  = if ($TenantId) { $TenantId } else { [string](& $prop (& $prop $cfg 'Intune') 'TenantId') }

        $pred = Get-Win32ToolkitPreviousProject -TemplateDirectory (Split-Path -Path $ProjectPath -Parent) -Version $version `
            -WingetId $src.WingetId -Vendor $vendor -DisplayName $display -ExcludePath $ProjectPath -TenantId $tenant

        $probeResult = $null
        $skipped = {
            param([string]$Reason)
            [pscustomobject]@{
                SchemaVersion = '1.0'; Status = 'Skipped'; Reason = $Reason; Url = ''; ProbedUtc = ''; FromMemo = $false
                WingetId = [string]$src.WingetId; Version = [string]$src.Version; Architecture = [string]$src.Architecture
                PackagedType = [string]$src.InstallerType; PackagedFamily = [string]$src.Family
                Tuples = @(); Siblings = @(); SameFamilyOther = @(); NotRegistering = @()
            }
        }
        if (-not $src.WingetId) {
            $probeResult = & $skipped 'NoWingetId'
        } else {
            if ($ReuseProbe) {
                $stored = $null
                $storedPath = Join-Path $ProjectPath 'Documentation\IdentityDelta.json'
                if (Test-Path -LiteralPath $storedPath) {
                    try {
                        $stored = Get-Content -LiteralPath $storedPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    } catch {
                        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                        Write-Verbose "Get-Win32ToolkitIdentityDelta: IdentityDelta.json is unreadable: $($_.Exception.Message)"
                    }
                }
                $sp = & $prop $stored 'Probe'
                if ($sp -and (& $same (& $prop $sp 'WingetId') $src.WingetId) -and (& $same (& $prop $sp 'Version') $src.Version) -and
                    (& $same (& $prop $sp 'Architecture') $src.Architecture) -and
                    ([string](& $prop $sp 'Status') -eq 'Ok' -or $NoProbe)) {
                    $probeResult = [pscustomobject]@{
                        SchemaVersion   = '1.0'
                        Status          = [string](& $prop $sp 'Status')
                        Reason          = [string](& $prop $sp 'Reason')
                        Url             = [string](& $prop $sp 'Url')
                        ProbedUtc       = & $iso (& $prop $sp 'ProbedUtc')
                        FromMemo        = $true
                        Reused          = $true
                        WingetId        = [string]$src.WingetId
                        Version         = [string]$src.Version
                        Architecture    = [string]$src.Architecture
                        PackagedType    = [string]$src.InstallerType
                        PackagedFamily  = [string]$src.Family
                        TupleCount      = [int](& $prop $sp 'TupleCount')
                        Siblings        = @(& $prop $stored 'Siblings')
                        SameFamilyOther = @(& $prop $stored 'SameFamilyOther')
                        NotRegistering  = @(& $prop $stored 'NotRegistering')
                    }
                    Write-Verbose 'Get-Win32ToolkitIdentityDelta: reusing the stored sibling probe.'
                }
            }
            if (-not $probeResult) {
                $probeResult = if ($NoProbe) { & $skipped 'NotRequested' }
                               else {
                                   Get-Win32ToolkitSiblingInstaller -WingetId $src.WingetId -Version $src.Version `
                                       -Architecture $src.Architecture -PackagedType $src.InstallerType
                               }
            }
        }

        return Get-Win32ToolkitIdentityDelta -Source $src -Predecessor $pred -Probe $probeResult `
            -TattooKey ('{0}\{1}\{2}' -f $author.Trim(), $vendor.Trim(), $display.Trim())
    }

    # ======================== Data set: pure comparison ========================
    $anchor = $null; $highest = $null; $ambiguous = @(); $firstMatch = $null
    if ($null -ne $Predecessor) {
        if ($Predecessor.PSObject.Properties['Anchor'] -or $Predecessor.PSObject.Properties['Matches']) {
            $anchor     = & $prop $Predecessor 'Anchor'
            $highest    = & $prop $Predecessor 'HighestUnanchored'
            $ambiguous  = @(& $prop $Predecessor 'AmbiguousIds' | Where-Object { $_ })
            $firstMatch = @(& $prop $Predecessor 'Matches') | Select-Object -First 1
        } elseif (& $prop $Predecessor 'Anchored') {
            $anchor = $Predecessor
        } else {
            $highest = $Predecessor
        }
    }
    $noPath = { param($m) if ($m) { $m | Select-Object -Property * -ExcludeProperty Path } else { $null } }

    $type     = ([string](& $prop $Source 'InstallerType')).ToLowerInvariant()
    $family   = [string](& $prop $Source 'Family')
    $typeRow  = Get-Win32ToolkitInstallerFamily -Type $type
    if (-not $family) { $family = $typeRow.Family }
    $pinnedBy = [string](& $prop $Source 'PinnedBy')
    $scope    = ([string](& $prop $Source 'Scope')).ToLowerInvariant()
    $req      = ([string](& $prop $Source 'RequestedInstallerType')).ToLowerInvariant()

    $sourceOut = $Source | Select-Object -Property * -ExcludeProperty Rebuilt
    $sourceOut | Add-Member -NotePropertyName Rebuilt -NotePropertyValue ([bool](& $prop $Source 'Rebuilt')) -Force

    $probeStatus = [string](& $prop $Probe 'Status')
    $probeOk     = $probeStatus -eq 'Ok'
    # @(if ...) - never '$x = if ... { @(...) }': an if statement unrolls its output (one entry -> a bare object,
    # none -> $null) and spec 2.9 stores these three as JSON arrays.
    $siblings    = @(if ($probeOk) { & $prop $Probe 'Siblings' | Where-Object { $_ } })
    $sameOther   = @(if ($probeOk) { & $prop $Probe 'SameFamilyOther' | Where-Object { $_ } })
    $notReg      = @(if ($probeOk) { & $prop $Probe 'NotRegistering' | Where-Object { $_ } })
    $tupleCount  = if (& $prop $Probe 'Tuples') { @($Probe.Tuples).Count } else { [int](& $prop $Probe 'TupleCount') }
    $probeOut = if ($null -eq $Probe) { $null } else {
        [pscustomobject]@{
            Status       = $probeStatus
            Reason       = [string](& $prop $Probe 'Reason')
            Url          = [string](& $prop $Probe 'Url')
            ProbedUtc    = & $iso (& $prop $Probe 'ProbedUtc')
            WingetId     = & $safe (& $prop $Probe 'WingetId') 128
            Version      = & $safe (& $prop $Probe 'Version') 128
            Architecture = & $safe (& $prop $Probe 'Architecture') 32
            PackagedType = & $safe (& $prop $Probe 'PackagedType') 32
            TupleCount   = $tupleCount
        }
    }
    $arch = if ($probeOut -and $probeOut.Architecture) { $probeOut.Architecture } else { & $safe (& $prop $Source 'Architecture') 32 }
    $id   = if ($probeOut -and $probeOut.WingetId) { $probeOut.WingetId } else { & $safe (& $prop $Source 'WingetId') 128 }
    $ver  = if ($probeOut -and $probeOut.Version) { $probeOut.Version } else { & $safe (& $prop $Source 'Version') 128 }

    $findings = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Code, [string]$Severity, [string]$Message, [hashtable]$Data)
        $findings.Add([pscustomobject]@{ Code = $Code; Severity = $Severity; Message = $Message; Data = [pscustomobject]$Data })
    }
    $distinct = {
        param([object[]]$Values)
        $seen = @{}
        foreach ($v in $Values) { $s = [string]$v; if ($s -and -not $seen.ContainsKey($s.ToLowerInvariant())) { $seen[$s.ToLowerInvariant()] = $true; $s } }
    }

    # ---- ID-SIBLING-FAMILY / ID-SIBLING-UNTESTABLE ----
    $testable   = @($siblings | Where-Object { $_.Testable -and $_.Registers })
    $untestable = @($siblings | Where-Object { $_.Registers -and -not $_.Testable })
    $siblingFamily = $false
    if ($probeOk -and $testable.Count -gt 0) {
        $siblingFamily = $true
        $labels = @(& $distinct @($testable | ForEach-Object { & $safe $_.Label 128 }))
        $pcs    = @(& $distinct @($testable | ForEach-Object { & $safe $_.ProductCode 128 }))
        $pins   = @(& $distinct @($testable | ForEach-Object { [string]$_.PinValue }))
        $pcText = if ($pcs.Count) { " (ProductCode/ARP key '{0}')" -f ($pcs -join "', '") } else { '' }
        $msg = ("winget also ships {0} for {1} of {2} {3}{4}. Devices that already have that install would get two registrations over one folder. " +
                'Keep one technology across your devices: to package that one instead, use -InstallerType {5}; ' +
                'to test the switch, run Test-Win32ToolkitProject -Scenario Update -BaselineInstallerType Both.') -f
               ($labels -join ' and '), $arch, $id, $ver, $pcText, ($pins -join ' or -InstallerType ')
        & $add 'ID-SIBLING-FAMILY' 'Warning' $msg @{
            Families     = @(& $distinct @($testable | ForEach-Object { [string]$_.Family }))
            Types        = @(& $distinct @($testable | ForEach-Object { [string]$_.EffectiveType }))
            PinValues    = $pins
            ProductCodes = $pcs
        }
    }
    if ($probeOk -and $untestable.Count -gt 0) {
        $labels  = @(& $distinct @($untestable | ForEach-Object { & $safe $_.Label 128 }))
        $reasons = @(& $distinct @($untestable | ForEach-Object { if ($_.ZipWrapped) { 'zip-wrapped' } else { 'Microsoft Store only' } }))
        $msg = 'winget also ships {0} for {1} ({2}): win32-toolkit cannot package it or use it as an Update baseline yet.' -f
               ($labels -join ' and '), $arch, ($reasons -join ', ')
        & $add 'ID-SIBLING-UNTESTABLE' 'Info' $msg @{
            Types  = @(& $distinct @($untestable | ForEach-Object { [string]$_.EffectiveType }))
            Labels = $labels
        }
    }

    # ---- ID-NO-ANCHOR (multi-family apps only, L4/Dv2; and only without an anchored predecessor) ----
    if ($pinnedBy -eq 'winget-default' -and $siblingFamily -and -not $anchor) {
        $pin = if ($typeRow.PinValue) { $typeRow.PinValue } else { $type }
        # The label already names the type ('wix (MSI)'), so it is printed alone, as ID-SIBLING-FAMILY does (S9-F3).
        $chosenLabel = if ($typeRow.Label) { $typeRow.Label } else { $type }
        $msg = ('winget chose {0} and no earlier version of this app in this template was published or pinned, so nothing keeps the ' +
                'installer technology stable between versions. Pin it with -InstallerType {1} (or choose it in the menu).') -f
               (& $safe $chosenLabel 128), (& $safe $pin 32)
        & $add 'ID-NO-ANCHOR' 'Warning' $msg @{ InstallerType = $type; PinValue = $pin }
    }

    # ---- ID-PROBE-UNAVAILABLE ----
    if ($probeStatus -eq 'Unavailable') {
        $reason = [string](& $prop $Probe 'Reason')
        $why = switch ($reason) {
            'NotFound'  { 'NotFound: winget-pkgs has no installer manifest for it' }
            'Network'   { 'Network: the request failed' }
            'Timeout'   { 'Timeout: no answer in time' }
            'TooLarge'  { 'TooLarge: the manifest is too large' }
            'Parse'     { 'Parse: the manifest lists no installer' }
            'InvalidId' { 'InvalidId: the id or version cannot be looked up' }
            default     { & $safe $reason 64 }
        }
        $msg = ('Could not check which installer technologies winget lists for {0} {1} ({2}). If this app ships both an EXE and an MSI, ' +
                'pin one with -InstallerType so later versions keep it.') -f $id, $ver, $why
        & $add 'ID-PROBE-UNAVAILABLE' 'Warning' $msg @{ Reason = & $safe $reason 64 }
    }

    # ---- ID-FAMILY / ID-TATTOO (anchored predecessor only) ----
    if ($anchor) {
        $predName   = & $safe (& $prop $anchor 'Name')
        $predType   = ([string](& $prop $anchor 'InstallerType')).ToLowerInvariant()
        $predRow    = Get-Win32ToolkitInstallerFamily -Type $predType
        $predFamily = [string](& $prop $anchor 'Family')
        if (-not $predFamily) { $predFamily = $predRow.Family }
        $how = if ([string](& $prop $anchor 'AnchorReason') -like 'pinned*') { 'pinned' } else { 'published' }
        if ($predFamily -and $family -and $predFamily -ne 'other' -and $family -ne 'other' -and $predFamily -ne $family) {
            $remedy = if ($predRow.PinValue) { 'Rebuild with -InstallerType {0} to keep it.' -f $predRow.PinValue }
                      else { 'Rebuild from a package that ships {0}.' -f (& $safe $predFamily 32) }
            $msg = ('The installer technology changed: {0} ({1}) is {2} ({3}), this package is {4} ({5}). Devices with the earlier version ' +
                    'would get two registrations. {6}') -f $predName, $how, (& $safe $predType 32), (& $safe $predFamily 32),
                   (& $safe $type 32), (& $safe $family 32), $remedy
            & $add 'ID-FAMILY' 'Warning' $msg @{
                Predecessor = $predName; PredecessorType = $predType; PredecessorFamily = $predFamily
                InstallerType = $type; Family = $family; PinValue = [string]$predRow.PinValue
            }
        }
        $oldKey = & $safe (& $prop $anchor 'TattooKey')
        $newKey = & $safe $TattooKey
        $complete = '^[^\\]+\\[^\\]+\\.+$'
        if ($oldKey -match $complete -and $newKey -match $complete -and -not (& $same $oldKey $newKey)) {
            $msg = ('The detection key changed from HKLM\SOFTWARE\{0} to HKLM\SOFTWARE\{1}. Devices that have {2} keep it detected under ' +
                    "the old key; the update app's requirement does not see them.") -f $oldKey, $newKey, $predName
            & $add 'ID-TATTOO' 'Warning' $msg @{ Old = $oldKey; New = $newKey; Predecessor = $predName }
        }
    }

    # ---- ID-SCOPE ----
    if ($scope -eq 'user') {
        $msg = 'The winget manifest labels this installer user-scope. Intune installs it as SYSTEM: check the install capture ' +
               '(Documentation\InstallationChanges_*.json). A per-user install registers under SYSTEM''s profile and users never see it.'
        & $add 'ID-SCOPE' 'Warning' $msg @{ Scope = $scope }
    }

    # ---- ID-PREDECESSOR-AMBIGUOUS ----
    if ($ambiguous.Count -ge 2) {
        $ids = (@($ambiguous | ForEach-Object { & $safe $_ 128 }) -join ', ')
        $shown = if ($anchor) { $anchor } elseif ($highest) { $highest } else { $firstMatch }
        $msg = if ($shown) {
            'Several winget ids in this template look like the same product ({0}). The predecessor was matched by {1}; check that {2} is the right one.' -f
                $ids, (& $safe (& $prop $shown 'MatchedBy') 32), (& $safe (& $prop $shown 'Name'))
        } else {
            'Several winget ids in this template look like the same product ({0}); check that this package uses the id your devices already have.' -f $ids
        }
        & $add 'ID-PREDECESSOR-AMBIGUOUS' 'Warning' $msg @{ Ids = @($ambiguous | ForEach-Object { & $safe $_ 128 }); MatchedBy = [string](& $prop $shown 'MatchedBy') }
    }

    # ---- ID-VARIANT-SUBSTITUTE ----
    if ($req -and $type -and $req -ne $type) {
        $msg = 'Requested {0}; this version offers {1} in the same technology family - packaged {1}.' -f (& $safe $req 32), (& $safe $type 32)
        & $add 'ID-VARIANT-SUBSTITUTE' 'Info' $msg @{ Requested = $req; InstallerType = $type }
    }

    return [pscustomobject]@{
        SchemaVersion     = '1.0'
        GeneratedUtc      = [datetime]::UtcNow.ToString('o')
        Source            = $sourceOut
        Predecessor       = & $noPath $anchor
        HighestUnanchored = & $noPath $highest
        Probe             = $probeOut
        Siblings          = $siblings
        SameFamilyOther   = $sameOther
        NotRegistering    = $notReg
        Findings          = @($findings)
    }
}
