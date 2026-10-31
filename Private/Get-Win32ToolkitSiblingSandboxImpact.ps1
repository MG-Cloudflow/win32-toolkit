function Get-Win32ToolkitSiblingSandboxImpact {
    <#
    .SYNOPSIS
        Names the captured identities that a sibling capture in Windows Sandbox would make Block-only.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.5, 2.17, 2.18; SV28). A capture record from Windows Sandbox is never
        Enforce-eligible (the sibling installs as the sandbox's user), and it joins the records of the identity it sees:
        the proposal of that identity gets the Sandbox flag, so it is no longer Enforce-eligible, an Enforce rule of it is
        refused at Export (PRIOR-NOT-ELIGIBLE) and, since records are kept and carried to the next versions, a later
        capture on the Hyper-V test VM does not take that back.

        Returns the proposals (re-derived from the hash-verified records, ConvertTo-Win32ToolkitSiblingProposal) that such
        a capture could cost: every Enforce-eligible proposal, and every proposal that is already an Enforce rule (same
        identity, the Tuple hash of spec 2.3). -SiblingType limits them to the technologies the capture would run. The
        callers ask before a Sandbox capture (the menu), skip it (the pipeline) or refuse it (Test-Win32ToolkitProject
        -Scenario SiblingCapture without -Backend Sandbox, W32T.SiblingCaptureUnsupported) when the list is not empty
        (spec Dv14). An assisted capture (-Assisted, flag Assisted) costs the same: Test-Win32ToolkitProject warns with
        this list before it runs (installer-identity PR 3 live row ASSISTED).

        Read-only. Fail-open: a project whose proposals cannot be derived gives an empty list (one verbose line), so the
        capture behaves as before; a W32T.* error is re-thrown.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER SiblingType
        Only proposals of these sibling installer types (for example nullsoft). Empty: every type.
    .OUTPUTS
        [string[]] One entry per proposal: its id, followed by '(Enforce rule <id>)' when it is already one.
    .EXAMPLE
        $lost = @(Get-Win32ToolkitSiblingSandboxImpact -ProjectPath $p -SiblingType nullsoft)
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$SiblingType = @()
    )

    $types = @(@($SiblingType) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    try {
        $proposals = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $ProjectPath).Proposals | Where-Object { $null -ne $_ })
        if ($proposals.Count -eq 0) { return [string[]]@() }
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $entries = @(if ($cfg.PSObject.Properties['PriorInstalls'] -and $null -ne $cfg.PriorInstalls -and $cfg.PriorInstalls.PSObject.Properties['Entries']) { @($cfg.PriorInstalls.Entries) | Where-Object { $null -ne $_ -and $_ -isnot [string] } })
        $enforce = @($entries | Where-Object { $_.PSObject.Properties['Mode'] -and [string]$_.Mode -ceq 'Enforce' })
        $out = foreach ($p in $proposals) {
            if ($types.Count -and $types -notcontains ([string]$p.SiblingType).ToLowerInvariant()) { continue }
            $rule = @($enforce | Where-Object { (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $_) -ceq [string]$p.ProposalHash }) | Select-Object -First 1
            if ($rule) { '{0} (Enforce rule {1})' -f [string]$p.ProposalId, (ConvertTo-Win32ToolkitSafeText -Text ([string]$rule.Id) -MaxLength 40) }
            elseif ($p.EnforceEligible) { [string]$p.ProposalId }
        }
        return [string[]]@($out)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose ('The proposals a Windows Sandbox capture would affect could not be read: ' + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200))
        return [string[]]@()
    }
}
