function Invoke-Win32ToolkitPriorProof {
    <#
    .SYNOPSIS
        Runs the Hyper-V Unattended Update test that proves the unproven Enforce prior-install rules, one run per group.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.15.3; SV6, SV28, L27, B34). An Enforce rule removes another install as SYSTEM,
        so Export needs it proven by an Update test on the Hyper-V test VM, unattended. The rules are grouped
        (Get-Win32ToolkitPriorProofGroup): a captured rule by its floor capture record, any other by (UninstallerType,
        View). For every group with a NotProven rule (Get-Win32ToolkitPriorProofState) it calls

            Test-Win32ToolkitProject -ProjectPath <p> -Scenario Update -Backend HyperV -TestMode Unattended -ProofEntryId <group>

        and nothing else: Test-Win32ToolkitProject derives the group's baseline itself (the floor capture's installer
        for a captured group). Always Hyper-V Unattended, whatever HyperVTestMode says (SV28). Hyper-V not ready -> no
        run; every such rule is reported "not proven: Hyper-V is not ready". A run that throws a W32T.* error (a guest
        that changed project files, a lease timeout) stops here; any other failure of a run gives one warning and the
        next group runs.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER EntryId
        Prove only the groups that hold these rules (default: every group with an unproven Enforce rule).
    .OUTPUTS
        [pscustomobject[]] the proof state of every rule after the runs (Get-Win32ToolkitPriorProofState), with Reason
        'not proven: Hyper-V is not ready (...)' for the rules that could not run.
    .EXAMPLE
        Invoke-Win32ToolkitPriorProof -ProjectPath $p | Format-Table Id, State, Reason
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowEmptyCollection()]
        [string[]]$EntryId = @()
    )

    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $states = @(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath)
    $wanted = @($EntryId | Where-Object { $_ })
    $notProven = [string[]]@($states | Where-Object { $_.Mode -ceq 'Enforce' -and $_.State -eq 'NotProven' -and ($wanted.Count -eq 0 -or $wanted -ccontains $_.Id) } | ForEach-Object { $_.Id })
    if ($notProven.Count -eq 0) { return $states }
    $groups = @(Get-Win32ToolkitPriorProofGroup -ProjectPath $ProjectPath | Where-Object { @($_.EntryIds | Where-Object { $notProven -ccontains $_ }).Count -gt 0 })
    if ($groups.Count -eq 0) { return $states }

    $notReady = @(Test-Win32ToolkitHyperVReady)
    if ($notReady.Count -gt 0) {
        $why = 'not proven: Hyper-V is not ready (' + (@($notReady | ForEach-Object { & $safe $_ 200 }) -join '; ') + ')'
        $ids = [string[]]@($groups | ForEach-Object { $_.EntryIds })
        Write-Warning "Prior-install rule(s) $($ids -join ', ') $why. A proof needs an Update test on the Hyper-V test VM (New-Win32ToolkitTestVM)."
        return @($states | ForEach-Object {
                if ($ids -ccontains $_.Id -and $_.State -eq 'NotProven') { $c = $_.PSObject.Copy(); $c.Reason = $why; $c } else { $_ }
            })
    }

    foreach ($g in $groups) {
        $ids = [string[]]@($g.EntryIds)
        $what = if ($g.Lineage -eq 'Capture') { "the floor capture $($g.CaptureId)" } else { "$($g.UninstallerType) [$($g.View)]" }
        Write-Host "Proof run for the prior-install rule(s) $($ids -join ', ') ($what): Update test on Hyper-V, unattended." -ForegroundColor Cyan
        try {
            $null = Test-Win32ToolkitProject -ProjectPath $ProjectPath -Scenario Update -Backend HyperV -TestMode Unattended -ProofEntryId $ids
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Warning "The proof run of $($ids -join ', ') did not complete ($(& $safe $_.Exception.Message 200)): the rule(s) stay unproven."
        }
    }
    return @(Get-Win32ToolkitPriorProofState -ProjectPath $ProjectPath)
}
