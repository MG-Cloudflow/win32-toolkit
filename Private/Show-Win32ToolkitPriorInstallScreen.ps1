function Show-Win32ToolkitPriorInstallScreen {
    <#
    .SYNOPSIS
        The prior-install screen of a project (Spectre): its rules with source, dates and proof state, and the actions.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.18; D24, V15, L25). The rules table comes from Set-Win32ToolkitPriorInstall (List)
        plus the capture date (the floor record's start time) and the approval date. Actions:
          - declare from the last Update test's candidates (Block listed first and preselected, Enforce never preselected,
            V15);
          - change the mode of a rule; remove a rule (Enforce, here and for the candidates, asks once more, default No,
            as on the review card);
          - prove now (Invoke-Win32ToolkitPriorDemotion -Prove: the Hyper-V proof runs, a captured rule that fails is
            demoted);
          - capture the other installer technologies (Test-Win32ToolkitProject -Scenario SiblingCapture); its output waits
            for a key, then the review opens when it recorded something;
            without a ready Hyper-V test VM, Read-Win32ToolkitSiblingCaptureBackend first says that it would run in
            Windows Sandbox (Block-only), names what a Sandbox record would make Block-only and offers to cancel (SV28);
          - review the capture proposals (Show-Win32ToolkitSiblingCaptureReview).
        Every write goes through Set-Win32ToolkitPriorInstall (its rules and refusals apply); every captured string passes
        Get-SpectreEscapedText; an error is shown in a panel (the TUI is the display sink).
    .PARAMETER ProjectPath
        The PSADT project folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectPath)

    $esc = { param($Value) Get-SpectreEscapedText -Text ([string]$Value) }
    $showError = { param($Err) Format-SpectrePanel -Data "[red]$(& $esc $Err.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red | Out-SpectreHost }
    $modeChoices = @(
        [pscustomobject]@{ Key = 'Block'; Label = 'Block: refuse the install where it is found (69101)' }
        [pscustomobject]@{ Key = 'Report'; Label = 'Report: mark it, install anyway' }
        [pscustomobject]@{ Key = 'Enforce'; Label = 'Enforce: remove it before installing (needs a Hyper-V proof)' }
    )
    while ($true) {
        Clear-Host
        Write-SpectreRule -Title 'Prior installs: other technologies removed before install' -Color Blue
        $rows = @()
        try { $rows = @(Set-Win32ToolkitPriorInstall -ProjectPath $ProjectPath 6>$null) }
        catch { & $showError $_ }
        $decisions = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath)
        $cfg = $null
        try { $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath } catch { $cfg = $null }
        $entries = @(if ($cfg -and $cfg.PSObject.Properties['PriorInstalls']) { @($cfg.PriorInstalls.Entries) | Where-Object { $null -ne $_ } })
        if ($rows.Count -eq 0) {
            Write-SpectreHost '[grey]No prior-install rule in this project.[/]'
        }
        else {
            $table = foreach ($r in $rows) {
                $e = @($entries | Where-Object { [string]$_.Id -ceq [string]$r.Id }) | Select-Object -First 1
                $captured = ''
                if ($e -and $e.PSObject.Properties['CaptureId'] -and $e.CaptureId) {
                    $rec = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath -CaptureId ([string]$e.CaptureId)) | Select-Object -First 1
                    if ($rec -and [string]$rec.Run.StartedUtc) { $captured = ([string]$rec.Run.StartedUtc).Substring(0, 10) } elseif ($rec) { $captured = 'yes' } else { $captured = 'record missing' }
                }
                $ap = @($decisions | Where-Object { $_.Kind -eq 'Approval' -and $_.Target -ceq [string]$r.Id -and $_.Latest }) | Select-Object -First 1
                [pscustomobject][ordered]@{
                    Id       = & $esc $r.Id
                    Mode     = & $esc $r.Mode
                    Key      = & $esc "$($r.Key) [$($r.View)]"
                    Window   = & $esc $r.Window
                    Source   = & $esc $r.Source
                    Captured = & $esc $captured
                    Approved = & $esc $(if ($ap) { if ($ap.Demoted) { "demoted $($ap.Demoted)" } else { $ap.On } } else { '' })
                    Proof    = & $esc $r.Proof
                }
            }
            # The cells are escaped for markup, so the table renders them as markup (live row TUI: without -AllowMarkup every
            # bracket showed doubled, 'Notepad++ [[Native]]'), as Show-Win32ToolkitHealth does.
            $table | Format-SpectreTable -AllowMarkup -Border Rounded -Color Blue | Out-SpectreHost
        }

        $act = Read-SpectreSelection -Message 'What would you like to do?' -Choices @(
            [pscustomobject]@{ Key = 'review'; Label = 'Review the capture proposals' }
            [pscustomobject]@{ Key = 'capture'; Label = 'Capture the other installer technologies (Hyper-V test VM)...' }
            [pscustomobject]@{ Key = 'candidates'; Label = 'Declare from the last Update test' }
            [pscustomobject]@{ Key = 'mode'; Label = 'Change the mode of a rule' }
            [pscustomobject]@{ Key = 'remove'; Label = 'Remove a rule' }
            [pscustomobject]@{ Key = 'prove'; Label = 'Prove now (Update test on the Hyper-V test VM)' }
            [pscustomobject]@{ Key = 'back'; Label = 'Back' }
        ) -ChoiceLabelProperty 'Label' -Color Blue -PageSize 10
        $pickRule = {
            if ($rows.Count -eq 0) { Write-SpectreHost '[yellow]There is no rule.[/]'; return $null }
            $map = [ordered]@{}
            foreach ($r in $rows) { $map[(& $esc "$($r.Id)  $($r.Mode)  $($r.Key) [$($r.View)]")] = [string]$r.Id }
            $label = Read-SpectreSelection -Message 'Which rule?' -Choices @($map.Keys) -Color Blue
            if ($map.Contains([string]$label)) { $map[[string]$label] } else { $null }
        }
        # Enforce removes another vendor's install as SYSTEM: as on the review card, it asks once more (default No).
        $enforceOk = {
            param([string]$Mode, [string]$What)
            if ($Mode -cne 'Enforce') { return $true }
            if (Read-SpectreConfirm -Message (& $esc "Remove $What as SYSTEM on every device before installing? Export refuses the rule until a Hyper-V proof run proves it (Prove now).") -DefaultAnswer 'n') { return $true }
            Write-SpectreHost '[grey]Nothing changed.[/]'
            return $false
        }
        $skipPause = $false
        try {
            switch ([string]$act.Key) {
                'back' { return }
                'review' { Show-Win32ToolkitSiblingCaptureReview -ProjectPath $ProjectPath; $skipPause = $true }
                'capture' {
                    # Without a ready VM the capture would run in Windows Sandbox: said first, with the offer to cancel (SV28).
                    $backend = Read-Win32ToolkitSiblingCaptureBackend -ProjectPath $ProjectPath
                    if ($backend) {
                        Clear-Host; Write-SpectreRule -Title 'Capturing the other installer technologies...' -Color Blue
                        $done = Test-Win32ToolkitProject -ProjectPath $ProjectPath -Scenario SiblingCapture -Backend $backend
                        # Only a capture that recorded something opens the review, and only after a key: the review clears
                        # the screen, and the capture's output can hold a "Not captured: <type> ... capture again" warning
                        # (live rows RAISE, INNO). Otherwise its warnings stay on screen until the pause below.
                        if ($done -eq $true) {
                            Read-SpectrePause -Message 'Press any key to review the other installer technologies' -AnyKey | Out-Null
                            Show-Win32ToolkitSiblingCaptureReview -ProjectPath $ProjectPath; $skipPause = $true
                        }
                    }
                }
                'candidates' {
                    # Block first: the highlighted default (V15); Enforce is never preselected and asks once more.
                    $m = Read-SpectreSelection -Message 'Declare the High candidate of the last Update test as' -Choices $modeChoices -ChoiceLabelProperty 'Label' -Color Blue
                    if (& $enforceOk $m.Key 'the High candidate of the last Update test') {
                        $null = Set-Win32ToolkitPriorInstall -ProjectPath $ProjectPath -FromUpdateTest -Mode $m.Key -Confirm:$false
                    }
                }
                'mode' {
                    $id = & $pickRule
                    if ($id) {
                        $m = Read-SpectreSelection -Message (& $esc "New mode for $id") -Choices $modeChoices -ChoiceLabelProperty 'Label' -Color Blue
                        $ruleKey = @($rows | Where-Object { [string]$_.Id -ceq $id } | ForEach-Object { "$($_.Key) [$($_.View)]" }) | Select-Object -First 1
                        if (& $enforceOk $m.Key "$ruleKey (rule $id)") {
                            $null = Set-Win32ToolkitPriorInstall -ProjectPath $ProjectPath -Id $id -Mode $m.Key -Confirm:$false
                        }
                    }
                }
                'remove' {
                    $id = & $pickRule
                    if ($id -and (Read-SpectreConfirm -Message (& $esc "Remove the rule $id? Devices with that install then keep it next to this package.") -DefaultAnswer 'n')) {
                        $null = Set-Win32ToolkitPriorInstall -ProjectPath $ProjectPath -Remove $id -Confirm:$false
                    }
                }
                'prove' {
                    $notReady = @(Test-Win32ToolkitHyperVReady)
                    if ($notReady.Count) { Write-SpectreHost "[yellow]$(& $esc ('Hyper-V is not ready (' + ($notReady -join '; ') + '): a proof needs the Hyper-V test VM.'))[/]" }
                    else {
                        $r = Invoke-Win32ToolkitPriorDemotion -ProjectPath $ProjectPath -Prove
                        $msg = @("Proven: $(if (@($r.Proven).Count) { @($r.Proven) -join ', ' } else { 'none' })")
                        if (@($r.Demoted).Count) { $msg += "Demoted to proposals: $(@($r.Demoted | ForEach-Object { "$($_.Id) ($($_.Reason))" }) -join '; ')" }
                        if (@($r.Unproven).Count) { $msg += "Not proven (never demoted): $(@($r.Unproven) -join ', ')" }
                        Format-SpectrePanel -Data (& $esc ($msg -join "`n")) -Header 'Proof' -Border Rounded -Color $(if (@($r.Demoted).Count -or @($r.Unproven).Count) { 'Yellow' } else { 'Green' }) | Out-SpectreHost
                    }
                }
            }
        }
        catch { & $showError $_ }
        if (-not $skipPause) { Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null }
    }
}
