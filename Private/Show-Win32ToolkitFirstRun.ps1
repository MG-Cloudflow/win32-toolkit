function Show-Win32ToolkitFirstRun {
    <#
    .SYNOPSIS
        First-run base-folder setup via the UI; saves to the registry and RETURNS NOTHING — the caller
        re-reads Get-Win32ToolkitBasePath. TUI screens render THROUGH their success stream, so callers
        must never capture them (issue #67). See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param()

    Format-SpectrePanel -Data "Welcome! Choose the base folder where all output lives (Templates, Projects, Staging, IntuneWin).`nThis is saved to the registry so you only pick it once." -Header 'First-run setup' -Border Rounded -Color Blue | Out-SpectreHost
    $folder = Read-SpectreText -Message 'Base folder' -DefaultAnswer 'C:\Win32Apps'
    if ([string]::IsNullOrWhiteSpace($folder)) { $folder = 'C:\Win32Apps' }
    $saved = Get-Win32ToolkitBasePath -Set $folder
    Write-SpectreHost "[green]Saved base folder:[/] $(Get-SpectreEscapedText -Text $saved)"
}
