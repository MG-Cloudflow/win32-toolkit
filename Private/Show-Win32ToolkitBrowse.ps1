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
        $projects | Sort-Object Template, Name |
            Select-Object @{ n = 'Template'; e = { $_.Template } }, @{ n = 'Application'; e = { $_.Name } } |
            Format-SpectreTable -Border Rounded -Color Grey -Title "$($projects.Count) project(s) under $BasePath"
    }
    Read-SpectrePause -Message 'Press any key to return to the menu' -AnyKey | Out-Null
}
