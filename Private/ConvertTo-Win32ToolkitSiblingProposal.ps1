function ConvertTo-Win32ToolkitSiblingProposal {
    <#
    .SYNOPSIS
        Turns a project's hash-verified sibling-capture records into prior-install proposals.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.8; SV1, SV3, SV5, SV8-SV12, SV14, SV34, S23-S35, D25, D62). Always
        re-derived from the records (Get-Win32ToolkitSiblingCaptureRecord: name = SHA-256 prefix, frozen shape), never
        from the index, so the same answer comes at capture end, when a proposal is applied and at Export.

        Per capture record:
          1. attribution (the shared text, Get-Win32ToolkitSiblingAttribution): the one primary uninstall entry (High:
             a manifest / Apps and Features ProductCode, or an Apps and Features name and publisher; Medium: the manifest
             PackageName / Publisher, the install folder and a host-verified signer). None or several -> NoPrimary; the
             others -> CoInstalled (with a primary: inside any folder the capture created, except a Microsoft entry of a
             non-Microsoft package) or Unattributed. The signer subjects the host verified on the copied uninstaller and
             main program belong to the guest's provisional primary only, which the guest ranked High or not at all: in
             PR 3b no capture reaches Medium (MediumNotNamed below is for the follow-up that copies out a Medium-shaped
             candidate).
          2. gates: the package's own uninstall key (OwnIdentity, Uninstall - never the install tattoo) -> SameKey, no
             proposal; a registration under a user profile or in HKCU only -> PerUser, no proposal;
          3. the identity (the Tuple of spec 2.3): Key, View, Publisher, DisplayName or a {v} template, the kind
             (nullsoft: the NSIS magic on the copied uninstaller; inno: an _is1 key, the Inno Setup App Path value and an
             unins*.dat; a manifest 'exe' with one of them -> that kind + ManifestTypeGeneric; a contradiction ->
             TypeMismatch; none -> generic exe), the uninstaller file name and host-verified signer, InstallDir, MainExe
             and its process name;
          4. per-capture flags: UninstallerOutsideRoot (not canonical, not in a new root that passes
             Test-Win32ToolkitCleanupPath -AsInstallRoot, or InstallDir outside it), UninstallerName, InstallDirNotProgramFiles,
             NoMainExe, WeakAcl (the device's allow-list of text B on the recorded permissions: an owner other than SYSTEM,
             Administrators or TrustedInstaller, or another account's Allow rule with a write-class right, InheritOnly
             folder rules skipped), EmptyName, LocaleInName, NameEmbedsVersion, UnsafeText, KeyCharset, Sandbox, Assisted,
             ProbeNotClean (the removability probe of THIS entry was not Clean, NotProbed included), NoiseUnverified,
             ArgsDiffer (informational), SignerMismatch (Test-Win32ToolkitSiblingSigner).
        Per identity (captures of one sibling type and architecture with the same Tuple): at least two captures, else
        Unattributed; another identity or a capture without a primary inside its version range -> Unstable; the observed
        versions against the winget versions -> VersionScheme (unless strictly monotone across at least two winget
        versions) or ConstantVersion; drift -> one proposal per identity, the older ones Track Frozen, the versions
        between them in Gaps; a class E winget id -> flag ClassE (never a reason, D25); a sibling of the package's own
        family keeps only versions below the package version (S3) and is reported SameFamily.

        EnforceEligible is false when any flag other than ArgsDiffer, ManifestTypeGeneric, ClassE and SignerMismatch is
        set, or the proposal is Medium and not named by -ProposalId (MediumNotNamed). BlockEligible: every proposal (a
        primary, not PerUser, not SameKey). FlagFree (the bulk Block of spec 2.12 rule 7): no flag other than ArgsDiffer
        and ManifestTypeGeneric. DataLoss: a capture's probe saw the uninstaller remove configuration in its folder.

        Read-only. NotCapturable, ReportOnly and Failed come from the informational index
        (Documentation\SiblingCapture.json): they are types and runs, not records.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER ProposalId
        The proposals an operator named (a Medium proposal is Enforce-eligible only when named).
    .PARAMETER PackageSigner
        The package installer's signature @{ Status; Subject } (default: Get-AuthenticodeSignature on
        Files\<Installer.FileName>).
    .OUTPUTS
        [pscustomobject] Proposals, Captures (one row per record: CaptureId, Type, Architecture, SiblingVersion, Role,
        ObservedVersion, Primary, View, Rank, Tuple, Entry, Flags, ...), CoInstalled, Unattributed, NoPrimary, PerUser,
        SameKey, SameFamily, NotCapturable, ReportOnly, Failed, Gaps.
    .EXAMPLE
        (ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $p).Proposals | Format-Table ProposalId, Key, VersionMin, VersionMax, EnforceEligible
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ProposalId = @(),

        [AllowNull()]
        [object]$PackageSigner
    )

    $prop = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
        if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
        return $null
    }
    $str = { param($Object, [string]$Name) $v = & $prop $Object $Name; if ($null -eq $v) { '' } else { [string]$v } }
    $list = { param($Object, [string]$Name) @(@(& $prop $Object $Name) | Where-Object { $null -ne $_ }) }
    $same = { param([string]$A, [string]$B) [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase) }
    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $named = @($ProposalId | Where-Object { $_ })

    # ---- the package ----
    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $app = & $prop $cfg 'App'
    $installer = & $prop $cfg 'Installer'
    $source = & $prop $cfg 'Source'
    $ownIdentity = & $prop $cfg 'OwnIdentity'
    $uninstall = & $prop $cfg 'Uninstall'
    $ownArp = [System.Collections.Generic.List[object]]::new()
    foreach ($k in (& $list $ownIdentity 'ArpKeys')) { if (& $str $k 'Key') { $ownArp.Add([pscustomobject]@{ Key = (& $str $k 'Key'); View = (& $str $k 'View') }) } }
    foreach ($k in (& $list $uninstall 'PrimaryKeys')) { if (& $str $k 'Name') { $ownArp.Add([pscustomobject]@{ Key = (& $str $k 'Name'); View = (& $str $k 'View') }) } }
    $ownCodes = [string[]]@(@((& $str $ownIdentity 'ProductCode'), (& $str $source 'ProductCode')) + @(& $list $uninstall 'ProductCodes' | ForEach-Object { [string]$_ }) | Where-Object { $_ })
    $own = [pscustomobject]@{ ArpKeys = [object[]]$ownArp.ToArray(); ProductCodes = $ownCodes }
    $pkgPublisher = & $str $app 'Vendor'
    $pkgVersionText = & $str $app 'Version'
    $pkgVersion = ConvertTo-Win32ToolkitPriorVersion -Text $pkgVersionText
    $pkgFamily = (Get-Win32ToolkitInstallerFamily -Type (& $str $installer 'Type')).Family
    $wingetId = & $str $source 'WingetId'
    $classE = $wingetId -match '^(Python\.Python\.|Microsoft\.DotNet\.|Microsoft\.VCRedist\.|EclipseAdoptium\.Temurin\.|Oracle\.JDK\.)' -or $wingetId -match '\.Preview$'
    if ($PSBoundParameters.ContainsKey('PackageSigner')) { $pkgSigner = $PackageSigner }
    else {
        $pkgSigner = [pscustomobject]@{ Status = ''; Subject = '' }
        $leaf = & $str $installer 'FileName'
        if ($leaf) { $leaf = Split-Path -Path $leaf -Leaf }
        $file = if ($leaf) { Join-Path $ProjectPath "Files\$leaf" } else { '' }
        if ($file -and (Test-Path -LiteralPath $file -PathType Leaf)) {
            try {
                $sig = Get-AuthenticodeSignature -LiteralPath $file -ErrorAction Stop
                $pkgSigner = [pscustomobject]@{ Status = [string]$sig.Status; Subject = $(if ($sig.SignerCertificate) { & $safe $sig.SignerCertificate.Subject 512 } else { '' }) }
            }
            catch { $pkgSigner = [pscustomobject]@{ Status = 'Unreadable'; Subject = '' } }
        }
    }

    # ---- the device's ACL allow-list (text B, $w32tPrAclProblem) on the recorded permissions ----
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $weakMask = 0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    $aclProblem = {
        param($Acl, [string]$UninstallerPath)
        $items = @($Acl | Where-Object { $null -ne $_ })
        if ($items.Count -eq 0) { return 'its permissions were not recorded' }
        foreach ($a in $items) {
            $path = & $str $a 'Path'
            $folder = -not (& $same $path $UninstallerPath)
            if ($trusted -notcontains (& $str $a 'Owner')) { return "$(& $safe $path 260) is not owned by SYSTEM, Administrators or TrustedInstaller" }
            foreach ($r in (& $list $a 'Rules')) {
                if ((& $str $r 'Type') -cne 'Allow') { continue }
                if ($folder -and (([int](& $prop $r 'Propagation')) -band 2)) { continue }
                if ($trusted -contains (& $str $r 'Sid')) { continue }
                if ((([int](& $prop $r 'Rights')) -band $weakMask) -ne 0) { return "an account other than SYSTEM, Administrators or TrustedInstaller can change $(& $safe $path 260)" }
            }
        }
        return ''
    }
    $expand = { param([string]$Token) $Token -replace '^%ProgramFiles\(x86\)%', 'C:\Program Files (x86)' -replace '^%ProgramFiles%', 'C:\Program Files' }
    $inside = {
        param([string]$Path, [string]$Root)
        $p = $Path.TrimEnd('\'); $r = $Root.TrimEnd('\')
        $p -and $r -and ((& $same $p $r) -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase))
    }
    $leafRule = '^[A-Za-z0-9 ._+-]{1,64}\.exe$'

    # ---- 1-3: one row per record ----
    $records = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath)
    $rows = [System.Collections.Generic.List[object]]::new()
    $coInstalled = [System.Collections.Generic.List[object]]::new()
    $unattributed = [System.Collections.Generic.List[object]]::new()
    $noPrimary = [System.Collections.Generic.List[object]]::new()
    $perUser = [System.Collections.Generic.List[object]]::new()
    $sameKey = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $records) {
        $cid = [string]$r.CaptureId
        $sib = $r.Sibling
        $obs = $r.Observation
        $hc = $r.HostChecks
        $probe = $r.Probe
        $type = & $str $sib 'InstallerType'
        $guestPrimary = & $str $obs 'ProvisionalPrimary'
        $isGuestPrimary = {
            param($C)
            (& $same (& $str $C 'Key') $guestPrimary) -and ((& $str $probe 'ProbedView') -eq '' -or -not (& $same (& $str $probe 'ProbedKey') (& $str $C 'Key')) -or (& $str $probe 'ProbedView') -ceq (& $str $C 'View'))
        }
        $valid = { param($S) if ((& $str $S 'Status') -ceq 'Valid') { & $str $S 'Subject' } else { '' } }
        $cands = @(foreach ($c in (& $list $obs 'Candidates')) {
                $g = & $isGuestPrimary $c
                [pscustomobject]@{
                    Key = (& $str $c 'Key'); View = (& $str $c 'View'); DisplayName = (& $str $c 'DisplayName'); DisplayVersion = (& $str $c 'DisplayVersion')
                    Publisher = (& $str $c 'Publisher'); SystemComponent = [bool](& $prop $c 'SystemComponent'); InstallLocation = (& $str $c 'InstallLocation')
                    UninstallerPath = (& $str $c 'UninstallerPath'); InstallDir = (& $str $c 'InstallDir')
                    UninstallerSignerSubject = $(if ($g) { & $valid (& $prop $hc 'UninstallerSigner') } else { '' })
                    MainSignerSubject = $(if ($g) { & $valid (& $prop $hc 'MainSigner') } else { '' })
                    Source = $c; GuestPrimary = [bool]$g
                }
            })
        $manifest = & $prop $sib 'Manifest'
        $man = [pscustomobject]@{
            ProductCodes = [string[]]@(& $list $manifest 'ProductCodes'); Afe = @(& $list $manifest 'Afe'); PackageName = (& $str $manifest 'PackageName')
            Publisher = (& $str $manifest 'Publisher'); DefaultInstallLocation = (& $str $manifest 'DefaultInstallLocation'); InstallerSignerSubject = (& $valid (& $prop $hc 'InstallerSigner'))
        }
        $attr = Get-Win32ToolkitSiblingAttribution -Candidates $cands -Manifest $man -Own $own -PackagePublisher $pkgPublisher -NewRoots ([string[]]@(& $list $obs 'NewRoots'))
        foreach ($x in @($attr.CoInstalled)) { $coInstalled.Add([pscustomobject]@{ CaptureId = $cid; Key = (& $safe $x.Key); View = $x.View }) }
        foreach ($x in @($attr.Unattributed)) { $unattributed.Add([pscustomobject]@{ CaptureId = $cid; Key = (& $safe $x.Key); View = $x.View; Reason = 'not the sibling installer''s own entry' }) }
        $row = [ordered]@{
            CaptureId = $cid; Type = $type; Architecture = (& $str $sib 'Architecture'); SiblingVersion = (& $str $sib 'Version'); ReleaseDate = (& $str $sib 'ReleaseDate')
            Role = (& $str $sib 'Role'); Backend = (& $str $r.Run 'Backend'); Mode = (& $str $r.Run 'Mode'); Primary = ''; View = ''; Rank = ''; Reason = [string]$attr.Reason
            ObservedVersion = ''; Tuple = ''; Entry = $null; Flags = [string[]]@(); FlagText = @{}; DataLoss = $false; Status = 'NoPrimary'
        }
        $c = $null
        if ($attr.Primary) { $c = @($cands | Where-Object { (& $same $_.Key $attr.Primary) -and $_.View -ceq $attr.PrimaryView }) | Select-Object -First 1 }
        if ($null -eq $c) {
            $hkcu = @(& $list $obs 'HkcuArp')
            if ($hkcu.Count -gt 0 -and @($cands | Where-Object { -not $_.SystemComponent }).Count -eq 0) {
                $row.Status = 'PerUser'
                $perUser.Add([pscustomobject]@{ CaptureId = $cid; Type = $type; Key = (& $safe (& $str $hkcu[0] 'Key')); Reason = 'it registers for the installing user only (HKCU)' })
            }
            else { $noPrimary.Add([pscustomobject]@{ CaptureId = $cid; Type = $type; Version = (& $safe $row.SiblingVersion 64); Reason = [string]$attr.Reason }) }
            $rows.Add([pscustomobject]$row)
            continue
        }
        $row.Primary = & $safe $c.Key 255; $row.View = $c.View; $row.Rank = [string]$attr.Rank; $row.ObservedVersion = $c.DisplayVersion
        if ($attr.SameKey) {
            $row.Status = 'SameKey'
            $sameKey.Add([pscustomobject]@{ CaptureId = $cid; Type = $type; Key = (& $safe $c.Key); View = $c.View })
            $rows.Add([pscustomobject]$row)
            continue
        }
        if ($c.InstallLocation -match '^[A-Za-z]:\\Users\\' -or $c.UninstallerPath -match '^[A-Za-z]:\\Users\\') {
            $row.Status = 'PerUser'
            $perUser.Add([pscustomobject]@{ CaptureId = $cid; Type = $type; Key = (& $safe $c.Key); Reason = 'it installs under a user profile' })
            $rows.Add([pscustomobject]$row)
            continue
        }
        $row.Status = 'Primary'
        $flags = [ordered]@{}
        $flag = { param([string]$Name, [string]$Text) if (-not $flags.Contains($Name)) { $flags[$Name] = $Text } }
        $src = $c.Source

        # the kind (SV12): host-verified signatures of the copied uninstaller belong to the guest's provisional primary
        $nsis = $c.GuestPrimary -and [bool](& $prop $hc 'NsisMagic')
        $inno = $c.Key.EndsWith('_is1', [StringComparison]::OrdinalIgnoreCase) -and [bool](& $prop $src 'InnoAppPath') -and [bool](& $prop $src 'UnsDat')
        $observed = if ($nsis -and $inno) { 'both' } elseif ($nsis) { 'nullsoft' } elseif ($inno) { 'inno' } else { '' }
        $mType = & $str $sib 'EffectiveType'
        if (-not $mType) { $mType = $type }
        $kind = ''
        if ($observed -eq 'both') { & $flag 'TypeMismatch' 'the uninstaller shows both NSIS and Inno Setup markers' }
        elseif ($mType -in @('nullsoft', 'inno')) {
            if ($observed -eq $mType) { $kind = $mType }
            elseif ($observed) { & $flag 'TypeMismatch' "winget says $mType, the uninstaller is $observed" }
            else { & $flag 'GenericExe' "no $mType signature on the uninstaller (a generic exe: Block only)" }
        }
        elseif ($mType -eq 'exe') {
            if ($observed) { $kind = $observed; & $flag 'ManifestTypeGeneric' "winget says exe, the uninstaller is $observed" }
            else { & $flag 'GenericExe' 'no NSIS or Inno Setup signature on the uninstaller (a generic exe: Block only)' }
        }
        else {
            if ($observed) { & $flag 'TypeMismatch' "winget says $mType, the uninstaller is $observed" }
            else { & $flag 'GenericExe' "a $mType sibling has no NSIS or Inno Setup uninstaller (Block only)" }
        }

        # the name (SV8, SV24)
        $dn = $c.DisplayName; $dv = $c.DisplayVersion
        $name = ''; $template = ''
        if (-not $dn.Trim()) { & $flag 'EmptyName' 'its DisplayName is empty' }
        else {
            $at = if ($dv) { $dn.IndexOf($dv, [StringComparison]::Ordinal) } else { -1 }
            if ($at -ge 0) {
                if ($dn.IndexOf($dv, $at + $dv.Length, [StringComparison]::Ordinal) -ge 0) { & $flag 'NameEmbedsVersion' 'its DisplayName holds the version twice' }
                $template = $dn.Substring(0, $at) + '{v}' + $dn.Substring($at + $dv.Length)
            }
            else { $name = $dn }
            $rest = if ($template) { $template.Replace('{v}', '') } else { $name }
            if ($rest -match '\d+\.\d+') { & $flag 'NameEmbedsVersion' 'its DisplayName holds another version form' }
            $locale = & $str $sib 'Locale'
            # A bare language code too: the Mozilla locale packages set no InstallerLocale and register 'Mozilla Firefox (x64 nl)'
            # (live row COPRODUCT): a lowercase 2-3 letter token that ends a parenthesised part, alone or after another word.
            if (($locale -and $dn.IndexOf($locale, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or $dn -cmatch '\b[a-z]{2,3}-[A-Z]{2}\b' -or $dn -cmatch '\((?:[^()]*\s)?[a-z]{2,3}\)') { & $flag 'LocaleInName' 'its DisplayName holds the installer language' }
        }

        # removal data (SV8-SV10)
        $uPath = $c.UninstallerPath
        $uLeaf = & $str $src 'UninstallerLeaf'
        $root = ''
        if (-not $uPath -or -not [bool](& $prop $src 'UninstallerCanonical')) { & $flag 'UninstallerOutsideRoot' 'its uninstaller path is not canonical' }
        else {
            $root = @(@(& $list $obs 'NewRoots') | ForEach-Object { [string]$_ } | Where-Object { & $inside $uPath $_ } | Sort-Object -Property Length -Descending) | Select-Object -First 1
            if (-not $root) { & $flag 'UninstallerOutsideRoot' 'its uninstaller is not in a folder the install created' }
            else {
                $rootCheck = Test-Win32ToolkitCleanupPath -Path $root -AsInstallRoot
                if (-not $rootCheck.Valid) { & $flag 'UninstallerOutsideRoot' "its install folder is not a valid install root ($($rootCheck.Explanation))" }
            }
        }
        if ($uLeaf -cnotmatch $leafRule) { & $flag 'UninstallerName' 'its uninstaller file name is not a plain .exe name'; $uLeaf = '' }
        $dir = $c.InstallDir
        if (-not $dir) { & $flag 'InstallDirNotProgramFiles' 'its folder is not under Program Files' }
        elseif ($root -and -not (& $inside (& $expand $dir) $root)) { & $flag 'UninstallerOutsideRoot' 'its InstallDir is outside the install root' }
        $main = & $str $src 'MainExe'
        if ($main -cnotmatch $leafRule -or ($uLeaf -and (& $same $main $uLeaf))) { & $flag 'NoMainExe' 'no main program was observed in its folder'; $main = '' }
        $procs = [string[]]@(if ($main) { $main.Substring(0, $main.Length - 4) })
        $acl = & $aclProblem (& $list $src 'Acl') $uPath
        if ($acl) { & $flag 'WeakAcl' $acl }
        $uSigner = if ($c.GuestPrimary) { & $valid (& $prop $hc 'UninstallerSigner') } else { '' }
        $quiet = & $str $src 'QuietUninstallArgs'
        if ($quiet) {
            $allowed = if ($kind -eq 'inno') { @('/VERYSILENT', '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART') } else { @('/S') }
            $extra = @(-split $quiet | Where-Object { $_ -match '^[/-]' } | ForEach-Object { ($_ -split '[=:]')[0].ToUpperInvariant() } | Where-Object { $allowed -notcontains $_ })
            if ($extra.Count) { & $flag 'ArgsDiffer' "its own quiet uninstall uses $(& $safe ($extra -join ' ') 120), which the constant switches lack" }
        }
        if ([bool](& $prop $src 'UnsafeText')) { & $flag 'UnsafeText' 'a captured text held control or delimiter characters' }
        if ($c.Key -cnotmatch '^[A-Za-z0-9 ._+(){}-]{1,255}$') { & $flag 'KeyCharset' 'its key has characters outside the conservative set' }
        if ($row.Backend -eq 'Sandbox') { & $flag 'Sandbox' 'it was captured in Windows Sandbox (Block only)' }
        if ($row.Mode -eq 'Assisted') { & $flag 'Assisted' 'it was an assisted capture (Block only)' }
        if ((& $str $probe 'Result') -cne 'Clean' -or -not (& $same (& $str $probe 'ProbedKey') $c.Key) -or ((& $str $probe 'ProbedView') -and (& $str $probe 'ProbedView') -cne $c.View)) {
            & $flag 'ProbeNotClean' "the removability probe was not clean ($(& $safe (& $str $probe 'Result') 16))"
        }
        if ((& $str $obs 'NoiseControl') -cne 'Verified') { & $flag 'NoiseUnverified' 'the guest noise control was not verified' }
        $signer = Test-Win32ToolkitSiblingSigner -SiblingInstaller (& $prop $hc 'InstallerSigner') -SiblingMain $(if ($c.GuestPrimary) { & $prop $hc 'MainSigner' } else { $null }) -PackageInstaller $pkgSigner
        if ($signer.Mismatch) { & $flag 'SignerMismatch' (($signer.Reasons) -join '; ') }

        $entry = [pscustomobject][ordered]@{
            Kind = 'ArpKey'; Key = $c.Key; View = $c.View; Publisher = $c.Publisher; DisplayName = $name; DisplayNameTemplate = $template
            UninstallerType = $kind; UninstallerFileName = $uLeaf; UninstallerSigner = $uSigner; InstallDir = $dir; MainExe = $main; ProcessNames = $procs
        }
        $row.Entry = $entry
        $row.Tuple = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $entry
        $row.Flags = [string[]]@($flags.Keys)
        $row.FlagText = $flags
        $row.DataLoss = [bool](& $prop $probe 'RootConfigRemoved')
        $rows.Add([pscustomobject]$row)
    }

    # ---- 4-10: identities and proposals ----
    $toV = { param([string]$T) ConvertTo-Win32ToolkitPriorVersion -Text $T }
    $informational = @('ArgsDiffer', 'ManifestTypeGeneric')
    $notReasons = @('ArgsDiffer', 'ManifestTypeGeneric', 'ClassE', 'SignerMismatch')
    $proposals = [System.Collections.Generic.List[object]]::new()
    $gaps = [System.Collections.Generic.List[object]]::new()
    $sameFamily = [System.Collections.Generic.List[object]]::new()
    $attributed = @($rows | Where-Object { $_.Status -eq 'Primary' })
    foreach ($grp in @($rows | Where-Object { $_.Status -in @('Primary', 'NoPrimary') } | Group-Object -Property { "$($_.Type)|$($_.Architecture)" })) {
        $typeRows = @($grp.Group)
        $identities = [System.Collections.Generic.List[object]]::new()
        foreach ($ig in @($attributed | Where-Object { "$($_.Type)|$($_.Architecture)" -ceq $grp.Name } | Group-Object -Property Tuple -CaseSensitive)) {
            $caps = @($ig.Group)
            $wv = @($caps | ForEach-Object { & $toV $_.SiblingVersion } | Where-Object { $null -ne $_ } | Sort-Object)
            $identities.Add([pscustomobject]@{ Tuple = $ig.Name; Captures = $caps; MinW = $(if ($wv.Count) { $wv[0] } else { $null }); MaxW = $(if ($wv.Count) { $wv[-1] } else { $null }) })
        }
        $sortedIds = @($identities | Sort-Object -Property @{ Expression = { if ($_.MaxW) { $_.MaxW } else { [version]'0.0' } } }, @{ Expression = 'Tuple' })
        for ($i = 0; $i -lt $sortedIds.Count; $i++) {
            $id = $sortedIds[$i]
            $caps = @($id.Captures)
            $first = $caps[0]
            if ($caps.Count -lt 2) {
                $unattributed.Add([pscustomobject]@{ CaptureId = $first.CaptureId; Key = $first.Primary; View = $first.View; Reason = 'this identity was seen in one capture only' })
                continue
            }
            $flags = [ordered]@{}
            foreach ($cap in $caps) { foreach ($f in $cap.Flags) { if (-not $flags.Contains($f)) { $flags[$f] = $cap.FlagText[$f] } } }
            # stability: nothing else of this type inside the identity's version range
            if ($id.MinW -and $id.MaxW) {
                $intruders = @($typeRows | Where-Object { $_.Tuple -cne $id.Tuple } | Where-Object { $v = & $toV $_.SiblingVersion; $null -ne $v -and $v -ge $id.MinW -and $v -le $id.MaxW })
                if ($intruders.Count) { $flags['Unstable'] = "another identity or a capture without a primary lies inside its versions ($(@($intruders | ForEach-Object { & $safe $_.SiblingVersion 32 }) -join ', '))" }
            }
            # the version scheme (SV3, SV14)
            $pairs = @($caps | ForEach-Object { [pscustomobject]@{ W = (& $toV $_.SiblingVersion); O = (& $toV $_.ObservedVersion) } })
            if (@($pairs | Where-Object { $null -eq $_.W -or $null -eq $_.O }).Count) { $flags['VersionScheme'] = 'a version cannot be read' }
            elseif (@($pairs | Where-Object { $_.W -ne $_.O }).Count) {
                $byW = @($pairs | Group-Object -Property { $_.W.ToString() } | ForEach-Object { [pscustomobject]@{ W = $_.Group[0].W; O = @($_.Group | ForEach-Object { $_.O } | Sort-Object -Unique) } } | Sort-Object -Property W)
                $distinctO = @($pairs | ForEach-Object { $_.O.ToString() } | Sort-Object -Unique)
                $monotone = $byW.Count -ge 2 -and @($byW | Where-Object { @($_.O).Count -ne 1 }).Count -eq 0
                if ($monotone) { for ($k = 1; $k -lt $byW.Count; $k++) { if (@($byW[$k].O)[0] -le @($byW[$k - 1].O)[0]) { $monotone = $false } } }
                if ($byW.Count -ge 2 -and $distinctO.Count -eq 1) { $flags['ConstantVersion'] = "its DisplayVersion stays $(& $safe $distinctO[0] 32) across winget versions" }
                elseif (-not $monotone) { $flags['VersionScheme'] = 'its DisplayVersion does not follow the winget version' }
            }
            if ($classE) { $flags['ClassE'] = 'a versioned family (its versions install side by side)' }
            # the window (L36) and the package's own family (S3, SV34)
            $sf = (Get-Win32ToolkitInstallerFamily -Type $first.Type).Family -eq $pkgFamily -and $pkgFamily -ne 'other'
            $below = if ($sf) { $pkgVersionText } else { '' }
            $window = Get-Win32ToolkitPriorInstallWindow -Captures $caps -Tuple $id.Tuple -Below $below
            if ($sf -and @($caps | Where-Object { $v = & $toV $_.ObservedVersion; $null -ne $v -and $null -ne $pkgVersion -and $v -ge $pkgVersion }).Count) {
                $sameFamily.Add([pscustomobject]@{ Type = $first.Type; Key = $first.Primary; Reason = "a $($first.Type) sibling of the package's own family observed at or above the package version $(& $safe $pkgVersionText 64)" })
            }
            if (-not $window.Found) { continue }
            $floorCap = @($caps | Where-Object { $_.CaptureId -ceq $window.FloorCaptureId })[0]
            $confidence = if (@($caps | Where-Object { $_.Rank -ne 'High' }).Count) { 'Medium' } else { 'High' }
            $flagNames = [string[]]@($flags.Keys)
            $reasons = [System.Collections.Generic.List[string]]::new()
            foreach ($f in $flagNames) { if ($notReasons -notcontains $f) { $reasons.Add("${f}: $($flags[$f])") } }
            $p = [pscustomobject][ordered]@{
                ProposalId          = ''
                ProposalHash        = $id.Tuple
                Primary             = $true
                Confidence          = $confidence
                Kind                = 'ArpKey'
                Key                 = $first.Entry.Key
                View                = $first.Entry.View
                Publisher           = $first.Entry.Publisher
                DisplayName         = $first.Entry.DisplayName
                DisplayNameTemplate = $first.Entry.DisplayNameTemplate
                VersionMin          = $window.VersionMin
                VersionMax          = $window.VersionMax
                UninstallerType     = $first.Entry.UninstallerType
                UninstallerFileName = $first.Entry.UninstallerFileName
                UninstallerSigner   = $first.Entry.UninstallerSigner
                InstallDir          = $first.Entry.InstallDir
                MainExe             = $first.Entry.MainExe
                ProcessNames        = [string[]]@($first.Entry.ProcessNames)
                Stability           = $(if ($flags.Contains('Unstable')) { 'Unstable' } else { 'Stable' })
                Track               = $(if ($i -lt $sortedIds.Count - 1) { 'Frozen' } else { 'Current' })
                CaptureIds          = [string[]]$window.CaptureIds
                FloorCaptureId      = $window.FloorCaptureId
                FloorVersion        = $floorCap.SiblingVersion
                FloorReleaseDate    = $floorCap.ReleaseDate
                SiblingType         = $first.Type
                Architecture        = $first.Architecture
                Flags               = $flagNames
                FlagText            = $flags
                FlagFree            = (@($flagNames | Where-Object { $informational -notcontains $_ }).Count -eq 0)
                IneligibleReasons   = [string[]]@()
                EnforceEligible     = $false
                BlockEligible       = $true
                SameFamily          = [bool]$sf
                DataLoss            = (@($caps | Where-Object { $_.DataLoss }).Count -gt 0)
                ObservedVersions    = [string[]]@($caps | ForEach-Object { $_.ObservedVersion } | Sort-Object -Unique)
            }
            $proposals.Add([pscustomobject]@{ P = $p; Reasons = $reasons; Stem = "$(switch ($p.UninstallerType) { 'nullsoft' { 'nsis' } 'inno' { 'inno' } default { 'exe' } })-$(if ($p.View -eq 'Wow6432') { 'x86' } else { 'x64' })"; MaxW = $id.MaxW })
            if ($i -gt 0) {
                $prev = $sortedIds[$i - 1]
                $gaps.Add([pscustomobject]@{ Type = $first.Type; Architecture = $first.Architecture; From = (& $safe @($prev.Captures | Sort-Object { & $toV $_.SiblingVersion })[-1].SiblingVersion 64); To = (& $safe @($caps | Sort-Object { & $toV $_.SiblingVersion })[0].SiblingVersion 64) })
            }
        }
    }

    # ---- ids: the current identity takes the stem, drift identities '-2', '-3' ... ----
    $taken = @{}
    $final = foreach ($x in @($proposals | Sort-Object -Property @{ Expression = 'Stem' }, @{ Expression = { $_.P.Track -ne 'Current' } }, @{ Expression = { if ($_.MaxW) { $_.MaxW } else { [version]'0.0' } }; Descending = $true }, @{ Expression = { $_.P.ProposalHash } })) {
        $pid0 = $x.Stem; $n = 1
        while ($taken.ContainsKey($pid0)) { $n++; $pid0 = "$($x.Stem)-$n" }
        $taken[$pid0] = $true
        $x.P.ProposalId = $pid0
        if ($x.P.Confidence -eq 'Medium' -and $named -cnotcontains $pid0) { $x.Reasons.Add('MediumNotNamed: a Medium-confidence identity becomes Enforce only when named with -ProposalId') }
        $x.P.IneligibleReasons = [string[]]$x.Reasons.ToArray()
        $x.P.EnforceEligible = ($x.Reasons.Count -eq 0)
        $x.P
    }

    # ---- the informational index: types and runs that are not records ----
    $index = $null
    $indexFile = Join-Path $ProjectPath 'Documentation\SiblingCapture.json'
    try { if ((Test-Path -LiteralPath $indexFile -PathType Leaf) -and (Get-Item -LiteralPath $indexFile).Length -le 4MB) { $index = Get-Content -LiteralPath $indexFile -Raw -Encoding UTF8 | ConvertFrom-Json } }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose 'Documentation\SiblingCapture.json is unreadable and is ignored.'
    }
    $typeList = { param([string]$Name) @(& $list $index $Name | ForEach-Object { [pscustomobject]@{ Type = (& $safe (& $str $_ 'Type') 32); Reason = (& $safe (& $str $_ 'Reason') 300) } }) }
    $failed = @(& $list $index 'Failed' | ForEach-Object { [pscustomobject]@{ CaptureKey = (& $safe (& $str $_ 'CaptureKey') 80); Type = (& $safe (& $str $_ 'Type') 32); Version = (& $safe (& $str $_ 'Version') 64); Reason = (& $safe (& $str $_ 'Reason') 300) } })

    return [pscustomobject]@{
        Proposals     = @($final | Sort-Object -Property ProposalId)
        Captures      = @($rows.ToArray())
        CoInstalled   = @($coInstalled.ToArray())
        Unattributed  = @($unattributed.ToArray())
        NoPrimary     = @($noPrimary.ToArray())
        PerUser       = @($perUser.ToArray())
        SameKey       = @($sameKey.ToArray())
        SameFamily    = @($sameFamily.ToArray())
        NotCapturable = @(& $typeList 'NotCapturable')
        ReportOnly    = @(& $typeList 'ReportOnly')
        Failed        = $failed
        Gaps          = @($gaps.ToArray())
    }
}
