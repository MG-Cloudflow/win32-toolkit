function ConvertTo-Win32ToolkitSiblingCaptureRecord {
    <#
    .SYNOPSIS
        Re-types one sibling-capture record to its frozen schema (spec 2.14.7), or returns $null.
    .DESCRIPTION
        Installer-identity PR 3b (L35). A capture record (Documentation\SiblingCapture\<CaptureId>.json) holds
        guest-derived facts about another installer technology of the same app. Its shape is frozen field by field:
        this function is the one place that knows it. The record writer builds the record through it and the
        record reader (Get-Win32ToolkitSiblingCaptureRecord) re-types every parsed file through it, so both always
        agree:
          - only the known fields, in the frozen order (unknown fields are dropped);
          - every string through ConvertTo-Win32ToolkitSafeText with its length limit (256 unless stated);
          - enumerations and patterns checked (a value outside them makes the record invalid);
          - booleans and integers type-checked (a string where a number belongs makes the record invalid);
          - arrays capped (Candidates 64, Files 200, Lingering 20, ...), never $null.
        Missing fields take their empty value ('' / 0 / $false / @()). Pure; returns $null (one Verbose line naming
        the field) for a record of the wrong shape.
    .PARAMETER InputObject
        The record (an ordered dictionary built by the writer, or the object ConvertFrom-Json returned).
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary] or $null.
    .EXAMPLE
        $typed = ConvertTo-Win32ToolkitSiblingCaptureRecord -InputObject ($json | ConvertFrom-Json -Depth 20)
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject
    )

    $s = { param([int]$Max = 256, [string]$Rx = '', [string[]]$Set = @()) @{ T = 's'; Max = $Max; Rx = $Rx; Set = $Set } }
    $i = @{ T = 'i' }
    $b = @{ T = 'b' }
    $as = { param([int]$Max = 256, [int]$Count = 200, [string]$Rx = '') @{ T = 'as'; Max = $Max; Count = $Count; Rx = $Rx } }
    $o = { param($P) @{ T = 'o'; P = $P } }
    $ao = { param($P, [int]$Count = 64) @{ T = 'ao'; P = $P; Count = $Count } }
    $sha = '^[0-9A-F]{64}$'
    $arch = @('x64', 'x86')
    $signer = & $o ([ordered]@{ Status = (& $s 64); Subject = (& $s 512) })

    $schema = & $o ([ordered]@{
            SchemaVersion = & $s 8 '' @('1.0')
            CaptureKey    = & $s 80 '^[a-z0-9_.+-]{1,80}$'
            Package       = & $o ([ordered]@{ WingetId = (& $s 128); Version = (& $s 64); Architecture = (& $s 8 '' $arch); InstallerType = (& $s 32); Family = (& $s 32) })
            Sibling       = & $o ([ordered]@{
                    InstallerType = (& $s 32); EffectiveType = (& $s 32); Version = (& $s 64)
                    Role = (& $s 16 '' @('Newest', 'Floor', 'Repeat', 'Extra', 'Coverage'))
                    ReleaseDate = (& $s 10 '^(\d{4}-\d{2}-\d{2})?$'); Scope = (& $s 8 '' @('machine', 'user', '')); Locale = (& $s 32)
                    Architecture = (& $s 8 '' $arch); InstallerFile = (& $s 260); InstallerSha256 = (& $s 64 $sha)
                    SilentArgs = (& $s 512); SilentArgsSource = (& $s 32)
                    Manifest = & $o ([ordered]@{
                            ProductCodes = (& $as 256 32)
                            Afe = (& $ao ([ordered]@{ DisplayName = (& $s); Publisher = (& $s); DisplayVersion = (& $s 64); ProductCode = (& $s); UpgradeCode = (& $s); InstallerType = (& $s 32) }) 32)
                            PackageName = (& $s); Publisher = (& $s); DefaultInstallLocation = (& $s 260)
                        })
                })
            Run           = & $o ([ordered]@{
                    Backend = (& $s 16 '' @('HyperV', 'Sandbox')); Mode = (& $s 16 '' @('Unattended', 'Assisted')); Account = (& $s 128); Is64 = $b
                    OsBuild = (& $s 64); StartedUtc = (& $s 20 '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)?$'); Seconds = $i; ToolkitVersion = (& $s 32)
                    GuestScriptSha256 = (& $s 64 $sha); DependenciesSkipped = $b
                })
            Install       = & $o ([ordered]@{ ExitCode = $i; TimedOut = $b; Completed = $b; RebootRequested = $b; Lingering = (& $as 64 20); Seconds = $i })
            Observation   = & $o ([ordered]@{
                    Candidates = (& $ao ([ordered]@{
                                Key = (& $s 255); View = (& $s 8 '' @('Native', 'Wow6432')); DisplayName = (& $s); DisplayVersion = (& $s 64); Publisher = (& $s)
                                WindowsInstaller = $b; SystemComponent = $b; InstallLocation = (& $s 260); DisplayIconLeaf = (& $s)
                                UninstallerPath = (& $s 260); UninstallerCanonical = $b; UninstallerLeaf = (& $s)
                                InstallDir = (& $s 260 '^(%ProgramFiles(\(x86\))?%\\.*)?$'); MainExe = (& $s)
                                Files = (& $as 256 200); InstallLocationFiles = (& $as 256 200); InnoAppPath = $b; UnsDat = $b
                                QuietUninstallArgs = (& $s 512)
                                Acl = (& $ao ([ordered]@{
                                            Path = (& $s 260); Owner = (& $s 184)
                                            Rules = (& $ao ([ordered]@{ Sid = (& $s 184); Rights = $i; Inheritance = $i; Propagation = $i; Type = (& $s 8 '' @('Allow', 'Deny')) }) 64)
                                        }) 16)
                                UnsafeText = $b
                            }) 64)
                    Services = (& $ao ([ordered]@{ Name = (& $s); DisplayName = (& $s); ImageLeaf = (& $s) }) 64)
                    Shortcuts = (& $as 260 64)
                    Tasks = (& $ao ([ordered]@{ Path = (& $s 260); ActionLeaf = (& $s) }) 64)
                    Appx = (& $as 256 64)
                    HkcuArp = (& $ao ([ordered]@{ Key = (& $s 255); DisplayName = (& $s) }) 64)
                    NewRoots = (& $as 260 64)
                    NoiseControl = (& $s 16 '' @('Verified', 'Unverified'))
                    PfroCount = $i
                    ProvisionalPrimary = (& $s 255)
                })
            Probe         = & $o ([ordered]@{
                    Result = (& $s 16 '' @('Clean', 'NeedsRestart', 'TimedOut', 'Survived', 'NotProbed')); ProbedKey = (& $s 255); ProbedView = (& $s 8 '' @('Native', 'Wow6432', ''))
                    ExitCode = $i; Seconds = $i; LingeringProcess = (& $as 64 20); PfroUnderRoot = $b; RootConfigRemoved = $b; VendorConfigRemoved = (& $as 256 64)
                })
            HostChecks    = & $o ([ordered]@{ UninstallerSigner = $signer; MainSigner = $signer; InstallerSigner = $signer; NsisMagic = $b; InnoMarkers = $b })
        })

    # Field access that works for a dictionary (writer) and a PSCustomObject (parsed JSON).
    $get = {
        param($Obj, [string]$Name)
        if ($null -eq $Obj) { return @{ Has = $false } }
        if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return @{ Has = $true; V = $Obj[$Name] } } else { return @{ Has = $false } } }
        if ($Obj.PSObject.Properties[$Name]) { return @{ Has = $true; V = $Obj.$Name } }
        return @{ Has = $false }
    }
    $isObject = { param($V) $V -is [System.Collections.IDictionary] -or $V -is [System.Management.Automation.PSCustomObject] }
    $bad = { param([string]$Where) throw [System.FormatException]::new($Where) }
    $conv = {
        param($V, $Spec, [string]$Where)
        switch ($Spec.T) {
            's' {
                if ($null -eq $V) { $V = '' }
                # PowerShell 7.4's ConvertFrom-Json turns an ISO date-time text into a DateTime (7.5+ readers pass -DateKind String).
                if ($V -is [datetime]) {
                    $V = if ($V.Kind -eq [System.DateTimeKind]::Utc) { $V.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) } else { $V.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
                }
                if ($V -isnot [string]) { & $bad "$Where is not a string" }
                $t = ConvertTo-Win32ToolkitSafeText -Text $V -MaxLength ([Math]::Max(4, $Spec.Max))
                if (@($Spec.Set).Count -gt 0 -and @($Spec.Set) -cnotcontains $t) { & $bad "$Where has an unknown value" }
                if ($Spec.Rx -and $t -cnotmatch $Spec.Rx) { & $bad "$Where does not match its pattern" }
                return $t
            }
            'i' {
                if ($null -eq $V) { return 0 }
                if ($V -isnot [int] -and $V -isnot [long]) { & $bad "$Where is not an integer" }
                if ($V -lt [int]::MinValue -or $V -gt [int]::MaxValue) { & $bad "$Where is out of range" }
                return [int]$V
            }
            'b' {
                if ($null -eq $V) { return $false }
                if ($V -isnot [bool]) { & $bad "$Where is not a boolean" }
                return [bool]$V
            }
            'as' {
                $out = [System.Collections.Generic.List[string]]::new()
                if ($null -ne $V) {
                    if ($V -is [string] -or (& $isObject $V)) { & $bad "$Where is not a list" }
                    foreach ($x in @($V)) {
                        if ($out.Count -ge $Spec.Count) { break }
                        $out.Add((& $conv $x @{ T = 's'; Max = $Spec.Max; Rx = $Spec.Rx; Set = @() } "$Where[]"))
                    }
                }
                return , ([string[]]$out.ToArray())
            }
            'o' {
                if ($null -ne $V -and -not (& $isObject $V)) { & $bad "$Where is not an object" }
                $r = [ordered]@{}
                foreach ($name in $Spec.P.Keys) {
                    $f = & $get $V $name
                    # No subexpression here: $( ) would unroll a one-element list into its element.
                    $fv = $null
                    if ($f.Has) { $fv = $f.V }
                    $r[$name] = & $conv $fv $Spec.P[$name] "$Where.$name"
                }
                return $r
            }
            'ao' {
                $out = [System.Collections.Generic.List[object]]::new()
                if ($null -ne $V) {
                    if ($V -is [string] -or (& $isObject $V)) { & $bad "$Where is not a list" }
                    foreach ($x in @($V)) {
                        if ($out.Count -ge $Spec.Count) { break }
                        if (-not (& $isObject $x)) { & $bad "$Where[] is not an object" }
                        $out.Add((& $conv $x @{ T = 'o'; P = $Spec.P } "$Where[]"))
                    }
                }
                return , ([object[]]$out.ToArray())
            }
        }
    }

    if ($null -eq $InputObject -or -not (& $isObject $InputObject)) { Write-Verbose 'Sibling-capture record: not an object.'; return $null }
    try { return (& $conv $InputObject $schema 'record') }
    catch [System.FormatException] {
        Write-Verbose ('Sibling-capture record ignored: ' + $_.Exception.Message)
        return $null
    }
}
