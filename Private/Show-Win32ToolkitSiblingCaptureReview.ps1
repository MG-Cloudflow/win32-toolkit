function Show-Win32ToolkitSiblingCaptureReview {
    <#
    .SYNOPSIS
        The review screen of a sibling capture (Spectre): one card per proposal, Block preselected, Enforce only by name.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.18; D24, D57, SV11, SV14, SV30). The proposals are re-derived from the
        hash-verified capture records (ConvertTo-Win32ToolkitSiblingProposal). Each card shows the identity (key, view,
        publisher, name or {v} template, kind), the confidence, the window in the sibling's own versions, the floor
        version and its release date with the uncovered range (devices below VersionMin keep it next to this package,
        D14; above VersionMax the install fails with 69102), the constant removal command, the probe / stability / noise
        results and the flags, and what each choice does on a device (SV30).

        Choices: Block (listed first, the highlighted default, D57) - devices with that install FAIL this one (69101)
        until the rule is Enforce; Enforce (offered only when the proposal is Enforce-eligible and the Hyper-V test VM is
        ready - else the card says why, since an unproven captured rule is demoted at once, D59a -; a second
        confirmation, whose No shows the same card again; Set-Win32ToolkitPriorInstall writes the approval; then the proof
        and demotion loop runs, Invoke-Win32ToolkitPriorDemotion -Prove, and its result is shown; for a rule that survived
        the proof, the acknowledgements Export needs are asked for, each with its reason: DATA-LOSS when the vendor
        uninstaller deletes data (the card says so), SIGNER-MISMATCH when the sibling's signer differs from the package's
        (the SignerMismatch flag)); Report; Widen (one more capture of an older version of that technology,
        then the card again - after a key press when the capture recorded nothing, so its warnings can be read; without
        a ready Hyper-V test VM, Read-Win32ToolkitSiblingCaptureBackend first says that it
        would run in Windows Sandbox, names what a Sandbox record would make Block-only and offers to cancel, SV28); Skip.
        A proposal that is already a rule says so. The card also shows the removal probe, noise-control and stability
        results.
        CoInstalled, Unattributed, ReportOnly, NotCapturable and Failed are listed below the cards without choices.
        Every captured string passes Get-SpectreEscapedText. Errors are shown in a panel (the TUI is the display sink);
        an error decides nothing: the card comes back, unless its rule was already written.
    .PARAMETER ProjectPath
        The PSADT project folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectPath)

    $esc = { param($Value) Get-SpectreEscapedText -Text ([string]$Value) }
    $showError = { param($Err) Format-SpectrePanel -Data "[red]$(& $esc $Err.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
    $handled = @{}
    while ($true) {
        Clear-Host
        Write-SpectreRule -Title 'Other installer technologies: review the proposals' -Color Blue
        $sib = $null
        try { $sib = ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $ProjectPath }
        catch { & $showError $_; Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null; return }
        $entries = @()
        try { $entries = @(@((Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath).PriorInstalls.Entries) | Where-Object { $null -ne $_ }) } catch { $entries = @() }
        $pending = @($sib.Proposals | Where-Object { -not $handled.ContainsKey($_.ProposalHash) } | Sort-Object -Property @{ Expression = { $_.Track -ne 'Current' } }, ProposalId)
        if ($pending.Count -eq 0) { break }
        $p = $pending[0]
        $applied = @($entries | Where-Object { (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $_) -ceq $p.ProposalHash }) | Select-Object -First 1
        # An Enforce rule is proven right after its approval on the Hyper-V test VM; without a ready VM it would be demoted at
        # once (D59a), so Enforce is offered only when the VM is ready.
        $hvNotReady = @(Test-Win32ToolkitHyperVReady)
        $enforceNow = $p.EnforceEligible -and $hvNotReady.Count -eq 0
        $kindText = switch ($p.UninstallerType) { 'nullsoft' { 'NSIS' } 'inno' { 'Inno Setup' } default { 'generic EXE (Block only)' } }
        $root = if ($p.View -eq 'Wow6432') { 'HKLM\SOFTWARE\WOW6432Node\...\Uninstall' } else { 'HKLM\SOFTWARE\...\Uninstall' }
        $removal = if ($p.UninstallerType -eq 'inno') { "$($p.UninstallerFileName) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" } elseif ($p.UninstallerType -eq 'nullsoft') { "$($p.UninstallerFileName) /S _?=<its folder>" } else { '(none: Block or Report only)' }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("Proposal     : $($p.ProposalId) ($($p.SiblingType), $($p.Confidence) confidence, $($p.Track), $($p.Stability))")
        $lines.Add("Uninstall key: $root\$($p.Key)")
        $lines.Add("Publisher    : $($p.Publisher)")
        $lines.Add("Name         : $(if ($p.DisplayNameTemplate) { "$($p.DisplayNameTemplate)  ({v} = its version)" } else { $p.DisplayName })")
        $lines.Add("Kind         : $kindText")
        $lines.Add("Folder       : $($p.InstallDir)   main program: $(if ($p.MainExe) { $p.MainExe } else { '(none)' })")
        $lines.Add("Window       : $($p.VersionMin) <= version <= $($p.VersionMax)   (captured: $(@($p.ObservedVersions) -join ', '))")
        $lines.Add("Floor        : $($p.FloorVersion)$(if ($p.FloorReleaseDate) { " (released $($p.FloorReleaseDate))" })")
        $lines.Add("Not covered  : devices with a version below $($p.VersionMin) keep it next to this package (left as it is); devices above $($p.VersionMax) fail with 69102.")
        $lines.Add("Removal      : $removal (constant switches; the captured ones are never used)")
        $lines.Add("Captures     : $(@($p.CaptureIds) -join ', ')")
        # The probe, noise-control and stability results (spec 2.18), read from the proposal's flags.
        $checks = @(
            $(if (@($p.Flags) -contains 'ProbeNotClean') { 'removal probe NOT clean' } else { 'removal probe clean' })
            $(if (@($p.Flags) -contains 'NoiseUnverified') { 'noise control NOT verified' } else { 'noise control verified' })
            "$(if ($p.Stability -eq 'Unstable') { 'unstable' } else { 'stable' }) over $(@($p.CaptureIds).Count) captures"
        )
        $lines.Add("Checks       : $($checks -join ', ')")
        $lines.Add("Flags        : $(if (@($p.Flags).Count) { @($p.Flags | ForEach-Object { "$_ ($($p.FlagText[$_]))" }) -join '; ' } else { 'none' })")
        if ($p.DataLoss) { $lines.Add('Data loss    : its uninstaller deleted configuration files in its own folder in the capture''s probe: an Enforce rule needs a DATA-LOSS acknowledgement before it is packaged.') }
        if (-not $p.EnforceEligible) { $lines.Add("Enforce      : not offered ($(@($p.IneligibleReasons) -join '; '))") }
        elseif (-not $enforceNow) { $lines.Add("Enforce      : not offered now: the Hyper-V test VM is not ready ($($hvNotReady -join '; ')), and an Enforce rule needs its proof run there.") }
        if ($applied) { $lines.Add("Already      : rule '$($applied.Id)' ($($applied.Mode))") }
        $lines.Add('')
        $lines.Add($(if (@($p.Flags) -contains 'Sandbox' -or @($p.Flags) -contains 'Assisted') { "Block   : devices with this $($p.SiblingType) install FAIL this install (69101); this identity stays Block-only (a Windows Sandbox or assisted capture saw it)." } else { "Block   : devices with this $($p.SiblingType) install FAIL this install (69101) until the rule is Enforce." }))
        if ($enforceNow) { $lines.Add("Enforce : the package runs $removal as SYSTEM before it installs (after a Hyper-V proof run).") }
        $lines.Add('Report  : devices with it get a marker (LastSeen) and the install goes on; nothing is removed.')
        Format-SpectrePanel -Data (& $esc ($lines -join "`n")) -Header (& $esc "Proposal $($p.ProposalId): $($p.Key)") -Border Rounded -Color Blue | Out-SpectreHost

        $choices = [System.Collections.Generic.List[object]]::new()
        $choices.Add([pscustomobject]@{ Key = 'Block'; Label = 'Block (recommended): refuse the install where it is found' })
        if ($enforceNow) { $choices.Add([pscustomobject]@{ Key = 'Enforce'; Label = 'Enforce: remove it before installing (approval + Hyper-V proof)' }) }
        $choices.Add([pscustomobject]@{ Key = 'Report'; Label = 'Report: mark it, install anyway' })
        $choices.Add([pscustomobject]@{ Key = 'Widen'; Label = 'Widen: capture one more, older version first' })
        $choices.Add([pscustomobject]@{ Key = 'Skip'; Label = 'Skip' })
        $pick = Read-SpectreSelection -Message (& $esc "What should the package do with $($p.Key)?") -Choices @($choices) -ChoiceLabelProperty 'Label' -Color Blue
        try {
            switch ([string]$pick.Key) {
                'Block' { $null = Set-Win32ToolkitPriorInstall -ProjectPath $ProjectPath -FromSiblingCapture -Mode Block -ProposalId $p.ProposalId -Confirm:$false; $handled[$p.ProposalHash] = $true }
                'Report' { $null = Set-Win32ToolkitPriorInstall -ProjectPath $ProjectPath -FromSiblingCapture -Mode Report -ProposalId $p.ProposalId -Confirm:$false; $handled[$p.ProposalHash] = $true }
                'Enforce' {
                    # No at the second confirmation shows the same card again (Block still first): declining Enforce never
                    # skips the proposal silently.
                    if (Read-SpectreConfirm -Message (& $esc "Remove $($p.Key) as SYSTEM on every device before installing? One approval for this proposal is recorded.") -DefaultAnswer 'n') {
                        # Handled once the rule is written: a refused write shows the card again (Block still first).
                        $null = Set-Win32ToolkitPriorInstall -ProjectPath $ProjectPath -FromSiblingCapture -Mode Enforce -ProposalId $p.ProposalId -Confirm:$false
                        $handled[$p.ProposalHash] = $true
                        $ready = @(Test-Win32ToolkitHyperVReady).Count -eq 0
                        if ($ready) { Write-SpectreHost '[grey]Proving it on the Hyper-V test VM (an Update test from the floor capture)...[/]' }
                        $eid = @(@((Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath).PriorInstalls.Entries) | Where-Object { $null -ne $_ -and (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $_) -ceq $p.ProposalHash } | ForEach-Object { [string]$_.Id }) | Select-Object -First 1
                        $r = Invoke-Win32ToolkitPriorDemotion -ProjectPath $ProjectPath -Prove:$ready
                        $gone = @($r.Demoted | Where-Object { $_.Id -ceq $eid })
                        $msg = if (@($r.Proven) -ccontains $eid) { "Proven: $eid removes $($p.Key) before installing." }
                        elseif ($gone.Count) { "Not proven ($($gone[0].Reason)): $eid was demoted to a proposal again; the package does not remove that install." }
                        else { 'Not proven yet (see the warnings above): Export refuses the rule until it is proven.' }
                        Format-SpectrePanel -Data (& $esc $msg) -Header 'Proof' -Border Rounded -Color $(if ($gone.Count) { 'Red' } elseif (@($r.Proven) -ccontains $eid) { 'Green' } else { 'Yellow' }) | Out-SpectreHost
                        # The two Export refusals of a proven captured rule that an operator decision lifts: the vendor
                        # uninstaller deletes data (the capture's probe or the proof run saw it), or the sibling is signed
                        # differently from this package. Each is asked here, default No, with a reason, so the package can be built.
                        if ($eid -and $gone.Count -eq 0) {
                            $acks = @(
                                @{ Finding = 'PRIOR-DATA-LOSS'; Code = 'DATA-LOSS'; Header = 'Data loss'; Ask = "Acknowledge that removing $($p.Key) deletes that data on the devices where it is found?"; Why = 'Why is that acceptable for your users? (kept on this computer, never shipped)' }
                                @{ Finding = 'PRIOR-SIGNER'; Code = 'SIGNER-MISMATCH'; Header = 'Signer'; Ask = "Acknowledge that $($p.Key) is the same vendor's app although its signer differs from this package's?"; Why = 'How did you check it? (kept on this computer, never shipped)' }
                            )
                            $found = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $ProjectPath -Stage Export | Where-Object { $_.Target -ceq $eid })
                            foreach ($a in $acks) {
                                $row = @($found | Where-Object { $_.Code -eq $a.Finding }) | Select-Object -First 1
                                if (-not $row) { continue }
                                Format-SpectrePanel -Data (& $esc "$($row.Message)`nExport refuses the rule until this is acknowledged.") -Header $a.Header -Border Rounded -Color Yellow | Out-SpectreHost
                                if (-not (Read-SpectreConfirm -Message (& $esc $a.Ask) -DefaultAnswer 'n')) { continue }
                                $why = [string](Read-SpectreText -Message $a.Why)
                                if ([string]::IsNullOrWhiteSpace($why)) { Write-SpectreHost "[yellow]Not acknowledged: no reason was given. Export refuses the rule until it is ($($a.Code)).[/]" }
                                else { $null = Set-Win32ToolkitPriorInstall -ProjectPath $ProjectPath -Acknowledge $a.Code -Target $eid -Reason $why.Trim() -Confirm:$false }
                            }
                        }
                        Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                    }
                }
                'Widen' {
                    # Widen never decides the proposal: its card comes back after the capture (also after an error). Without a
                    # ready VM the capture would run in Windows Sandbox: said first, with the offer to cancel (SV28).
                    $backend = Read-Win32ToolkitSiblingCaptureBackend -ProjectPath $ProjectPath -SiblingType $p.SiblingType
                    $v = if ($backend) { Read-SpectreText -Message (& $esc "An older $($p.SiblingType) version to capture (the floor now is $($p.FloorVersion))") } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($v)) {
                        $done = Test-Win32ToolkitProject -ProjectPath $ProjectPath -Scenario SiblingCapture -Backend $backend -SiblingInstallerType $p.SiblingType -SiblingVersion ([string]$v).Trim()
                        # Only a capture that recorded something goes straight back to the card; otherwise its warnings (every
                        # capture failed, the version is unknown, or GitHub limits this computer: live rows RAISE, INNO) stay
                        # on screen until a key is pressed, as on the Prior installs screen.
                        if ($done -ne $true) { Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null }
                    }
                    elseif (-not $backend) { Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null }
                }
                default { $handled[$p.ProposalHash] = $true }
            }
        }
        catch {
            # An error decides nothing: the card comes back (Block still first), unless its rule was already written.
            & $showError $_; Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
        }
    }

    # ---- what was not proposed ----
    $other = [System.Collections.Generic.List[string]]::new()
    foreach ($x in @($sib.CoInstalled)) { $other.Add("Installed alongside (never proposed): $($x.Key) [$($x.View)]") }
    foreach ($x in @($sib.Unattributed)) { $other.Add("Not attributed: $($x.Key) [$($x.View)] - $($x.Reason)") }
    foreach ($x in @($sib.ReportOnly)) { $other.Add("Report only: $($x.Type) - $($x.Reason)") }
    foreach ($x in @($sib.NotCapturable)) { $other.Add("Not capturable: $($x.Type) - $($x.Reason)") }
    foreach ($x in @($sib.Failed)) { $other.Add("Capture failed: $($x.Type) $($x.Version) - $($x.Reason)") }
    if ($other.Count) { Format-SpectrePanel -Data (& $esc ($other -join "`n")) -Header 'Not proposed' -Border Rounded -Color Grey | Out-SpectreHost }
    elseif (@($sib.Proposals).Count -eq 0) { Format-SpectrePanel -Data 'No proposal: capture the other installer technologies first.' -Header 'Nothing to review' -Border Rounded -Color Yellow | Out-SpectreHost }
    Read-SpectrePause -Message 'Press any key to return' -AnyKey | Out-Null
}
