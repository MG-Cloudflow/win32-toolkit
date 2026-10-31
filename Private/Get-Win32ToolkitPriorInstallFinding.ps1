function Get-Win32ToolkitPriorInstallFinding {
    <#
    .SYNOPSIS
        The Export errors and the advisory warnings of a project's prior-install rules.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.11, D12, D17, D20, D25, D29, L3, L13, L28, L38, L39, SV2, SV5, SV14). Read-only.
        -Stage Export returns the Error rows (Assert-Win32ToolkitPackageReady adds each one, prefixed 'Prior install: ',
        to its W32T.PackageNotReady error; nothing overrides them except the decision named in the table);
        -Stage Advisory returns the Warning and Info rows (Get-Win32ToolkitPackageAdvisory shows them).

          Code                         Severity  Condition (override)
          GUEST-TAMPER                 Error     Documentation\GuestTamper.json exists: a guest changed project files (none:
                                                 re-create the project)
          ID-PRIOR-DROPPED             Error     the carry-forward source (Get-Win32ToolkitPriorCarrySource) has a rule whose
                                                 Kind, Key and View are missing here and that is not this package's own key
                                                 (an ID-PRIOR-DROPPED acknowledgement for that rule id); also every rule of
                                                 a source a test guest changed, from which nothing was carried, and every
                                                 rule of Documentation\PriorInstallDropped.json (the rules a re-created
                                                 project lost to a test guest, Get-Win32ToolkitPriorInstallDropped) whose
                                                 Kind, Key and View are missing here (the same acknowledgement); a file
                                                 that cannot be read refuses the Export
          PRIOR-NO-SLOTS               Error     rules and no remove-prior blocks, or a dialog before prior-check (none: re-create)
          PRIOR-REVISION               Error     rules and remove-prior blocks of another catalog revision (none: re-create)
          PRIOR-NO-OWNIDENTITY         Error     rules and no known own identity, or an Enforce rule and no OwnIdentity (none:
                                                 run the install capture)
          PRIOR-INVALID                Error     a rule or the set fails the spec 2.1 rules (none)
          PRIOR-CAPTURE-RECORD         Error     a captured rule without its hash-verified capture record, or whose identity
                                                 (Tuple) or window its records re-derive differently (none: re-capture); a
                                                 sibling of the package's own family may keep a lower VersionMax that a
                                                 same-identity record observed (S3 cut it at an older package version; a
                                                 carried rule keeps it until a new capture raises it, D61)
          PRIOR-NOT-ELIGIBLE           Error     a captured Enforce rule whose re-derived proposal is not Enforce-eligible,
                                                 or whose records no longer make it a proposal (S30; class E is not a
                                                 reason) (none: Block, or capture again)
          PRIOR-SIGNER                 Error     a captured Enforce rule whose proposal has SignerMismatch (a SIGNER-MISMATCH
                                                 acknowledgement)
          PRIOR-PROOF                  Error     an Enforce rule not proven by a Hyper-V Unattended Update test (a PROOF waiver;
                                                 never for a captured rule)
          PRIOR-VERSIONMIN             Error     a proven Enforce rule whose VersionMin is below the oldest proven version, exact
                                                 (a VERSIONMIN waiver; never for a captured rule)
          PRIOR-DATA-LOSS              Error     the proof run saw the prior's uninstaller delete user data, or the capture's
                                                 removability probe saw it delete configuration in its folder (a DATA-LOSS
                                                 acknowledgement)
          PRIOR-APPROVAL               Error     a captured Enforce rule without a latest, not demoted Approval of exactly its
                                                 identity (none: approve its proposal again)
          PRIOR-BLOCK-FLEET            Warning   a Block rule: devices with that install FAIL this one (69101)
          PRIOR-ENFORCE-PILOT          Warning   Enforce rules: pilot first; the kill switch
          PRIOR-NO-WELCOME             Warning   an Enforce rule and OrgUi.Welcome.Enabled false: nothing closes the app first
          PRIOR-PREDECESSOR-PUBLISHED  Warning   Enforce rules and an earlier version of the app in this template is published
          ID-PRIOR-OWN                 Warning   a rule of the carry-forward source is now this package's own uninstall key
          PRIOR-CLASS-E                Warning   an Enforce rule in a versioned-family winget id (Python.Python.*, ...)
          PRIOR-UNCOVERED              Info      a captured rule: what devices outside its window keep or get (with the
                                                 release date of its floor capture when the record has one)
          ID-SIBLING-UNAPPLIED         Warning   a current sibling-capture proposal that is not a rule (the exact command)
          ID-SIBLING-PERUSER, -SAME-KEY, -SAME-FAMILY, -NEW-FAMILY, -NOT-CAPTURABLE, -REPORT-ONLY, -DRIFT-GAP, -ASSISTED,
          -SANDBOX                     Warning   from the proposals re-derived from the hash-verified capture records
                                                 (ConvertTo-Win32ToolkitSiblingProposal) and the capture index

        Waivers and acknowledgements come from Documentation\PriorInstallDecisions.json (Get-Win32ToolkitPriorInstallDecision);
        a waiver never applies to a captured rule (D59b, SV14). A project without rules gives at most GUEST-TAMPER,
        ID-PRIOR-DROPPED and ID-PRIOR-OWN. An AppConfig.json that cannot be read gives nothing (the cleanup-path check
        reports it). Any other failure: one Error row at Export (the rules could not be checked), one Warning in the
        advisory (a W32T.* error is re-thrown). Every untrusted value passes ConvertTo-Win32ToolkitSafeText.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Stage
        Export (the Error rows) or Advisory (the Warning and Info rows).
    .OUTPUTS
        [pscustomobject[]] Code, Severity, Target (a rule id or ''), Message.
    .EXAMPLE
        Get-Win32ToolkitPriorInstallFinding -ProjectPath $p -Stage Export | ForEach-Object { "Prior install: $($_.Message)" }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [ValidateSet('Export', 'Advisory')]
        [string]$Stage = 'Export'
    )

    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $rows = [System.Collections.Generic.List[object]]::new()
    $add = { param([string]$Code, [string]$Severity, [string]$Target, [string]$Message) $rows.Add([pscustomobject]@{ Code = $Code; Severity = $Severity; Target = $Target; Message = $Message }) }
    $finish = {
        if ($Stage -eq 'Export') { return [object[]]@($rows | Where-Object { $_.Severity -eq 'Error' }) }
        return [object[]]@($rows | Where-Object { $_.Severity -ne 'Error' })
    }

    try {
        # ---- a guest that changed project files (T1) ----
        if (Test-Path -LiteralPath (Join-Path $ProjectPath 'Documentation\GuestTamper.json') -PathType Leaf) {
            & $add 'GUEST-TAMPER' 'Error' '' "a test guest changed this project's files (Documentation\GuestTamper.json): nothing it touched can be trusted. Re-create the project (Invoke-Win32Toolkit -Force or New-Win32ToolkitManualApp)."
        }

        $cfg = $null
        try { $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath -ErrorAction Stop }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            return (& $finish)
        }
        $entries = @(@(& $prop (& $prop $cfg 'PriorInstalls') 'Entries') | Where-Object { $null -ne $_ })
        $decisions = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath)
        $hasDecision = {
            param([string]$Kind, [string]$Code, [string]$Target)
            @($decisions | Where-Object { $_.Kind -ceq $Kind -and $_.Code -ceq $Code -and $_.Target -ceq $Target }).Count -gt 0
        }
        $set = "Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath'"
        $author = & $safe (& $prop (& $prop $cfg 'App') 'ScriptAuthor') 128
        # The version the last failed Update test observed for a rule's key (Documentation\PriorInstallCandidates.json), or ''.
        $observedOf = {
            param($Rule)
            try {
                $cf = Join-Path $ProjectPath 'Documentation\PriorInstallCandidates.json'
                if (-not (Test-Path -LiteralPath $cf -PathType Leaf) -or (Get-Item -LiteralPath $cf).Length -gt 1MB) { return '' }
                $c = @(@(& $prop (Get-Content -LiteralPath $cf -Raw -Encoding UTF8 | ConvertFrom-Json) 'Candidates') | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -and
                            [string](& $prop $_ 'View') -ceq [string](& $prop $Rule 'View') -and [string]::Equals([string](& $prop $_ 'Key'), [string](& $prop $Rule 'Key'), [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
                $v = if ($c) { & $safe (& $prop $c 'ObservedVersion') 64 } else { '' }
                if ($v -match '^[0-9][0-9A-Za-z._+-]{0,63}$') { return $v }
                return ''
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                return ''
            }
        }

        # The package's own uninstall keys (never the tattoo): OwnIdentity, Uninstall and the MSI's Source codes.
        $own = & $prop $cfg 'OwnIdentity'
        $uninstall = & $prop $cfg 'Uninstall'
        $ownKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($k in @([string](& $prop $own 'ProductCode'), [string](& $prop (& $prop $cfg 'Source') 'ProductCode'))) { if ($k) { $ownKeys.Add($k) } }
        foreach ($k in @(& $prop $own 'ArpKeys')) { if ($k -and [string](& $prop $k 'Key')) { $ownKeys.Add([string](& $prop $k 'Key')) } }
        foreach ($k in @(& $prop $uninstall 'ProductCodes')) { if ($k) { $ownKeys.Add([string]$k) } }
        # Uninstall.PrimaryKeys holds { Name; View } objects (Update-PSADTUninstallLogic): the key is the Name.
        foreach ($k in @(& $prop $uninstall 'PrimaryKeys')) { if ($k -and [string](& $prop $k 'Name')) { $ownKeys.Add([string](& $prop $k 'Name')) } }
        $isOwn = { param([string]$Key) @($ownKeys | Where-Object { [string]::Equals($_, $Key, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0 }

        # ---- the rules of the carry-forward source (L5, L34) ----
        $source = Get-Win32ToolkitPriorCarrySource -ProjectPath $ProjectPath
        if ($source) {
            foreach ($se in @($source.Entries)) {
                $sKind = [string](& $prop $se 'Kind'); $sKey = [string](& $prop $se 'Key'); $sView = [string](& $prop $se 'View'); $sId = & $safe (& $prop $se 'Id') 40
                $here = @($entries | Where-Object { [string](& $prop $_ 'Kind') -ceq $sKind -and [string]::Equals([string](& $prop $_ 'Key'), $sKey, [StringComparison]::OrdinalIgnoreCase) -and [string](& $prop $_ 'View') -ceq $sView }).Count -gt 0
                if ($here) { continue }
                if (& $isOwn $sKey) {
                    & $add 'ID-PRIOR-OWN' 'Warning' $sId "the rule '$sId' of $(& $safe $source.Name 128) names $(& $safe $sKey), which is this package's own uninstall key: it is not carried (a package never removes itself)."
                    continue
                }
                if (& $hasDecision 'Acknowledgement' 'ID-PRIOR-DROPPED' $sId) { continue }
                & $add 'ID-PRIOR-DROPPED' 'Error' $sId ("the rule '$sId' ($(& $safe $sKey) [$(& $safe $sView 16)]) of $(& $safe $source.Name 128) is missing from this package, so devices with that install keep it next to this one. " +
                    "Declare it again ($set ...), or acknowledge the drop: $set -Acknowledge ID-PRIOR-DROPPED -Target $sId -Reason '<why>'")
            }
        }
        # ---- the rules this project or a version before it lost to a test guest (Documentation\PriorInstallDropped.json, L4) ----
        # The reader throws on a file it cannot read: the catch below then refuses the Export (fail-closed).
        foreach ($d in @(Get-Win32ToolkitPriorInstallDropped -ProjectPath $ProjectPath)) {
            $dId = & $safe $d.Id 40
            $here = @($entries | Where-Object { [string](& $prop $_ 'Kind') -ceq $d.Kind -and [string]::Equals([string](& $prop $_ 'Key'), $d.Key, [StringComparison]::OrdinalIgnoreCase) -and [string](& $prop $_ 'View') -ceq $d.View }).Count -gt 0
            if ($here) { continue }
            if (@($rows | Where-Object { $_.Code -in 'ID-PRIOR-DROPPED', 'ID-PRIOR-OWN' -and $_.Target -ceq $dId }).Count -gt 0) { continue }
            $from = if ($d.From) { & $safe $d.From 128 } else { 'a re-created project' }
            if (& $isOwn $d.Key) {
                & $add 'ID-PRIOR-OWN' 'Warning' $dId "the rule '$dId' of $from names $(& $safe $d.Key), which is this package's own uninstall key: it is not needed (a package never removes itself)."
                continue
            }
            if (& $hasDecision 'Acknowledgement' 'ID-PRIOR-DROPPED' $d.Id) { continue }
            & $add 'ID-PRIOR-DROPPED' 'Error' $dId ("the rule '$dId' ($(& $safe $d.Key) [$(& $safe $d.View 16)]) of $from was not kept because a test guest changed that project, so devices with that install keep it next to this one. " +
                "Declare it again ($set ..., or capture the sibling technologies again and apply its proposal), or acknowledge the drop: $set -Acknowledge ID-PRIOR-DROPPED -Target $dId -Reason '<why>'")
        }
        # ---- the sibling-capture proposals, re-derived from the hash-verified records (spec 2.14.8, A1) ----
        $records = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath)
        $sibling = $null
        if ($records.Count -gt 0 -or (Test-Path -LiteralPath (Join-Path $ProjectPath 'Documentation\SiblingCapture.json') -PathType Leaf)) {
            $sibling = ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $ProjectPath
        }
        $tupleOf = @{}
        foreach ($e in $entries) { $tupleOf[[string](& $prop $e 'Id')] = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $e }
        if ($sibling) {
            $seen = @{}
            $once = { param([string]$Code, [string]$Key) $k = "$Code|$($Key.ToUpperInvariant())"; if ($seen.ContainsKey($k)) { return $false }; $seen[$k] = $true; return $true }
            foreach ($p in @($sibling.Proposals)) {
                $pid1 = & $safe $p.ProposalId 40
                $what = "$(& $safe $p.Key) [$($p.View)], $($p.SiblingType), $(& $safe $p.VersionMin 64)..$(& $safe $p.VersionMax 64)"
                if (@($tupleOf.Values | Where-Object { $_ -ceq $p.ProposalHash }).Count -eq 0) {
                    & $add 'ID-SIBLING-UNAPPLIED' 'Warning' $pid1 "the sibling-capture proposal '$pid1' ($what, $($p.Confidence) confidence) is not a rule: devices with that install keep it next to this package. Apply it: $set -FromSiblingCapture -Mode Block -ProposalId $pid1"
                }
                if ($p.Flags -contains 'Sandbox' -and (& $once 'SANDBOX' $p.ProposalId)) { & $add 'ID-SIBLING-SANDBOX' 'Warning' $pid1 "the proposal '$pid1' ($what) comes from a Windows Sandbox capture: it can only Block, also after a later Hyper-V capture (a Sandbox record stays with the records of the identity it saw)." }
                if ($p.Flags -contains 'Assisted' -and (& $once 'ASSISTED' $p.ProposalId)) { & $add 'ID-SIBLING-ASSISTED' 'Warning' $pid1 "the proposal '$pid1' ($what) comes from an assisted capture: it can only Block, also after a later unattended capture (an assisted record stays with the records of the identity it saw)." }
            }
            foreach ($x in @($sibling.PerUser)) { if (& $once 'PERUSER' $x.Key) { & $add 'ID-SIBLING-PERUSER' 'Warning' '' "the $(& $safe $x.Type 32) installer of this app registers $(& $safe $x.Key) per user ($(& $safe $x.Reason 120)): no rule is proposed (the package runs as SYSTEM and never touches per-user installs)." } }
            foreach ($x in @($sibling.SameKey)) { if (& $once 'SAMEKEY' $x.Key) { & $add 'ID-SIBLING-SAME-KEY' 'Warning' '' "the $(& $safe $x.Type 32) installer of this app writes this package's own uninstall key $(& $safe $x.Key): no rule is proposed (an in-place upgrade question, not a prior install)." } }
            foreach ($x in @($sibling.SameFamily)) { if (& $once 'SAMEFAMILY' $x.Key) { & $add 'ID-SIBLING-SAME-FAMILY' 'Warning' '' "$(& $safe $x.Reason 200): its rule keeps only versions below the package version." } }
            foreach ($x in @($sibling.NotCapturable)) { if (& $once 'NOTCAPTURABLE' $x.Type) { & $add 'ID-SIBLING-NOT-CAPTURABLE' 'Warning' '' "winget also ships a $($x.Type) installer of this app that cannot be captured ($($x.Reason)): devices with it are not covered." } }
            foreach ($x in @($sibling.ReportOnly)) { if (& $once 'REPORTONLY' $x.Type) { & $add 'ID-SIBLING-REPORT-ONLY' 'Warning' '' "winget also ships a $($x.Type) installer of this app that a rule can only report ($($x.Reason))." } }
            foreach ($x in @($sibling.Gaps)) { & $add 'ID-SIBLING-DRIFT-GAP' 'Warning' '' "the $($x.Type) installer changed its identity between $($x.From) and $($x.To): the versions in between were not captured (capture them: Test-Win32ToolkitProject -ProjectPath '$ProjectPath' -Scenario SiblingCapture -SiblingVersion <version>)." }
            $ruleTypes = @(foreach ($e in $entries) {
                    $cid = [string](& $prop $e 'CaptureId')
                    if ($cid) { @($sibling.Captures | Where-Object { $_.CaptureId -ceq $cid } | ForEach-Object { $_.Type }) }
                })
            if ($ruleTypes.Count -gt 0) {
                foreach ($t in @($sibling.Proposals | ForEach-Object { $_.SiblingType } | Sort-Object -Unique)) {
                    if ($ruleTypes -notcontains $t) { & $add 'ID-SIBLING-NEW-FAMILY' 'Warning' '' "a $t installer of this app appeared since the captured rules were applied: review its proposal ($set)." }
                }
            }
        }
        if ($entries.Count -eq 0) { return (& $finish) }

        # ---- the deploy script must hold this catalog's remove-prior pair (D12, L3, L38, L39) ----
        $shape = Get-Win32ToolkitDeployScriptShape -Path (Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1')
        $catalogRevision = [int](Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision)
        $recreate = 'Re-create the project with this win32-toolkit version (copy hand-written Install code out first: re-creating deletes the folder); the rules are data and are carried into the new project.'
        if ([int]$shape.RemovePriorRevision -lt 1 -or -not $shape.PriorCheckFirst) {
            $why = if ([int]$shape.RemovePriorRevision -lt 1) { 'its deploy script has no remove-prior blocks (it was created before this win32-toolkit version)' } else { 'a dialog of its deploy script runs before the prior-check block' }
            & $add 'PRIOR-NO-SLOTS' 'Error' '' "this project has $($entries.Count) prior-install rule(s), but $why, so a device would ignore them. $recreate"
        }
        elseif ([int]$shape.RemovePriorRevision -ne $catalogRevision) {
            & $add 'PRIOR-REVISION' 'Error' '' "the remove-prior blocks of this deploy script are catalog revision $([int]$shape.RemovePriorRevision), this win32-toolkit writes revision ${catalogRevision}: the requirement script and the test assertions would check the rules differently from the device. $recreate"
        }

        # ---- the rules themselves (spec 2.1) ----
        $check = Test-Win32ToolkitPriorInstallEntry -Config $cfg -Decisions $decisions -Records $records
        $ownKnown = ($own -and ([string](& $prop $own 'ProductCode') -or [string](& $prop $own 'UpgradeCode') -or @(& $prop $own 'ArpKeys' | Where-Object { $_ }).Count -gt 0)) -or
            @(& $prop $uninstall 'PrimaryKeys' | Where-Object { $_ }).Count -gt 0 -or @(& $prop $uninstall 'ProductCodes' | Where-Object { $_ }).Count -gt 0
        $enforce = @($entries | Where-Object { [string](& $prop $_ 'Mode') -ceq 'Enforce' })
        if (-not $ownKnown) {
            & $add 'PRIOR-NO-OWNIDENTITY' 'Error' '' "this package's own uninstall identity is not known, so no rule can be checked against it: run the install capture (Complete-Win32ToolkitManualApp, or Invoke-Win32Toolkit again)."
        }
        elseif ($enforce.Count -gt 0 -and -not $own) {
            & $add 'PRIOR-NO-OWNIDENTITY' 'Error' '' "an Enforce rule needs this package's OwnIdentity, which the install capture writes: run the install capture again (Complete-Win32ToolkitManualApp, or Invoke-Win32Toolkit -Force)."
        }
        $ownProblem = { param([string]$Text) $Text -match "own uninstall identity is unknown|needs this package's OwnIdentity" }
        foreach ($sp in @($check.SetProblems | Where-Object { -not (& $ownProblem $_) })) {
            & $add 'PRIOR-INVALID' 'Error' '' "the prior-install rules are invalid: $(& $safe $sp 400)."
        }
        foreach ($pe in @($check.PerEntry)) {
            $eid = & $safe $pe.Id 40
            $plain = @($pe.Problems | Where-Object { [string]$_ -notlike 'capture record:*' -and -not (& $ownProblem $_) })
            $rec = @($pe.Problems | Where-Object { [string]$_ -like 'capture record:*' })
            if ($plain.Count) { & $add 'PRIOR-INVALID' 'Error' $eid "the rule '$eid' is invalid: $((@($plain) | ForEach-Object { & $safe $_ 300 }) -join '; '). Fix it with $set or remove it (-Remove $eid)." }
            if ($rec.Count) { & $add 'PRIOR-CAPTURE-RECORD' 'Error' $eid "the captured rule '$eid' does not match a hash-verified capture record ($((@($rec) | ForEach-Object { & $safe (([string]$_).Substring(15).Trim()) 300 }) -join '; ')): re-capture the sibling technologies (Test-Win32ToolkitProject -Scenario SiblingCapture)." }
        }

        # ---- captured rules re-derived from their records (L36, SV5, S30): identity, window, eligibility, signer ----
        $pkgVersionText = [string](& $prop (& $prop $cfg 'App') 'Version')
        $pkgFamily = (Get-Win32ToolkitInstallerFamily -Type ([string](& $prop (& $prop $cfg 'Installer') 'Type'))).Family
        foreach ($e in $entries) {
            $eid = [string](& $prop $e 'Id')
            $sid = & $safe $eid 40
            if ([string]$check.Lineage[$eid] -ne 'Capture' -or $null -eq $sibling) { continue }
            if (@($rows | Where-Object { $_.Code -eq 'PRIOR-CAPTURE-RECORD' -and $_.Target -ceq $sid }).Count) { continue }
            $cid = [string](& $prop $e 'CaptureId')
            $floorRow = @($sibling.Captures | Where-Object { $_.CaptureId -ceq $cid }) | Select-Object -First 1
            $sf = $floorRow -and (Get-Win32ToolkitInstallerFamily -Type $floorRow.Type).Family -eq $pkgFamily -and $pkgFamily -ne 'other'
            $w = Get-Win32ToolkitPriorInstallWindow -Captures $sibling.Captures -Tuple $tupleOf[$eid] -FloorCaptureId $cid -Below $(if ($sf) { $pkgVersionText } else { '' })
            if (-not $w.Found) {
                & $add 'PRIOR-CAPTURE-RECORD' 'Error' $sid "the captured rule '$sid' is not the identity its capture records re-derive ($(& $safe $w.Reason 200)): it was edited or its records changed. Capture again or apply its proposal again ($set -FromSiblingCapture -Mode <mode> -ProposalId <id>)."
                continue
            }
            $lo = ConvertTo-Win32ToolkitPriorVersion -Text ([string](& $prop $e 'VersionMin')); $hi = ConvertTo-Win32ToolkitPriorVersion -Text ([string](& $prop $e 'VersionMax'))
            $maxOk = $null -ne $hi -and $hi.ToString() -ceq $w.VersionMax
            if (-not $maxOk -and $sf -and $null -ne $hi -and $null -ne $lo -and $hi -ge $lo -and $hi -lt (ConvertTo-Win32ToolkitPriorVersion -Text $w.VersionMax)) {
                # A sibling of the package's own family: S3 cut the window below the package version it was applied with.
                # A carried rule keeps it (D61) until a new capture raises it, so a lower VersionMax is accepted while a
                # same-identity record observed exactly that version (never typed).
                $maxOk = @($sibling.Captures | Where-Object { $_.Tuple -ceq $tupleOf[$eid] -and (ConvertTo-Win32ToolkitPriorVersion -Text ([string]$_.ObservedVersion)) -eq $hi }).Count -gt 0
            }
            if ($null -eq $lo -or $lo.ToString() -cne $w.VersionMin -or -not $maxOk) {
                & $add 'PRIOR-CAPTURE-RECORD' 'Error' $sid "the captured rule '$sid' covers $(& $safe (& $prop $e 'VersionMin') 64)..$(& $safe (& $prop $e 'VersionMax') 64), but its capture records give $($w.VersionMin)..$($w.VersionMax) (the window is never typed). Update it from the records (Invoke-Win32Toolkit -CaptureSiblingTechnologies, or apply its proposal again)."
            }
            if ([string](& $prop $e 'Mode') -cne 'Enforce') { continue }
            $p = @($sibling.Proposals | Where-Object { $_.ProposalHash -ceq $tupleOf[$eid] }) | Select-Object -First 1
            if (-not $p) {
                # Fail closed: the records still give the window but no longer make the identity a proposal (S30: fewer
                # than two captures register it identically), so its re-derived EnforceEligible is false.
                & $add 'PRIOR-NOT-ELIGIBLE' 'Error' $sid "the captured Enforce rule '$sid' is not removable on its capture evidence (its records no longer make it a proposal: an identity needs at least two captures that register it identically): set it to Block ($set -Id $sid -Mode Block) or capture again."
                continue
            }
            $approved = @($decisions | Where-Object { $_.Kind -eq 'Approval' -and $_.Target -ceq $eid -and $_.Latest -and -not $_.Demoted -and [string]$_.ProposalHash -ceq $tupleOf[$eid] }).Count -gt 0
            $reasons = @($p.IneligibleReasons | Where-Object { -not ($approved -and [string]$_ -like 'MediumNotNamed*') })
            if ($reasons.Count) {
                & $add 'PRIOR-NOT-ELIGIBLE' 'Error' $sid "the captured Enforce rule '$sid' is not removable on its capture evidence ($((@($reasons) | ForEach-Object { & $safe $_ 200 }) -join '; ')): set it to Block ($set -Id $sid -Mode Block); these reasons stay with the capture records of that identity."
            }
            if ($p.Flags -contains 'SignerMismatch' -and -not (& $hasDecision 'Acknowledgement' 'SIGNER-MISMATCH' $eid)) {
                & $add 'PRIOR-SIGNER' 'Error' $sid ("the signer of the captured install '$sid' does not match this package's ($(& $safe $p.FlagText['SignerMismatch'] 300)): a winget manifest may name another vendor's product. " +
                    "If you checked it: $set -Acknowledge SIGNER-MISMATCH -Target $sid -Reason '<why>'")
            }
            if ($p.DataLoss -and -not (& $hasDecision 'Acknowledgement' 'DATA-LOSS' $eid) -and @($rows | Where-Object { $_.Code -eq 'PRIOR-DATA-LOSS' -and $_.Target -ceq $sid }).Count -eq 0) {
                & $add 'PRIOR-DATA-LOSS' 'Error' $sid ("the removability probe saw the uninstaller of '$sid' delete configuration in its folder. If that is acceptable for your users: " +
                    "$set -Acknowledge DATA-LOSS -Target $sid -Reason '<why>'")
            }
        }

        # ---- proof, window, data loss, approval (D17, L13, SV2, SV14) ----
        $states = @(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath)
        $groups = @()
        try { $groups = @(Get-Win32ToolkitPriorProofGroup -ProjectPath $ProjectPath) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $groups = @()
        }
        foreach ($e in $enforce) {
            $eid = [string](& $prop $e 'Id')
            $sid = & $safe $eid 40
            $capture = [string]$check.Lineage[$eid] -eq 'Capture'
            $st = @($states | Where-Object { $_.Id -ceq $eid }) | Select-Object -First 1
            # Fail closed: an Enforce rule the proof state does not name is not proven.
            if (-not $st -or $st.State -ne 'Proven') {
                if ($capture -or -not (& $hasDecision 'Waiver' 'PROOF' $eid)) {
                    $group = if ($groups.Count -gt 1) { @($groups | Where-Object { @($_.EntryIds) -ccontains $eid }) | Select-Object -First 1 } else { $null }
                    $groupArg = if ($group) { ' -ProofEntryId ' + (@($group.EntryIds) -join ',') } else { '' }
                    $waive = if ($capture) { '' } else { " Or ship it unproven on purpose: $set -Waive PROOF -Target $sid -Reason '<why>'." }
                    $why = if ($st) { & $safe $st.Reason 300 } else { 'its proof state could not be read' }
                    # What the newest failed run's exit code says to do (live row OP-NEWER: after a 69102 the only remedy offered was
                    # the same run, which fails the same way while VersionMax is below the version on the test VM). The run is "the
                    # newest run that checked it": a watched or Sandbox run revokes a proof too but is no proof run (live row MSIBUSY).
                    $exitCode = if ($st -and $st.PSObject.Properties['LastExitCode']) { $st.LastExitCode } else { $null }
                    $observed = & $observedOf $e
                    # The rule's floor, lowered to the observed version only when that is below it.
                    $minNow = & $safe (& $prop $e 'VersionMin') 64
                    $minV = if ($minNow) { ConvertTo-Win32ToolkitPriorVersion -Text $minNow } else { $null }
                    $obsV = if ($observed) { ConvertTo-Win32ToolkitPriorVersion -Text $observed } else { $null }
                    if ($minV -and $obsV -and $obsV -lt $minV) { $minNow = $observed }
                    $keepWindow = "-VersionMin '$($minNow.Replace("'", "''"))'"
                    # ... and its VersionMax raised to the observed version only when that is above it.
                    $maxNow = & $safe (& $prop $e 'VersionMax') 64
                    $maxV = if ($maxNow) { ConvertTo-Win32ToolkitPriorVersion -Text $maxNow } else { $null }
                    if ($obsV -and (-not $maxV -or $obsV -gt $maxV)) { $maxNow = $observed }
                    # Live row OP-UNPROVEN: the run did not match the rule's identity (PriorPresent-PreUpdate.<id> FAIL): proving it
                    # again fails the same way, and a PROOF waiver would ship a rule that matches nothing on such devices.
                    $unmatched = $st -and [string]$st.LastFailure -match ('(^|[ ,;])PriorPresent-PreUpdate\.' + [regex]::Escape($eid) + '($|[ ,;])')
                    $first = switch ($exitCode) {
                        69102 {
                            $widen = if ($capture) { "capture that newer version (Test-Win32ToolkitProject -ProjectPath '$ProjectPath' -Scenario SiblingCapture$(if ($observed) { " -SiblingVersion '$observed'" })) to raise its VersionMax" }
                                     else { "widen its window, keeping its mode and floor ($set -FromUpdateTest -Id $sid -Mode Enforce $keepWindow -VersionMax '$(if ($observed) { $observed } else { '<version>' })')" }
                            "The prior install on the test VM$(if ($observed) { " ($observed)" }) was newer than the rule's VersionMax (69102), so that run fails again: $widen, or prove it from a baseline inside its window (-SpecificVersion <version>). Then prove it: "
                        }
                        1618 { 'The newest run that checked it ended with the retry code 1618 (on the test VM: the prior app was still running after the close-apps dialog, Windows Installer was busy, or the prior install changed while the dialog was open): it says nothing about the rule. Run it again: ' }
                        69107 { 'The newest run that checked it ended with the retry code 69107 (on the test VM: a restart was pending, from Windows servicing or from the removal of the prior install): it says nothing about the rule. Run it again: ' }
                        69111 {
                            # Live row KILL-NATIVE: the same proof run refuses again while whatever set the kill switch is still there.
                            "The newest run that checked it ended with 69111: removal of prior installs was switched off on the test VM (RemovePriorDisabled = 1 under HKLM\SOFTWARE\$(if ($author) { $author } else { '<ScriptAuthor>' })\win32-toolkit, set by the package itself - an org hook - or by the test VM's checkpoint), so that run refuses again. Remove what sets it, then prove it: "
                        }
                        default {
                            if ($unmatched) {
                                $replace = if ($capture) { "capture the other installer technologies again (Test-Win32ToolkitProject -ProjectPath '$ProjectPath' -Scenario SiblingCapture) and apply its proposal again" }
                                           else { "replace it from that run's candidate, keeping its mode ($set -FromUpdateTest -Id $sid -Mode Enforce $keepWindow -VersionMax '$($maxNow.Replace("'", "''"))')" }
                                # No PROOF waiver: it would ship a rule that matches nothing on devices like the test VM.
                                $waive = ''
                                "The newest run that checked it found the install on the test VM but the rule's identity did not match it (PriorPresent-PreUpdate.$sid FAIL: its publisher, name or version window differ), so proving it again fails the same way: $replace, then prove it: "
                            }
                            else { 'Prove it: ' }
                        }
                    }
                    & $add 'PRIOR-PROOF' 'Error' $sid ("the Enforce rule '$sid' is not proven ($why): it removes another install as SYSTEM. $first" +
                        "Test-Win32ToolkitProject -ProjectPath '$ProjectPath' -Scenario Update -Backend HyperV -TestMode Unattended$groupArg.$waive")
                }
            }
            if ($st -and $st.State -eq 'Proven' -and @($st.ProvenVersions | Where-Object { $_ }).Count -gt 0) {
                $oldest = @($st.ProvenVersions | ForEach-Object { ConvertTo-Win32ToolkitPriorVersion -Text ([string]$_) } | Where-Object { $null -ne $_ } | Sort-Object) | Select-Object -First 1
                $minText = [string](& $prop $e 'VersionMin')
                $min = if ($minText) { ConvertTo-Win32ToolkitPriorVersion -Text $minText } else { $null }
                if ($null -ne $oldest -and ($null -eq $min -or $min -lt $oldest) -and ($capture -or -not (& $hasDecision 'Waiver' 'VERSIONMIN' $eid))) {
                    $waive = if ($capture) { '' } else { " Or accept it: $set -Waive VERSIONMIN -Target $sid -Reason '<why>'." }
                    & $add 'PRIOR-VERSIONMIN' 'Error' $sid ("the Enforce rule '$sid' removes versions from $(if ($minText) { & $safe $minText 64 } else { 'any version' }) on, but the oldest version a proof run removed is $oldest. " +
                        "Raise VersionMin to $oldest ($set ... -VersionMin $oldest), or prove the older version.$waive")
                }
            }
            if ($st -and $st.DataLoss -and -not (& $hasDecision 'Acknowledgement' 'DATA-LOSS' $eid)) {
                & $add 'PRIOR-DATA-LOSS' 'Error' $sid ("the proof run saw the uninstaller of '$sid' delete user data. If that is acceptable for your users: " +
                    "$set -Acknowledge DATA-LOSS -Target $sid -Reason '<why>'")
            }
            if ($capture) {
                $tuple = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $e
                $ok = @($decisions | Where-Object { $_.Kind -eq 'Approval' -and $_.Target -ceq $eid -and $_.Latest -and -not $_.Demoted -and [string]$_.ProposalHash -ceq $tuple }).Count -gt 0
                if (-not $ok) {
                    # The command names the current proposal of this identity (proposal ids follow the records; a rule id
                    # need not be one), else the rule id.
                    $cur = @(if ($sibling) { @($sibling.Proposals) | Where-Object { $_.ProposalHash -ceq $tuple } }) | Select-Object -First 1
                    $propId = if ($cur) { & $safe $cur.ProposalId 40 } else { $sid }
                    & $add 'PRIOR-APPROVAL' 'Error' $sid "the captured Enforce rule '$sid' has no current approval of exactly this identity (its approval is missing, was demoted, or the rule changed since): approve its proposal again ($set -FromSiblingCapture -Mode Enforce -ProposalId $propId)."
                }
            }
        }

        # ---- advisory rows ----
        foreach ($e in @($entries | Where-Object { [string](& $prop $_ 'Mode') -ceq 'Block' })) {
            $tech = switch ([string](& $prop $e 'UninstallerType')) { 'nullsoft' { 'the NSIS install' } 'inno' { 'the Inno Setup install' } default { 'the other install' } }
            $lo = [string](& $prop $e 'VersionMin'); $hi = [string](& $prop $e 'VersionMax')
            $window = if ($lo) { "$(& $safe $lo 64) <= version <= $(& $safe $hi 64)" } else { "version <= $(& $safe $hi 64)" }
            # An identity a Windows Sandbox or assisted capture saw stays Block-only (live rows SB-CAPTURE and ASSISTED): no "until".
            $blockOnly = @(if ($sibling) { @($sibling.Proposals) | Where-Object { $_.ProposalHash -ceq $tupleOf[[string](& $prop $e 'Id')] -and ($_.Flags -contains 'Sandbox' -or $_.Flags -contains 'Assisted') } }).Count -gt 0
            $until = if ($blockOnly) { ' (its identity stays Block-only: a Windows Sandbox or assisted capture saw it)' } else { ' until the rule is Enforce' }
            & $add 'PRIOR-BLOCK-FLEET' 'Warning' (& $safe (& $prop $e 'Id') 40) "devices with $tech ($(& $safe (& $prop $e 'Key')), $window) FAIL this install (69101)$($until): assign it to a pilot group first."
        }
        if ($enforce.Count -gt 0) {
            $keys = (@($enforce | ForEach-Object { & $safe (& $prop $_ 'Key') 128 }) -join ', ')
            & $add 'PRIOR-ENFORCE-PILOT' 'Warning' ((@($enforce | ForEach-Object { & $safe (& $prop $_ 'Id') 40 })) -join ',') ("this package removes another install of the app ($keys) as SYSTEM before it installs: assign it to a pilot group first. " +
                "Kill switch: the DWORD RemovePriorDisabled = 1 under HKLM\SOFTWARE\$author\win32-toolkit makes every device refuse instead of removing (exit 69111); set it with a 64-bit remediation script.")
            $orgUi = & $prop $cfg 'OrgUi'
            $welcome = & $prop $orgUi 'Welcome'
            if ($null -ne $welcome -and $welcome.PSObject.Properties['Enabled'] -and $welcome.Enabled -eq $false) {
                $procs = (@($enforce | ForEach-Object { @(& $prop $_ 'ProcessNames') } | Where-Object { $_ } | ForEach-Object { & $safe $_ 64 } | Select-Object -Unique) -join ', ')
                & $add 'PRIOR-NO-WELCOME' 'Warning' '' "the org template turns the welcome dialog off, so nothing closes $(if ($procs) { $procs } else { 'the app' }) before the removal: devices where it runs retry with 1618 until it is closed."
            }
            $wingetId = [string](& $prop (& $prop $cfg 'Source') 'WingetId')
            if ($wingetId -match '^(Python\.Python\.|Microsoft\.DotNet\.|Microsoft\.VCRedist\.|EclipseAdoptium\.Temurin\.|Oracle\.JDK\.)' -or $wingetId -match '\.Preview$') {
                & $add 'PRIOR-CLASS-E' 'Warning' '' "$(& $safe $wingetId 128) belongs to a versioned family whose versions install side by side: make sure the removed install is not one other apps still need."
            }
            if ($Stage -eq 'Advisory') {
                $app = & $prop $cfg 'App'
                $display = [string](& $prop $app 'DisplayName'); if (-not $display) { $display = [string](& $prop $app 'Name') }
                $prev = Get-Win32ToolkitPreviousProject -TemplateDirectory (Split-Path -Path $ProjectPath.TrimEnd('\') -Parent) -Version ([string](& $prop $app 'Version')) -WingetId $wingetId -Vendor ([string](& $prop $app 'Vendor')) -DisplayName $display -ExcludePath $ProjectPath.TrimEnd('\')
                $published = @(@($prev.Matches) | Where-Object { $_.Published })
                if ($published.Count) {
                    & $add 'PRIOR-PREDECESSOR-PUBLISHED' 'Warning' '' "$((@($published) | ForEach-Object { $_.Name }) -join ', ') is published in Intune: unassign it before you assign this one, or a version-equal tattoo makes the old app reinstall over this package."
                }
            }
        }
        foreach ($e in $entries) {
            $eid = [string](& $prop $e 'Id')
            if ([string]$check.Lineage[$eid] -ne 'Capture') { continue }
            # The floor capture's release date (spec 2.11 PRIOR-UNCOVERED; D60: the floor is the oldest release of the last 12 months).
            $cid = [string](& $prop $e 'CaptureId')
            $floorDate = if ($sibling -and $cid) { [string](@($sibling.Captures | Where-Object { $_.CaptureId -ceq $cid }) | Select-Object -First 1 | ForEach-Object { $_.ReleaseDate }) } else { '' }
            $released = if ($floorDate -cmatch '^\d{4}-\d{2}-\d{2}$') { " (released $floorDate)" } else { '' }
            & $add 'PRIOR-UNCOVERED' 'Info' (& $safe $eid 40) "devices with $(& $safe (& $prop $e 'Key')) below $(& $safe (& $prop $e 'VersionMin') 64)$released keep it next to this package (left as it is); devices above $(& $safe (& $prop $e 'VersionMax') 64) fail with 69102."
        }
        return (& $finish)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        $msg = & $safe $_.Exception.Message 300
        if ($Stage -eq 'Export') { return [object[]]@([pscustomobject]@{ Code = 'PRIOR-INVALID'; Severity = 'Error'; Target = ''; Message = "the prior-install rules could not be checked ($msg): nothing is packaged until they can." }) }
        return [object[]]@([pscustomobject]@{ Code = 'PRIOR-UNCHECKED'; Severity = 'Warning'; Target = ''; Message = "the prior-install rules could not be checked ($msg)." })
    }
}
