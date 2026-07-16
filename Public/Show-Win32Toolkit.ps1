function Show-Win32Toolkit {
<#
.SYNOPSIS
    Launches the interactive, menu-driven text UI (TUI) for win32-toolkit.
.DESCRIPTION
    A fool-proof, first-line-friendly front-end over the whole pipeline: package an app from winget
    or a manual installer, test and update-test existing projects (Windows Sandbox or the Hyper-V
    VM), manage dependencies, package and publish to Intune, manage org templates, the test VM, and
    settings — all from guided menus. The first screen is a prerequisite health check that tells you
    exactly what is missing and how to fix it.

    Built on PwshSpectreConsole — offered for one-time install on first launch if absent. Requires
    PowerShell 7.2+ and an interactive console.
.PARAMETER BasePath
    Optional base folder override for this session. If omitted, the registry-saved value is used, or
    first-run setup prompts for it.
.EXAMPLE
    Show-Win32Toolkit
#>
    [CmdletBinding()]
    param([string]$BasePath)

    # ── Guards: PS7.2+ and an interactive console ─────────────────────────────
    if ($PSVersionTable.PSVersion -lt [version]'7.2') {
        Write-Warning 'Show-Win32Toolkit requires PowerShell 7.2 or later.'
        return
    }
    if ([System.Console]::IsInputRedirected -or [System.Console]::IsOutputRedirected) {
        Write-Warning 'Show-Win32Toolkit needs an interactive console window (not a redirected or embedded host).'
        return
    }

    # ── Ensure the UI component (plain prompt — Spectre may not be present yet) ─
    if (-not (Get-Module -ListAvailable PwshSpectreConsole)) {
        Write-Host 'The text UI needs the PwshSpectreConsole module (a one-time install).' -ForegroundColor Yellow
        if ((Read-Host 'Install it now for your user account? (Y/N)') -match '^[Yy]') {
            try { Install-Module PwshSpectreConsole -Scope CurrentUser -Force -AcceptLicense -ErrorAction Stop }
            catch { Write-Warning "Install failed: $($_.Exception.Message)"; return }
        }
        else {
            Write-Host 'Cannot start the UI without it. You can still use the commands: Get-Command -Module win32-toolkit' -ForegroundColor Yellow
            return
        }
    }
    Import-Module PwshSpectreConsole -ErrorAction Stop

    # ── Resolve the base folder (first-run setup via the UI if unset) ──────────
    $base = Get-Win32ToolkitBasePath -BasePath $BasePath -NonInteractive
    Clear-Host
    Write-SpectreFigletText -Text 'win32-toolkit' -Color Blue
    if (-not $base) { $base = Show-Win32ToolkitFirstRun }

    # ── Main loop ──────────────────────────────────────────────────────────────
    while ($true) {
        Clear-Host
        Write-SpectreFigletText -Text 'win32-toolkit' -Color Blue
        Show-Win32ToolkitHealth -BasePath $base

        switch (Show-Win32ToolkitMainMenu) {
            'winget'    { Invoke-Win32ToolkitWingetWizard -BasePath $base }
            'manual'    { Invoke-Win32ToolkitManualWizard -BasePath $base }
            'project'   { Show-Win32ToolkitProjectActions -BasePath $base }
            'browse'    { Show-Win32ToolkitBrowse   -BasePath $base }
            'templates' { Show-Win32ToolkitTemplates -BasePath $base }
            'settings'  { $base = Show-Win32ToolkitSettings -BasePath $base }
            'exit'      { Write-SpectreHost '[grey]Goodbye.[/]'; return }
            default     { return }
        }
    }
}
