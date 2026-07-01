function Show-Win32ToolkitTemplates {
    <#
    .SYNOPSIS
        Org-template management screen (Spectre): list, view, create, edit. Create/edit reuse the
        existing New-OrgTemplate wizard. See knowledge-base/designs/tui.md.
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
                        "Welcome dlg : enabled=$($t.WelcomeDialog.Enabled), deferrals=$($t.WelcomeDialog.DeferTimes), countdown=$($t.WelcomeDialog.CloseProcessesCountdown)s"
                        "Completion  : enabled=$($t.CompletionPrompt.Enabled)"
                    ) -join "`n"
                    Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $lines) -Header "Template: $(Get-SpectreEscapedText -Text $t.TemplateName)" -Border Rounded -Color Blue
                    Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
                }
            }
            'back' { return }
        }
    }
}
