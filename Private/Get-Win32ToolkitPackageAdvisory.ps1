function Get-Win32ToolkitPackageAdvisory {
    <#
    .SYNOPSIS
        Collects the warnings to show before a package is exported or published: failed Update tests,
        technology switches, identity checks and unsafe uninstall cleanup paths.
    .DESCRIPTION
        Installer-identity PR 1, spec 2.13 (D1: warn only, never block). Read-only: it never writes a file
        and never throws; an unexpected error becomes one Warning finding 'Could not check the Update test
        and identity warnings: ...'.

        Update findings (Documentation\TestResults.json, Scenario Update), one per baseline family: the
        latest judged record of each Baseline.Family. A record marked Baseline.Unavailable (the baseline
        technology could not be downloaded) is never judged, so it cannot hide an older failure. A record
        written before baselines were recorded (no Baseline) counts only when it is the newest judged
        Update record; its family comes from Sandbox\OldVersion when that manifest is the version the
        generated Sandbox\UpdateAssertions.ps1 expected and the run used a winget baseline (else unknown).
          UPDATE-FAILED        Warning  the latest record of a family failed (names the failed assertions and the
                                        run's own log folder, Sandbox\Logs\Runs\<run>, when the record has one)
          UPDATE-INCONCLUSIVE  Info     the latest record of a family has no verdict
          ID-TECH-SWITCH       Warning  every Get-Win32ToolkitTechnologySwitch result

        Identity findings: Get-Win32ToolkitIdentityDelta -ReuseProbe re-evaluated in memory (a fresh
        predecessor lookup, the probe stored in Documentation\IdentityDelta.json), plus -NoProbe unless
        -ProbeIfMissing. On top of them:
          ID-SIBLING-UNTESTED  Warning  winget ships another testable technology and the latest judged
                                        Update test from it did not pass (or there is none); when the latest
                                        one of every such family passed, ID-SIBLING-FAMILY becomes Info.

        Cleanup (-Context Publish and Tui only; at Export the package check already refuses them):
          UNSAFE-CLEANUP       Warning  Get-Win32ToolkitCleanupPathFinding reports an unsafe cleanup path
                                        or install root (a package exported before the check carries it),
                                        or SupportFiles\AppConfig.json could not be read, so the cleanup
                                        paths could not be checked (Windows PowerShell 5.1 on the device
                                        may still read it).

        Order: UNSAFE-CLEANUP, UPDATE-FAILED, ID-TECH-SWITCH, ID-FAMILY, ID-SIBLING-UNTESTED,
        ID-SIBLING-FAMILY, ID-NO-ANCHOR, ID-TATTOO, ID-SCOPE, ID-PROBE-UNAVAILABLE,
        ID-PREDECESSOR-AMBIGUOUS, other warnings, then every Info finding. Every untrusted value passes
        ConvertTo-Win32ToolkitSafeText.
    .PARAMETER ProjectPath
        The PSADT project folder (Projects\<Template>\<App>).
    .PARAMETER Context
        Export, Publish (default) or Tui: Export leaves out UNSAFE-CLEANUP and words UPDATE-FAILED for
        packaging.
    .PARAMETER ProbeIfMissing
        Allow one sibling-probe request when no matching probe is stored (memoised per process).
    .OUTPUTS
        [pscustomobject] SchemaVersion, PackageType, PackageFamily, Update (BaselineFamily, BaselineType,
        BaselineVersion, Verdict, FailedAssertions, TimestampUtc, Backend, Mode, Legacy, LogFolder), Findings (Code,
        Severity, Source = UpdateTest|IdentityDelta|AppConfig, Message).
    .EXAMPLE
        (Get-Win32ToolkitPackageAdvisory -ProjectPath $proj -Context Publish -ProbeIfMissing).Findings
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [ValidateSet('Export', 'Publish', 'Tui')]
        [string]$Context = 'Publish',

        [switch]$ProbeIfMissing
    )

    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $prop = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } return $null }
        if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
        return $null
    }
    $unquote = {
        param([string]$Value)
        $v = ([string]$Value -replace '\s+#.*$', '').Trim()
        if ($v.Length -ge 2 -and $v[0] -eq "'" -and $v[-1] -eq "'") { $v = $v.Substring(1, $v.Length - 2).Replace("''", "'") }
        elseif ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[-1] -eq '"') { $v = $v.Substring(1, $v.Length - 2) }
        $v
    }
    # ConvertFrom-Json turns an ISO timestamp into [datetime]; both forms give a UTC instant (or $null).
    $instant = {
        param($Value)
        if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
        $parsed = [datetime]::MinValue
        if ($Value -and [datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) { return $parsed }
        return $null
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Code, [string]$Severity, [string]$Source, [string]$Message)
        $findings.Add([pscustomobject]@{ Code = $Code; Severity = $Severity; Source = $Source; Message = $Message })
    }
    $failOpen = {
        param([string]$Source, $ErrorRecord)
        & $add 'ADVISORY-UNAVAILABLE' 'Warning' $Source ('Could not check the Update test and identity warnings: {0}' -f (& $safe $ErrorRecord.Exception.Message 512))
    }

    # ---- The packaged technology ----
    $packageType = ''; $packageFamily = ''
    try {
        $src = Get-Win32ToolkitProjectSource -ProjectPath $ProjectPath
        $packageType   = & $safe (& $prop $src 'InstallerType') 32
        $packageFamily = & $safe (& $prop $src 'Family') 32
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        & $failOpen 'UpdateTest' $_
    }

    # ---- A pre-PR-1 Update record: its baseline from Sandbox\OldVersion (spec 2.12 legacy rule, L5) ----
    $legacyBaseline = {
        param($Record)
        $none = @{ Type = ''; Family = ''; Version = '' }
        $names = @(@(& $prop $Record 'Assertions') | ForEach-Object { [string](& $prop $_ 'Name') })
        if ($names -contains 'TattooBaseline-PreUpdate') {
            Write-Verbose 'Package advisory: the legacy Update record used a project baseline; its technology is unknown.'
            return $none
        }
        $assertFile = Join-Path $ProjectPath 'Sandbox\UpdateAssertions.ps1'
        if (-not (Test-Path -LiteralPath $assertFile)) { return $none }
        # Data only: the generated assertion script is read as text, never executed.
        # [string]: Get-Content -Raw returns $null for an empty file.
        $match = [regex]::Match([string](Get-Content -LiteralPath $assertFile -Raw -Encoding UTF8), '(?m)^\$expectedOldVersion = ''((?:[^'']|'''')*)''')
        if (-not $match.Success) { return $none }
        $expected = $match.Groups[1].Value.Replace("''", "'")
        $manifest = Get-WingetManifestFile -Path (Join-Path $ProjectPath 'Sandbox\OldVersion') -Kind Installer
        if (-not $manifest) { return $none }
        $yaml = [string](Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8)
        $read = {
            param([string]$Key)
            $m = [regex]::Match($yaml, "(?m)^\s*-?\s*$Key\s*:[ \t]*(\S.*?)\s*$")
            if ($m.Success) { & $unquote $m.Groups[1].Value } else { '' }
        }
        $version = & $read 'PackageVersion'
        if (-not $version -or -not [string]::Equals($version, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Verbose 'Package advisory: Sandbox\OldVersion does not hold the version of the legacy Update record; its technology is unknown.'
            return $none
        }
        $row = Get-Win32ToolkitInstallerFamily -Type (& $read 'InstallerType') -NestedType (& $read 'NestedInstallerType')
        $family = if ($row.Family -eq 'other' -and -not $row.EffectiveType) { '' } else { $row.Family }
        return @{ Type = $row.EffectiveType; Family = $family; Version = $version }
    }

    # The run's own log folder (Sandbox\Logs\Runs\<run>, test campaign F2). The record is data: only that shape is used.
    $logFolder = {
        param($Record)
        $rel = & $safe (& $prop $Record 'LogFolder') 256
        if ($rel -match '^Sandbox\\Logs\\Runs\\[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$' -and $rel -notmatch '\.\.') { $rel } else { '' }
    }

    # ---- Update records: the judged ones, then the latest per baseline family ----
    $judged = [System.Collections.Generic.List[object]]::new()
    try {
        $records = Get-Win32ToolkitTestResult -ProjectPath $ProjectPath
        $candidates = @(@($records) | Where-Object {
                $_ -and [string](& $prop $_ 'Scenario') -eq 'Update' -and -not [bool](& $prop (& $prop $_ 'Baseline') 'Unavailable')
            })
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $r = $candidates[$i]
            $b = & $prop $r 'Baseline'
            if ($null -ne $b) {
                $base = @{ Type = [string](& $prop $b 'InstallerType'); Family = [string](& $prop $b 'Family'); Version = [string](& $prop $b 'Version') }
                if (-not $base.Family -and $base.Type) { $base.Family = (Get-Win32ToolkitInstallerFamily -Type $base.Type).Family }
                $legacy = $false
            } elseif ($i -eq $candidates.Count - 1) {
                # The lookup only names the technology: when it fails, the record is still judged (D1)
                # with an unknown technology.
                try {
                    $base = & $legacyBaseline $r
                } catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    Write-Verbose ('Package advisory: could not read the baseline of the legacy Update record; its technology is unknown: {0}' -f (& $safe $_.Exception.Message 512))
                    $base = @{ Type = ''; Family = ''; Version = '' }
                }
                $legacy = $true
            } else {
                continue
            }
            $when = & $instant (& $prop $r 'TimestampUtc')
            $judged.Add([pscustomobject]@{
                    BaselineFamily   = (& $safe $base.Family 32).ToLowerInvariant()
                    BaselineType     = (& $safe $base.Type 32).ToLowerInvariant()
                    BaselineVersion  = & $safe $base.Version 128
                    Verdict          = & $safe (& $prop $r 'Verdict') 32
                    FailedAssertions = [string[]]@(@(& $prop $r 'Assertions') | Where-Object { $_ -and [string](& $prop $_ 'Result') -eq 'FAIL' } |
                            ForEach-Object { & $safe (& $prop $_ 'Name') 128 })
                    TimestampUtc     = if ($when) { $when.ToString('o') } else { '' }
                    Backend          = & $safe (& $prop $r 'Backend') 32
                    Mode             = & $safe (& $prop $r 'Mode') 32
                    Legacy           = $legacy
                    LogFolder        = & $logFolder $r
                    Date             = if ($when) { $when.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
                })
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        & $failOpen 'UpdateTest' $_
    }
    $latest = [ordered]@{}
    foreach ($j in $judged) { $latest[$j.BaselineFamily] = $j }

    $technology = {
        param($Entry)
        if ($Entry.BaselineType) { return (Get-Win32ToolkitInstallerFamily -Type $Entry.BaselineType).Label }
        if ($Entry.BaselineFamily) { return "$($Entry.BaselineFamily) family" }
        return ''
    }
    $runText = {
        param($Entry)
        $label = & $technology $Entry
        $with  = if ($label -match '^[aeiou]') { " with an $label baseline" } elseif ($label) { " with a $label baseline" } else { '' }
        $where = [System.Collections.Generic.List[string]]::new()
        if ($Entry.BaselineVersion) { $where.Add("v$($Entry.BaselineVersion)") }
        if ($Entry.Backend -or $Entry.Mode) { $where.Add("$($Entry.Backend)/$($Entry.Mode)") }
        if ($Entry.Date) { $where.Add($Entry.Date) }
        $at = if ($where.Count) { ' ({0})' -f ($where -join ', ') } else { '' }
        "The latest Update test$with$at"
    }
    $continues = if ($Context -eq 'Export') { 'the package is still packaged' } else { 'publishing continues' }
    foreach ($entry in $latest.Values) {
        if ($entry.Verdict -eq 'Failed') {
            $names = if ($entry.FailedAssertions.Count) { $entry.FailedAssertions -join ', ' } else { 'no failed assertion was recorded' }
            $review = if ($entry.LogFolder) { '{0}\UpdateAssertions.log' -f $entry.LogFolder } else { 'Sandbox\Logs\UpdateAssertions.log' }
            & $add 'UPDATE-FAILED' 'Warning' 'UpdateTest' ('{0} FAILED: {1}. This only warns: {2}. Review {3} before you assign it.' -f (& $runText $entry), $names, $continues, $review)
        } elseif ($entry.Verdict -eq 'Inconclusive') {
            & $add 'UPDATE-INCONCLUSIVE' 'Info' 'UpdateTest' ('{0} gave no verdict (Inconclusive). Run it again to confirm that devices with the earlier version update cleanly.' -f (& $runText $entry))
        }
    }

    # ---- Technology switches seen by the Update tests ----
    try {
        $switchArgs = @{ ProjectPath = $ProjectPath }
        if ($packageType) { $switchArgs.PackageType = $packageType }
        if ($packageFamily) { $switchArgs.PackageFamily = $packageFamily }
        foreach ($s in @(Get-Win32ToolkitTechnologySwitch @switchArgs)) {
            if (-not $s) { continue }
            & $add 'ID-TECH-SWITCH' 'Warning' 'UpdateTest' (& $safe (& $prop $s 'Message') 2048)
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        & $failOpen 'UpdateTest' $_
    }

    # ---- Identity checks (in memory; the stored probe is reused, no file is written, L6) ----
    $delta = $null
    try {
        $deltaArgs = @{ ProjectPath = $ProjectPath; ReuseProbe = $true }
        if (-not $ProbeIfMissing) { $deltaArgs.NoProbe = $true }
        $delta = Get-Win32ToolkitIdentityDelta @deltaArgs
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        & $failOpen 'IdentityDelta' $_
    }
    if ($delta) {
        $siblingFinding = $null
        foreach ($f in @(& $prop $delta 'Findings')) {
            if (-not $f) { continue }
            $code = & $safe (& $prop $f 'Code') 64
            $severity = if ([string](& $prop $f 'Severity') -eq 'Warning') { 'Warning' } else { 'Info' }
            $item = [pscustomobject]@{ Code = $code; Severity = $severity; Source = 'IdentityDelta'; Message = & $safe (& $prop $f 'Message') 2048 }
            $findings.Add($item)
            if ($code -eq 'ID-SIBLING-FAMILY') { $siblingFinding = $item }
        }
        if ($siblingFinding) {
            $testable = @(@(& $prop $delta 'Siblings') | Where-Object { $_ -and (& $prop $_ 'Testable') -and (& $prop $_ 'Registers') })
            $families = @($testable | ForEach-Object { ([string](& $prop $_ 'Family')).ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
            $tested = [System.Collections.Generic.List[string]]::new()
            $project = (& $safe $ProjectPath 1024).Replace("'", "''")
            foreach ($family in $families) {
                # Tested = the LATEST judged record of the family passed (as for UPDATE-FAILED): an older
                # pass never outweighs a newer failure.
                $latestRun = $latest[$family]
                if ($latestRun -and $latestRun.Verdict -eq 'Passed') {
                    $tested.Add($(if ($latestRun.Date) { 'Update from {0} passed on {1}' -f $family, $latestRun.Date } else { 'Update from {0} passed' -f $family }))
                    continue
                }
                $labels = @($testable | Where-Object { ([string](& $prop $_ 'Family')).ToLowerInvariant() -eq $family } |
                        ForEach-Object { & $safe (& $prop $_ 'Label') 128 } | Where-Object { $_ } | Select-Object -Unique)
                $label = if ($labels.Count) { $labels -join ' and ' } else { $family }
                $article = if ($family -match '^[aeiou]') { 'an' } else { 'a' }
                & $add 'ID-SIBLING-UNTESTED' 'Warning' 'IdentityDelta' (("winget also ships {0}, but no Update test has passed from {1} {2} install. Run: Test-Win32ToolkitProject -ProjectPath '{3}' " +
                        '-Scenario Update -BaselineInstallerType Both') -f $label, $article, (& $safe $family 32), $project)
            }
            if ($families.Count -gt 0 -and $tested.Count -eq $families.Count) {
                $siblingFinding.Severity = 'Info'
                $siblingFinding.Message  = '{0} (tested: {1})' -f $siblingFinding.Message, ($tested -join '; ')
            }
        }
    }

    # ---- Uninstall cleanup paths of a package exported before the check (L22; Export already refuses them) ----
    if ($Context -ne 'Export') {
        try {
            $cleanup = @(Get-Win32ToolkitCleanupPathFinding -ProjectPath $ProjectPath | Where-Object { $_ })
            $unsafe = @($cleanup | Where-Object { [string](& $prop $_ 'Kind') -eq 'CleanupPath' })
            if ($unsafe.Count -eq 0) { $unsafe = @($cleanup | Where-Object { [string](& $prop $_ 'Kind') -eq 'InstallRoot' }) }
            if ($unsafe.Count) {
                $first = $unsafe[0]
                $path  = & $safe (& $prop $first 'Path') 512
                $why   = & $safe (& $prop $first 'Explanation') 512
                if (-not $why) { $why = & $safe ((@(& $prop $first 'Reasons') | Where-Object { $_ }) -join ', ') 256 }
                & $add 'UNSAFE-CLEANUP' 'Warning' 'AppConfig' (("UNSAFE-CLEANUP: this project's uninstall would delete {0} folder(s) outside the app's own install folder as SYSTEM " +
                        "(first: '{1}' - {2}). A package exported before this check carries them: re-export it (Export refuses it until the paths " +
                        'are fixed: re-run the install capture) before you publish.') -f $unsafe.Count, $path, $why)
            }
            else {
                # An AppConfig.json PowerShell 7 cannot read is no all-clear: Windows PowerShell 5.1 on the device
                # may still read it and delete its cleanup paths, which nobody checked (Export refuses it too).
                $unreadable = @($cleanup | Where-Object { [string](& $prop $_ 'Kind') -eq 'Unreadable' }) | Select-Object -First 1
                if ($unreadable) {
                    $why = & $safe (& $prop $unreadable 'Explanation') 512
                    if (-not $why) { $why = 'unknown error' }
                    & $add 'UNSAFE-CLEANUP' 'Warning' 'AppConfig' (("UNSAFE-CLEANUP: this project's uninstall cleanup paths could not be checked: SupportFiles\AppConfig.json could not be read ({0}). " +
                            'Windows PowerShell 5.1 on the device may still read it and delete them as SYSTEM. A package exported before this check carries them: ' +
                            'fix the file (or re-create the project), re-export it (Export refuses it until the file can be read) before you publish.') -f $why)
                }
            }
        } catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            & $failOpen 'AppConfig' $_
        }
    }

    $rank = @{
        'UNSAFE-CLEANUP' = 0; 'UPDATE-FAILED' = 1; 'ID-TECH-SWITCH' = 2; 'ID-FAMILY' = 3; 'ID-SIBLING-UNTESTED' = 4
        'ID-SIBLING-FAMILY' = 5; 'ID-NO-ANCHOR' = 6; 'ID-TATTOO' = 7; 'ID-SCOPE' = 8; 'ID-PROBE-UNAVAILABLE' = 9
        'ID-PREDECESSOR-AMBIGUOUS' = 10
    }
    $ordered = @($findings | Sort-Object -Stable -Property @{
            Expression = { if ($_.Severity -ne 'Warning') { 1000 } elseif ($rank.ContainsKey($_.Code)) { $rank[$_.Code] } else { 500 } }
        })

    return [pscustomobject]@{
        SchemaVersion = '1.0'
        PackageType   = $packageType
        PackageFamily = $packageFamily
        Update        = @($latest.Values | Select-Object -Property BaselineFamily, BaselineType, BaselineVersion, Verdict, FailedAssertions,
            TimestampUtc, Backend, Mode, Legacy, LogFolder)
        Findings      = $ordered
    }
}
