function Copy-Win32ToolkitPriorInstallState {
    <#
    .SYNOPSIS
        Gives a newly created project the prior-install rules of the version it rebuilds or of the version before it.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.13; D18, L4, L5, L33, D61). Called by Invoke-Win32Toolkit and
        New-Win32ToolkitManualApp right after the configure step (AppConfig.json, with App and Source, exists; the install
        capture has not run yet):

        1. Same-version rebuild (L4): -Snapshot (Get-Win32ToolkitPriorInstallSnapshot, taken before Create-PSADTProject
           deleted the folder) restores the decisions file, the lost-rules file (PriorInstallDropped.json) and the
           Documentation\SiblingCapture* files byte for byte and, when the old AppConfig had a PriorInstalls property, its
           entries AS THEY WERE (no bump). TestResults.json is not restored: the rebuilt package needs a new proof run.
           A snapshot of a project a test guest changed (Tampered, GUEST-TAMPER) restores nothing: only the identities
           of its rules (Lost) are recorded in Documentation\PriorInstallDropped.json (Add-Win32ToolkitPriorInstallDropped,
           first, before anything else can fail), and the new project continues with step 2 like any new version. Export
           lists each recorded rule as ID-PRIOR-DROPPED until it is declared again or acknowledged (fail-closed). With no
           version before it, such a project gets an empty PriorInstalls set, so it is the next version's carry source.
        2. Else the carry-forward source (L5): -SourceProjectPath, else Get-Win32ToolkitPriorCarrySource (the highest
           lower version of the same app and architecture with a PriorInstalls property; an empty list carries nothing).
           Per entry: Operator / UpdateTest lineage of another family -> VersionMax raised to the new App.Version (D18);
           of the package's own family (an EXE package) -> raised to the SOURCE project's App.Version (L33, always below
           the new one); SiblingCapture lineage -> unchanged (D61). Waivers and acknowledgements are NOT carried (they
           were decisions about the previous package). For every carried capture-lineage rule the capture records
           it rests on (its CaptureId and every source record that re-derives the same identity) are copied byte for
           byte into Documentation\SiblingCapture\, and its latest Approval into the decisions file: host files only,
           re-verified by Get-Win32ToolkitSiblingCaptureRecord (hash prefix) on every later use (installer-identity
           PR 3b, A1). The source's lost rules (its PriorInstallDropped.json) that it neither declared again nor
           acknowledged are recorded in the new project's file too, so a lost rule is never forgotten by the next version.
           A source that a test guest changed (Documentation\GuestTamper.json) gives NOTHING (Action Refused, one
           warning): the new project gets an empty list, the identities of that version's rules and of its lost rules
           are recorded in the new project's PriorInstallDropped.json, and Export lists each one as ID-PRIOR-DROPPED until
           it is declared again or acknowledged.

        Then every entry is checked with Test-Win32ToolkitPriorInstallEntry -PreCapture against the new project (L34: no
        own-identity precondition; the own key is the packaged MSI's Source.ProductCode): an entry naming it is dropped
        with an ID-PRIOR-OWN warning; any other failure (an invalid or duplicate Id and an entry that is not an object
        included) drops that entry alone with one warning naming the problem (Export then reports ID-PRIOR-DROPPED
        against the carry source). The Block / Enforce process names are merged into
        ProcessesToClose (D20, Add-Win32ToolkitPriorInstallProcessName) and AppConfig.json is written once. Host line:
        "Carried 1 prior-install rule from <project> (Enforce: ARP <Key>); it needs a new proof run."

        Never throws (C-7): any problem gives one warning and leaves the new project without carried rules (Export then
        reports ID-PRIOR-DROPPED); a W32T.* error is re-thrown.
    .PARAMETER ProjectPath
        The new project.
    .PARAMETER Snapshot
        The snapshot of the version being rebuilt ($null when it is not a rebuild).
    .PARAMETER SourceProjectPath
        The project to carry from (default: Get-Win32ToolkitPriorCarrySource).
    .OUTPUTS
        [pscustomobject] Action (Restored | Carried | Refused | None), Source, Entries (ids written), Dropped (@{ Id; Reason }),
        Own (ids dropped as the package's own key), ProcessNamesAdded, Records (capture records copied), Approvals
        (approvals copied), Lost (ids recorded in Documentation\PriorInstallDropped.json by this call).
    .EXAMPLE
        $null = Copy-Win32ToolkitPriorInstallState -ProjectPath $projectFullPath -Snapshot $priorSnapshot
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowNull()]
        [object]$Snapshot,

        [AllowEmptyString()]
        [string]$SourceProjectPath = ''
    )

    $summary = [pscustomobject]@{ Action = 'None'; Source = ''; Entries = @(); Dropped = @(); Own = @(); ProcessNamesAdded = @(); Records = 0; Approvals = 0; Lost = @() }
    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    # The identities of rules this project does not get (Documentation\PriorInstallDropped.json): Export lists each one as
    # ID-PRIOR-DROPPED until it is declared again or acknowledged.
    # Never throws (C-7): a failure costs only this record (one warning), never the rules carried next to it.
    $recordLost = {
        param([object[]]$Identities, [string]$From)
        if (@($Identities | Where-Object { $null -ne $_ }).Count -eq 0) { return }
        try {
            $ids = @(Add-Win32ToolkitPriorInstallDropped -ProjectPath $ProjectPath -Entry $Identities -From $From -WhatIf:$WhatIfPreference -Confirm:$false)
            $summary.Lost = [string[]]@(@($summary.Lost) + $ids | Where-Object { $_ } | Select-Object -Unique)
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $names = (@($Identities | ForEach-Object { & $safe (& $prop $_ 'Id') 40 } | Where-Object { $_ }) -join ', ')
            Write-Warning ("The prior-install rules this project does not get ($names) could not be recorded in Documentation\PriorInstallDropped.json (" + (& $safe $_.Exception.Message 200) + '): declare them again (Set-Win32ToolkitPriorInstall) or make sure they are not needed.')
        }
    }
    $identityOf = { param($Entry, [string]$From) [pscustomobject]@{ Id = [string](& $prop $Entry 'Id'); Kind = [string](& $prop $Entry 'Kind'); Key = [string](& $prop $Entry 'Key'); View = [string](& $prop $Entry 'View'); From = $From } }
    try {
        if ($null -ne $Snapshot -and $Snapshot.PSObject.Properties['Tampered'] -and $Snapshot.Tampered) {
            # A project a test guest changed: nothing of it is restored, but which rules it had is recorded first.
            & $recordLost @($Snapshot.Lost) (Split-Path -Path ([string]$Snapshot.ProjectPath).TrimEnd('\') -Leaf)
            $Snapshot = $null
        }
        $cfgFile = Join-Path $ProjectPath 'SupportFiles\AppConfig.json'
        if (-not (Test-Path -LiteralPath $cfgFile -PathType Leaf)) { return $summary }
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $newVersion = [string](& $prop (& $prop $cfg 'App') 'Version')
        $ownFamily = [string](& $prop (& $prop $cfg 'Installer') 'Type') -eq 'exe'
        $entries = @()
        $sourceName = ''

        if ($null -ne $Snapshot -and $Snapshot.PSObject.Properties['HasPriorInstalls']) {
            # 1. Same-version rebuild: the host files as they were, then the entries as they were.
            $files = @()
            if ($null -ne $Snapshot.Decisions) { $files += [pscustomobject]@{ Path = 'Documentation\PriorInstallDecisions.json'; Bytes = [byte[]]$Snapshot.Decisions } }
            if ($Snapshot.PSObject.Properties['Dropped'] -and $null -ne $Snapshot.Dropped) { $files += [pscustomobject]@{ Path = 'Documentation\PriorInstallDropped.json'; Bytes = [byte[]]$Snapshot.Dropped } }
            $files += @($Snapshot.CaptureFiles | Where-Object { $null -ne $_ })
            foreach ($f in $files) {
                $rel = [string]$f.Path
                if ($rel -notmatch '^Documentation\\(PriorInstallDecisions\.json|PriorInstallDropped\.json|SiblingCapture[^\\]*\.json|SiblingCapture\\[^\\]+\.json)$') { Write-Verbose "Copy-Win32ToolkitPriorInstallState: '$rel' is not a prior-install file - not restored."; continue }
                $target = Join-Path $ProjectPath $rel
                if ($PSCmdlet.ShouldProcess($target, 'Restore the prior-install file of the rebuilt version')) {
                    $null = New-Item -ItemType Directory -Path (Split-Path -Path $target -Parent) -Force
                    [System.IO.File]::WriteAllBytes($target, [byte[]]$f.Bytes)
                }
            }
            if ($Snapshot.HasPriorInstalls) {
                $summary.Action = 'Restored'
                $sourceName = Split-Path -Path $ProjectPath -Leaf
                $old = ConvertFrom-Json -InputObject ([string]$Snapshot.PriorInstallsJson)
                $entries = @(@(& $prop $old 'Entries') | Where-Object { $null -ne $_ })
            }
        }
        if ($summary.Action -eq 'None') {
            # 2. Carry-forward from the version before.
            $source = $null
            if ($SourceProjectPath) {
                $sCfg = Get-Win32ToolkitAppConfig -ProjectPath $SourceProjectPath
                if ($null -ne $sCfg.PSObject.Properties['PriorInstalls']) {
                    $source = [pscustomobject]@{ Path = $SourceProjectPath; Name = (Split-Path -Path $SourceProjectPath -Leaf); Version = [string](& $prop (& $prop $sCfg 'App') 'Version')
                        Entries = @(@(& $prop $sCfg.PriorInstalls 'Entries') | Where-Object { $null -ne $_ }) }
                }
            }
            else { $source = Get-Win32ToolkitPriorCarrySource -ProjectPath $ProjectPath }
            if ($null -eq $source) {
                # Nothing to carry. A project that lost rules (a tampered rebuild) still gets an empty rule set, so it is
                # the next version's carry source (Get-Win32ToolkitPriorCarrySource) and hands its lost rules on.
                if (@($summary.Lost).Count -gt 0 -and $null -eq $cfg.PSObject.Properties['PriorInstalls'] -and $PSCmdlet.ShouldProcess($cfgFile, 'Write an empty prior-install rule set')) {
                    $cfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; Entries = @() }) -Force
                    $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg -Confirm:$false
                }
                return $summary
            }
            $summary.Action = 'Carried'
            $summary.Source = [string]$source.Path
            $sourceName = & $safe $source.Name 128
            $sourceVersion = [string]$source.Version
            $newKey = ConvertTo-Win32ToolkitPriorVersion -Text $newVersion
            $srcKey = ConvertTo-Win32ToolkitPriorVersion -Text $sourceVersion
            $carried = [System.Collections.Generic.List[object]]::new()
            # The rules the source itself lost (its PriorInstallDropped.json). Read leniently here: an unreadable file is
            # reported by the source's own Export.
            $srcLost = @()
            try { $srcLost = @(Get-Win32ToolkitPriorInstallDropped -ProjectPath ([string]$source.Path)) }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Warning ("The prior-install rules $sourceName has lost could not be read (" + (& $safe $_.Exception.Message 200) + '): they are not recorded in this project.')
            }
            if (Test-Path -LiteralPath (Join-Path ([string]$source.Path) 'Documentation\GuestTamper.json') -PathType Leaf) {
                # A test guest changed that project (GUEST-TAMPER): nothing it holds is trusted, so nothing is carried. The
                # new project gets an empty list and the identities of the source's rules (and of the rules it had lost)
                # are recorded, so Export lists each one as ID-PRIOR-DROPPED until it is declared again or acknowledged
                # (fail-closed), even after the source itself is re-created.
                $summary.Action = 'Refused'
                Write-Warning ("$sourceName was changed by a test guest (Documentation\GuestTamper.json): its prior-install rules, capture records and approvals are NOT carried. " +
                    'Declare the rules again with Set-Win32ToolkitPriorInstall (Export lists each one as ID-PRIOR-DROPPED until then).')
                & $recordLost (@(@($source.Entries) | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] } | ForEach-Object { & $identityOf $_ ([string]$source.Name) }) + $srcLost) ([string]$source.Name)
            }
            else {
                # A rule the source lost and neither declared again nor acknowledged stays lost in the new version.
                $srcAck = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath ([string]$source.Path) | Where-Object { $_.Kind -eq 'Acknowledgement' -and $_.Code -eq 'ID-PRIOR-DROPPED' } | ForEach-Object { $_.Target })
                $open = @($srcLost | Where-Object {
                        $d = $_
                        $srcAck -cnotcontains $d.Id -and @(@($source.Entries) | Where-Object { [string](& $prop $_ 'Kind') -ceq $d.Kind -and [string]::Equals([string](& $prop $_ 'Key'), $d.Key, [StringComparison]::OrdinalIgnoreCase) -and [string](& $prop $_ 'View') -ceq $d.View }).Count -eq 0
                    })
                & $recordLost $open ([string]$source.Name)
                foreach ($e in @($source.Entries)) {
                    # Per entry (C-7): only an object is copied. A JSON round trip, or an 'if' expression that outputs it,
                    # would enumerate an empty array ([] or [null]) into $null, and the validation below would then match
                    # no entry by position and drop every rule. An entry that is not an object is kept as it is, and the
                    # validation below drops it alone.
                    $copy = $e
                    if ($e -is [System.Management.Automation.PSCustomObject]) {
                        $copy = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $e -Depth 6)
                        $capture = [string](& $prop $copy 'Source') -ceq 'SiblingCapture' -or [string](& $prop $copy 'CaptureId')
                        if (-not $capture) {
                            $maxKey = ConvertTo-Win32ToolkitPriorVersion -Text ([string](& $prop $copy 'VersionMax'))
                            $to = if ($ownFamily) { $sourceVersion } else { $newVersion }
                            $toKey = if ($ownFamily) { $srcKey } else { $newKey }
                            # A hand-edited entry may have no VersionMax property at all; an existing one keeps its place.
                            if ($null -ne $toKey -and ($null -eq $maxKey -or $toKey -gt $maxKey)) {
                                if ($copy.PSObject.Properties['VersionMax']) { $copy.VersionMax = $to } else { $copy | Add-Member -NotePropertyName VersionMax -NotePropertyValue $to }
                            }
                        }
                    }
                    $carried.Add($copy)
                }
            }
            $entries = @($carried.ToArray())
        }

        # Re-validated against the new project before the install capture (L34).
        $ownCode = [string](& $prop (& $prop $cfg 'Source') 'ProductCode')
        $kept = [System.Collections.Generic.List[object]]::new()
        $dropped = [System.Collections.Generic.List[object]]::new()
        $own = [System.Collections.Generic.List[string]]::new()
        foreach ($e in $entries) {
            $eid = & $safe (& $prop $e 'Id') 40
            if ($ownCode -and [string]::Equals([string](& $prop $e 'Key'), $ownCode, [StringComparison]::OrdinalIgnoreCase)) {
                $own.Add($eid)
                Write-Warning "ID-PRIOR-OWN: the prior-install rule '$eid' names $(& $safe (& $prop $e 'Key')), this package's own uninstall key: it is not carried."
                continue
            }
            $kept.Add($e)
        }
        $probe = $cfg.PSObject.Copy()
        $probe | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; Entries = @($kept.ToArray()) }) -Force
        $check = Test-Win32ToolkitPriorInstallEntry -Config $probe -PreCapture
        $final = [System.Collections.Generic.List[object]]::new()
        # PerEntry holds one result per entry, in order: matched by position, so an entry with an invalid or a duplicate
        # Id (PerEntry names it 'entry <n>', or twice) is dropped too.
        $perEntry = @($check.PerEntry)
        for ($i = 0; $i -lt $kept.Count; $i++) {
            $e = $kept[$i]
            $pe = if ($perEntry.Count -eq $kept.Count) { $perEntry[$i] } else { $null }
            if ($null -eq $pe -or -not $pe.Valid) {
                $label = if ($pe) { & $safe $pe.Id 40 } else { & $safe (& $prop $e 'Id') 40 }
                $why = if ($pe) { (@($pe.Problems) | ForEach-Object { & $safe $_ 200 }) -join '; ' } else { 'it could not be checked' }
                $dropped.Add([pscustomobject]@{ Id = $label; Reason = $why })
                Write-Warning "The prior-install rule '$label' of $sourceName is not valid for this package and was not kept ($why). Declare it again (Set-Win32ToolkitPriorInstall) or acknowledge it at Export."
                continue
            }
            $final.Add($e)
        }
        $ids = [string[]]@($final | ForEach-Object { [string](& $prop $_ 'Id') })
        $order = [int[]]@(0..([Math]::Max(0, $final.Count - 1)))
        if ($final.Count -gt 1) { [Array]::Sort($ids, $order, [System.StringComparer]::Ordinal) }
        $sorted = @(if ($final.Count -gt 0) { $order | ForEach-Object { $final[$_] } })

        $cfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; Entries = $sorted }) -Force
        $added = @(Add-Win32ToolkitPriorInstallProcessName -Config $cfg)
        if ($PSCmdlet.ShouldProcess($cfgFile, 'Write the carried prior-install rules')) {
            $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg -Confirm:$false
        }
        $summary.Entries = [string[]]@($sorted | ForEach-Object { [string](& $prop $_ 'Id') })
        $summary.Dropped = @($dropped.ToArray())
        $summary.Own = [string[]]@($own.ToArray())
        $summary.ProcessNamesAdded = [string[]]$added

        # The capture records and approvals of carried capture-lineage rules (spec 2.13, A1).
        $capturedKept = @($sorted | Where-Object { [string](& $prop $_ 'Source') -ceq 'SiblingCapture' -or [string](& $prop $_ 'CaptureId') })
        if ($summary.Action -eq 'Carried' -and $summary.Source -and $capturedKept.Count -gt 0) {
            $srcSibling = ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $summary.Source
            $want = [ordered]@{}
            foreach ($e in $capturedKept) {
                $cid = [string](& $prop $e 'CaptureId')
                if ($cid) { $want[$cid] = $true }
                $tuple = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $e
                foreach ($row in @($srcSibling.Captures | Where-Object { $_.Tuple -ceq $tuple })) { $want[[string]$row.CaptureId] = $true }
            }
            $srcDir = Join-Path $summary.Source 'Documentation\SiblingCapture'
            $dstDir = Join-Path $ProjectPath 'Documentation\SiblingCapture'
            foreach ($id in @($want.Keys)) {
                $from = Join-Path $srcDir "$id.json"
                if ($id -cnotmatch '^[a-f0-9]{16}$' -or -not (Test-Path -LiteralPath $from -PathType Leaf)) { continue }
                if ($PSCmdlet.ShouldProcess((Join-Path $dstDir "$id.json"), 'Copy the capture record of a carried prior-install rule')) {
                    $null = New-Item -ItemType Directory -Path $dstDir -Force
                    Copy-Item -LiteralPath $from -Destination (Join-Path $dstDir "$id.json") -Force
                    $summary.Records++
                }
            }
            $srcDecisions = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $summary.Source)
            foreach ($e in $capturedKept) {
                $eid = [string](& $prop $e 'Id')
                $ap = @($srcDecisions | Where-Object { $_.Kind -eq 'Approval' -and $_.Target -ceq $eid -and $_.Latest }) | Select-Object -First 1
                if ($ap -and $PSCmdlet.ShouldProcess($eid, 'Copy the approval of a carried prior-install rule')) {
                    $null = Set-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath -Record @{ Kind = 'Approval'; Code = [string]$ap.Code; Target = $eid; Reason = ''; On = [string]$ap.On
                        ProposalId = [string]$ap.ProposalId; ProposalHash = [string]$ap.ProposalHash; CaptureIds = @($ap.CaptureIds); Demoted = [string]$ap.Demoted } -Confirm:$false
                    $summary.Approvals++
                }
            }
        }
        if ($sorted.Count -gt 0) {
            $parts = @($sorted | ForEach-Object { "$(& $safe (& $prop $_ 'Mode') 16): ARP $(& $safe (& $prop $_ 'Key'))" }) -join ', '
            $enforce = @($sorted | Where-Object { [string](& $prop $_ 'Mode') -ceq 'Enforce' }).Count
            $verb = if ($summary.Action -eq 'Restored') { 'Kept' } else { 'Carried' }
            $from = if ($summary.Action -eq 'Restored') { 'of the rebuilt version' } else { "from $sourceName" }
            $tail = if ($enforce -eq 1) { '; it needs a new proof run.' } elseif ($enforce -gt 1) { '; they need a new proof run.' } else { '.' }
            Write-Host "$verb $($sorted.Count) prior-install rule$(if ($sorted.Count -ne 1) { 's' }) $from ($parts)$tail" -ForegroundColor Yellow
        }
        return $summary
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning ("The prior-install rules could not be carried into '$ProjectPath' (" + (& $safe $_.Exception.Message 200) + '): declare them again with Set-Win32ToolkitPriorInstall (Export reports ID-PRIOR-DROPPED until then).')
        return $summary
    }
}
