function Get-Win32ToolkitPriorInstallDecision {
    <#
    .SYNOPSIS
        Reads a project's host-side prior-install decisions (Documentation\PriorInstallDecisions.json), leniently.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.4, D19, V20, SV2, SV5). The operator's waivers, acknowledgements and the
        per-proposal approvals of captured Enforce rules live on the host only (the file never ships). This is the
        ONLY reader of the file:

          { "SchemaVersion": "1.0", "Records": [ { Kind, Code, Target, Reason, On, [ProposalId, ProposalHash,
            CaptureIds, Demoted] } ] }

          Kind Waiver          Code PROOF | VERSIONMIN | DISPLAYNAME
          Kind Acknowledgement Code ID-PRIOR-DROPPED | DATA-LOSS | SIGNER-MISMATCH
          Kind Approval        Code SIBLING-ENFORCE (ProposalHash = the 64-hex tuple hash, CaptureIds, Demoted)

        Lenient: a missing or unreadable file gives an empty set and one Verbose line; a record of an unknown kind
        or code, or with a malformed field, is ignored. One Waiver / Acknowledgement per Kind + Code + Target (the
        last one in the file wins). Approvals are kept in file order; each carries Latest = $true when it is the last
        Approval for its Target. An Approval counts only when it is Latest and its Demoted is '' (Appendix B #18).
        Every string passes ConvertTo-Win32ToolkitSafeText. Never throws (a W32T.* error is re-thrown).
    .PARAMETER ProjectPath
        The PSADT project folder.
    .OUTPUTS
        [pscustomobject[]] Kind, Code, Target, Reason, On, ProposalId, ProposalHash, CaptureIds, Demoted, Latest.
    .EXAMPLE
        $decisions = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $p)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $file = Join-Path $ProjectPath 'Documentation\PriorInstallDecisions.json'
    $codes = @{
        'Waiver'          = @('PROOF', 'VERSIONMIN', 'DISPLAYNAME')
        'Acknowledgement' = @('ID-PRIOR-DROPPED', 'DATA-LOSS', 'SIGNER-MISMATCH')
        'Approval'        = @('SIBLING-ENFORCE')
    }
    $raw = $null
    try {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Write-Verbose 'No prior-install decisions recorded (Documentation\PriorInstallDecisions.json is absent).'; return @() }
        if ((Get-Item -LiteralPath $file).Length -gt 4MB) { throw 'the file is larger than 4 MB' }
        $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 10
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose ('Documentation\PriorInstallDecisions.json is unreadable and is ignored: ' + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200))
        return @()
    }
    if ($null -eq $raw -or -not $raw.PSObject.Properties['Records']) { return @() }

    $text = {
        param($Object, [string]$Name, [int]$Max = 256)
        if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name] -or $null -eq $Object.$Name) { return '' }
        if ($Object.$Name -isnot [string]) { return $null }
        return (ConvertTo-Win32ToolkitSafeText -Text $Object.$Name -MaxLength $Max)
    }
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($raw.Records)) {
        if ($null -eq $r -or $r -isnot [pscustomobject]) { continue }
        $kind = & $text $r 'Kind'; $code = & $text $r 'Code'; $target = & $text $r 'Target' 40
        if (-not $kind -or -not $codes.ContainsKey($kind) -or $codes[$kind] -cnotcontains $code) { continue }
        if ($target -cnotmatch '^[a-z0-9-]{1,40}$') { continue }
        $on = & $text $r 'On' 10
        if ($on -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
        $reason = & $text $r 'Reason' 512
        if ($null -eq $reason) { continue }
        $rec = [ordered]@{ Kind = $kind; Code = $code; Target = $target; Reason = $reason; On = $on
            ProposalId = ''; ProposalHash = ''; CaptureIds = @(); Demoted = ''; Latest = $false }
        if ($kind -eq 'Approval') {
            $proposalId = & $text $r 'ProposalId' 40
            $ph = & $text $r 'ProposalHash' 64
            $dem = & $text $r 'Demoted' 10
            if ($proposalId -cnotmatch '^[a-z0-9-]{1,40}$' -or $ph -cnotmatch '^[0-9A-F]{64}$' -or $null -eq $dem -or ($dem -and $dem -notmatch '^\d{4}-\d{2}-\d{2}$')) { continue }
            $ids = @()
            if ($r.PSObject.Properties['CaptureIds']) { $ids = @(@($r.CaptureIds) | Where-Object { $_ -is [string] -and $_ -cmatch '^[a-f0-9]{16}$' }) }
            $rec.ProposalId = $proposalId; $rec.ProposalHash = $ph; $rec.CaptureIds = [string[]]$ids; $rec.Demoted = $dem
        }
        elseif (-not $reason) { continue }
        else {
            # One Waiver / Acknowledgement per Kind + Code + Target: a later record replaces an earlier one.
            for ($i = $kept.Count - 1; $i -ge 0; $i--) {
                if ($kept[$i].Kind -ceq $kind -and $kept[$i].Code -ceq $code -and $kept[$i].Target -ceq $target) { $kept.RemoveAt($i) }
            }
        }
        $kept.Add([pscustomobject]$rec)
    }
    $lastApproval = @{}
    for ($i = 0; $i -lt $kept.Count; $i++) { if ($kept[$i].Kind -eq 'Approval') { $lastApproval[$kept[$i].Target] = $i } }
    foreach ($t in $lastApproval.Keys) { $kept[$lastApproval[$t]].Latest = $true }
    return @($kept)
}
