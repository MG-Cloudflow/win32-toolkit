function Set-Win32ToolkitPriorInstallDecision {
    <#
    .SYNOPSIS
        Writes one host-side prior-install decision (Documentation\PriorInstallDecisions.json).
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.4, D19). The operator's waivers, acknowledgements and the approvals of captured
        Enforce rules are host records: they never ship (Documentation\ is not packaged; a Documentation folder left in
        Staging is fatal). One record per Kind + Code + Target: a new Waiver or Acknowledgement replaces the older one;
        an Approval is APPENDED (the lineage history is kept; the latest one per Target counts). -Remove deletes the
        Waiver or Acknowledgement of that Kind + Code + Target (an Approval is never removed). The file is rewritten
        from the lenient reader's records (unknown records are dropped), BOM-less, through '<file>.tmp' and Move-Item.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Record
        @{ Kind; Code; Target; Reason; On; [ProposalId; ProposalHash; CaptureIds; Demoted] }.
    .PARAMETER Remove
        Remove the Waiver / Acknowledgement named by Record's Kind, Code and Target instead of writing it.
    .PARAMETER DemoteTarget
        Mark the latest Approval of this Target as demoted (Demoted = Record.On) instead of writing Record.
    .OUTPUTS
        [string] the path of the decisions file.
    .EXAMPLE
        Set-Win32ToolkitPriorInstallDecision -ProjectPath $p -Record @{ Kind = 'Waiver'; Code = 'PROOF'; Target = 'nsis-x64'; Reason = 'pilot'; On = '2026-10-25' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [hashtable]$Record,

        [switch]$Remove,

        [switch]$DemoteTarget
    )

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath)) {
        $records.Add([ordered]@{ Kind = $r.Kind; Code = $r.Code; Target = $r.Target; Reason = $r.Reason; On = $r.On; ProposalId = $r.ProposalId
                ProposalHash = $r.ProposalHash; CaptureIds = @($r.CaptureIds); Demoted = $r.Demoted })
    }
    $kind = [string]$Record['Kind']; $code = [string]$Record['Code']; $target = [string]$Record['Target']
    if ($DemoteTarget) {
        for ($i = $records.Count - 1; $i -ge 0; $i--) {
            if ($records[$i].Kind -eq 'Approval' -and $records[$i].Target -ceq $target) { $records[$i].Demoted = [string]$Record['On']; break }
        }
    }
    else {
        if ($kind -ne 'Approval') {
            for ($i = $records.Count - 1; $i -ge 0; $i--) {
                if ($records[$i].Kind -ceq $kind -and $records[$i].Code -ceq $code -and $records[$i].Target -ceq $target) { $records.RemoveAt($i) }
            }
        }
        if (-not $Remove) {
            $new = [ordered]@{ Kind = $kind; Code = $code; Target = $target; Reason = [string]$Record['Reason']; On = [string]$Record['On'] }
            if ($kind -eq 'Approval') {
                $new.ProposalId = [string]$Record['ProposalId']; $new.ProposalHash = [string]$Record['ProposalHash']
                $new.CaptureIds = @($Record['CaptureIds'] | Where-Object { $_ }); $new.Demoted = [string]$Record['Demoted']
            }
            $records.Add($new)
        }
    }
    $out = @(foreach ($r in $records) {
            $o = [ordered]@{ Kind = $r.Kind; Code = $r.Code; Target = $r.Target; Reason = $r.Reason; On = $r.On }
            if ($r.Kind -eq 'Approval') { $o.ProposalId = $r.ProposalId; $o.ProposalHash = $r.ProposalHash; $o.CaptureIds = @($r.CaptureIds); $o.Demoted = $r.Demoted }
            $o
        })
    $doc = [ordered]@{ SchemaVersion = '1.0'; Records = $out }
    $docDir = Join-Path $ProjectPath 'Documentation'
    $file = Join-Path $docDir 'PriorInstallDecisions.json'
    if ($PSCmdlet.ShouldProcess($file, 'Write the prior-install decisions')) {
        if (-not (Test-Path -LiteralPath $docDir)) { $null = New-Item -ItemType Directory -Path $docDir -Force }
        $tmp = "$file.tmp"
        [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $doc -Depth 6), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $file -Force
    }
    return $file
}
