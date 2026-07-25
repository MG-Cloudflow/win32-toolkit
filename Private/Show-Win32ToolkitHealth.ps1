function Show-Win32ToolkitHealth {
    <#
    .SYNOPSIS
        Renders the prerequisite status table (Spectre). See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([string]$BasePath)

    $checks = Test-Win32ToolkitPrerequisites -BasePath $BasePath
    # Out-SpectreHost renders and returns NOTHING. Without it, Write-SpectreRule/Format-SpectreTable
    # (PwshSpectreConsole 2.6.3+) return the renderable to the pipeline; when a caller CAPTURES this
    # screen's output (Settings' "recheck" branch), those objects pollute the captured value.
    Write-SpectreRule -Title 'System check' -Color Grey | Out-SpectreHost
    $rows = foreach ($c in $checks) {
        [pscustomobject]@{
            ' '          = if ($c.Ok) { '[green]OK[/]' } else { '[red]X[/]' }
            'Component'  = $c.Name
            # Wrap so a long status (e.g. the Hyper-V "not elevated ..." message) wraps WITHIN this
            # column instead of forcing the table wide and mid-word-wrapping the label columns.
            'Detail'     = Get-SpectreEscapedText -Text (Get-Win32ToolkitWrappedText -Text $c.Detail -MaxWidth 50)
            'Needed for' = $c.Purpose
        }
    }
    $rows | Format-SpectreTable -AllowMarkup -Border Rounded -Color Grey | Out-SpectreHost
    if (@($checks | Where-Object { -not $_.Ok -and $_.Fixable }).Count -gt 0) {
        Write-SpectreHost "[yellow]Tip:[/] fixable items can be resolved from [blue]Settings[/], or the toolkit offers to fix them when you first use a feature."
    }
}
