function Show-Win32ToolkitTemplates {
    <#
    .SYNOPSIS
        Org-template management screen (Spectre): list, view, create, edit, duplicate, delete.
        Create/edit reuse the New-OrgTemplate wizard; duplicate/delete clone or remove the template
        JSON AND its sidecar Templates\<name>\ folder (hooks/module/assets), never the output tiers.
        See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BasePath)

    $templatesDir = (Get-Win32ToolkitPaths -BasePath $BasePath).Templates

    # Local picker: string label + lookup; returns the selected template record or $null.
    function Select-One($records) {
        $lookup = [ordered]@{}
        $labels = foreach ($r in $records) {
            $label = Get-SpectreEscapedText -Text $r.Name
            $lookup[$label] = $r
            $label
        }
        $chosen = Read-SpectreSelection -Message 'Choose a template' -Choices @($labels) -Color Blue -PageSize 12
        return $lookup[$chosen]
    }

    while ($true) {
        Clear-Host
        Write-SpectreRule -Title 'Org templates' -Color Blue

        $files = if (Test-Path $templatesDir) { @(Get-ChildItem $templatesDir -Filter *.json -ErrorAction SilentlyContinue) } else { @() }
        $records = foreach ($f in $files) {
            $t = try { Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
            if ($t) {
                [pscustomobject]@{
                    Name    = if ($t.TemplateName) { $t.TemplateName } else { $f.BaseName }
                    Company = $t.CompanyName
                    Author  = $t.AppScriptAuthor
                    PSADT   = $t.PsadtVersion
                    Obj     = $t
                }
            }
        }
        $records = @($records)

        if ($records.Count -gt 0) {
            $records | Select-Object Name, Company, Author, PSADT |
                Format-SpectreTable -Border Rounded -Color Grey -Title "Templates in $(Get-SpectreEscapedText -Text $templatesDir)"
        }
        else {
            Write-SpectreHost "[yellow]No templates yet — create one to brand your packages.[/]"
        }

        $sel = Read-SpectreSelection -Message 'Templates' -Choices @(
            [pscustomobject]@{ Key = 'new';  Label = 'Create a new template' }
            [pscustomobject]@{ Key = 'edit'; Label = 'Edit a template' }
            [pscustomobject]@{ Key = 'view'; Label = 'View a template''s settings' }
            [pscustomobject]@{ Key = 'dup';  Label = 'Duplicate a template' }
            [pscustomobject]@{ Key = 'del';  Label = 'Delete a template' }
            [pscustomobject]@{ Key = 'back'; Label = 'Back to the main menu' }
        ) -ChoiceLabelProperty 'Label' -Color Blue

        switch ($sel.Key) {
            'new' {
                Write-SpectreHost '[grey]Launching the template wizard…[/]'
                try { New-OrgTemplate -BasePath $BasePath | Out-Null }
                catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
            }
            'edit' {
                if ($records.Count -eq 0) { Write-SpectreHost '[yellow]No templates to edit.[/]'; Read-SpectrePause -AnyKey | Out-Null; break }
                $pick = Select-One $records
                if ($pick) {
                    Write-SpectreHost '[grey]Launching the template wizard (pre-filled)…[/]'
                    try { New-OrgTemplate -ExistingTemplate $pick.Obj -BasePath $BasePath | Out-Null }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'view' {
                if ($records.Count -eq 0) { Write-SpectreHost '[yellow]No templates to view.[/]'; Read-SpectrePause -AnyKey | Out-Null; break }
                $pick = Select-One $records
                if ($pick) {
                    $t = $pick.Obj
                    $lines = @(
                        "Template    : $($t.TemplateName)"
                        "Company     : $($t.CompanyName)"
                        "Author      : $($t.AppScriptAuthor)"
                        "Accent      : $($t.FluentAccentColor)"
                        "Log path    : $($t.LogPath)"
                        "PSADT       : $($t.PsadtVersion)"
                        "Dialog style: $($t.DialogStyle)"
                        "Language    : $(if ($t.LanguageOverride) { $t.LanguageOverride } else { 'auto-detect' })"
                        "Welcome dlg : enabled=$($t.WelcomeDialog.Enabled), deferrals=$($t.WelcomeDialog.DeferTimes), countdown=$($t.WelcomeDialog.CloseProcessesCountdown)s"
                        "Completion  : enabled=$($t.CompletionPrompt.Enabled)"
                        "Hooks       : enabled=$($t.Hooks.Enabled), on-error=$($t.Hooks.FailureAction)"
                        "Ext module  : $($t.ExtensionModule)"
                        "Org assets  : $($t.CustomAssets)"
                        "Intune min-OS: $($t.IntuneDefaults.MinimumWindowsRelease), restart=$($t.IntuneDefaults.DeviceRestartBehavior), maxRun=$($t.IntuneDefaults.MaxRuntimeMinutes)m"
                    ) -join "`n"
                    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $lines) -Header "Template: $(Get-SpectreEscapedText -Text $t.TemplateName)" -Border Rounded -Color Blue
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'dup' {
                if ($records.Count -eq 0) { Write-SpectreHost '[yellow]No templates to duplicate.[/]'; Read-SpectrePause -AnyKey | Out-Null; break }
                $pick = Select-One $records
                if ($pick) {
                    $newName = Read-SpectreText -Message "New template name (copy of '$($pick.Name)')"
                    try {
                        $path = Copy-Win32ToolkitTemplate -SourceName $pick.Name -NewName $newName -BasePath $BasePath
                        if ($path) { Write-SpectreHost "[green]✓ Duplicated to '$(Get-SpectreEscapedText -Text $newName)'.[/]" }
                    }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'del' {
                if ($records.Count -eq 0) { Write-SpectreHost '[yellow]No templates to delete.[/]'; Read-SpectrePause -AnyKey | Out-Null; break }
                $pick = Select-One $records
                if ($pick) {
                    $inUse = @(Get-Win32ToolkitTemplateUsage -Name $pick.Name -BasePath $BasePath)
                    if ($inUse.Count -gt 0) {
                        Write-SpectreHost "[yellow]⚠ '$(Get-SpectreEscapedText -Text $pick.Name)' is in use by $($inUse.Count) output folder(s):[/]"
                        foreach ($u in $inUse) { Write-SpectreHost "  [grey]$(Get-SpectreEscapedText -Text $u)[/]" }
                        Write-SpectreHost '[grey]Only the template definition is deleted — those projects are left untouched.[/]'
                    }
                    if (Read-SpectreConfirm -Message "Delete template '$(Get-SpectreEscapedText -Text $pick.Name)'?" -DefaultAnswer 'n') {
                        try {
                            $res = Remove-Win32ToolkitTemplate -Name $pick.Name -BasePath $BasePath -Force
                            $col = if ($res.Removed) { 'green' } else { 'yellow' }
                            Write-SpectreHost "[$col]$(Get-SpectreEscapedText -Text $res.Message)[/]"
                        }
                        catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Error' -Border Rounded -Color Red }
                    } else { Write-SpectreHost '[grey]Cancelled.[/]' }
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'back' { return }
        }
    }
}
