function Update-Win32ToolkitPriorInstallWindow {
    <#
    .SYNOPSIS
        After a new sibling capture: raises a captured rule's VersionMax to the newest version that registered the same
        identity, or marks the rule Frozen when the newest capture registers another identity.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.15.5; D61, L36, SV3). Carry-forward copies captured rules unchanged; only a new
        capture moves them. For every capture-lineage rule (Source SiblingCapture or a CaptureId) the window is
        re-derived from the hash-verified records with Get-Win32ToolkitPriorInstallWindow (the same implementation the
        proposals and Export use):
          - a record with the SAME identity (Tuple hash) observed a higher version -> VersionMax is raised to it.
            VersionMin stays the CaptureId record's. The Approval stays valid (the Tuple has no window); the binding
            hash changes, so the rule needs a new proof run;
          - a newer capture of the same sibling type registers ANOTHER identity -> the rule becomes Track Frozen (its
            window stays); the new identity is a new proposal that needs review and approval.
        The raise never adds, removes or re-modes a rule and writes nothing else (no decision, no other AppConfig
        section). AppConfig is written only when something changed. Never throws (C-7): a problem gives one warning; a
        W32T.* error is re-thrown.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .OUTPUTS
        [pscustomobject] Raised (@{ Id; From; To }), Frozen (ids).
    .EXAMPLE
        $null = Update-Win32ToolkitPriorInstallWindow -ProjectPath $p
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $summary = [pscustomobject]@{ Raised = @(); Frozen = @() }
    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath 'SupportFiles\AppConfig.json') -PathType Leaf)) { return $summary }
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $entries = @(@(& $prop (& $prop $cfg 'PriorInstalls') 'Entries') | Where-Object { $null -ne $_ })
        $captured = @($entries | Where-Object { [string](& $prop $_ 'Source') -ceq 'SiblingCapture' -or [string](& $prop $_ 'CaptureId') })
        if ($captured.Count -eq 0) { return $summary }
        $sib = ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $ProjectPath
        $rows = @($sib.Captures)
        $pkgVersionText = [string](& $prop (& $prop $cfg 'App') 'Version')
        $pkgFamily = (Get-Win32ToolkitInstallerFamily -Type ([string](& $prop (& $prop $cfg 'Installer') 'Type'))).Family
        $raised = [System.Collections.Generic.List[object]]::new()
        $frozen = [System.Collections.Generic.List[string]]::new()
        foreach ($e in $captured) {
            $eid = [string](& $prop $e 'Id')
            $tuple = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $e
            $floorRow = @($rows | Where-Object { $_.CaptureId -ceq [string](& $prop $e 'CaptureId') }) | Select-Object -First 1
            $sf = $floorRow -and (Get-Win32ToolkitInstallerFamily -Type $floorRow.Type).Family -eq $pkgFamily -and $pkgFamily -ne 'other'
            $window = Get-Win32ToolkitPriorInstallWindow -Captures $rows -Tuple $tuple -FloorCaptureId ([string](& $prop $e 'CaptureId')) -Below $(if ($sf) { $pkgVersionText } else { '' })
            if (-not $window.Found) { Write-Verbose "Prior-install rule ${eid}: its records do not re-derive it ($($window.Reason)); not raised."; continue }
            $now = ConvertTo-Win32ToolkitPriorVersion -Text ([string](& $prop $e 'VersionMax'))
            $max = ConvertTo-Win32ToolkitPriorVersion -Text $window.VersionMax
            if ($null -ne $max -and ($null -eq $now -or $max -gt $now)) {
                $raised.Add([pscustomobject]@{ Id = $eid; From = [string](& $prop $e 'VersionMax'); To = $window.VersionMax })
                $e.VersionMax = $window.VersionMax
            }
            # A newer capture of the same sibling type and architecture with another identity (or none): the rule is frozen.
            if ($floorRow) {
                $newestOwn = @($rows | Where-Object { $_.Tuple -ceq $tuple } | ForEach-Object { ConvertTo-Win32ToolkitPriorVersion -Text $_.SiblingVersion } | Where-Object { $null -ne $_ } | Sort-Object)[-1]
                $newer = @($rows | Where-Object { $_.Type -ceq $floorRow.Type -and $_.Architecture -ceq $floorRow.Architecture -and $_.Status -in @('Primary', 'NoPrimary') -and $_.Tuple -cne $tuple } |
                        Where-Object { $v = ConvertTo-Win32ToolkitPriorVersion -Text $_.SiblingVersion; $null -ne $v -and $null -ne $newestOwn -and $v -gt $newestOwn })
                if ($newer.Count -gt 0 -and [string](& $prop $e 'Track') -cne 'Frozen') {
                    if ($e.PSObject.Properties['Track']) { $e.Track = 'Frozen' } else { $e | Add-Member -NotePropertyName Track -NotePropertyValue 'Frozen' }
                    $frozen.Add($eid)
                }
            }
        }
        if ($raised.Count -eq 0 -and $frozen.Count -eq 0) { return $summary }
        if ($PSCmdlet.ShouldProcess((Join-Path $ProjectPath 'SupportFiles\AppConfig.json'), 'Update the windows of the captured prior-install rules')) {
            $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg -Confirm:$false
            foreach ($x in $raised) { Write-Host "Prior-install rule $(& $safe $x.Id 40): VersionMax raised from $(& $safe $x.From 64) to $(& $safe $x.To 64) (a newer capture registered the same identity); it needs a new proof run." -ForegroundColor Yellow }
            foreach ($x in $frozen) { Write-Host "Prior-install rule $(& $safe $x 40) is now Frozen: the newest capture of its technology registers another identity - review the new proposal (Set-Win32ToolkitPriorInstall -ProjectPath '$ProjectPath')." -ForegroundColor Yellow }
        }
        $summary.Raised = @($raised.ToArray())
        $summary.Frozen = [string[]]$frozen.ToArray()
        return $summary
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning ("The windows of the captured prior-install rules could not be updated (" + (& $safe $_.Exception.Message 200) + '): their VersionMax stays; devices with a newer version fail with 69102.')
        return $summary
    }
}
