function Get-Win32ToolkitSiblingCapturePlan {
    <#
    .SYNOPSIS
        Plans which other installer technologies of an app to capture, at which versions.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.2; SV21, SV24, SV29, SV34, D60, L32, L36). Read-only; every winget GET is
        fail-open (a failed one skips that version and is listed in ProbeFailures).

        1. The package version's sibling probe (Get-Win32ToolkitSiblingInstaller): the other families (Siblings) and the
           same family's other registration types (SameFamilyOther), by EffectiveType. msi and wix are one registration
           type; nullsoft, inno, burn and exe stay separate. The not-registering tuples (zip/portable) are listed too.
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
           version before Newest. A type that already has rules from a sibling capture (L36) is captured at Newest only
           (their floor records still count), unless -SiblingVersion or -VersionsBack is given.
           A scope is pinned only when the probe saw one on that version's tuple (SV20).
        4. CaptureKey = '<type>-<version>[-x86][-r]', lower-case, every character outside [a-z0-9._+-] -> '_', <= 80.
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
    .OUTPUTS
        [pscustomobject] Package {WingetId, Version, Architecture, InstallerType, Family}, Backend, Types[] {Type,
        EffectiveType, Class, Reason, Captures[] {Version, Role, ReleaseDate, Scope, CaptureKey}}, ProbeFailures[],
        EstimatedRuns.
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

        [switch]$IncludeReportOnly
    )

    $safe = { param($Value, [int]$Max = 128) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $src = Get-Win32ToolkitProjectSource -ProjectPath $ProjectPath
    $appVersion = [string]$cfg.App.Version
    $arch = ([string]$src.Architecture).ToLowerInvariant()
    if (-not $arch) { $arch = ([string]$cfg.App.Arch).ToLowerInvariant() }
    $pkgType = ([string]$src.InstallerType).ToLowerInvariant()
    if (-not $pkgType) { $pkgType = ([string]$cfg.Installer.Type).ToLowerInvariant() }
    $pkgFamily = [string](Get-Win32ToolkitInstallerFamily -Type $pkgType).Family
    $plan = [ordered]@{
        Package       = [pscustomobject][ordered]@{ WingetId = [string]$src.WingetId; Version = $appVersion; Architecture = $arch; InstallerType = $pkgType; Family = $pkgFamily }
        Backend       = ''
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
    # A release date (untrusted manifest data) as a [datetime], or $null when it is not a real yyyy-MM-dd day: a
    # pattern-valid impossible date (2025-02-30) counts as missing (the count rule), never a FormatException.
    $dateOf = {
        param([string]$Text)
        $d = [datetime]::MinValue
        if ($Text -match '^\d{4}-\d{2}-\d{2}$' -and [datetime]::TryParseExact($Text, 'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { $d } else { $null }
    }

    $probe = Get-Win32ToolkitSiblingInstaller -WingetId ([string]$src.WingetId) -Version $appVersion -Architecture $arch -PackagedType $pkgType
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
        $types.Add([ordered]@{ Type = $c.Type; EffectiveType = $c.EffectiveType; Class = $c.Class; Reason = $c.Reason; SameFamily = ([string]$t.Family -eq $pkgFamily); Captures = @() })
    }
    if ($SiblingInstallerType) {
        $wanted = @($SiblingInstallerType | ForEach-Object { & $regType $_.ToLowerInvariant() })
        $types = [System.Collections.Generic.List[object]]@($types | Where-Object { $wanted -contains (& $regType $_.Type) })
    }

    # ---- versions ----
    $capturable = @($types | Where-Object { $_.Class -eq 'RemovableNow' -or ($IncludeReportOnly -and $_.Class -eq 'ReportOnly') })
    $allVersions = @()
    if ($capturable.Count -gt 0) {
        try { $allVersions = @(Get-WingetVersions -AppId ([string]$src.WingetId)) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $failures.Add("the winget versions could not be listed ($(& $safe $_.Exception.Message 200))")
        }
    }
    $pkgKey = ConvertTo-Win32ToolkitPriorVersion -Text $appVersion
    $cutoff = (Get-Date).Date.AddDays(-365)
    $carried = @()
    if ($cfg.PSObject.Properties['PriorInstalls'] -and $cfg.PriorInstalls -and $cfg.PriorInstalls.PSObject.Properties['Entries']) {
        $carried = @(@($cfg.PriorInstalls.Entries) | Where-Object { $null -ne $_ -and ([string]$_.Source -ceq 'SiblingCapture' -or [string]$_.CaptureId) })
    }
    foreach ($ty in $capturable) {
        $offering = [System.Collections.Generic.List[object]]::new()
        $missingDate = $false
        $probes = 0
        $candidates = @($allVersions | Where-Object {
                $k = ConvertTo-Win32ToolkitPriorVersion -Text ([string]$_)
                $null -ne $k -and $null -ne $pkgKey -and ($(if ($ty.SameFamily) { $k -lt $pkgKey } else { $k -le $pkgKey }))
            })
        if ($SiblingVersion) { $candidates = @($SiblingVersion | Where-Object { $_ } | Sort-Object -Unique | Sort-Object -Descending -Property { $k = ConvertTo-Win32ToolkitPriorVersion -Text ([string]$_); if ($k) { $k } else { [version]'0.0' } }) }
        foreach ($v in $candidates) {
            if ($probes -ge 40) { break }
            $probes++
            $p = Get-Win32ToolkitSiblingInstaller -WingetId ([string]$src.WingetId) -Version ([string]$v) -Architecture $arch
            if ($p.Status -ne 'Ok') { $failures.Add("$($ty.Type) $(& $safe $v 64): the manifest could not be read ($($p.Reason))"); continue }
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
                elseif ($missingDate) { if ($offering.Count -ge 6) { break } }
                elseif ($null -ne $dt -and $dt -lt $cutoff) { break }
            }
        }
        if ($offering.Count -eq 0) { $ty.Reason = (@($ty.Reason, 'no version at or below the package version offers it for this architecture') | Where-Object { $_ }) -join '; '; continue }
        $newest = $offering[0]
        $caps = [System.Collections.Generic.List[object]]::new()
        $add = { param($O, [string]$Role) $caps.Add([pscustomobject][ordered]@{ Version = $O.Version; Role = $Role; ReleaseDate = $O.ReleaseDate; Scope = $O.Scope; CaptureKey = (& $keyOf $ty.Type $O.Version ($Role -eq 'Repeat')) }) }
        $isCarried = @($carried | Where-Object { (& $regType ([string]$_.UninstallerType)) -eq (& $regType $ty.Type) }).Count -gt 0
        if ($SiblingVersion) {
            & $add $newest 'Newest'
            if ($offering.Count -eq 1) { & $add $newest 'Repeat' }
            else {
                for ($i = 1; $i -lt $offering.Count - 1; $i++) { & $add $offering[$i] 'Extra' }
                & $add $offering[$offering.Count - 1] 'Floor'
            }
        }
        elseif ($isCarried -and $VersionsBack -eq 0) { & $add $newest 'Newest' }
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
