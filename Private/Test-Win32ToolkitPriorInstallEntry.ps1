function Test-Win32ToolkitPriorInstallEntry {
    <#
    .SYNOPSIS
        Validates a project's prior-install rules (AppConfig.PriorInstalls) against the spec 2.1 rules.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.1, L28, L34, D21, SV5, SV8, SV11, SV15). The host half of the rules the
        device re-checks in the remove-prior blocks; every writer and the Export gate call it. Pure: no file I/O -
        the decisions (waivers, approvals) and the hash-verified capture records are passed in as objects.

        Per entry: Id ^[a-z0-9-]{1,40}$ unique; Kind 'ArpKey'; Mode Block|Enforce|Report (case-sensitive, no
        default); Key 1-255 characters without \ / * ? [ ] or control/format characters, not '.'/'..', never one of
        the package's own uninstall keys (OwnIdentity.ProductCode, OwnIdentity.ArpKeys, Uninstall.ProductCodes,
        Uninstall.PrimaryKeys - never the install tattoo, which lives outside the Uninstall namespace); capture
        lineage + Enforce also ^[A-Za-z0-9 ._+(){}-]{1,255}$; (Key, View) unique; View Native|Wow6432; Publisher
        non-empty; DisplayName or a DisplayNameTemplate with exactly one {v}; VersionMin / VersionMax parseable by
        the device parser (VersionMax required; an EXE package's own family: VersionMax < App.Version); Enforce:
        UninstallerType nullsoft|inno, UninstallerFileName and MainExe plain .exe leaves (different), InstallDir
        under %ProgramFiles% / %ProgramFiles(x86)% (1-4 plain segments), 1-8 ProcessNames; Source Operator|
        UpdateTest|SiblingCapture; CaptureId (SiblingCapture) 16 hex; Track Current|Frozen; AddedOn yyyy-MM-dd.
        Set: at most 32 entries; App.ScriptAuthor a valid registry key name; App.Version parseable; a known own
        identity for every entry (OwnIdentity with a key or code, or Uninstall.PrimaryKeys / ProductCodes) and
        OwnIdentity itself for Enforce, with at least one own uninstall key or product code (L28) - the device
        refuses an Enforce entry without one (69105), so an UpgradeCode alone is not enough there.

        The host is never more lenient than the device, which re-checks every field ('the host rules again' in the
        remove-prior blocks): every pattern is anchored with \z as on the device, so a value with a trailing line
        break (which '$' would accept) is refused here instead of making every device refuse 69105. Values are read with
        the device's truthiness: a falsy OwnIdentity ('', 0, false in a hand-edited AppConfig) is no OwnIdentity, and a
        falsy process name (0, false, '') is no name - the host refuses it rather than casting it to '0' / 'False'.

        -Decisions bound: DisplayName and VersionMin are required unless a DISPLAYNAME / VERSIONMIN waiver names
        the entry (never for capture lineage). -Records bound: a capture-lineage entry's CaptureId must name a
        verified record whose candidate (Key, View) observed exactly VersionMin (padded); such problems start with
        'capture record:'. -PreCapture (carry-forward, same-version restore, before the install capture): no own-
        identity precondition, and the own keys are the packaged MSI's Source.ProductCode only.

        Lineage per entry: Capture (Source SiblingCapture, a CaptureId, or an Approval record for its Id),
        UpdateTest (Source UpdateTest) or Operator.
    .PARAMETER Config
        The project's AppConfig object.
    .PARAMETER Decisions
        Records from Get-Win32ToolkitPriorInstallDecision.
    .PARAMETER Records
        Records from Get-Win32ToolkitSiblingCaptureRecord.
    .PARAMETER PreCapture
        Validate before the install capture wrote OwnIdentity (L34).
    .OUTPUTS
        [pscustomobject] Valid, Problems[] (all, entry problems prefixed '<id>: '), SetProblems[] (the set rules), Lineage
        (hashtable Id -> lineage), PerEntry[] {Id, Valid, Problems[], Lineage}.
    .EXAMPLE
        $v = Test-Win32ToolkitPriorInstallEntry -Config $cfg -Decisions $decisions -Records $records
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Config,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Decisions,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Records,

        [switch]$PreCapture
    )

    $useDecisions = $PSBoundParameters.ContainsKey('Decisions')
    $useRecords = $PSBoundParameters.ContainsKey('Records')
    $decisionList = @($Decisions | Where-Object { $null -ne $_ })
    $recordList = @($Records | Where-Object { $null -ne $_ })

    $value = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
        if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
        return $null
    }
    $str = { param($Object, [string]$Name) $v = & $value $Object $Name; if ($null -eq $v) { '' } else { [string]$v } }
    $ccf = '[\p{Cc}\p{Cf}]'
    # Anchored with \z, as the device's text B: '$' also matches before a final line break.
    $idRule = '^[a-z0-9-]{1,40}\z'
    $leafRule = '^[A-Za-z0-9 ._+-]{1,64}\.exe\z'
    $procRule = '^[A-Za-z0-9 ._+-]{1,64}\z'
    $dirRule = '^%ProgramFiles(\(x86\))?%(\\[A-Za-z0-9 ._+()-]{1,64}){1,4}\z'
    $captureIdRule = '^[a-f0-9]{16}\z'
    $guid = '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$'

    $setProblems = [System.Collections.Generic.List[string]]::new()
    $perEntry = [System.Collections.Generic.List[object]]::new()
    $lineage = @{}

    $pi = & $value $Config 'PriorInstalls'
    $entries = @()
    if ($null -ne $pi) { $entries = @(@(& $value $pi 'Entries') | Where-Object { $null -ne $_ }) }

    $app = & $value $Config 'App'
    $installer = & $value $Config 'Installer'
    $own = & $value $Config 'OwnIdentity'
    $uninstall = & $value $Config 'Uninstall'
    $pkgVersion = ConvertTo-Win32ToolkitPriorVersion -Text (& $str $app 'Version')
    $pkgType = & $str $installer 'Type'

    # The package's own uninstall keys (never the tattoo).
    $ownKeys = [System.Collections.Generic.List[string]]::new()
    if ($PreCapture) {
        $src = & $value $Config 'Source'
        if ((& $str $src 'ProductCode') -match $guid) { $ownKeys.Add((& $str $src 'ProductCode')) }
    }
    else {
        if (& $str $own 'ProductCode') { $ownKeys.Add((& $str $own 'ProductCode')) }
        foreach ($k in @(& $value $own 'ArpKeys')) { if ($null -ne $k -and (& $str $k 'Key')) { $ownKeys.Add((& $str $k 'Key')) } }
        foreach ($k in @(& $value $uninstall 'ProductCodes')) { if ($k) { $ownKeys.Add([string]$k) } }
        foreach ($k in @(& $value $uninstall 'PrimaryKeys')) { if ($null -ne $k -and (& $str $k 'Name')) { $ownKeys.Add((& $str $k 'Name')) } }
    }
    # The device's truthiness (text B: -not $w32tOwnId): a falsy OwnIdentity ('', 0, false) is no OwnIdentity there.
    $hasOwnIdentityObject = [bool]$own
    $ownKnown = $ownKeys.Count -gt 0 -or ($hasOwnIdentityObject -and (& $str $own 'UpgradeCode'))

    if ($entries.Count -gt 0) {
        if ($entries.Count -gt 32) { $setProblems.Add("there are $($entries.Count) entries; at most 32 are allowed") }
        $author = & $str $app 'ScriptAuthor'
        if ($author -notmatch '\S' -or $author -match '[\\/*?\[\]]' -or $author -match $ccf) { $setProblems.Add('App.ScriptAuthor cannot be used as a registry key name (it is the root of the device markers)') }
        if (-not $pkgVersion) { $setProblems.Add('App.Version cannot be read as a version') }
        if (-not $PreCapture -and -not $ownKnown) { $setProblems.Add("this package's own uninstall identity is unknown (no OwnIdentity, no Uninstall keys): run the install capture first") }
    }

    $approvalTargets = @($decisionList | Where-Object { [string](& $value $_ 'Kind') -eq 'Approval' } | ForEach-Object { [string](& $value $_ 'Target') })
    $waived = { param([string]$Code, [string]$Id) @($decisionList | Where-Object { [string](& $value $_ 'Kind') -eq 'Waiver' -and [string](& $value $_ 'Code') -ceq $Code -and [string](& $value $_ 'Target') -ceq $Id }).Count -gt 0 }

    $ids = @{}
    $keyViews = @{}
    $index = 0
    foreach ($e in $entries) {
        $index++
        $p = [System.Collections.Generic.List[string]]::new()
        $id = & $str $e 'Id'
        $mode = & $str $e 'Mode'
        $source = & $str $e 'Source'
        $captureId = & $str $e 'CaptureId'
        $lin = if ($source -ceq 'SiblingCapture' -or $captureId -or ($id -and $approvalTargets -ccontains $id)) { 'Capture' } elseif ($source -ceq 'UpdateTest') { 'UpdateTest' } else { 'Operator' }
        $label = if ($id -cmatch $idRule) { $id } else { "entry $index" }
        if ($id -cmatch $idRule) { $lineage[$id] = $lin }

        if ($e -isnot [System.Management.Automation.PSCustomObject] -and $e -isnot [System.Collections.IDictionary]) {
            $p.Add('the entry is not an object')
            $perEntry.Add([pscustomobject]@{ Id = $label; Valid = $false; Problems = [string[]]$p.ToArray(); Lineage = $lin })
            continue
        }
        if ($id -cnotmatch $idRule) { $p.Add('Id must match ^[a-z0-9-]{1,40}$') }
        elseif ($ids.ContainsKey($id)) { $p.Add('Id is used by another entry') }
        else { $ids[$id] = $true }
        if ((& $str $e 'Kind') -cne 'ArpKey') { $p.Add("Kind must be 'ArpKey'") }
        if (@('Block', 'Enforce', 'Report') -cnotcontains $mode) { $p.Add('Mode must be Block, Enforce or Report (no default)') }

        $key = & $str $e 'Key'
        $view = & $str $e 'View'
        if ($key -notmatch '^[^\\/*?\[\]\p{Cc}\p{Cf}]{1,255}\z' -or $key -eq '.' -or $key -eq '..') { $p.Add('Key must be 1-255 characters without \ / * ? [ ] or control characters (an exact uninstall key name)') }
        elseif (@($ownKeys | Where-Object { [string]::Equals($_, $key, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { $p.Add("Key is this package's own uninstall key") }
        elseif ($lin -eq 'Capture' -and $mode -ceq 'Enforce' -and $key -cnotmatch '^[A-Za-z0-9 ._+(){}-]{1,255}\z') { $p.Add('Key of a captured Enforce entry must match ^[A-Za-z0-9 ._+(){}-]{1,255}$') }
        if (@('Native', 'Wow6432') -cnotcontains $view) { $p.Add('View must be Native or Wow6432') }
        elseif ($key) {
            $kv = $view + '|' + $key.ToUpperInvariant()
            if ($keyViews.ContainsKey($kv)) { $p.Add("another entry names the same uninstall key ($view)") } else { $keyViews[$kv] = $true }
        }

        $publisher = & $str $e 'Publisher'
        if ($publisher -notmatch '\S' -or $publisher -match $ccf -or $publisher.Length -gt 256) { $p.Add('Publisher must be 1-256 characters without control characters') }
        $name = & $str $e 'DisplayName'
        $template = & $str $e 'DisplayNameTemplate'
        if ($name -match $ccf -or $name.Length -gt 256) { $p.Add('DisplayName must be at most 256 characters without control characters') }
        if ($template) {
            if ($name) { $p.Add('DisplayName must be empty when DisplayNameTemplate is set') }
            if ($template -match $ccf -or $template.Length -gt 256 -or ($template.Length - $template.Replace('{v}', '').Length) -ne 3) { $p.Add('DisplayNameTemplate must hold exactly one {v} (at most 256 characters, no control characters)') }
        }
        elseif (-not $name -and $useDecisions -and -not ($lin -ne 'Capture' -and (& $waived 'DISPLAYNAME' $id))) {
            $p.Add('DisplayName is required (or a DisplayNameTemplate; an operator entry may carry a DISPLAYNAME waiver)')
        }

        $minText = & $str $e 'VersionMin'
        $maxText = & $str $e 'VersionMax'
        $min = ConvertTo-Win32ToolkitPriorVersion -Text $minText
        $max = ConvertTo-Win32ToolkitPriorVersion -Text $maxText
        if ($minText -and -not $min) { $p.Add('VersionMin cannot be read as a version (at most 4 parts of at most 9 digits)') }
        elseif (-not $minText -and $useDecisions -and -not ($lin -ne 'Capture' -and (& $waived 'VERSIONMIN' $id))) { $p.Add('VersionMin is required (an operator entry may carry a VERSIONMIN waiver)') }
        if (-not $max) { $p.Add('VersionMax is required and must be a version (at most 4 parts of at most 9 digits)') }
        elseif ($pkgType -eq 'exe' -and $pkgVersion -and $max -ge $pkgVersion) { $p.Add("VersionMax must be lower than this package's version (a prior of the package's own technology family)") }
        if ($min -and $max -and $min -gt $max) { $p.Add('VersionMin is higher than VersionMax') }

        $uType = & $str $e 'UninstallerType'
        $uLeaf = & $str $e 'UninstallerFileName'
        $signer = & $str $e 'UninstallerSigner'
        $dir = & $str $e 'InstallDir'
        $main = & $str $e 'MainExe'
        # The device keeps only truthy names (text B: Where-Object { $_ }), so 0, false and '' are not names there; the
        # host counts them apart and refuses them (never a '0' / 'False' name the device would not see).
        $procItems = @(@(& $value $e 'ProcessNames') | Where-Object { $null -ne $_ })
        $procs = @($procItems | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $procsFalsy = $procItems.Count - $procs.Count
        if ($uType -and @('nullsoft', 'inno') -cnotcontains $uType) { $p.Add('UninstallerType must be nullsoft or inno') }
        if ($uLeaf -and $uLeaf -cnotmatch $leafRule) { $p.Add('UninstallerFileName must be a plain .exe file name') }
        if ($signer -and ($signer.Length -gt 512 -or $signer -match $ccf)) { $p.Add('UninstallerSigner must be at most 512 characters without control characters') }
        $dirBad = $dir -and ($dir -cnotmatch $dirRule -or $dir -match '\\[. ]*(\\|\z)|[. ](\\|\z)|\\ ')
        if ($dirBad) { $p.Add('InstallDir must be %ProgramFiles%\... or %ProgramFiles(x86)%\... with 1-4 plain folder names') }
        if ($main -and $main -cnotmatch $leafRule) { $p.Add('MainExe must be a plain .exe file name') }
        if ($main -and $uLeaf -and [string]::Equals($main, $uLeaf, [StringComparison]::OrdinalIgnoreCase)) { $p.Add('MainExe must differ from UninstallerFileName') }
        if ($procs.Count -gt 8) { $p.Add('at most 8 ProcessNames') }
        if ($procsFalsy -gt 0 -or @($procs | Where-Object { $_ -cnotmatch $procRule -or $_ -match '\.exe\z' }).Count -gt 0) { $p.Add('ProcessNames must be plain process names without .exe') }
        if ($mode -ceq 'Enforce') {
            if (-not $uType) { $p.Add('an Enforce entry needs UninstallerType (nullsoft or inno)') }
            if (-not $uLeaf) { $p.Add('an Enforce entry needs UninstallerFileName') }
            if (-not $dir) { $p.Add('an Enforce entry needs InstallDir') }
            if (-not $main) { $p.Add('an Enforce entry needs MainExe') }
            if ($procs.Count -eq 0) { $p.Add('an Enforce entry needs at least one ProcessName') }
            # The device's rule (text B): OwnIdentity AND at least one own uninstall key or product code, else 69105.
            if (-not $PreCapture -and -not $hasOwnIdentityObject) { $p.Add("an Enforce entry needs this package's OwnIdentity (run the install capture)") }
            elseif (-not $PreCapture -and $ownKeys.Count -eq 0) { $p.Add('an Enforce entry needs at least one own uninstall key or product code (OwnIdentity.ArpKeys, OwnIdentity.ProductCode, Uninstall); an UpgradeCode alone is refused on the device (69105): run the install capture again') }
        }

        if (@('Operator', 'UpdateTest', 'SiblingCapture') -cnotcontains $source) { $p.Add('Source must be Operator, UpdateTest or SiblingCapture') }
        if ($source -ceq 'SiblingCapture' -and $captureId -cnotmatch $captureIdRule) { $p.Add('CaptureId must be 16 lower-case hex characters for a SiblingCapture entry') }
        elseif ($captureId -and $captureId -cnotmatch $captureIdRule) { $p.Add('CaptureId must be 16 lower-case hex characters') }
        $track = & $str $e 'Track'
        if ($track -and @('Current', 'Frozen') -cnotcontains $track) { $p.Add('Track must be Current or Frozen') }
        if ((& $str $e 'AddedOn') -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}\z') { $p.Add('AddedOn must be yyyy-MM-dd') }

        if ($useRecords -and $lin -eq 'Capture') {
            $rec = @($recordList | Where-Object { [string](& $value $_ 'CaptureId') -ceq $captureId }) | Select-Object -First 1
            if (-not $rec) { $p.Add("capture record: no hash-verified capture record '$captureId' (re-capture)") }
            else {
                $obs = & $value $rec 'Observation'
                $cand = @(@(& $value $obs 'Candidates') | Where-Object { $null -ne $_ -and [string]::Equals((& $str $_ 'Key'), $key, [StringComparison]::OrdinalIgnoreCase) -and (& $str $_ 'View') -ceq $view }) | Select-Object -First 1
                $floor = if ($cand) { ConvertTo-Win32ToolkitPriorVersion -Text (& $str $cand 'DisplayVersion') } else { $null }
                if (-not $cand) { $p.Add("capture record: the record '$captureId' did not observe this uninstall key") }
                elseif (-not $floor -or -not $min -or $floor -ne $min) { $p.Add("capture record: VersionMin must be exactly the version the floor capture observed ($(ConvertTo-Win32ToolkitSafeText -Text (& $str $cand 'DisplayVersion') -MaxLength 64))") }
            }
        }

        $perEntry.Add([pscustomobject]@{ Id = $label; Valid = ($p.Count -eq 0); Problems = [string[]]$p.ToArray(); Lineage = $lin })
    }

    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($sp in $setProblems) { $all.Add($sp) }
    foreach ($pe in $perEntry) { foreach ($x in $pe.Problems) { $all.Add("$($pe.Id): $x") } }
    return [pscustomobject]@{
        Valid       = ($all.Count -eq 0)
        Problems    = [string[]]$all.ToArray()
        SetProblems = [string[]]$setProblems.ToArray()
        Lineage     = $lineage
        PerEntry    = [object[]]$perEntry.ToArray()
    }
}
