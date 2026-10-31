function Get-Win32ToolkitPackageAdvisory {
    <#
    .SYNOPSIS
        Collects the warnings to show before a package is exported or published: failed install/uninstall
        and Update tests, technology switches, identity checks and unsafe uninstall cleanup paths.
    .DESCRIPTION
        Installer-identity PR 1, spec 2.13 (D1: warn only, never block). Read-only: it never writes a file
        and never throws; an unexpected error becomes one Warning finding 'Could not check the Update test
        and identity warnings: ...'.

        Update findings (Documentation\TestResults.json, Scenario Update), one per baseline family: the
        latest judged record of each Baseline.Family. A record marked Baseline.Unavailable (the baseline
        technology could not be downloaded), or one with NotRun (the Intune-parity pre-check did not start
        the test), is never judged, so it cannot hide an older failure. A record
        written before baselines were recorded (no Baseline) counts only when it is the newest judged
        Update record; its family comes from Sandbox\OldVersion when that manifest is the version the
        generated Sandbox\UpdateAssertions.ps1 expected and the run used a winget baseline (else unknown).
          UPDATE-FAILED        Warning  the latest record of a family failed (names the failed assertions and the
                                        run's own log folder, Sandbox\Logs\Runs\<run>, when the record has one, and the
                                        update's exit code with its meaning when the Notes give it); Info when the update
                                        exited 69101 and the project has a Block rule (the refusal was the intended
                                        outcome; Requirement-PreUpdate, judged before it, is said to fail by design, D28);
                                        a retry code (1618, 69107) says the run judged nothing, with that code's causes
                                        (run it again)
          UPDATE-INCONCLUSIVE  Info     the latest record of a family has no verdict
          ID-TECH-SWITCH       Warning  every Get-Win32ToolkitTechnologySwitch result

        Install findings (TUI audit G1, Scenario InstallUninstall; Export, Publish and Tui): the latest record
        wins (one track: backend and mode do not split it), so an older failure is hidden by a newer pass and an
        older pass never hides a newer failure. A NotRun record is never judged; no record at all gives no
        finding. They only warn and never block.
          INSTALL-FAILED       Warning  the latest record failed (names the failed assertions and
                                        <LogFolder>\InstallAssertions.log, else Sandbox\Logs\InstallAssertions.log)
          INSTALL-INCONCLUSIVE Warning  the latest record has no verdict (names the command to run it again)

        Identity findings: Get-Win32ToolkitIdentityDelta -ReuseProbe re-evaluated in memory (a fresh
        predecessor lookup, the probe stored in Documentation\IdentityDelta.json), plus -NoProbe unless
        -ProbeIfMissing. On top of them:
          ID-SIBLING-UNTESTED  Warning  winget ships another testable technology and the latest judged
                                        Update test from it did not pass (or there is none); when the latest
                                        one of every such family passed, ID-SIBLING-FAMILY becomes Info. The advice
                                        follows the failed run's cause (installer-identity PR 3 live checks): a Block
                                        rule's 69101 -> Info (as intended; Enforce and prove it to remove the install);
                                        a retry code (1618, 69107) -> its own causes, run it again; 69102 -> widen the
                                        rule's window (-FromUpdateTest -Id keeping its mode and floor, or a capture) or a
                                        baseline inside it; 69111 -> the kill switch on the test VM; a rule whose
                                        identity did not match (ID-TECH-SWITCH UnmatchedRules) -> replace it from the
                                        candidate; a Report rule of that family -> it stays side by side by design
                                        (Enforce it); a declarable candidate in PriorInstallCandidates.json -> declare it
                                        (Block first), or, when the project's remove-prior blocks are not this catalog's,
                                        re-create it and run the test again first; else run the test again
                                        (-BaselineInstallerType Both). The run is named by its baseline type. When
                                        ID-TECH-SWITCH names rules whose identity did not match on the test VM, or a
                                        69102 run found the install newer than a rule's VersionMax, ID-SIBLING-FAMILY is a
                                        Warning whose coverage sentence is replaced by what the run found.

        Cleanup (-Context Publish and Tui only; at Export the package check already refuses them):
          UNSAFE-CLEANUP       Warning  Get-Win32ToolkitCleanupPathFinding reports an unsafe cleanup path
                                        or install root (a package exported before the check carries it),
                                        or SupportFiles\AppConfig.json could not be read, so the cleanup
                                        paths could not be checked (Windows PowerShell 5.1 on the device
                                        may still read it).

        Prior installs (installer-identity PR 3; every context): the Warning and Info rows of
        Get-Win32ToolkitPriorInstallFinding -Stage Advisory (Source PriorInstalls, message prefix 'Prior install: '):
        PRIOR-BLOCK-FLEET, PRIOR-NO-WELCOME, PRIOR-PREDECESSOR-PUBLISHED, PRIOR-ENFORCE-PILOT, ID-PRIOR-OWN,
        PRIOR-CLASS-E (warnings) and PRIOR-UNCOVERED (Info); the ID-SIBLING-* rows of the sibling capture (installer-identity
        PR 3b: UNAPPLIED, PERUSER, SAME-KEY, SAME-FAMILY, NEW-FAMILY, NOT-CAPTURABLE, REPORT-ONLY, DRIFT-GAP, ASSISTED,
        SANDBOX) come with Source SiblingCapture and the prefix 'Sibling capture: '. Export refuses the Error rows itself.

        Order: UNSAFE-CLEANUP, INSTALL-FAILED, UPDATE-FAILED, ID-TECH-SWITCH, INSTALL-INCONCLUSIVE, ID-FAMILY,
        ID-SIBLING-UNTESTED, ID-SIBLING-FAMILY, ID-NO-ANCHOR, ID-TATTOO, ID-SCOPE, ID-PROBE-UNAVAILABLE,
        ID-PREDECESSOR-AMBIGUOUS, PRIOR-BLOCK-FLEET, PRIOR-NO-WELCOME, PRIOR-PREDECESSOR-PUBLISHED, PRIOR-ENFORCE-PILOT,
        ID-PRIOR-OWN, PRIOR-CLASS-E, other warnings, then every Info finding. Every untrusted value passes
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
        BaselineVersion, Verdict, FailedAssertions, TimestampUtc, Backend, Mode, Legacy, LogFolder), Install ($null,
        or the latest judged install/uninstall record: Verdict, FailedAssertions, TimestampUtc, Backend, Mode,
        LogFolder), Findings (Code, Severity, Source = UpdateTest|InstallTest|IdentityDelta|AppConfig|PriorInstalls|SiblingCapture,
        Message).
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
    $install = $null
    try {
        $records = Get-Win32ToolkitTestResult -ProjectPath $ProjectPath
        $candidates = @(@($records) | Where-Object {
                $_ -and [string](& $prop $_ 'Scenario') -eq 'Update' -and -not [bool](& $prop (& $prop $_ 'Baseline') 'Unavailable') -and
                -not (& $prop $_ 'NotRun')
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
            # The update's own exit code and what it means, from the record's Notes (installer-identity PR 3 live rows OP-BLOCK,
            # RC2-BLOCK, OP-NEWER, DEMOTE: a Block refusal, a 69102 and a retry code all read as the same failed assertions).
            $exitCode = $null; $exitMeaning = ''
            foreach ($em in [regex]::Matches([string](& $prop $r 'Notes'), '(?:The update|Intune-parity phase ''Update[^'']*'') exited with code (-?\d{1,10})(?:: ([^.]+))?\.')) {
                $n = 0
                if ([int]::TryParse($em.Groups[1].Value, [ref]$n)) { $exitCode = $n; if ($em.Groups[2].Success -and -not $exitMeaning) { $exitMeaning = & $safe $em.Groups[2].Value 300 } }
            }
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
                    ExitCode         = $exitCode
                    ExitMeaning      = $exitMeaning
                })
        }

        # Install/uninstall records (TUI audit G1, S8-F1): one track, the latest record wins (file order = write order),
        # so an older failure is hidden by a newer pass and an older pass never hides a newer failure. A NotRun record
        # (the Intune-parity pre-check did not start the test) is never judged. No record at all: no finding.
        $installRecords = @(@($records) | Where-Object { $_ -and [string](& $prop $_ 'Scenario') -eq 'InstallUninstall' -and -not (& $prop $_ 'NotRun') })
        $installLatest  = if ($installRecords.Count) { $installRecords[-1] } else { $null }
        if ($installLatest) {
            $when = & $instant (& $prop $installLatest 'TimestampUtc')
            $install = [pscustomobject]@{
                Verdict          = & $safe (& $prop $installLatest 'Verdict') 32
                FailedAssertions = [string[]]@(@(& $prop $installLatest 'Assertions') | Where-Object { $_ -and [string](& $prop $_ 'Result') -eq 'FAIL' } |
                        ForEach-Object { & $safe (& $prop $_ 'Name') 128 })
                TimestampUtc     = if ($when) { $when.ToString('o') } else { '' }
                Backend          = & $safe (& $prop $installLatest 'Backend') 32
                Mode             = & $safe (& $prop $installLatest 'Mode') 32
                LogFolder        = & $logFolder $installLatest
                Date             = if ($when) { $when.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' }
            }
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
    # Export: worded so it holds for a real build and for Export -WhatIf, which builds nothing (re-verification
    # 2026-10-21, A2 sb#1: 'the package is still packaged' printed right after 'nothing was staged or packaged').
    $continues = if ($Context -eq 'Export') { 'it does not stop packaging' } else { 'publishing continues' }
    # The project's prior-install rules (installer-identity PR 3; fail-open): a failure their own policy explains is said as
    # such (live rows OP-BLOCK, RC2-BLOCK: a deliberate Block refusal gave three warnings, one asking for a run that cannot
    # pass while the rule is Block).
    $priorRules = @()
    $scriptAuthor = ''
    try {
        $cfgRules = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $priorRules = @(@(& $prop (& $prop $cfgRules 'PriorInstalls') 'Entries') | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] })
        $scriptAuthor = & $safe (& $prop (& $prop $cfgRules 'App') 'ScriptAuthor') 128
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose ('Package advisory: the prior-install rules could not be read: {0}' -f (& $safe $_.Exception.Message 512))
    }
    $ruleIds = { param([object[]]$Rules) @($Rules | ForEach-Object { & $safe (& $prop $_ 'Id') 40 } | Where-Object { $_ } | Select-Object -Unique) }
    $rulesOf = {
        param([string]$Mode, [string]$Family)
        @($priorRules | Where-Object { [string](& $prop $_ 'Mode') -ceq $Mode -and (-not $Family -or (Get-Win32ToolkitInstallerFamily -Type ([string](& $prop $_ 'UninstallerType'))).Family -eq $Family) })
    }
    $isRetry = { param($Code) $null -ne $Code -and @(1618, 69107) -contains [int]$Code }
    # What a retry code means on the test VM, per code (live rows APP-RUNNING, MSIBUSY: one list for both codes named "a
    # restart pending" for 1618, which only 69107 means, and left out 1618's "changed while the dialog was open").
    $retryCause = {
        param($Code)
        switch ([int]$Code) {
            1618 { 'on the test VM: the prior app was still running after the close-apps dialog, Windows Installer was busy, or the prior install changed while the dialog was open' }
            69107 { 'on the test VM: a restart was pending, from Windows servicing or from the removal of the prior install' }
            default { 'a retry code' }
        }
    }
    foreach ($entry in $latest.Values) {
        if ($entry.Verdict -eq 'Failed') {
            $names = if ($entry.FailedAssertions.Count) { $entry.FailedAssertions -join ', ' } else { 'no failed assertion was recorded' }
            $review = if ($entry.LogFolder) { '{0}\UpdateAssertions.log' -f $entry.LogFolder } else { 'Sandbox\Logs\UpdateAssertions.log' }
            $blockIds = @(& $ruleIds (& $rulesOf 'Block' ''))
            if ($entry.ExitCode -eq 69101 -and $blockIds.Count -gt 0) {
                # Live rows OP-BLOCK, RC2-BLOCK: Requirement-PreUpdate is judged BEFORE the update and fails because the update
                # requirement includes Enforce rules only (D28), not because of the refusal.
                $after = @($entry.FailedAssertions | Where-Object { $_ -ne 'Requirement-PreUpdate' })
                $afterText = if ($after.Count) { " The failed assertions after it follow from that refusal: $($after -join ', ')." } else { '' }
                $preText = if (@($entry.FailedAssertions) -contains 'Requirement-PreUpdate') { ' Requirement-PreUpdate was judged before the update and fails by design: the update requirement detects only installs an Enforce rule names, so devices with only that install do not get this package as an update while the rule is Block.' } else { '' }
                & $add 'UPDATE-FAILED' 'Info' 'UpdateTest' (('{0} ended as intended: the Block prior-install rule(s) {1} refused the update (exit code 69101), so devices with that install FAIL this package until a rule is Enforce.' -f (& $runText $entry), ($blockIds -join ', ')) + $afterText + $preText)
            }
            elseif (& $isRetry $entry.ExitCode) {
                & $add 'UPDATE-FAILED' 'Warning' 'UpdateTest' ('{0} judged nothing: the update exited with the retry code {1} ({2}). This only warns: {3}. Run it again before you assign it.' -f (& $runText $entry), $entry.ExitCode, (& $retryCause $entry.ExitCode), $continues)
            }
            else {
                $codeText = if ($null -ne $entry.ExitCode) { ' (the update exited with code {0}{1})' -f $entry.ExitCode, $(if ($entry.ExitMeaning) { ": $($entry.ExitMeaning)" } else { '' }) } else { '' }
                & $add 'UPDATE-FAILED' 'Warning' 'UpdateTest' ('{0} FAILED{4}: {1}. This only warns: {2}. Review {3} before you assign it.' -f (& $runText $entry), $names, $continues, $review, $codeText)
            }
        } elseif ($entry.Verdict -eq 'Inconclusive') {
            & $add 'UPDATE-INCONCLUSIVE' 'Info' 'UpdateTest' ('{0} gave no verdict (Inconclusive). Run it again to confirm that devices with the earlier version update cleanly.' -f (& $runText $entry))
        }
    }

    # ---- The latest install/uninstall test (TUI audit G1): warn only, never block (like D1 for Update) ----
    if ($install) {
        $installWhere = [System.Collections.Generic.List[string]]::new()
        if ($install.Backend -or $install.Mode) { $installWhere.Add("$($install.Backend)/$($install.Mode)") }
        if ($install.Date) { $installWhere.Add($install.Date) }
        $installRun = 'The latest install/uninstall test' + $(if ($installWhere.Count) { ' ({0})' -f ($installWhere -join ', ') } else { '' })
        if ($install.Verdict -eq 'Failed') {
            $names = if ($install.FailedAssertions.Count) { $install.FailedAssertions -join ', ' } else { 'no failed assertion was recorded' }
            $review = if ($install.LogFolder) { '{0}\InstallAssertions.log' -f $install.LogFolder } else { 'Sandbox\Logs\InstallAssertions.log' }
            & $add 'INSTALL-FAILED' 'Warning' 'InstallTest' ('{0} FAILED: {1}. This only warns: {2}. Review {3} before you assign it.' -f $installRun, $names, $continues, $review)
        } elseif ($install.Verdict -eq 'Inconclusive') {
            $project = (& $safe $ProjectPath 1024).Replace("'", "''")
            & $add 'INSTALL-INCONCLUSIVE' 'Warning' 'InstallTest' (("{0} gave no verdict (Inconclusive): it did not show that the package installs and uninstalls. This only warns: {1}. " +
                    "Run it again before you assign it: Test-Win32ToolkitProject -ProjectPath '{2}' -Scenario InstallUninstall") -f $installRun, $continues, $project)
        }
    }

    # ---- Technology switches seen by the Update tests ----
    $unmatchedIds = [System.Collections.Generic.List[string]]::new()
    # The unmatched rules per baseline family of the switch that names them ('' when the switch does not say).
    $unmatchedFam = @{}
    try {
        $switchArgs = @{ ProjectPath = $ProjectPath }
        if ($packageType) { $switchArgs.PackageType = $packageType }
        if ($packageFamily) { $switchArgs.PackageFamily = $packageFamily }
        foreach ($s in @(Get-Win32ToolkitTechnologySwitch @switchArgs)) {
            if (-not $s) { continue }
            & $add 'ID-TECH-SWITCH' 'Warning' 'UpdateTest' (& $safe (& $prop $s 'Message') 2048)
            $sFam = ([string](& $prop $s 'BaselineFamily')).ToLowerInvariant()
            foreach ($u in @(& $prop $s 'UnmatchedRules')) {
                if (-not $u) { continue }
                $uId = & $safe $u 40
                if (-not $unmatchedIds.Contains($uId)) { $unmatchedIds.Add($uId) }
                if (-not $unmatchedFam.ContainsKey($sFam)) { $unmatchedFam[$sFam] = [System.Collections.Generic.List[string]]::new() }
                if (-not $unmatchedFam[$sFam].Contains($uId)) { $unmatchedFam[$sFam].Add($uId) }
            }
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
        $siblingLead = ''
        foreach ($f in @(& $prop $delta 'Findings')) {
            if (-not $f) { continue }
            $code = & $safe (& $prop $f 'Code') 64
            $severity = if ([string](& $prop $f 'Severity') -eq 'Warning') { 'Warning' } else { 'Info' }
            $item = [pscustomobject]@{ Code = $code; Severity = $severity; Source = 'IdentityDelta'; Message = & $safe (& $prop $f 'Message') 2048 }
            $findings.Add($item)
            if ($code -eq 'ID-SIBLING-FAMILY') { $siblingFinding = $item; $siblingLead = & $safe (& $prop (& $prop $f 'Data') 'Lead') 1024 }
        }
        $project = (& $safe $ProjectPath 1024).Replace("'", "''")
        # This project's remove-prior blocks (fail-open: unknown -> assumed current): a project of another catalog revision cannot
        # take a rule (live row OP-CONTROL: the advised -FromUpdateTest command was refused with W32T.PriorInstallSlotsMissing).
        $slotProblem = ''
        try {
            $advScript = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
            $advShape = if (Test-Path -LiteralPath $advScript -PathType Leaf) { Get-Win32ToolkitDeployScriptShape -Path $advScript } else { $null }
            $advRevision = [int](Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision)
            if ($null -eq $advShape) { $slotProblem = '' }
            elseif ([int]$advShape.RemovePriorRevision -lt 1) { $slotProblem = 'its deploy script has no remove-prior blocks (it was created before this win32-toolkit version)' }
            elseif ([int]$advShape.RemovePriorRevision -ne $advRevision) { $slotProblem = "its remove-prior blocks are catalog revision $([int]$advShape.RemovePriorRevision), this version writes revision $advRevision" }
            elseif (-not $advShape.PriorCheckFirst) { $slotProblem = 'a dialog of its deploy script runs before the prior-check block' }
        } catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose ('Package advisory: the deploy script shape could not be read: {0}' -f (& $safe $_.Exception.Message 512))
        }
        # A rule's replacement from the Update test's candidate, keeping its mode and widening its window just enough to cover
        # the observed version (live rows OP-NEWER, OP-UNPROVEN: the advice dropped the mode and the floor, or named no command).
        # A rule from a sibling capture changes only through its capture.
        $replaceCmd = {
            param($Rule, [string]$Observed)
            $rid = & $safe (& $prop $Rule 'Id') 40
            if ([string](& $prop $Rule 'Source') -ceq 'SiblingCapture' -or [string](& $prop $Rule 'CaptureId')) {
                return "capture the other installer technologies again (Test-Win32ToolkitProject -ProjectPath '$project' -Scenario SiblingCapture$(if ($Observed) { " -SiblingVersion '$((& $safe $Observed 64).Replace("'", "''"))'" })) and apply its proposal again"
            }
            $minText = [string](& $prop $Rule 'VersionMin'); $maxText = [string](& $prop $Rule 'VersionMax')
            $obsV = if ($Observed) { ConvertTo-Win32ToolkitPriorVersion -Text $Observed } else { $null }
            $minV = if ($minText) { ConvertTo-Win32ToolkitPriorVersion -Text $minText } else { $null }
            $maxV = ConvertTo-Win32ToolkitPriorVersion -Text $maxText
            $newMin = if ($minText -and $obsV -and $minV -and $obsV -lt $minV) { $Observed } else { $minText }
            $newMax = if ($obsV -and (-not $maxV -or $obsV -gt $maxV)) { $Observed } elseif ($maxText) { $maxText } else { '<version>' }
            "Set-Win32ToolkitPriorInstall -ProjectPath '$project' -FromUpdateTest -Id $rid -Mode $(& $safe (& $prop $Rule 'Mode') 16) -VersionMin '$((& $safe $newMin 64).Replace("'", "''"))' -VersionMax '$((& $safe $newMax 64).Replace("'", "''"))'"
        }
        # The candidate PriorInstallCandidates.json holds for a rule's key (its observed version), or $null.
        $candidateFor = {
            param($Rule)
            try {
                $cf = Join-Path $ProjectPath 'Documentation\PriorInstallCandidates.json'
                if (-not (Test-Path -LiteralPath $cf -PathType Leaf) -or (Get-Item -LiteralPath $cf).Length -gt 1MB) { return $null }
                $cdoc = Get-Content -LiteralPath $cf -Raw -Encoding UTF8 | ConvertFrom-Json
                return (@(@(& $prop $cdoc 'Candidates') | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -and [string](& $prop $_ 'View') -ceq [string](& $prop $Rule 'View') -and
                            [string]::Equals([string](& $prop $_ 'Key'), [string](& $prop $Rule 'Key'), [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1)
            } catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose ('Package advisory: the prior-install candidates could not be read: {0}' -f (& $safe $_.Exception.Message 512))
                return $null
            }
        }
        $ruleById = { param([string]$Id) @($priorRules | Where-Object { [string](& $prop $_ 'Id') -ceq $Id }) | Select-Object -First 1 }
        # The rules of a family below the version a 69102 run observed (live row OP-NEWER).
        $newerOf = [ordered]@{}
        if ($siblingFinding) {
            $testable = @(@(& $prop $delta 'Siblings') | Where-Object { $_ -and (& $prop $_ 'Testable') -and (& $prop $_ 'Registers') })
            $families = @($testable | ForEach-Object { ([string](& $prop $_ 'Family')).ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
            $tested = [System.Collections.Generic.List[string]]::new()
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
                $failed = $latestRun -and $latestRun.Verdict -eq 'Failed'
                $on = if ($failed -and $latestRun.Date) { " (on $($latestRun.Date))" } else { '' }
                # The run's own technology when it has one (live row MSIBUSY: "ships nullsoft ..., but the latest Update test
                # from an exe install").
                $fromType = if ($latestRun -and $latestRun.BaselineType) { & $safe $latestRun.BaselineType 32 } else { & $safe $family 32 }
                $fromText = '{0} {1} install' -f $(if ($fromType -match '^[aeiou]') { 'an' } else { 'a' }), $fromType
                $runCmd = "Test-Win32ToolkitProject -ProjectPath '$project' -Scenario Update -BaselineInstallerType Both"
                $proveCmd = "Test-Win32ToolkitProject -ProjectPath '$project' -Scenario Update -Backend HyperV -TestMode Unattended"
                # The Block or Enforce rules of this family the latest run did not match (ID-TECH-SWITCH names them).
                $famUnmatched = @(@(if ($unmatchedFam.ContainsKey($family)) { $unmatchedFam[$family] }) + @(if ($unmatchedFam.ContainsKey('')) { $unmatchedFam[''] }) | Where-Object { $_ } | Select-Object -Unique)
                # The Block or Enforce rules of this family whose VersionMax is below what a 69102 run observed.
                $famNewer = @()
                if ($failed -and $latestRun.ExitCode -eq 69102) {
                    $famNewer = @($priorRules | Where-Object { [string](& $prop $_ 'Mode') -cin @('Block', 'Enforce') -and (Get-Win32ToolkitInstallerFamily -Type ([string](& $prop $_ 'UninstallerType'))).Family -eq $family })
                    if ($famNewer.Count -eq 0) { $famNewer = @($priorRules | Where-Object { [string](& $prop $_ 'Mode') -cin @('Block', 'Enforce') }) }
                    if ($famNewer.Count) { $newerOf[$family] = $famNewer }
                }
                # What the failed run's own cause says to do (installer-identity PR 3 live rows OP-BLOCK, RC2-BLOCK, DEMOTE,
                # OP-NEWER, OP-REPORT, OP-CONTROL): the same run is advised only when it can tell something new.
                $famBlock = @(& $ruleIds (& $rulesOf 'Block' $family)); if ($famBlock.Count -eq 0) { $famBlock = @(& $ruleIds (& $rulesOf 'Block' '')) }
                $famReport = @(& $ruleIds (& $rulesOf 'Report' $family))
                $candidate = $null
                if ($failed) {
                    try {
                        $candFile = Join-Path $ProjectPath 'Documentation\PriorInstallCandidates.json'
                        if ((Test-Path -LiteralPath $candFile -PathType Leaf) -and (Get-Item -LiteralPath $candFile).Length -le 1MB) {
                            $candDoc = Get-Content -LiteralPath $candFile -Raw -Encoding UTF8 | ConvertFrom-Json
                            if (([string](& $prop (& $prop $candDoc 'Baseline') 'Family')).ToLowerInvariant() -eq $family) {
                                $cands = @(@(& $prop $candDoc 'Candidates') | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -and (& $prop $_ 'WindowsInstaller') -ne $true })
                                $cands = @($cands | Where-Object { $cd = $_; @($priorRules | Where-Object { [string](& $prop $_ 'View') -ceq [string](& $prop $cd 'View') -and [string]::Equals([string](& $prop $_ 'Key'), [string](& $prop $cd 'Key'), [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0 })
                                $candidate = $cands | Select-Object -First 1
                                if ($candidate) { $candHigh = @($cands | Where-Object { [string](& $prop $_ 'Confidence') -eq 'High' }).Count -eq 1 -and [string](& $prop $candidate 'Confidence') -eq 'High' }
                            }
                        }
                    } catch {
                        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                        Write-Verbose ('Package advisory: the prior-install candidates could not be read: {0}' -f (& $safe $_.Exception.Message 512))
                        $candidate = $null
                    }
                }
                if ($failed -and $latestRun.ExitCode -eq 69101 -and $famBlock.Count -gt 0) {
                    & $add 'ID-SIBLING-UNTESTED' 'Info' 'IdentityDelta' (("winget also ships {0}; the latest Update test from {1} ended with the refusal of the Block rule(s) {2} (69101){3}, as intended: " +
                            "while the rule is Block that test cannot pass. To remove that install before installing instead, make it Enforce (Set-Win32ToolkitPriorInstall -ProjectPath '{4}' -Id {5} -Mode Enforce) " +
                            'and prove it (Test-Win32ToolkitProject -ProjectPath ''{4}'' -Scenario Update -Backend HyperV -TestMode Unattended).') -f $label, $fromText, ($famBlock -join ', '), $on, $project, $famBlock[0])
                }
                elseif ($failed -and (& $isRetry $latestRun.ExitCode)) {
                    & $add 'ID-SIBLING-UNTESTED' 'Warning' 'IdentityDelta' ('winget also ships {0}, but the latest Update test from {1}{2} judged nothing: it ended with the retry code {3} ({4}). Run it again: {5}' -f
                        $label, $fromText, $on, $latestRun.ExitCode, (& $retryCause $latestRun.ExitCode), $runCmd)
                }
                elseif ($failed -and $latestRun.ExitCode -eq 69102) {
                    # Live row OP-NEWER: "so the same run fails again" was followed by that same run. The steps that can help: widen
                    # the window (keeping the rule's mode and floor), or a baseline inside the window.
                    $newRule = @($famNewer | Where-Object { [string](& $prop $_ 'Mode') -ceq 'Enforce' }) + @($famNewer | Where-Object { [string](& $prop $_ 'Mode') -cne 'Enforce' }) | Select-Object -First 1
                    $obs = ''
                    if ($newRule) { $nc = & $candidateFor $newRule; if ($nc) { $obs = [string](& $prop $nc 'ObservedVersion') } }
                    if (-not $obs -and $latestRun.BaselineVersion) { $obs = [string]$latestRun.BaselineVersion }
                    $widenText = if ($newRule) { & $replaceCmd $newRule $obs } else { 'declare the rule again with a higher VersionMax' }
                    $baseType = if ($latestRun.BaselineType) { & $safe $latestRun.BaselineType 32 } else { 'Both' }
                    & $add 'ID-SIBLING-UNTESTED' 'Warning' 'IdentityDelta' (("winget also ships {0}, but the latest Update test from {1}{2} ended with 69102: the install on the test VM{3} was newer than the VersionMax of the rule(s) {4}, " +
                            'so the same run fails again. Widen the window: {5}; or run from a baseline inside it: Test-Win32ToolkitProject -ProjectPath ''{6}'' -Scenario Update -BaselineInstallerType {7} -SpecificVersion <version>.') -f
                        $label, $fromText, $on, $(if ($obs) { " ($(& $safe $obs 64))" } else { '' }), ((@($famNewer | ForEach-Object { & $safe (& $prop $_ 'Id') 40 })) -join ', '), $widenText, $project, $baseType)
                }
                elseif ($failed -and $latestRun.ExitCode -eq 69111) {
                    # Live row KILL-NATIVE: after a kill-switch refusal the advice was the same run (or a proof), which refuses
                    # again while whatever set the switch on the test VM is still there.
                    & $add 'ID-SIBLING-UNTESTED' 'Warning' 'IdentityDelta' (("winget also ships {0}, but the latest Update test from {1}{2} ended with 69111: removal of prior installs was switched off on the test VM " +
                            '(RemovePriorDisabled = 1 under HKLM\SOFTWARE\{4}\win32-toolkit, set by the package itself - an org hook - or by the test VM''s checkpoint), so the same run refuses again. ' +
                            'Remove what sets it, then run it again: {3}') -f $label, $fromText, $on, $proveCmd, $(if ($scriptAuthor) { $scriptAuthor } else { '<ScriptAuthor>' }))
                }
                elseif ($failed -and $famUnmatched.Count -gt 0) {
                    # Live row OP-UNPROVEN: a rule whose identity did not match the install on the test VM got "run the test
                    # again", which fails the same way: the rule itself has to change.
                    $um = & $ruleById ([string]$famUnmatched[0])
                    $umCand = if ($um) { & $candidateFor $um } else { $null }
                    $umObs = if ($umCand) { [string](& $prop $umCand 'ObservedVersion') } else { '' }
                    $umFix = if ($um) { & $replaceCmd $um $umObs } else { "correct the rule's publisher, name and version window" }
                    & $add 'ID-SIBLING-UNTESTED' 'Warning' 'IdentityDelta' (("winget also ships {0}; the latest Update test from {1}{2} found that install on the test VM, but the rule(s) {3} did not match it (see ID-TECH-SWITCH), " +
                            'so devices like it keep that install next to this package, and running the test again or proving the rule fails the same way. Replace the rule from that test''s candidate: {4}.') -f
                        $label, $fromText, $on, ($famUnmatched -join ', '), $umFix)
                }
                elseif ($failed -and $famReport.Count -gt 0) {
                    & $add 'ID-SIBLING-UNTESTED' 'Warning' 'IdentityDelta' (("winget also ships {0}, but the latest Update test from {1} failed{2}: the Report rule(s) {3} leave that install next to this package by design " +
                            "(OldArpGone fails while it is Report). To remove it before installing, make it Enforce (Set-Win32ToolkitPriorInstall -ProjectPath '{4}' -Id {5} -Mode Enforce) and prove it.") -f $label, $fromText, $on, ($famReport -join ', '), $project, $famReport[0])
                }
                elseif ($candidate -and $slotProblem) {
                    # Live row OP-CONTROL: the advised -FromUpdateTest command is refused in a project that cannot take a rule, and
                    # re-creating the project drops PriorInstallCandidates.json: re-create, run the Update test again, then declare.
                    & $add 'ID-SIBLING-UNTESTED' 'Warning' 'IdentityDelta' (("winget also ships {0}, but the latest Update test from {1} failed{2} and left a prior-install candidate ({3} [{4}]), and this project cannot take a rule: {5}. " +
                            "Re-create it with this win32-toolkit version (Invoke-Win32Toolkit -Force or New-Win32ToolkitManualApp; copy hand-written Install code out first), run this Update test again ({6}; re-creating drops the candidates), " +
                            'then declare it (Block first): Set-Win32ToolkitPriorInstall -ProjectPath ''{7}'' -FromUpdateTest -Mode Block.') -f
                        $label, $fromText, $on, (& $safe (& $prop $candidate 'Key')), (& $safe (& $prop $candidate 'View') 16), $slotProblem, $runCmd, $project)
                }
                elseif ($candidate) {
                    $pick = if ($candHigh) { '' } else { " -CandidateKey '$((& $safe (& $prop $candidate 'Key')).Replace("'", "''"))'" }
                    & $add 'ID-SIBLING-UNTESTED' 'Warning' 'IdentityDelta' (("winget also ships {0}, but the latest Update test from {1} failed{2} and left a prior-install candidate ({3} [{4}]): " +
                            "declare it (Block first): Set-Win32ToolkitPriorInstall -ProjectPath '{5}' -FromUpdateTest -Mode Block{6}; make it Enforce and prove it to remove that install before installing.") -f
                        $label, $fromText, $on, (& $safe (& $prop $candidate 'Key')), (& $safe (& $prop $candidate 'View') 16), $project, $pick)
                }
                else {
                    # Live check KILL-NATIVE (2026-10-26): "no Update test has passed" was false when an older run had passed
                    # and only the latest one failed: that case names the latest run.
                    $whatRan = if ($failed) { 'the latest Update test from {0} failed{1}' -f $fromText, $on }
                               else { 'no Update test has passed from {0}' -f $fromText }
                    & $add 'ID-SIBLING-UNTESTED' 'Warning' 'IdentityDelta' (('winget also ships {0}, but {1}. Run: {2}') -f $label, $whatRan, $runCmd)
                }
            }
            if ($families.Count -gt 0 -and $tested.Count -eq $families.Count) {
                $siblingFinding.Severity = 'Info'
                $siblingFinding.Message  = '{0} (tested: {1})' -f $siblingFinding.Message, ($tested -join '; ')
            }
        }
        # Live rows OP-UNPROVEN, OP-NEWER: the rules ID-SIBLING-FAMILY counts as covering did not match the install on the test VM
        # (ID-TECH-SWITCH names them), or a 69102 run found it newer than their VersionMax: the "no two registrations" sentence
        # is false for such devices, so it is REPLACED (after the finding's first sentence, Data.Lead), not contradicted.
        $newerIds = @($newerOf.Values | ForEach-Object { $_ } | ForEach-Object { & $safe (& $prop $_ 'Id') 40 } | Where-Object { $_ } | Select-Object -Unique)
        if ($siblingFinding -and ($unmatchedIds.Count -gt 0 -or $newerIds.Count -gt 0)) {
            $sentences = [System.Collections.Generic.List[string]]::new()
            if ($unmatchedIds.Count -gt 0) { $sentences.Add(('The prior-install rule(s) {0} name that install, but the latest Update test found it on the test VM and they did not match it (see ID-TECH-SWITCH): devices like it keep that install next to this package until the rule is replaced.' -f ($unmatchedIds -join ', '))) }
            if ($newerIds.Count -gt 0) { $sentences.Add(('The prior-install rule(s) {0} name that install, but the latest Update test found a newer one on the test VM than their VersionMax (69102): devices with it FAIL this package until the window is widened.' -f ($newerIds -join ', '))) }
            $covered = $siblingFinding.Message -like '* name that install, so devices that have it do not get two registrations*'
            $siblingFinding.Severity = 'Warning'
            $siblingFinding.Message = if ($covered -and $siblingLead -and $siblingFinding.Message.StartsWith($siblingLead, [System.StringComparison]::Ordinal)) { $siblingLead + ' ' + ($sentences -join ' ') } else { $siblingFinding.Message + ' ' + ($sentences -join ' ') }
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

    # ---- Prior-install rules (installer-identity PR 3, spec 2.11): the warnings and notes; Export refuses the errors ----
    try {
        foreach ($pf in @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $ProjectPath -Stage Advisory)) {
            if ([string]$pf.Code -like 'ID-SIBLING-*') { & $add ([string]$pf.Code) ([string]$pf.Severity) 'SiblingCapture' ('Sibling capture: ' + [string]$pf.Message) }
            else { & $add ([string]$pf.Code) ([string]$pf.Severity) 'PriorInstalls' ('Prior install: ' + [string]$pf.Message) }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        & $failOpen 'PriorInstalls' $_
    }

    $rank = @{
        'UNSAFE-CLEANUP' = 0; 'INSTALL-FAILED' = 1; 'UPDATE-FAILED' = 2; 'ID-TECH-SWITCH' = 3; 'INSTALL-INCONCLUSIVE' = 4
        'ID-FAMILY' = 5; 'ID-SIBLING-UNTESTED' = 6; 'ID-SIBLING-FAMILY' = 7; 'ID-NO-ANCHOR' = 8; 'ID-TATTOO' = 9; 'ID-SCOPE' = 10
        'ID-PROBE-UNAVAILABLE' = 11; 'ID-PREDECESSOR-AMBIGUOUS' = 12
        'PRIOR-BLOCK-FLEET' = 13; 'PRIOR-NO-WELCOME' = 14; 'PRIOR-PREDECESSOR-PUBLISHED' = 15; 'PRIOR-ENFORCE-PILOT' = 16; 'ID-PRIOR-OWN' = 17
        'PRIOR-CLASS-E' = 18
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
        Install       = if ($install) { $install | Select-Object -Property Verdict, FailedAssertions, TimestampUtc, Backend, Mode, LogFolder } else { $null }
        Findings      = $ordered
    }
}
