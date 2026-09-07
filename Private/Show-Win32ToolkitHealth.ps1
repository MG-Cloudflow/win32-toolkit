function Show-Win32ToolkitHealth {
    <#
    .SYNOPSIS
        Renders the prerequisite status table (Spectre). See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([string]$BasePath)

    $checks = Test-Win32ToolkitPrerequisites -BasePath $BasePath
    # PwshSpectreConsole 2.6.x render commands — Write-SpectreRule, Format-SpectreTable, and
    # Out-SpectreHost itself — RETURN the rendered ANSI text; it only displays when the stream reaches
    # Out-Default. So this screen renders THROUGH its success stream: callers must invoke it as a bare
    # statement, never capture or Out-Null it (issue #67; knowledge-base/designs/tui.md).
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
