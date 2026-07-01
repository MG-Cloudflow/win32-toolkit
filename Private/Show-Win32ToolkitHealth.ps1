function Show-Win32ToolkitHealth {
    <#
    .SYNOPSIS
        Renders the prerequisite status table (Spectre). See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([string]$BasePath)

    $checks = Test-Win32ToolkitPrerequisites -BasePath $BasePath
    Write-SpectreRule -Title 'System check' -Color Grey
    $rows = foreach ($c in $checks) {
        [pscustomobject]@{
            ' '          = if ($c.Ok) { '[green]OK[/]' } else { '[red]X[/]' }
            'Component'  = $c.Name
            'Detail'     = Get-SpectreEscapedText -Text $c.Detail
            'Needed for' = $c.Purpose
        }
    }
    $rows | Format-SpectreTable -AllowMarkup -Border Rounded -Color Grey
    if (@($checks | Where-Object { -not $_.Ok -and $_.Fixable }).Count -gt 0) {
        Write-SpectreHost "[yellow]Tip:[/] fixable items can be resolved from [blue]Settings[/], or the toolkit offers to fix them when you first use a feature."
    }
}
