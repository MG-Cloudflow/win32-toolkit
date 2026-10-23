function Show-Win32ToolkitBrowse {
    <#
    .SYNOPSIS
        Read-only project browser grouped by template (Spectre). See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([string]$BasePath)

    Write-SpectreRule -Title 'Projects' -Color Grey
    $projects = @(Get-PSADTProjects -BasePath $BasePath)
    if ($projects.Count -eq 0) {
        Write-SpectreHost "[yellow]No projects yet.[/] Use [blue]Package an app[/] to create one."
    }
    else {
        # PSADT column (ORG-14): the bundled toolkit version, derived on demand from the project folder.
        # '(legacy)' = deploy script from win32-toolkit 1.1.6 or older (still packageable);
        # '(unsupported)' = shape/version pair this win32-toolkit version cannot generate or package.
        $psadtLabel = {
            param($ProjectPath)
            try {
                $pv = Get-Win32ToolkitProjectPsadtVersion -ProjectPath $ProjectPath
                $label = [string]$pv.VersionText
                if ($pv.IsLegacy) { $label += ' (legacy)' }
                if (-not $pv.IsSupported) { $label += ' (unsupported)' }
                $label
            }
            catch { 'unknown' }
        }
        $projects | Sort-Object Template, Name |
            Select-Object @{ n = 'Template'; e = { $_.Template } },
                # TUI audit G4: a project whose build stopped after its folder was created (Package and Publish refuse it).
                @{ n = 'Application'; e = { if ($_.PSObject.Properties['NotConfigured'] -and $_.NotConfigured) { $_.Name + ' (not configured)' } else { $_.Name } } },
                @{ n = 'PSADT'; e = { & $psadtLabel $_.Path } } |
            Format-SpectreTable -Border Rounded -Color Grey -Title "$($projects.Count) project(s) under $(Get-SpectreEscapedText -Text $BasePath)"
    }
    Read-SpectrePause -Message 'Press any key to return to the menu' -AnyKey | Out-Null
}
