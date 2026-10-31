function ConvertFrom-Win32ToolkitSiblingCaptureOutput {
    <#
    .SYNOPSIS
        Reads one sibling capture's quarantine and builds its canonical capture record (or says why there is none).
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.7; C-14, SV1, SV4, SV5, SV11, L31, L35). The quarantine
        (<run>\quarantine\Out) holds what the guest wrote after it ran an installer nobody vetted, so every file is
        untrusted data:
          - exact names only (Sibling(Pre|Install|Capture|Probe|Done)_<key>.json, SiblingCopy_<key>_(uninstaller|main).exe);
            each JSON at most 8 MB, parsed in a try, unknown fields dropped;
          - every string through ConvertTo-Win32ToolkitSafeText; a candidate whose Key, DisplayName, Publisher,
            DisplayVersion, InstallLocation or uninstaller path held a control, format or line/paragraph separator
            character, a CMTrace delimiter or a comment-close sequence, is kept but flagged UnsafeText (its proposal is Block-only);
          - an uninstaller path that is not canonical becomes '' (UninstallerCanonical false); an InstallDir that is not
            '%ProgramFiles[(x86)]%\<1-4 plain segments>' becomes ''; a NewRoots entry that is not canonical is dropped;
          - the copied uninstaller and main program are read on the host (Get-AuthenticodeSignature: status and subject;
            Get-Win32ToolkitInstallerTechnology: the NSIS / Inno Setup markers), never executed, then deleted (L31).
        The record is built in the frozen shape and passed through ConvertTo-Win32ToolkitSiblingCaptureRecord (the one
        place that knows it). A capture whose install did not complete, or whose files are missing or unreadable, gives
        no record: Failure names why.
    .PARAMETER RunFolder
        The capture's work folder (Sandbox\SiblingRuns\<CaptureKey>-<stamp>).
    .PARAMETER OutputFolder
        Where the guest output is (default <RunFolder>\quarantine\Out, the Hyper-V copy-back; a Windows Sandbox capture
        writes straight into <RunFolder>\quarantine). An assisted capture (Context.Run.Mode Assisted) has no install file:
        the operator installed the sibling, so the install counts as completed - but one that left no uninstall entry of
        the app (no provisional primary, no per-user entry) gives no record: the operator installed nothing.
    .PARAMETER Context
        The host facts: @{ CaptureKey; Package = @{...}; Sibling = @{...}; Run = @{ Backend; Mode; ToolkitVersion;
        GuestScriptSha256; DependenciesSkipped; Seconds }; InstallerPath }.
    .OUTPUTS
        [pscustomobject] Record (an ordered dictionary or $null), Failure ('' or the reason), NoiseDetail (the guest's noise-control
        states, '<service> <state>/<start mode>; ...', printable text for the operator; never part of the record), NoiseCause
        ('' when Verified, else why: the controls could not be held before the install, Windows Update installed something,
        its log could not be read, or a service or task was not held still; '; '-joined).
    .EXAMPLE
        $r = ConvertFrom-Win32ToolkitSiblingCaptureOutput -RunFolder $run -Context $facts
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RunFolder,

        [Parameter(Mandatory)]
        [hashtable]$Context,

        [AllowEmptyString()]
        [string]$OutputFolder = ''
    )

    $key = [string]$Context.CaptureKey
    $out = if ($OutputFolder) { $OutputFolder } else { Join-Path $RunFolder 'quarantine\Out' }
    $fail = { param([string]$Why) [pscustomobject]@{ Record = $null; Failure = $Why } }
    $prop = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
        if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
        return $null
    }
    $str = { param($Object, [string]$Name) $v = & $prop $Object $Name; if ($null -eq $v) { '' } elseif ($v -is [datetime]) { $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) } else { [string]$v } }
    $int = { param($Object, [string]$Name) $v = & $prop $Object $Name; $n = 0L; if ($null -ne $v -and [long]::TryParse([string]$v, [ref]$n) -and $n -ge [int]::MinValue -and $n -le [int]::MaxValue) { [int]$n } else { 0 } }
    $bool = { param($Object, [string]$Name) (& $prop $Object $Name) -eq $true }
    $list = { param($Object, [string]$Name) @(@(& $prop $Object $Name) | Where-Object { $null -ne $_ }) }
    $unsafe = { param([string]$Text) $Text -match '[\p{Cc}\p{Cf}\u2028\u2029]' -or $Text.Contains('#>') -or $Text.Contains('<![LOG[') -or $Text.Contains(']LOG]!>') }
    $canonical = { param([string]$P) $P -match '^[A-Za-z]:\\[^/:*?"<>|~\p{Cc}\p{Cf}\u2028\u2029]+$' -and $P -notmatch '\\[. ]*(\\|$)|[. ](\\|$)' -and $P.Length -le 260 }
    $dateKind = (Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')
    $readJson = {
        param([string]$Name, [switch]$Optional)
        $p = Join-Path $out $Name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { if ($Optional) { return $null }; throw "$Name is missing" }
        if ((Get-Item -LiteralPath $p).Length -gt 8MB) { throw "$Name is larger than 8 MB" }
        $text = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
        if ($dateKind) { return ($text | ConvertFrom-Json -Depth 20 -DateKind String) }
        return ($text | ConvertFrom-Json -Depth 20)
    }
    $signer = {
        param([string]$Path)
        $r = [ordered]@{ Status = ''; Subject = '' }
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $r }
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            $r.Status = [string]$sig.Status
            if ($sig.SignerCertificate) { $r.Subject = ConvertTo-Win32ToolkitSafeText -Text ([string]$sig.SignerCertificate.Subject) -MaxLength 512 }
        }
        catch { $r.Status = 'Unreadable' }
        return $r
    }

    try {
        if ($key -cnotmatch '^[a-z0-9_.+-]{1,80}$') { return (& $fail 'the capture key is not valid') }
        if (-not (Test-Path -LiteralPath $out -PathType Container)) { return (& $fail 'the guest returned no output') }
        $pre = & $readJson "SiblingPre_$key.json"
        $assisted = [string]$Context.Run.Mode -eq 'Assisted'
        $inst = & $readJson "SiblingInstall_$key.json" -Optional:$assisted
        if ($null -eq $inst -and $assisted) { $inst = [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Completed = $true; RebootRequested = $false; Lingering = @(); Seconds = 0 } }
        if (-not (& $bool $inst 'Completed')) {
            $why = if (& $bool $inst 'TimedOut') { 'the sibling installer was still running after 20 minutes' } else { "the sibling installer failed (exit code $(& $int $inst 'ExitCode'))" }
            return (& $fail $why)
        }
        $cap = & $readJson "SiblingCapture_$key.json"
        if (& $bool $cap 'PostSiblingFailed') { return (& $fail 'the snapshot after the install failed') }
        # An assisted install proves nothing by itself (no exit code): no new uninstall entry of the app (no primary) and no
        # per-user one means the operator installed nothing, cancelled, or ran another file. Recorded, it would mark every
        # identity at that version Unstable for good (live row ASSISTED: a good Enforce-eligible identity became Block-only).
        if ($assisted -and -not (& $str $cap 'ProvisionalPrimary') -and @(& $list $cap 'HkcuArp').Count -eq 0) {
            return (& $fail 'the assisted install left no uninstall entry of this app (nothing installed, the setup cancelled, or another file): nothing is recorded; capture it again')
        }
        $probe = & $readJson "SiblingProbe_$key.json" -Optional

        # ---- host checks of the copied binaries (never executed; deleted afterwards, L31) ----
        $uninstallerCopy = Join-Path $out "SiblingCopy_${key}_uninstaller.exe"
        $mainCopy = Join-Path $out "SiblingCopy_${key}_main.exe"
        $tech = ''
        if (Test-Path -LiteralPath $uninstallerCopy -PathType Leaf) { $tech = Get-Win32ToolkitInstallerTechnology -Path $uninstallerCopy }
        $hostChecks = [ordered]@{
            UninstallerSigner = (& $signer $uninstallerCopy)
            MainSigner        = (& $signer $mainCopy)
            InstallerSigner   = (& $signer ([string]$Context.InstallerPath))
            NsisMagic         = ($tech -eq 'nullsoft')
            InnoMarkers       = ($tech -eq 'inno')
        }
        foreach ($c in @($uninstallerCopy, $mainCopy)) { if (Test-Path -LiteralPath $c) { Remove-Item -LiteralPath $c -Force -ErrorAction SilentlyContinue } }

        # ---- candidates (SV11) ----
        $cands = [System.Collections.Generic.List[object]]::new()
        foreach ($c in (& $list $cap 'Candidates')) {
            if ($cands.Count -ge 64) { break }
            $raw = @((& $str $c 'Key'), (& $str $c 'DisplayName'), (& $str $c 'Publisher'), (& $str $c 'DisplayVersion'), (& $str $c 'InstallLocation'), (& $str $c 'UninstallerPath'))
            $flag = @($raw | Where-Object { & $unsafe $_ }).Count -gt 0
            $uPath = & $str $c 'UninstallerPath'
            $uCanon = (& $bool $c 'UninstallerCanonical') -and (& $canonical $uPath)
            if (-not $uCanon) { $uPath = '' }
            $dir = & $str $c 'InstallDir'
            if ($dir -cnotmatch '^%ProgramFiles(\(x86\))?%(\\[A-Za-z0-9 ._+()-]{1,64}){1,4}$' -or $dir -match '\\[. ]*(\\|$)|[. ](\\|$)') { $dir = '' }
            $acl = [System.Collections.Generic.List[object]]::new()
            foreach ($a in (& $list $c 'Acl')) {
                if ($acl.Count -ge 16) { break }
                $rules = [System.Collections.Generic.List[object]]::new()
                foreach ($r in (& $list $a 'Rules')) {
                    if ($rules.Count -ge 64) { break }
                    $type = & $str $r 'Type'
                    if (@('Allow', 'Deny') -cnotcontains $type) { $type = 'Allow' }
                    $rules.Add([ordered]@{ Sid = (& $str $r 'Sid'); Rights = (& $int $r 'Rights'); Inheritance = (& $int $r 'Inheritance'); Propagation = (& $int $r 'Propagation'); Type = $type })
                }
                $acl.Add([ordered]@{ Path = (& $str $a 'Path'); Owner = (& $str $a 'Owner'); Rules = [object[]]$rules.ToArray() })
            }
            $view = & $str $c 'View'
            if (@('Native', 'Wow6432') -cnotcontains $view) { continue }
            $cands.Add([ordered]@{
                    Key = (& $str $c 'Key'); View = $view; DisplayName = (& $str $c 'DisplayName'); DisplayVersion = (& $str $c 'DisplayVersion'); Publisher = (& $str $c 'Publisher')
                    WindowsInstaller = (& $bool $c 'WindowsInstaller'); SystemComponent = (& $bool $c 'SystemComponent'); InstallLocation = (& $str $c 'InstallLocation')
                    DisplayIconLeaf = (& $str $c 'DisplayIconLeaf'); UninstallerPath = $uPath; UninstallerCanonical = [bool]$uCanon; UninstallerLeaf = (& $str $c 'UninstallerLeaf')
                    InstallDir = $dir; MainExe = (& $str $c 'MainExe'); Files = [string[]]@(& $list $c 'Files' | ForEach-Object { [string]$_ })
                    InstallLocationFiles = [string[]]@(& $list $c 'InstallLocationFiles' | ForEach-Object { [string]$_ }); InnoAppPath = (& $bool $c 'InnoAppPath'); UnsDat = (& $bool $c 'UnsDat')
                    QuietUninstallArgs = (& $str $c 'QuietUninstallArgs'); Acl = [object[]]$acl.ToArray(); UnsafeText = [bool]$flag
                })
        }
        $roots = [string[]]@(& $list $cap 'NewRoots' | ForEach-Object { [string]$_ } | Where-Object { & $canonical $_ })
        $noise = & $str $cap 'NoiseControl'
        if (@('Verified', 'Unverified') -cnotcontains $noise) { $noise = 'Unverified' }
        # What the guest's noise control found (live row GOAL-CAPTURE: an Unverified record said nothing about why): for the
        # operator only, never part of the record. Guest text: printable, at most 20 items of 160 characters; a nested list
        # (a guest script before the fix of live rows RAISE / ASSISTED) is flattened, never joined into one cut string.
        $noiseItems = @(& $list $cap 'NoiseDetail' | ForEach-Object { $_ } | Select-Object -First 20 | ForEach-Object { ConvertTo-Win32ToolkitSafeText -Text ([string]$_) -MaxLength 160 } | Where-Object { $_ })
        $noiseDetail = $noiseItems -join '; '
        # Why it was not verified, from the guest's constant item prefixes (live rows DEMOTE, INNO, ASSISTED: the warning said
        # "Windows Update installed something" when the check before the install had failed and nothing was installed).
        $noiseCause = ''
        if ($noise -ne 'Verified') {
            $causes = [System.Collections.Generic.List[string]]::new()
            if (@($noiseItems | Where-Object { $_.StartsWith('before the install: ', [StringComparison]::Ordinal) }).Count -gt 0) { $causes.Add('the update services and tasks could not be held still before the install') }
            if (@($noiseItems | Where-Object { $_.StartsWith('Windows Update installed: ', [StringComparison]::Ordinal) }).Count -gt 0) { $causes.Add('Windows Update installed something during the capture') }
            if (@($noiseItems | Where-Object { $_.StartsWith('Windows Update event log unreadable', [StringComparison]::Ordinal) }).Count -gt 0) { $causes.Add('the Windows Update event log could not be read, so a restarted update service could not be excused') }
            if ($causes.Count -eq 0) { $causes.Add('an update service or task was not held still during the capture') }
            $noiseCause = $causes -join '; '
        }
        $probeResult = & $str $probe 'Result'
        if (@('Clean', 'NeedsRestart', 'TimedOut', 'Survived', 'NotProbed') -cnotcontains $probeResult) { $probeResult = 'NotProbed' }
        $probedView = & $str $probe 'ProbedView'
        if (@('Native', 'Wow6432', '') -cnotcontains $probedView) { $probedView = '' }
        $started = & $str $pre 'StartedUtc'
        if ($started -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') { $started = '' }
        $run = $Context.Run
        $record = [ordered]@{
            SchemaVersion = '1.0'
            CaptureKey    = $key
            Package       = $Context.Package
            Sibling       = $Context.Sibling
            Run           = [ordered]@{
                Backend = [string]$run.Backend; Mode = [string]$run.Mode; Account = (& $str $pre 'Account'); Is64 = (& $bool $pre 'Is64'); OsBuild = (& $str $pre 'OsBuild')
                StartedUtc = $started; Seconds = [int]$run.Seconds; ToolkitVersion = [string]$run.ToolkitVersion; GuestScriptSha256 = [string]$run.GuestScriptSha256
                DependenciesSkipped = [bool]$run.DependenciesSkipped
            }
            Install       = [ordered]@{
                ExitCode = (& $int $inst 'ExitCode'); TimedOut = (& $bool $inst 'TimedOut'); Completed = (& $bool $inst 'Completed'); RebootRequested = (& $bool $inst 'RebootRequested')
                Lingering = [string[]]@(& $list $inst 'Lingering' | ForEach-Object { [string]$_ }); Seconds = (& $int $inst 'Seconds')
            }
            Observation   = [ordered]@{
                Candidates = [object[]]$cands.ToArray()
                Services = [object[]]@(& $list $cap 'Services' | ForEach-Object { [ordered]@{ Name = (& $str $_ 'Name'); DisplayName = (& $str $_ 'DisplayName'); ImageLeaf = (& $str $_ 'ImageLeaf') } })
                Shortcuts = [string[]]@(& $list $cap 'Shortcuts' | ForEach-Object { [string]$_ })
                Tasks = [object[]]@(& $list $cap 'Tasks' | ForEach-Object { [ordered]@{ Path = (& $str $_ 'Path'); ActionLeaf = (& $str $_ 'ActionLeaf') } })
                Appx = [string[]]@(& $list $cap 'Appx' | ForEach-Object { [string]$_ })
                HkcuArp = [object[]]@(& $list $cap 'HkcuArp' | ForEach-Object { [ordered]@{ Key = (& $str $_ 'Key'); DisplayName = (& $str $_ 'DisplayName') } })
                NewRoots = $roots
                NoiseControl = $noise
                PfroCount = (& $int $cap 'PfroCount')
                ProvisionalPrimary = (& $str $cap 'ProvisionalPrimary')
            }
            Probe         = [ordered]@{
                Result = $probeResult; ProbedKey = (& $str $probe 'ProbedKey'); ProbedView = $probedView; ExitCode = (& $int $probe 'ExitCode'); Seconds = (& $int $probe 'Seconds')
                LingeringProcess = [string[]]@(& $list $probe 'LingeringProcess' | ForEach-Object { [string]$_ }); PfroUnderRoot = (& $bool $probe 'PfroUnderRoot')
                RootConfigRemoved = (& $bool $probe 'RootConfigRemoved'); VendorConfigRemoved = [string[]]@(& $list $probe 'VendorConfigRemoved' | ForEach-Object { [string]$_ })
            }
            HostChecks    = $hostChecks
        }
        $typed = ConvertTo-Win32ToolkitSiblingCaptureRecord -InputObject $record
        if ($null -eq $typed) { return (& $fail 'the capture output does not have the record shape') }
        return [pscustomobject]@{ Record = $typed; Failure = ''; NoiseDetail = $noiseDetail; NoiseCause = $noiseCause }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        return (& $fail ('the capture output could not be read (' + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200) + ')'))
    }
}
