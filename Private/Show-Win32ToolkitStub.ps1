function Show-Win32ToolkitStub {
    <#
    .SYNOPSIS
        Placeholder panel for TUI actions not yet implemented (later phases).
        See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([string]$Title)

    Format-SpectrePanel -Data "[yellow]$Title[/] arrives in a later phase of the TUI.`nFor now, use the PowerShell commands directly (Get-Command -Module win32-toolkit)." -Header $Title -Border Rounded -Color Yellow
    Read-SpectrePause -Message 'Press any key to return to the menu' -AnyKey | Out-Null
}
