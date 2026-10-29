function Show-Win32ToolkitTestVMSelect {
    <#
    .SYNOPSIS
        Menu screen (Spectre): see and choose the Hyper-V test VM and checkpoint that tests use.
    .DESCRIPTION
        Menu selectors design section 4 (knowledge-base/designs/menu-selectors.md). Shows which VM and checkpoint tests
        use and why (Get-Win32ToolkitHyperVTarget: W32T_HYPERV_VM / W32T_HYPERV_CHECKPOINT in this window, the saved
        HyperVVMName / HyperVCheckpoint, or the defaults), the VMs with their clean checkpoints and whether another window
        is using them (Get-Win32ToolkitTestVMChoice, Get-Win32ToolkitHyperVLeaseState), and saves a choice with
        Set-Win32ToolkitHyperVTarget. Before it saves it says what the choice means: every test restores the checkpoint
        and loses all changes made in the VM since (V7, asked for every VM); a VM a lane runner holds keeps tests waiting
        (V2); windows that pin only the VM use the saved checkpoint name too (V4); a pin in this window stays (V4); the
        default test backend does not change (V8); every VM uses the one saved guest account (V9).

        Read-only on Hyper-V: this screen never starts, stops, restores, checkpoints or removes a VM, never takes a lease
        and never reads the guest credential. TUI screens render THROUGH their success stream, so callers invoke this as a
        bare statement and never capture it (issue #67).
    #>
    [CmdletBinding()]
    param()

    # Names are at most 100 characters (Get-Win32ToolkitTestVMChoice offers no longer one), so a label stays whole and unique.
    $esc = { param([string]$Text) Get-SpectreEscapedText -Text (ConvertTo-Win32ToolkitSafeText -Text $Text -MaxLength 400) }
    $pause = { Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null }
    $panel = {
        param([string]$Text, [string]$Header, [string]$Color)
        Format-SpectrePanel -Data $Text -Header $Header -Border Rounded -Color $Color | Out-SpectreHost
    }
    $source = {
        param([string]$Source, [string]$EnvName)
        switch ($Source) { 'Environment' { "pinned by $EnvName in this window" } 'Registry' { 'saved in Settings' } default { 'the default' } }
    }
    $inUseText = {
        param($Lease)
        if ($null -eq $Lease) { return '' }
        switch ([string]$Lease.State) {
            'ThisWindow' { 'this window' }
            'Free'       { 'free' }
            'InUse' {
                if ($Lease.ProcessId) { 'another window: {0} since {1} UTC (process {2})' -f $Lease.Purpose, $Lease.SinceUtc.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture), $Lease.ProcessId }
                else { 'another window' }
            }
            default { 'unknown' }
        }
    }
    # Save a choice and show what it means now. $UseDefault = back to the default (both values cleared).
    $save = {
        param([bool]$UseDefault, [string]$Name, [string]$Checkpoint)
        try {
            $res = if ($UseDefault) { Set-Win32ToolkitHyperVTarget -Default } else { Set-Win32ToolkitHyperVTarget -VMName $Name -CheckpointName $Checkpoint }
            $savedVm = if ($res.VMName) { $res.VMName } else { 'win32tk-golden' }
            $savedCp = if ($res.CheckpointName) { $res.CheckpointName } else { 'clean-base' }
            $lines = [System.Collections.Generic.List[string]]::new()
            if (-not $res.Ok) { $lines.Add('[yellow]The choice could not be saved completely.[/]') }
            $lines.Add("Saved: tests use VM $(& $esc $savedVm), checkpoint $(& $esc $savedCp).")
            $t = $res.Target
            if ($t -and $t.Source -eq 'Environment') {
                $lines.Add("This window keeps W32T_HYPERV_VM = '$(& $esc $t.VMName)'. Your choice is for your other windows.")
            }
            elseif ($t -and $t.CheckpointSource -eq 'Environment') {
                $lines.Add("This window keeps W32T_HYPERV_CHECKPOINT = '$(& $esc $t.CheckpointName)'.")
            }
            if ((Get-Win32ToolkitConfigValue -Name 'TestBackend' -Default 'Sandbox') -ne 'HyperV') {
                $lines.Add('Tests still run in Windows Sandbox. Set the default test backend to Hyper-V to use this VM.')
            }
            $lines.Add('Tests sign in to every test VM with the one saved guest account. A VM with another password fails at its first test.')
            # No readiness probe here: it reads the guest credential (V9). The Hyper-V test VM screen checks the new VM
            # and checkpoint as soon as it shows again (its readiness memo is keyed by VM and checkpoint).
            $lines.Add('The Hyper-V test VM screen shows next whether this VM is ready.')
            & $panel ($lines -join "`n") 'Saved' 'Green'
        }
        catch { & $panel "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" 'Not changed' 'Red' }
        & $pause
    }

    Clear-Host
    Write-SpectreRule -Title 'Choose the test VM' -Color Blue
    $target = Get-Win32ToolkitHyperVTarget -NoThrow
    if ($target.Problem) {
        Write-SpectreHost "[red]This window's test VM pin is not valid:[/] $(& $esc $target.Problem)"
    }
    else {
        Write-SpectreHost "Tests use: VM [blue]$(& $esc $target.VMName)[/], checkpoint [blue]$(& $esc $target.CheckpointName)[/]"
        $vmWhy = & $source $target.Source 'W32T_HYPERV_VM'
        $cpWhy = & $source $target.CheckpointSource 'W32T_HYPERV_CHECKPOINT'
        $why = if ($vmWhy -eq $cpWhy) { "both $vmWhy" } else { "the VM $vmWhy, the checkpoint $cpWhy" }
        Write-SpectreHost "[grey]Why:[/] $why."
    }
    if ($target.Source -eq 'Environment') {
        Write-SpectreHost '[grey]This window keeps its W32T_HYPERV_VM pin. What you choose here is saved for your other windows.[/]'
    }

    $list = Get-Win32ToolkitTestVMChoice
    $choices = [System.Collections.Generic.List[object]]::new()
    switch ($list.Problem) {
        'NotElevated' { Write-SpectreHost '[yellow]Start the menu as administrator to see and choose VMs.[/]' }
        'NoHyperV'    { Write-SpectreHost '[yellow]The Hyper-V PowerShell module is not installed, so no VM can be listed.[/]' }
        ''            {
            $rows = @($list.Rows)
            if ($rows.Count -eq 0) {
                Write-SpectreHost '[yellow]No VM found.[/] Provision one on the Hyper-V test VM screen.'
            }
            else {
                # Pre-wrap the long cells to the width their column really gets (as the system check does): one long cell
                # otherwise makes Spectre squeeze the others to '...' (live check of the PSADT screen, 2026-10-29).
                # 16 = 6 border glyphs + 10 padding for 5 columns; State is at most 'Running' wide.
                $bufW = 0
                try { $bufW = [int]$Host.UI.RawUI.BufferSize.Width } catch { $bufW = 0 }
                if ($bufW -le 0) { $bufW = 120 }
                $vmW = 24; $useW = 22; $noteW = 24
                $cpW = [Math]::Max(16, $bufW - 16 - $vmW - 'Running'.Length - $useW - $noteW - 1)
                $wrap = { param([string]$Text, [int]$Width) Get-SpectreEscapedText -Text (Get-Win32ToolkitWrappedText -Text (ConvertTo-Win32ToolkitSafeText -Text $Text -MaxLength 400) -MaxWidth $Width) }
                $table = foreach ($r in $rows) {
                    $clean = @($r.Checkpoints | Where-Object Offered | ForEach-Object { $_.Name })
                    $cpText = if ($clean.Count -gt 3) { (($clean[0..2]) -join ', ') + ', ...' } else { $clean -join ', ' }
                    $isTarget = -not $target.Problem -and [string]::Equals($r.Name, [string]$target.VMName, [System.StringComparison]::OrdinalIgnoreCase)
                    [pscustomobject]@{
                        'VM'                = & $wrap $(if ($r.Count -gt 1) { "$($r.Name) ($($r.Count) VMs)" } else { $r.Name }) $vmW
                        'State'             = & $esc $r.State
                        'Clean checkpoints' = & $wrap $cpText $cpW
                        'In use'            = & $wrap (& $inUseText $r.Lease) $useW
                        'Note'              = $(if ($isTarget) { '[green]tests use this one[/]' } elseif (-not $r.Offered) { "[grey]$(& $wrap "not offered: $($r.WhyNot)" $noteW)[/]" } else { '' })
                    }
                }
                $table | Format-SpectreTable -AllowMarkup -Border Rounded -Color Grey | Out-SpectreHost
                foreach ($r in @($rows | Where-Object Offered)) {
                    $label = "Use $($r.Name)"
                    if ($r.Lease -and $r.Lease.State -eq 'InUse') { $label += ' (in use by another window)' }
                    $choices.Add([pscustomobject]@{ Key = 'vm'; Label = (& $esc $label); Row = $r })
                }
            }
        }
        default { Write-SpectreHost "[yellow]$(& $esc $list.Problem)[/]" }
    }
    $choices.Add([pscustomobject]@{ Key = 'default'; Label = 'Back to the default (win32tk-golden, clean-base)'; Row = $null })
    $choices.Add([pscustomobject]@{ Key = 'back'; Label = 'Back'; Row = $null })

    $pick = Read-SpectreSelection -Message 'Test VM' -Choices $choices.ToArray() -ChoiceLabelProperty 'Label' -Color Blue -PageSize 12
    if ($pick.Key -eq 'back') { return }
    if ($pick.Key -eq 'default') {
        if (Read-SpectreConfirm -Message "Use the default VM win32tk-golden with checkpoint clean-base for tests? Every test restores 'clean-base' and loses all changes made in win32tk-golden since." -DefaultAnswer 'y') {
            & $save $true '' ''
        }
        return
    }

    $row = $pick.Row
    $cpChoices = [System.Collections.Generic.List[object]]::new()
    foreach ($cp in @($row.Checkpoints | Where-Object Offered)) {
        $label = $cp.Name
        if ($cp.CreatedUtc) { $label += ", taken $($cp.CreatedUtc.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)) UTC" }
        if ($cp.Automatic) { $label += ' (automatic checkpoint: not a clean base)' }
        $cpChoices.Add([pscustomobject]@{ Key = 'cp'; Label = (& $esc $label); Row = $cp })
    }
    $cpChoices.Add([pscustomobject]@{ Key = 'back'; Label = 'Back'; Row = $null })
    $cpPick = Read-SpectreSelection -Message "Checkpoint of $(& $esc $row.Name) that every test restores" -Choices $cpChoices.ToArray() -ChoiceLabelProperty 'Label' -Color Blue -PageSize 12
    if ($cpPick.Key -eq 'back') { return }
    $cpName = [string]$cpPick.Row.Name
    $vmText = & $esc $row.Name
    $cpText = & $esc $cpName

    # What the choice means (V2, V4, V7).
    if ($row.Lease -and $row.Lease.State -eq 'InUse') {
        if ($row.Lease.Purpose -eq 'lane') {
            $wait = Get-Win32ToolkitConfigValue -Name 'HyperVLeaseWaitMinutes' -Default '60'
            Write-SpectreHost "[yellow]A lane runner holds $vmText for a whole queue.[/] Your tests would wait up to $(& $esc $wait) minutes (HyperVLeaseWaitMinutes) and then stop."
            if (-not (Read-SpectreConfirm -Message "Use $vmText anyway?" -DefaultAnswer 'n')) { return }
        }
        else { Write-SpectreHost "[grey]Another window is using $vmText now. Your next test waits until it is free.[/]" }
    }
    if ($cpName -ne 'clean-base') {
        Write-SpectreHost "[grey]Windows that pin only the VM (W32T_HYPERV_VM) also use the checkpoint name '$cpText'. Their VM needs a checkpoint with that name.[/]"
    }
    $usual = $row.Name -eq 'win32tk-golden' -or (-not $target.Problem -and [string]::Equals($row.Name, [string]$target.VMName, [System.StringComparison]::OrdinalIgnoreCase))
    if (-not (Read-SpectreConfirm -Message "Every test restores '$cpText' and loses all changes made in $vmText since. Use $vmText for tests?" -DefaultAnswer $(if ($usual) { 'y' } else { 'n' }))) {
        return
    }
    & $save $false ([string]$row.Name) $cpName
}
