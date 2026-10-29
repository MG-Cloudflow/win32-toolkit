function Show-Win32ToolkitPsadtVersion {
    <#
    .SYNOPSIS
        Menu screen (Spectre): see and choose the PSAppDeployToolkit version for new projects, or install another
        supported version next to the others.
    .DESCRIPTION
        Menu selectors design section 3 (knowledge-base/designs/menu-selectors.md). Shows what new projects get and why
        (Select-Win32ToolkitPsadtModule: no pin, the PreferredPsadtVersion registry value, or $env:W32T_PSADT_VERSION),
        the copy loaded in this process when it differs (one PSADT per process: a change reaches the next session), the
        installed copies, and the choices of Get-Win32ToolkitPsadtChoice. A choice is saved with
        Set-Win32ToolkitPsadtPreference; an install goes through Install-Win32ToolkitPsadtVersion (stable, in range,
        Install-Module -RequiredVersion only). The screen never imports, removes or updates PSAppDeployToolkit, never
        changes the supported range and never sets or clears $env:W32T_PSADT_VERSION.

        TUI screens render THROUGH their success stream (PwshSpectreConsole 2.6.x render commands return their rendered
        text), so callers invoke this as a bare statement and never capture it (issue #67; knowledge-base/designs/tui.md).
    #>
    [CmdletBinding()]
    param()

    $esc = { param([string]$Text) Get-SpectreEscapedText -Text $Text }
    $pause = { Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null }
    $panel = {
        param([string]$Text, [string]$Header, [string]$Color)
        Format-SpectrePanel -Data $Text -Header $Header -Border Rounded -Color $Color | Out-SpectreHost
    }
    # The PSAppDeployToolkit this process has loaded (as Create-PSADTProject reads it), or $null.
    $loadedText = {
        $loaded = @(Get-Module -Name PSAppDeployToolkit -All | Where-Object { $_.ModuleBase }) | Select-Object -First 1
        if (-not $loaded) { return $null }
        $pre = ''
        try { $pre = [string](Import-PowerShellDataFile -LiteralPath (Join-Path $loaded.ModuleBase 'PSAppDeployToolkit.psd1')).PrivateData.PSData.Prerelease }
        catch { $pre = '' }
        if ($pre) { "$($loaded.Version)-$pre" } else { "$($loaded.Version)" }
    }
    # After a save or an install: what new projects get now, and the notes that apply (P3, P6, PE4).
    $afterNotes = {
        $now = Select-Win32ToolkitPsadtModule
        $lines = [System.Collections.Generic.List[string]]::new()
        if ($now.Status -eq 'Selected') { $lines.Add("New projects get PSADT $(& $esc $now.VersionText).") }
        else { $lines.Add((& $esc $now.Reason)) }
        if (-not [string]::IsNullOrWhiteSpace($env:W32T_PSADT_VERSION)) {
            $lines.Add("This window uses `$env:W32T_PSADT_VERSION = '$(& $esc (ConvertTo-Win32ToolkitSafeText -Text $env:W32T_PSADT_VERSION -MaxLength 40))'. Your choice is saved for your other windows.")
        }
        $l = & $loadedText
        if ($l -and $now.Status -eq 'Selected' -and -not [string]::Equals($l, $now.VersionText, [System.StringComparison]::OrdinalIgnoreCase)) {
            $lines.Add("New projects in this window keep $(& $esc $l). Start a new PowerShell session to use $(& $esc $now.VersionText).")
        }
        $lines.Add('Existing projects keep the PSADT copy they were built with. Re-create a project to change it.')
        $lines -join "`n"
    }
    # Install one gallery row (Kind Install or Replace) after the question; then offer to use it. $true = installed.
    $install = {
        param([object]$Row)
        $text = [string]$Row.VersionText
        if ($Row.Kind -eq 'Replace') {
            Write-SpectreHost "[yellow]PSAppDeployToolkit $(& $esc $text) replaces the installed $(& $esc $Row.Replaces) (the same folder).[/]"
            Write-SpectreHost "Close every other PowerShell window that uses PSAppDeployToolkit $(& $esc $Row.Replaces) first. Projects built with it keep their own copy."
            if (-not (Read-SpectreConfirm -Message "Replace $(& $esc $Row.Replaces) with $(& $esc $text)?" -DefaultAnswer 'n')) { return $false }
        }
        elseif (-not (Read-SpectreConfirm -Message "Install PSAppDeployToolkit $(& $esc $text) for your Windows account? It goes next to the others. Nothing else changes." -DefaultAnswer 'n')) {
            return $false
        }
        try {
            $after = Install-Win32ToolkitPsadtVersion -Version $text -Replace:($Row.Kind -eq 'Replace')
            Write-SpectreHost "[green]Installed PSAppDeployToolkit $(& $esc $text).[/]"
            if ($after -and -not ($after.Status -eq 'Selected' -and [string]::Equals($after.VersionText, $text, [System.StringComparison]::OrdinalIgnoreCase))) {
                if (Read-SpectreConfirm -Message "Use $(& $esc $text) for new projects?" -DefaultAnswer 'y') {
                    $saved = Set-Win32ToolkitPsadtPreference -Value $text
                    if (-not $saved.Ok) { Write-SpectreHost "[yellow]The choice could not be saved. Saved now: '$(& $esc $saved.Saved)'.[/]" }
                }
            }
            & $panel (& $afterNotes) 'Done' 'Green'
            return $true
        }
        catch {
            $msg = & $esc $_.Exception.Message
            if ($Row.Kind -eq 'Replace') { $msg += "`nIf the folder is now incomplete, install that version again by hand (Install-Module PSAppDeployToolkit -RequiredVersion $(& $esc $text) -Scope CurrentUser -Force)." }
            & $panel "[red]$msg[/]" 'Error' 'Red'
            return $false
        }
    }

    while ($true) {
        Clear-Host
        Write-SpectreRule -Title 'PSAppDeployToolkit version' -Color Blue

        $sel = Select-Win32ToolkitPsadtModule
        $saved = ([string](Get-Win32ToolkitConfigValue -Name 'PreferredPsadtVersion' -Default '')).Trim()
        $envPin = [string]$env:W32T_PSADT_VERSION

        # -- What new projects get, and why --------------------------------------------------------------------------
        switch ($sel.Status) {
            'Selected' {
                Write-SpectreHost "New projects get: [blue]PSADT $(& $esc $sel.VersionText)[/]"
                $why = switch ($sel.PreferredSource) {
                    'Environment' { "pinned by `$env:W32T_PSADT_VERSION = '$(& $esc (ConvertTo-Win32ToolkitSafeText -Text $envPin -MaxLength 40))' in this window." }
                    'Registry'    { "pinned by PreferredPsadtVersion '$(& $esc (ConvertTo-Win32ToolkitSafeText -Text $saved -MaxLength 40))' (saved in Settings)." }
                    default       { 'no pin, so the newest supported version that is installed.' }
                }
                Write-SpectreHost "[grey]Why:[/] $why"
                if ($sel.IsPrerelease) { Write-SpectreHost '[yellow]This is a prerelease: fine for testing, not for production packages.[/]' }
            }
            'NoneInstalled' {
                Write-SpectreHost "[yellow]No PSAppDeployToolkit installed.[/] New projects install the newest stable supported version ($(& $esc $script:PsadtSupportedRange.Display))."
            }
            default {
                Write-SpectreHost "[red]New projects cannot start now:[/] $(& $esc $sel.Reason)"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($envPin) -and $sel.PreferredSource -eq 'Environment') {
            Write-SpectreHost '[grey]What you choose here is saved for your other windows. This window keeps the variable until you close it.[/]'
        }
        $loaded = & $loadedText
        if ($loaded -and $sel.Status -eq 'Selected' -and -not [string]::Equals($loaded, $sel.VersionText, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-SpectreHost "[yellow]Loaded in this window: $(& $esc $loaded).[/] New projects in this window keep $(& $esc $loaded). Start a new PowerShell session to use $(& $esc $sel.VersionText)."
        }

        # -- Installed copies -----------------------------------------------------------------------------------------
        $candidates = @(@($sel.Candidates) | Where-Object { $null -ne $_ })
        if ($candidates.Count -gt 0) {
            $inUsePath = if ($sel.Module) { [string]$sel.Module.Path } else { '' }
            $rows = foreach ($c in $candidates) {
                $mark = ''
                if ($inUsePath -and [string]::Equals([string]$c.Path, $inUsePath, [System.StringComparison]::OrdinalIgnoreCase)) { $mark = '[green]in use[/]' }
                elseif (-not $c.InRange) { $mark = '[grey]ignored[/]' }
                [pscustomobject]@{
                    'Version'   = & $esc ([string]$c.VersionText)
                    'Supported' = $(if ($c.InRange) { 'Yes' } else { 'No' })
                    'Kind'      = $(if ($c.IsPrerelease) { 'prerelease' } else { 'stable' })
                    'Folder'    = & $esc (Split-Path -Parent ([string]$c.Path))
                    ' '         = $mark
                }
            }
            $rows | Format-SpectreTable -AllowMarkup -Border Rounded -Color Grey -Title 'Installed copies' | Out-SpectreHost
        }
        Write-SpectreHost '[grey]Existing projects keep the PSADT copy they were built with.[/]'

        # -- Choices ----------------------------------------------------------------------------------------------------
        $choices = [System.Collections.Generic.List[object]]::new()
        foreach ($r in @(Get-Win32ToolkitPsadtChoice -Selection $sel -SavedValue $saved)) {
            $label = $r.Label
            if ($r.Kind -ne 'Exact' -and $r.ResolvesTo) { $label += " - now $($r.ResolvesTo)" }
            if ($r.IsCurrent) { $label += ' (saved)' }
            $choices.Add([pscustomobject]@{ Key = 'choice'; Label = (& $esc $label); Row = $r })
        }
        # PE3: a pin that is not installed can be installed, when the gallery has it (checked when chosen).
        $pinValue = ''
        if ($sel.Status -eq 'PreferredNotFound') {
            $pinValue = if ($sel.PreferredSource -eq 'Environment') { $envPin.Trim() } else { $saved }
            if ($pinValue -match '^\d{1,9}\.\d{1,9}\.\d{1,9}(\.\d{1,9})?$' -and (Test-Win32ToolkitPsadtVersionSupported -Version $pinValue)) {
                $choices.Add([pscustomobject]@{ Key = 'installpin'; Label = (& $esc "Install the pinned version $pinValue"); Row = $null })
            }
        }
        $choices.Add([pscustomobject]@{ Key = 'install'; Label = 'Install another supported version from PowerShell Gallery'; Row = $null })
        $choices.Add([pscustomobject]@{ Key = 'back'; Label = 'Back'; Row = $null })

        $pick = Read-SpectreSelection -Message 'PSAppDeployToolkit version for new projects' -Choices $choices.ToArray() -ChoiceLabelProperty 'Label' -Color Blue -PageSize 12
        switch ($pick.Key) {
            'back' { return }
            'choice' {
                $row = $pick.Row
                if ($row.IsCurrent) {
                    Write-SpectreHost '[grey]That is already your saved choice. Nothing changed.[/]'
                    & $pause
                    continue
                }
                if ($row.IsPrerelease -and -not (Read-SpectreConfirm -Message "PSADT $(& $esc $row.Value) is a prerelease: fine for testing, not for production packages. Use it for new projects?" -DefaultAnswer 'n')) {
                    continue
                }
                try {
                    $res = Set-Win32ToolkitPsadtPreference -Value $row.Value
                    if ($res.Ok) { & $panel (& $afterNotes) 'Saved' 'Green' }
                    else { & $panel "[yellow]The choice could not be saved. Saved now: '$(& $esc $res.Saved)'.[/]" 'Not saved' 'Yellow' }
                }
                catch { & $panel "[red]$(& $esc $_.Exception.Message)[/]" 'Error' 'Red' }
                & $pause
            }
            { $_ -in 'install', 'installpin' } {
                Clear-Host
                Write-SpectreRule -Title 'Install PSAppDeployToolkit' -Color Blue
                Write-SpectreHost '[grey]Asking PowerShell Gallery for the supported versions...[/]'
                $gallery = Get-Win32ToolkitPsadtGalleryVersion -Candidates $candidates
                if ($gallery.Problem) {
                    & $panel "[yellow]$(& $esc $gallery.Problem)[/]`nYou can still choose an installed version." 'Gallery not reachable' 'Yellow'
                    & $pause
                    continue
                }
                $versions = @($gallery.Versions)
                if ($pick.Key -eq 'installpin') {
                    $hit = @($versions | Where-Object { $_.VersionText -eq $pinValue }) | Select-Object -First 1
                    if (-not $hit) {
                        & $panel "PowerShell Gallery has no stable PSAppDeployToolkit $(& $esc $pinValue). Choose another version for new projects." 'Not available' 'Yellow'
                        & $pause
                        continue
                    }
                    $null = & $install $hit
                    & $pause
                    continue
                }
                if ($versions.Count -eq 0) {
                    & $panel "Every supported stable version on PowerShell Gallery ($(& $esc $script:PsadtSupportedRange.Display)) is installed already." 'Nothing to install' 'Grey'
                    & $pause
                    continue
                }
                $vchoices = [System.Collections.Generic.List[object]]::new()
                foreach ($v in $versions) {
                    $vl = if ($v.Kind -eq 'Replace') { "Replace $($v.Replaces) with $($v.VersionText)" } else { "Install $($v.VersionText)" }
                    $vchoices.Add([pscustomobject]@{ Key = 'version'; Label = (& $esc $vl); Row = $v })
                }
                $vchoices.Add([pscustomobject]@{ Key = 'back'; Label = 'Back'; Row = $null })
                $vpick = Read-SpectreSelection -Message 'Supported stable versions on PowerShell Gallery' -Choices $vchoices.ToArray() -ChoiceLabelProperty 'Label' -Color Blue -PageSize 12
                if ($vpick.Key -eq 'back') { continue }
                $null = & $install $vpick.Row
                & $pause
            }
        }
    }
}
