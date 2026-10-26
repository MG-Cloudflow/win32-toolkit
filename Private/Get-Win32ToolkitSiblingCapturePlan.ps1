function Get-Win32ToolkitSiblingCapturePlan {
    <#
    .SYNOPSIS
        Plans which other installer technologies of an app to capture, at which versions.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.2; SV21, SV24, SV29, SV34, D60, L32, L36). Read-only; every winget GET is
        fail-open (a failed one skips that version and is listed in ProbeFailures).

        1. The package version's sibling probe (Get-Win32ToolkitSiblingInstaller -RetryFailed: an explicit plan asks a
           failure of earlier in the process again): the other families (Siblings) and the same family's other
           registration types (SameFamilyOther), by EffectiveType. msi and wix are one registration type; nullsoft, inno,
           burn and exe stay separate. The not-registering tuples (zip/portable) are listed too. Its Status, Reason,
           RetryAfterUtc and Cause (Transient for RateLimited / Network / Timeout, else Permanent) are the plan's
           PackageProbe: not Ok -> no type is planned (live rows RAISE, INNO: the capture then says the manifest could
           not be read, never that there is nothing to capture). Request records what was asked (the retry command of
           the capture's warning keeps that scope).
        2. A class per type (SV29, Dv2; Get-Win32ToolkitSiblingCaptureClass, shared with the winget wizard):
             nullsoft, inno                    RemovableNow
             exe                               RemovableNow (Block-only unless the binary shows NSIS or Inno Setup)
             msi, wix                          ReportOnly   (removal of an MSI sibling ships in PR 3c)
             burn, msix, msstore, appx         ReportOnly   (PR 7)
             portable, pwa, zip-wrapped, arm64 NotCapturable (with the reason)
           ReportOnly types are captured only with -IncludeReportOnly; NotCapturable never.
        3. Versions (SV24, D60, L32): the app's winget versions (unfiltered), kept at or below App.Version (strictly
           below for a type of the package's own family), newest first; one probe per version (at most 40 per type)
           says whether it offers the type for the architecture and its ReleaseDate.
             Newest  the newest offering version;
             Floor   the oldest offering version released in the last 365 days; when a considered version has no
                     date (none, or no calendar day such as 2025-02-30: read as missing, never parsed into a throw):
                     the 5th offering version before Newest (or the oldest one); Floor = Newest -> a second
                     capture of it, role Repeat (an identity needs two captures, SV1).
           -SiblingVersion names the versions (one -> plus a Repeat); -VersionsBack n makes the floor the n-th offering
           version before Newest; -Coverage n captures Newest and the newest offering version of each of the last n
           major.minor lines (role Coverage; SV14). A type that already has rules from a sibling capture (L36) is captured at Newest only
           (their floor records still count), unless -SiblingVersion, -VersionsBack or -Coverage is given. A rule
           counts for the installer type and architecture of its floor record (an x86 capture of a project whose rules
           came from x64 captures still gets a floor); one whose floor record cannot be read counts by its
           UninstallerType and View (Wow6432 = x86).
           A scope is pinned only when the probe saw one on that version's tuple (SV20). A version probe asks a failure
           of earlier in the process again once per plan (-RetryFailed on its first probe of that version; the other
           types reuse this plan's answer). A type with no offering version whose probes failed is ProbeFailed (its
           Reason says how many manifests could not be read), not "no version offers it"; ProbeCause says what would
           help: Transient (any RateLimited, Network or Timeout read: capture again later), Permanent (only Parse,
           TooLarge, InvalidId, or NotFound for a version named with -SiblingVersion: capturing again does not change it)
           or WingetList (the winget version list failed: check winget on this computer). A NotFound version of the default walk has no
           manifest winget could install either: it counts as not offering the type. A RateLimited probe ends the
           probing of every type (the probe's gate would answer every version not in the memo RateLimited).
        4. CaptureKey = '<type>-<version>[-x86][-r]', lower-case, every character outside [a-z0-9._+-] -> '_', <= 80.
        -Architecture x86 plans the x86 siblings of an x64 package (their rules are View Wow6432, class C); every type
        lists the versions it probed as offering (Offering, newest first: the bisection of a drift picks from them).
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER SiblingInstallerType
        Only these types (nullsoft, inno, exe, burn, msi, wix, msix).
    .PARAMETER SiblingVersion
        Capture exactly these versions.
    .PARAMETER VersionsBack
        The floor is the n-th offering version before Newest (1-20).
    .PARAMETER IncludeReportOnly
        Also capture the ReportOnly types (their records are listed, never proposed).
    .PARAMETER Coverage
        Newest and the newest offering version of each of the last n major.minor lines (1-10).
    .PARAMETER Architecture
        The siblings' architecture: x86 plans the x86 siblings of an x64 package (default: the package's).
    .OUTPUTS
        [pscustomobject] Package {WingetId, Version, Architecture, InstallerType, Family}, Architecture (the siblings'),
        Backend, Request {SiblingInstallerType[], SiblingVersion[], VersionsBack, Coverage, IncludeReportOnly},
        PackageProbe {Status, Reason, RetryAfterUtc, Cause}, RetryAfterUtc (when GitHub lets this computer ask again
        after a RateLimited probe, ISO 8601 UTC; ''), Types[] {Type, EffectiveType, Class, Reason, ProbeFailed,
        ProbeCause, Captures[] {Version, Role, ReleaseDate, Scope, CaptureKey}, Offering[] {Version, ReleaseDate,
        Scope}}, ProbeFailures[], EstimatedRuns.
    .EXAMPLE
        $plan = Get-Win32ToolkitSiblingCapturePlan -ProjectPath $p
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [ValidateSet('nullsoft', 'inno', 'exe', 'burn', 'msi', 'wix', 'msix')]
        [string[]]$SiblingInstallerType,

        [string[]]$SiblingVersion,

        [ValidateRange(0, 20)]
        [int]$VersionsBack = 0,

        [switch]$IncludeReportOnly,

        [ValidateRange(0, 10)]
        [int]$Coverage = 0,

        [ValidateSet('', 'x64', 'x86')]
        [string]$Architecture = ''
    )

    $safe = { param($Value, [int]$Max = 128) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $src = Get-Win32ToolkitProjectSource -ProjectPath $ProjectPath
    $appVersion = [string]$cfg.App.Version
    $arch = ([string]$src.Architecture).ToLowerInvariant()
    if (-not $arch) { $arch = ([string]$cfg.App.Arch).ToLowerInvariant() }
    $pkgArch = $arch
    if ($Architecture) { $arch = $Architecture }
    $pkgType = ([string]$src.InstallerType).ToLowerInvariant()
    if (-not $pkgType) { $pkgType = ([string]$cfg.Installer.Type).ToLowerInvariant() }
    $pkgFamily = [string](Get-Win32ToolkitInstallerFamily -Type $pkgType).Family
    $plan = [ordered]@{
        Package       = [pscustomobject][ordered]@{ WingetId = [string]$src.WingetId; Version = $appVersion; Architecture = $pkgArch; InstallerType = $pkgType; Family = $pkgFamily }
        Architecture  = $arch
        Backend       = ''
        Request       = [pscustomobject][ordered]@{ SiblingInstallerType = [string[]]@($SiblingInstallerType | Where-Object { $_ }); SiblingVersion = [string[]]@($SiblingVersion | Where-Object { $_ })
            VersionsBack = $VersionsBack; Coverage = $Coverage; IncludeReportOnly = [bool]$IncludeReportOnly }
        PackageProbe  = $null
        RetryAfterUtc = ''
        Types         = @()
        ProbeFailures = @()
        EstimatedRuns = 0
    }
    $failures = [System.Collections.Generic.List[string]]::new()
    $keyOf = {
        param([string]$Type, [string]$Version, [bool]$Repeat)
        $k = "$Type-$Version"
        if ($arch -eq 'x86') { $k += '-x86' }
        if ($Repeat) { $k += '-r' }
        $k = ($k.ToLowerInvariant() -replace '[^a-z0-9._+-]', '_')
        if ($k.Length -gt 80) { $k = $k.Substring(0, 80) }
        $k
    }
    $regType = { param([string]$t) if ($t -in @('msi', 'wix')) { 'msi' } else { $t } }
    $lineOf = { param([string]$V) $k = ConvertTo-Win32ToolkitPriorVersion -Text $V; if ($k) { "$($k.Major).$($k.Minor)" } else { $V } }
    # A release date (untrusted manifest data) as a [datetime], or $null when it is not a real yyyy-MM-dd day: a
    # pattern-valid impossible date (2025-02-30) counts as missing (the count rule), never a FormatException.
    $dateOf = {
        param([string]$Text)
        $d = [datetime]::MinValue
        if ($Text -match '^\d{4}-\d{2}-\d{2}$' -and [datetime]::TryParseExact($Text, 'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { $d } else { $null }
    }

    # What a failed manifest read means for the advice: a transient one may succeed later; any other never will.
    $transient = @('RateLimited', 'Network', 'Timeout')
    $probe = Get-Win32ToolkitSiblingInstaller -WingetId ([string]$src.WingetId) -Version $appVersion -Architecture $arch -PackagedType $pkgType -RetryFailed
    $plan.PackageProbe = [pscustomobject][ordered]@{ Status = [string]$probe.Status; Reason = [string]$probe.Reason; RetryAfterUtc = [string]$probe.RetryAfterUtc
        Cause = $(if ($probe.Status -eq 'Ok') { '' } elseif ([string]$probe.Reason -in $transient) { 'Transient' } else { 'Permanent' }) }
    $plan.RetryAfterUtc = [string]$probe.RetryAfterUtc
    if ($probe.Status -ne 'Ok') {
        $failures.Add("the package version's winget manifest could not be read ($($probe.Reason))")
        $plan.ProbeFailures = [string[]]$failures.ToArray()
        return [pscustomobject]$plan
    }

    # ---- types and classes ----
    $types = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($t in @(@($probe.Siblings) + @($probe.SameFamilyOther) + @($probe.NotRegistering))) {
        if ($null -eq $t) { continue }
        # The one classification (shared with the winget wizard's capture question).
        $c = Get-Win32ToolkitSiblingCaptureClass -Sibling $t
        if ($seen.ContainsKey($c.Key)) { continue }
        $seen[$c.Key] = $true
        $types.Add([ordered]@{ Type = $c.Type; EffectiveType = $c.EffectiveType; Class = $c.Class; Reason = $c.Reason; SameFamily = ([string]$t.Family -eq $pkgFamily); ProbeFailed = $false; ProbeCause = ''; Captures = @(); Offering = @() })
    }
    if ($SiblingInstallerType) {
        $wanted = @($SiblingInstallerType | ForEach-Object { & $regType $_.ToLowerInvariant() })
        $types = [System.Collections.Generic.List[object]]@($types | Where-Object { $wanted -contains (& $regType $_.Type) })
    }

    # ---- versions ----
    $capturable = @($types | Where-Object { $_.Class -eq 'RemovableNow' -or ($IncludeReportOnly -and $_.Class -eq 'ReportOnly') })
    $allVersions = @()
    $versionsFailed = $false
    if ($capturable.Count -gt 0) {
        try { $allVersions = @(Get-WingetVersions -AppId ([string]$src.WingetId)) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $versionsFailed = $true
            $failures.Add("the winget versions could not be listed ($(& $safe $_.Exception.Message 200))")
        }
    }
    $pkgKey = ConvertTo-Win32ToolkitPriorVersion -Text $appVersion
    $cutoff = (Get-Date).Date.AddDays(-365)
    $carried = @()
    if ($cfg.PSObject.Properties['PriorInstalls'] -and $cfg.PriorInstalls -and $cfg.PriorInstalls.PSObject.Properties['Entries']) {
        $carried = @(@($cfg.PriorInstalls.Entries) | Where-Object { $null -ne $_ -and ([string]$_.Source -ceq 'SiblingCapture' -or [string]$_.CaptureId) })
    }
    # The technologies that already have rules from a sibling capture (L36), per sibling architecture: a rule counts for
    # the installer type and architecture its floor capture recorded (its CaptureId record), so an x86 capture of a
    # project with rules from x64 captures still gets a floor, and an 'exe' sibling whose rule names the NSIS uninstaller
    # counts as 'exe'. A rule whose floor record cannot be read counts by its uninstaller technology and the architecture
    # whose installer writes its registry view on the 64-bit test VM (Wow6432 -> x86).
    $carriedKeys = @{}
    if ($carried.Count -gt 0) {
        $floorIds = [string[]]@($carried | ForEach-Object { [string]$_.CaptureId } | Where-Object { $_ -cmatch '^[a-f0-9]{16}$' } | Select-Object -Unique)
        $floors = @{}
        if ($floorIds.Count -gt 0) { foreach ($r in @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath -CaptureId $floorIds)) { $floors[[string]$r.CaptureId] = $r } }
        foreach ($e in $carried) {
            $r = if ([string]$e.CaptureId) { $floors[[string]$e.CaptureId] } else { $null }
            if ($null -ne $r) { $cType = ([string]$r.Sibling.InstallerType).ToLowerInvariant(); $cArch = ([string]$r.Sibling.Architecture).ToLowerInvariant() }
            else { $cType = ([string]$e.UninstallerType).ToLowerInvariant(); $cArch = if ([string]$e.View -ceq 'Wow6432') { 'x86' } else { 'x64' } }
            $carriedKeys["$(& $regType $cType)|$cArch"] = $true
        }
    }
    $rateLimited = $false
    $askedVersions = @{}   # versions this plan asked: a memoised failure is asked again once per plan, not once per type
    foreach ($ty in $capturable) {
        $offering = [System.Collections.Generic.List[object]]::new()
        $missingDate = $false
        $probes = 0
        $failedReads = [System.Collections.Generic.List[string]]::new()   # the Reason of every probe of this type that failed
        $notAsked = $false                                                # GitHub limited this computer before this type
        $candidates = @($allVersions | Where-Object {
                $k = ConvertTo-Win32ToolkitPriorVersion -Text ([string]$_)
                $null -ne $k -and $null -ne $pkgKey -and ($(if ($ty.SameFamily) { $k -lt $pkgKey } else { $k -le $pkgKey }))
            })
        if ($SiblingVersion) { $candidates = @($SiblingVersion | Where-Object { $_ } | Sort-Object -Unique | Sort-Object -Descending -Property { $k = ConvertTo-Win32ToolkitPriorVersion -Text ([string]$_); if ($k) { $k } else { [version]'0.0' } }) }
        foreach ($v in $candidates) {
            if ($probes -ge 40) { break }
            # After a RateLimited probe no further version is asked: the probe's gate would answer every one that is not
            # in the memo RateLimited.
            if ($rateLimited) {
                if ($probes -eq 0) { $notAsked = $true; $failures.Add("$($ty.Type): its versions were not checked (RateLimited)") }
                break
            }
            $probes++
            # An explicit plan asks a failure of earlier in the process again (like the package probe), once per version:
            # the other types reuse this plan's answer from the memo. The rate-limit gate still applies.
            $retry = -not $askedVersions.ContainsKey([string]$v); $askedVersions[[string]$v] = $true
            $p = Get-Win32ToolkitSiblingInstaller -WingetId ([string]$src.WingetId) -Version ([string]$v) -Architecture $arch -RetryFailed:$retry
            if ($p.Status -ne 'Ok') {
                # A version winget-pkgs has no manifest for (NotFound) cannot be installed by winget either: in the default
                # walk it does not offer the type; a version named with -SiblingVersion is a failed check.
                if ([string]$p.Reason -ne 'NotFound' -or $SiblingVersion) { $failedReads.Add([string]$p.Reason) }
                if ([string]$p.Reason -eq 'RateLimited') {
                    $rateLimited = $true
                    $plan.RetryAfterUtc = [string]$p.RetryAfterUtc
                    $failures.Add("$($ty.Type) $(& $safe $v 64): the manifest could not be read (RateLimited); no further version was checked")
                }
                else { $failures.Add("$($ty.Type) $(& $safe $v 64): the manifest could not be read ($($p.Reason))") }
                continue
            }
            $tuple = @(@($p.Tuples) | Where-Object { (& $regType ([string]$_.EffectiveType)) -eq (& $regType $ty.Type) -and -not $_.ZipWrapped -and ($_.Architecture -eq $arch -or $_.Architecture -eq 'neutral') }) | Select-Object -First 1
            if (-not $tuple) { continue }
            # The tuple's own date, else the version's (root) date; the first that is a real day. None -> no date.
            $date = ''; $dt = $null
            foreach ($cand in @([string]$tuple.ReleaseDate, [string]$p.ReleaseDate)) {
                $dt = & $dateOf $cand
                if ($null -ne $dt) { $date = $cand; break }
            }
            if ($null -eq $dt) { $missingDate = $true }
            $offering.Add([pscustomobject]@{ Version = [string]$v; ReleaseDate = $date; Scope = [string]$tuple.Scope })
            # Enough is known: a version older than the 12-month window (all dates known), or six offering versions
            # when a date is missing (the count rule), or the explicit back count.
            if (-not $SiblingVersion) {
                if ($VersionsBack -gt 0) { if ($offering.Count -gt $VersionsBack) { break } }
                elseif ($Coverage -gt 0) { if (@($offering | ForEach-Object { & $lineOf $_.Version } | Sort-Object -Unique).Count -gt $Coverage) { break } }
                elseif ($missingDate) { if ($offering.Count -ge 6) { break } }
                elseif ($null -ne $dt -and $dt -lt $cutoff) { break }
            }
        }
        if ($offering.Count -eq 0) {
            # Live rows RAISE, INNO: a type whose versions could not be read is not "offered by no version".
            $cause = ''
            $why = if ($failedReads.Count -gt 0) {
                # One transient failure (or the RateLimited stop) left a version unread that may still offer the type, so
                # capturing again can help: Permanent only when every failed read is permanent.
                $cause = if (@($failedReads | Where-Object { $_ -in $transient }).Count -gt 0) { 'Transient' } else { 'Permanent' }
                "its versions could not be checked: $($failedReads.Count) winget manifest(s) could not be read ($((@($failedReads) | Select-Object -Unique) -join ', '))"
            }
            elseif ($notAsked) { $cause = 'Transient'; 'its versions were not checked: GitHub limits requests from this computer (RateLimited)' }
            elseif ($versionsFailed -and -not $SiblingVersion) { $cause = 'WingetList'; 'its versions could not be checked: the winget versions could not be listed' }
            else { '' }
            if ($why) { $ty.ProbeFailed = $true; $ty.ProbeCause = $cause } else { $why = 'no version at or below the package version offers it for this architecture' }
            $ty.Reason = (@($ty.Reason, $why) | Where-Object { $_ }) -join '; '
            continue
        }
        $newest = $offering[0]
        $caps = [System.Collections.Generic.List[object]]::new()
        $add = { param($O, [string]$Role) $caps.Add([pscustomobject][ordered]@{ Version = $O.Version; Role = $Role; ReleaseDate = $O.ReleaseDate; Scope = $O.Scope; CaptureKey = (& $keyOf $ty.Type $O.Version ($Role -eq 'Repeat')) }) }
        $isCarried = $carriedKeys.ContainsKey("$(& $regType ([string]$ty.Type))|$arch")
        $ty.Offering = @($offering.ToArray())
        if ($SiblingVersion) {
            & $add $newest 'Newest'
            if ($offering.Count -eq 1) { & $add $newest 'Repeat' }
            else {
                for ($i = 1; $i -lt $offering.Count - 1; $i++) { & $add $offering[$i] 'Extra' }
                & $add $offering[$offering.Count - 1] 'Floor'
            }
        }
        elseif ($isCarried -and $VersionsBack -eq 0 -and $Coverage -eq 0) { & $add $newest 'Newest' }
        elseif ($Coverage -gt 0) {
            & $add $newest 'Newest'
            $lines = @{ (& $lineOf $newest.Version) = $true }
            foreach ($o in @($offering | Select-Object -Skip 1)) {
                $ln = & $lineOf $o.Version
                if (-not $lines.ContainsKey($ln) -and $lines.Count -lt $Coverage) { $lines[$ln] = $true; & $add $o 'Coverage' }
            }
            if ($caps.Count -eq 1) { & $add $newest 'Repeat' }
        }
        else {
            $floor = $null
            if ($VersionsBack -gt 0) { $floor = $offering[[Math]::Min($VersionsBack, $offering.Count - 1)] }
            elseif ($missingDate) { $floor = $offering[[Math]::Min(5, $offering.Count - 1)] }
            else {
                $inWindow = @($offering | Where-Object { $od = & $dateOf ([string]$_.ReleaseDate); $null -ne $od -and $od -ge $cutoff })
                $floor = if ($inWindow.Count -gt 0) { $inWindow[-1] } else { $newest }
            }
            & $add $newest 'Newest'
            if ($floor.Version -eq $newest.Version) { & $add $newest 'Repeat' } else { & $add $floor 'Floor' }
        }
        $ty.Captures = @($caps.ToArray())
    }
    $plan.Types = @($types | ForEach-Object { [pscustomobject]$_ })
    $plan.ProbeFailures = [string[]]$failures.ToArray()
    $plan.EstimatedRuns = @($plan.Types | ForEach-Object { @($_.Captures).Count } | Measure-Object -Sum).Sum
    if ($null -eq $plan.EstimatedRuns) { $plan.EstimatedRuns = 0 }
    return [pscustomobject]$plan
}
