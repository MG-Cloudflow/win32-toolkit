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
    # Pre-wrap Detail to the width its column really gets (test campaign 2026-10-21, S6-F3): a fixed 50 could be
    # wider than the column, so Spectre wrapped those lines AGAIN and left one-word lines ('not'). The pre-wrap
    # itself stays (Spectre alone mangles the label columns). Same width Write-AnsiConsole gives Spectre;
    # 13 = 5 border glyphs + 8 padding, 2 = the OK/!/X column. Inline on purpose: no new helper (C-9).
    $bufW = 0
    try { $bufW = [int]$Host.UI.RawUI.BufferSize.Width } catch { $bufW = 0 }
    if ($bufW -le 0) { $bufW = 120 }
    $nameW    = (@(@($checks | ForEach-Object { "$($_.Name)".Length }) + 'Component'.Length) | Measure-Object -Maximum).Maximum
    $purposeW = (@(@($checks | ForEach-Object { "$($_.Purpose)".Length }) + 'Needed for'.Length) | Measure-Object -Maximum).Maximum
    $detailW  = [Math]::Min(50, [Math]::Max(24, $bufW - 13 - 2 - $nameW - $purposeW))
    $rows = foreach ($c in $checks) {
        [pscustomobject]@{
            # Warn = usable, but worth a look (e.g. a prerelease PSAppDeployToolkit); rows without the
            # property render as before.
            ' '          = if ($c.Ok -and $c.Warn) { '[yellow]![/]' } elseif ($c.Ok) { '[green]OK[/]' } else { '[red]X[/]' }
            'Component'  = $c.Name
            # Wrap so a long status (e.g. the Hyper-V "not elevated ..." message) wraps WITHIN this
            # column instead of forcing the table wide and mid-word-wrapping the label columns.
            'Detail'     = Get-SpectreEscapedText -Text (Get-Win32ToolkitWrappedText -Text $c.Detail -MaxWidth $detailW)
            'Needed for' = $c.Purpose
        }
    }
    $rows | Format-SpectreTable -AllowMarkup -Border Rounded -Color Grey | Out-SpectreHost
    if (@($checks | Where-Object { -not $_.Ok -and $_.Fixable }).Count -gt 0) {
        Write-SpectreHost "[yellow]Tip:[/] fixable items can be resolved from [blue]Settings[/], or the toolkit offers to fix them when you first use a feature."
    }
}
