function Invoke-Win32ToolkitPriorDemotion {
    <#
    .SYNOPSIS
        Proves the captured Enforce prior-install rules and demotes the ones that cannot be proven, in one bounded loop.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.15.4; D59a, SV25, L37, D17). The binding hash of a proof covers the whole rule
        set (SV6): removing a rule un-proves every other Enforce rule just proven. So proof and demotion run as one loop:

          1. (-Prove) Invoke-Win32ToolkitPriorProof for every group with an unproven Enforce rule;
          2. every CAPTURED Enforce rule still NotProven is removed from PriorInstalls (it is a proposal again), its latest
             Approval is marked Demoted (today), and one warning names the failing assertions of its latest proof record
             (or why there is none); the package goes on without removing that install;
          3. when step 2 removed something, Enforce rules remain and -Prove was given: back to step 1 for the remaining set.
        The loop stops at a round that demotes nothing, when no Enforce rule remains, or after min(1 + the number of
        captured Enforce rules, -MaxRounds) rounds - the set shrinks every round. Without -Prove (no Update test was
        asked for, or Hyper-V is not ready) one round of step 2 only.

        When no proof round is left (no -Prove, or the last round demoted a rule), a removal un-proves the captured rules
        that survived it, and nothing here can prove them again: they are demoted too (their proof is missing, D59a),
        each with a warning that names the rules demoted before it. So, unless -WhatIf, no captured Enforce rule is left
        unproven: Export never refuses one as unproven (PRIOR-PROOF) only because another captured rule was demoted (L37).
        This settle pass is spec Dv13 (awaiting maintainer confirmation). In a next version a demoted CARRIED rule still
        meets ID-PRIOR-DROPPED at Export (spec 2.15.4), like any demoted carried rule, until it is approved and proven
        again or the drop is acknowledged.

        Operator and Update-test Enforce rules are never demoted (Export decides, D17): one warning each. A demoted rule
        keeps its process names in ProcessesToClose (harmless). A W32T.* error of a proof run is re-thrown.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Prove
        Run the proof (Hyper-V Unattended Update tests) before demoting.
    .PARAMETER MaxRounds
        The most proof rounds, 1 to 4 (default 4; L37: never more than four).
    .OUTPUTS
        [pscustomobject] Rounds, Proven (ids), Demoted (@{ Id; Reason }), Unproven (operator / Update-test ids left
        unproven).
    .EXAMPLE
        $r = Invoke-Win32ToolkitPriorDemotion -ProjectPath $p -Prove
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [switch]$Prove,

        [ValidateRange(1, 4)]
        [int]$MaxRounds = 4
    )

    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $today = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $summary = [pscustomobject]@{ Rounds = 0; Proven = [string[]]@(); Demoted = @(); Unproven = [string[]]@() }
    $demoted = [System.Collections.Generic.List[object]]::new()
    $cfgFile = Join-Path $ProjectPath 'SupportFiles\AppConfig.json'

    $initial = @(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath)
    $captured = @($initial | Where-Object { $_.Mode -ceq 'Enforce' -and $_.Lineage -eq 'Capture' }).Count
    $bound = [Math]::Min(1 + $captured, $MaxRounds)
    if (-not $Prove) { $bound = 1 }

    # A round proves (with -Prove) and demotes. Once no round is left, a "settle" pass only re-reads the state and demotes
    # the captured rules the previous removal un-proved; every pass removes at least one rule or ends the loop.
    $round = 0
    $settle = $false
    $removed = [string[]]@()
    while ($true) {
        if ($settle) { $states = @(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath) }
        else {
            $round++
            $summary.Rounds = $round
            $states = if ($Prove) { @(Invoke-Win32ToolkitPriorProof -ProjectPath $ProjectPath) } else { @(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath) }
        }
        $failing = @($states | Where-Object { $_.Mode -ceq 'Enforce' -and $_.Lineage -eq 'Capture' -and $_.State -eq 'NotProven' })
        if ($failing.Count -eq 0) { break }
        $ids = [string[]]@($failing | ForEach-Object { $_.Id })
        if (-not $PSCmdlet.ShouldProcess($cfgFile, "Demote the unproven captured prior-install rule(s) $($ids -join ', ')")) { break }
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        # The current proposal of each failing rule's identity, read before the removal (live row RAISE: the warning advised
        # "-Mode Enforce -ProposalId <id>" for an identity whose records had made it Block-only). Fail-open: none known.
        $proposalOf = @{}
        try {
            $props = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $ProjectPath).Proposals | Where-Object { $null -ne $_ })
            foreach ($e in @(@(& $prop (& $prop $cfg 'PriorInstalls') 'Entries') | Where-Object { $null -ne $_ -and $ids -ccontains [string](& $prop $_ 'Id') })) {
                $tuple = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $e
                $pp = @($props | Where-Object { [string]$_.ProposalHash -ceq $tuple }) | Select-Object -First 1
                if ($pp) { $proposalOf[[string](& $prop $e 'Id')] = $pp }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "The proposals of the demoted rules could not be read: $($_.Exception.Message)"
        }
        $keep = @(@(& $prop (& $prop $cfg 'PriorInstalls') 'Entries') | Where-Object { $null -ne $_ -and $ids -cnotcontains [string](& $prop $_ 'Id') })
        $cfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; Entries = @($keep) }) -Force
        $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg -Confirm:$false
        foreach ($f in $failing) {
            $null = Set-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath -Record @{ Target = [string]$f.Id; On = $today } -DemoteTarget -Confirm:$false
            $why = if ($settle) {
                $left = if ($Prove) { "the last proof round ($bound) has run" } else { 'no proof runs here (an Update test on the Hyper-V test VM proves it)' }
                "its proof also covered $(& $safe ($removed -join ', ') 200), demoted just before it, and $left"
            }
            elseif ($f.LastFailure) {
                # The proof state leads with the update's exit code when the run gave one (it is not an assertion).
                if ($f.PSObject.Properties['LastExitCode'] -and $null -ne $f.LastExitCode) { "the proof run failed: $(& $safe $f.LastFailure 300)" } else { "failing assertions: $(& $safe $f.LastFailure 300)" }
            }
            else { & $safe $f.Reason 200 }
            $demoted.Add([pscustomobject]@{ Id = [string]$f.Id; Reason = $why })
            $pp = $proposalOf[[string]$f.Id]
            $next = if (-not $pp) { "Approve its proposal again once the capture records make one (Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' lists them)." }
            elseif ($pp.EnforceEligible) { "Fix the cause and approve it again (Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromSiblingCapture -Mode Enforce -ProposalId $(& $safe $pp.ProposalId 40))." }
            else {
                "Its identity is no longer eligible for Enforce ($(& $safe ((@($pp.IneligibleReasons) | ForEach-Object { [string]$_ }) -join '; ') 300)); these reasons stay with the capture records of that identity. " +
                "To keep devices with that install from getting this package, apply it as Block (Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath' -FromSiblingCapture -Mode Block -ProposalId $(& $safe $pp.ProposalId 40))."
            }
            Write-Warning ("The captured Enforce rule '$(& $safe $f.Id 40)' was not proven ($why) and was demoted: it is a proposal again and this package does not remove that install. " + $next)
        }
        $removed = $ids
        if (@($keep | Where-Object { [string](& $prop $_ 'Mode') -ceq 'Enforce' }).Count -eq 0) { break }
        # No proof round left: what this removal un-proved cannot be proven again here (D59a: demote, L37).
        if (-not $Prove -or $round -ge $bound) { $settle = $true }
    }

    $final = @(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath)
    $summary.Proven = [string[]]@($final | Where-Object { $_.Mode -ceq 'Enforce' -and $_.State -eq 'Proven' } | ForEach-Object { $_.Id })
    $summary.Unproven = [string[]]@($final | Where-Object { $_.Mode -ceq 'Enforce' -and $_.State -eq 'NotProven' -and $_.Lineage -ne 'Capture' } | ForEach-Object { $_.Id })
    foreach ($id in $summary.Unproven) {
        $st = @($final | Where-Object { $_.Id -ceq $id })[0]
        Write-Warning "The Enforce rule '$(& $safe $id 40)' ($($st.Lineage)) is not proven ($(& $safe $st.Reason 200)): it is never demoted automatically; Export refuses it until it is proven or carries a PROOF waiver."
    }
    $summary.Demoted = @($demoted.ToArray())
    return $summary
}
