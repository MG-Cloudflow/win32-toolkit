function Get-Win32ToolkitPriorProofState {
    <#
    .SYNOPSIS
        The proof state of each prior-install rule of a project: Proven, NotProven or NotNeeded.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.11, D17, SV5, SV6, L12, L14, L26). An Enforce rule removes another vendor's
        install as SYSTEM, so it may ship only after a Hyper-V Unattended Update test removed exactly that prior with
        exactly this package. Pure read of AppConfig.json, Documentation\TestResults.json, the decisions file and the
        capture records:
          - Block and Report entries: NotNeeded.
          - Candidates: Update records with a Proof whose PriorInstallsHash, ScriptSha256, FilesSha256,
            SupportFilesSha256 and CatalogVersion equal the project's CURRENT binding (Get-Win32ToolkitPriorProofBinding)
            and whose EntryIds name the entry; records that were not run (NotRun) or whose baseline was unavailable
            are ignored.
          - The newest candidate with Verdict Failed (any backend, any mode) revokes every older pass.
          - Proven: a newer candidate with Verdict Passed, Backend HyperV, Mode Unattended, RequirementChecked, and
            PASS for Requirement-PreUpdate, PriorPresent-PreUpdate.<id>, PriorAbsent-PostUpdate.<id>,
            NewAppIntact-PostUpdate and Tattoo-PostUpdate; for capture lineage also SiblingIdentityStable-PreUpdate.<id>,
            PriorResidue-PostUpdate.<id> and a BaselineInstallerSha256 equal to the floor capture record's installer
            hash (the record named by the entry's CaptureId, hash-verified). User data (DATA lines, Proof.DataLoss)
            never decides: it only sets DataLoss.
        ProvenVersions = the observed versions of the entry in every proving record; DataLoss = a proving record lists
        the entry in Proof.DataLoss. Never throws (a W32T.* error from a helper is re-thrown).
    .PARAMETER ProjectPath
        The PSADT project folder.
    .OUTPUTS
        [pscustomobject[]] one per entry: Id, Mode, Lineage (Capture|UpdateTest|Operator), State, Reason, ProvenOn,
        ProvenVersions[], DataLoss, LastFailure (the failing assertions of the newest failed candidate, led by
        'the update exited with code N; ' when its Notes give the update's exit code, or ''), LastExitCode (that code as
        [int], else $null). A NotProven Reason after a binding change names the parts that changed (deploy script,
        Files, SupportFiles, rules, catalog); after a failed candidate that was not a Hyper-V Unattended run it names
        that run's backend and mode (a watched or Sandbox run that fails revokes a proof too, live row MSIBUSY).
    .EXAMPLE
        Get-Win32ToolkitPriorProofState -ProjectPath $p | Where-Object State -eq 'NotProven'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $entries = @()
    if ($cfg.PSObject.Properties['PriorInstalls'] -and $cfg.PriorInstalls -and $cfg.PriorInstalls.PSObject.Properties['Entries']) {
        $entries = @(@($cfg.PriorInstalls.Entries) | Where-Object { $null -ne $_ })
    }
    if ($entries.Count -eq 0) { return @() }

    $decisions = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath)
    $lineage = (Test-Win32ToolkitPriorInstallEntry -Config $cfg -Decisions $decisions -PreCapture).Lineage
    $binding = Get-Win32ToolkitPriorProofBinding -ProjectPath $ProjectPath
    $results = Get-Win32ToolkitTestResult -ProjectPath $ProjectPath
    $results = @($results | Where-Object { $null -ne $_ })

    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $null } }
    $assertResult = {
        param($Record, [string]$Name)
        $a = @(@(& $prop $Record 'Assertions') | Where-Object { $null -ne $_ -and [string](& $prop $_ 'Name') -ceq $Name }) | Select-Object -Last 1
        if ($a) { [string](& $prop $a 'Result') } else { '' }
    }
    $dateOf = {
        param($Record)
        $ts = & $prop $Record 'TimestampUtc'
        if ($ts -is [datetime]) { return $ts.ToUniversalTime().ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        $s = [string]$ts
        if ($s.Length -ge 10) { return $s.Substring(0, 10) }
        return ''
    }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $entries) {
        $id = [string](& $prop $e 'Id')
        $mode = [string](& $prop $e 'Mode')
        $lin = if ($id -and $lineage.ContainsKey($id)) { $lineage[$id] } else { 'Operator' }
        $state = [ordered]@{ Id = $id; Mode = $mode; Lineage = $lin; State = 'NotNeeded'; Reason = ''; ProvenOn = ''; ProvenVersions = [string[]]@(); DataLoss = $false; LastFailure = ''; LastExitCode = $null }
        if ($mode -cne 'Enforce') {
            $state.Reason = "policy $mode removes nothing"
            $out.Add([pscustomobject]$state)
            continue
        }

        $named = [System.Collections.Generic.List[int]]::new()
        $candidates = [System.Collections.Generic.List[int]]::new()
        for ($i = 0; $i -lt $results.Count; $i++) {
            $r = $results[$i]
            if ([string](& $prop $r 'Scenario') -ne 'Update') { continue }
            $proof = & $prop $r 'Proof'
            if ($null -eq $proof) { continue }
            if (@(@(& $prop $proof 'EntryIds') | ForEach-Object { [string]$_ }) -cnotcontains $id) { continue }
            if ($null -ne (& $prop $r 'NotRun')) { continue }
            $baseline = & $prop $r 'Baseline'
            if ($baseline -and ([string](& $prop $baseline 'Unavailable') -eq 'True')) { continue }
            $named.Add($i)
            $same = ([string](& $prop $proof 'PriorInstallsHash') -ceq $binding.PriorInstallsHash) -and ([string](& $prop $proof 'ScriptSha256') -ceq $binding.ScriptSha256) -and
                ([string](& $prop $proof 'FilesSha256') -ceq $binding.FilesSha256) -and ([string](& $prop $proof 'SupportFilesSha256') -ceq $binding.SupportFilesSha256) -and
                ([string](& $prop $proof 'CatalogVersion') -ceq $binding.CatalogVersion)
            if ($same) { $candidates.Add($i) }
        }
        $lastFailed = -1
        foreach ($i in $candidates) { if ([string](& $prop $results[$i] 'Verdict') -eq 'Failed') { $lastFailed = $i } }
        if ($lastFailed -ge 0) {
            $state.LastFailure = (@(@(& $prop $results[$lastFailed] 'Assertions') | Where-Object { [string](& $prop $_ 'Result') -eq 'FAIL' } | ForEach-Object { ConvertTo-Win32ToolkitSafeText -Text ([string](& $prop $_ 'Name')) -MaxLength 80 }) -join ', ')
            # The update's own exit code, when the record's Notes give it (live rows DEMOTE, RC2-PROOF, MSIBUSY: 69105, 69107 and
            # 1618 all read as the same failing assertions). It leads, so a shortened text keeps it (live row OP-NEWER: the
            # 69102 clause was cut off at the end of eight assertion names).
            $exitNote = [regex]::Match([string](& $prop $results[$lastFailed] 'Notes'), '(?:The update|Intune-parity phase ''Update[^'']*'') exited with code (-?\d{1,10})')
            $exitValue = 0
            if ($exitNote.Success -and [int]::TryParse($exitNote.Groups[1].Value, [ref]$exitValue)) {
                $state.LastExitCode = $exitValue
                $state.LastFailure = ("the update exited with code $exitValue; " + $state.LastFailure).TrimEnd(';', ' ')
            }
        }

        $floorSha = $null
        if ($lin -eq 'Capture') {
            $cid = [string](& $prop $e 'CaptureId')
            $rec = if ($cid -cmatch '^[a-f0-9]{16}$') { @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath -CaptureId $cid) | Select-Object -First 1 } else { $null }
            if ($rec) { $floorSha = [string]$rec.Sibling.InstallerSha256 }
        }
        $required = @('Requirement-PreUpdate', "PriorPresent-PreUpdate.$id", "PriorAbsent-PostUpdate.$id", 'NewAppIntact-PostUpdate', 'Tattoo-PostUpdate')
        if ($lin -eq 'Capture') { $required += @("SiblingIdentityStable-PreUpdate.$id", "PriorResidue-PostUpdate.$id") }
        $proving = [System.Collections.Generic.List[int]]::new()
        $weak = $false
        foreach ($i in $candidates) {
            if ($i -le $lastFailed) { continue }
            $r = $results[$i]
            if ([string](& $prop $r 'Verdict') -ne 'Passed') { continue }
            $proof = & $prop $r 'Proof'
            if ([string](& $prop $r 'Backend') -ne 'HyperV' -or [string](& $prop $r 'Mode') -ne 'Unattended' -or (& $prop $proof 'RequirementChecked') -ne $true) { $weak = $true; continue }
            if (@($required | Where-Object { (& $assertResult $r $_) -ne 'PASS' }).Count -gt 0) { continue }
            if ($lin -eq 'Capture' -and (-not $floorSha -or [string](& $prop $proof 'BaselineInstallerSha256') -cne $floorSha)) { continue }
            $proving.Add($i)
        }

        if ($proving.Count -gt 0) {
            $state.State = 'Proven'
            $state.ProvenOn = & $dateOf $results[$proving[$proving.Count - 1]]
            $versions = [System.Collections.Generic.List[string]]::new()
            foreach ($i in $proving) {
                $proof = & $prop $results[$i] 'Proof'
                $v = & $prop (& $prop $proof 'ObservedVersions') $id
                if ($v -and $versions -cnotcontains [string]$v) { $versions.Add([string]$v) }
                if (@(@(& $prop $proof 'DataLoss') | ForEach-Object { [string]$_ }) -ccontains $id) { $state.DataLoss = $true }
            }
            $state.ProvenVersions = [string[]]$versions.ToArray()
            $state.Reason = "proven by a Hyper-V Unattended Update test on $($state.ProvenOn)"
        }
        else {
            $state.State = 'NotProven'
            # What changed since the newest run that named the entry (live row OP-OWN: declaring a dependency changed
            # SupportFiles\AppConfig.json, and the reason said only "the package or its rules changed").
            $changedParts = @()
            if ($named.Count -gt 0 -and $candidates.Count -eq 0) {
                $np = & $prop $results[$named[$named.Count - 1]] 'Proof'
                # SupportFiles is one tree hash: AppConfig.json, the org hooks, UpdateRequirement.ps1 or any other file there
                # (live rows KILL-*, APP-RUNNING, OP-EXPORT: an added flag file or a rewritten requirement copy was named
                # "AppConfig.json" before).
                # No brackets inside a part: the reason itself is shown in brackets (live rows KILL-WOW, APP-RUNNING).
                $partNames = [ordered]@{ PriorInstallsHash = 'the prior-install rules or the own identity'; ScriptSha256 = 'the deploy script'; FilesSha256 = 'the Files folder'
                    SupportFilesSha256 = 'a file in SupportFiles was added, removed or changed - AppConfig.json, an org hook, UpdateRequirement.ps1 or another file'; CatalogVersion = 'the remove-prior catalog' }
                $changedParts = @($partNames.Keys | Where-Object { [string](& $prop $np $_) -cne [string]$binding.$_ } | ForEach-Object { $partNames[$_] })
            }
            $state.Reason = if ($named.Count -eq 0) { 'no proof run (Update test on Hyper-V, unattended)' }
            elseif ($candidates.Count -eq 0) { "the package or its prior-install rules changed after the last proof run$(if ($changedParts.Count) { " ($($changedParts -join '; '))" }): run it again" }
            elseif ($lastFailed -ge 0 -and @($candidates | Where-Object { $_ -gt $lastFailed }).Count -eq 0) {
                $fb = [string](& $prop $results[$lastFailed] 'Backend'); $fm = [string](& $prop $results[$lastFailed] 'Mode')
                if ($fb -eq 'HyperV' -and $fm -eq 'Unattended') { "the newest proof run failed ($($state.LastFailure))" }
                else {
                    $kind = if ($fb -eq 'Sandbox') { 'a Windows Sandbox run' } elseif ($fb -eq 'HyperV') { 'a watched Hyper-V run' } else { 'a run' }
                    "the newest run that checked it, $kind, failed ($($state.LastFailure)); a failed run revokes the proof whatever its backend or mode"
                }
            }
            elseif ($lin -eq 'Capture' -and -not $floorSha) { 'its floor capture record is missing or changed (re-capture)' }
            elseif ($weak) { 'only Sandbox or watched runs passed: a proof needs a Hyper-V Unattended Update test' }
            else { 'no passing proof run checked every required assertion' }
        }
        $out.Add([pscustomobject]$state)
    }
    return $out.ToArray()
}
