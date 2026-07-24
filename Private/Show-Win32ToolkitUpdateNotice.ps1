function Show-Win32ToolkitUpdateNotice {
    <#
    .SYNOPSIS
        Renders one muted line when a newer win32-toolkit release is available. Never blocks or prompts.
    .DESCRIPTION
        A thin, fail-open presenter over Get-Win32ToolkitUpdateInfo. Prints nothing when the check is
        opted out, throttled, fails, or the toolkit is already current. The update hint covers both
        install styles: Update-Module for a Gallery install, and the releases page for a git clone.
    .PARAMETER Force
        Force a live check (bypass the cache TTL). Used by the Settings 'check now' action.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    $info = try { Get-Win32ToolkitUpdateInfo -Force:$Force } catch { $null }
    if (-not $info -or -not $info.UpdateAvailable) { return }

    Write-SpectreHost ("[grey]Update available:[/] [yellow]v{0}[/] [grey]->[/] [green]v{1}[/]  [grey](Update-Module win32-toolkit, or {2})[/]" -f `
            $info.Installed, $info.Latest, $info.ReleasesUrl)
}
