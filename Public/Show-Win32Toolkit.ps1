function Show-Win32Toolkit {
<#
.SYNOPSIS
    Starts the win32-toolkit menu, where you do every task step by step.
.DESCRIPTION
    Show-Win32Toolkit starts the win32-toolkit menu in this PowerShell window. In the menu you
    package apps from winget or from your own installer, then test, build and publish them. You
    also manage org templates, the Intune connection, the Hyper-V test VM and the settings.

    Use the menu for your first app and for daily work. In scripts, use the other commands, for
    example Invoke-Win32Toolkit.

    If the PwshSpectreConsole module is missing, the command first asks to install it for your
    user account. Without that module the menu does not start, but the other commands still work.
    If no base folder is saved yet, the menu asks for one (the default is C:\Win32Apps) and saves
    it in the registry.

    The main screen shows the System check table of what the toolkit needs. On a new PC, up to
    three red rows are normal: PSAppDeployToolkit, Microsoft.Graph.Authentication and
    IntuneWinAppUtil.exe. The toolkit gets each one when you first need it. It asks before it
    installs Microsoft.Graph.Authentication.

    If a task stops on an error, you see a red "Something went wrong" panel and stay in the menu.
.PARAMETER BasePath
    The base folder to use for this menu session only. It is not saved, and the menu skips the
    first-run question. Default: your saved base folder.
.EXAMPLE
    Show-Win32Toolkit

    This starts the menu with your saved base folder. If no base folder is saved yet, it asks for
    one first.
.EXAMPLE
    Show-Win32Toolkit -BasePath 'D:\Win32Apps'

    This starts the menu with the base folder D:\Win32Apps. Your saved base folder does not change.
.OUTPUTS
    None. The menu shows its results on screen.
.NOTES
    Needs: PowerShell 7.4 or later in an interactive console window. If the input or output is
    redirected, the menu does not start: "Show-Win32Toolkit needs an interactive console window".
.LINK
    https://win32toolkit.com/reference/Show-Win32Toolkit/
.LINK
    https://win32toolkit.com/menu/
.LINK
    https://win32toolkit.com/install/
#>
    [CmdletBinding()]
    param([string]$BasePath)

    # ── Guards: PS7.4+ and an interactive console ─────────────────────────────
    if ($PSVersionTable.PSVersion -lt [version]'7.4') {
        Write-Warning 'Show-Win32Toolkit requires PowerShell 7.4 or later.'
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

    # ── Progress bars and a Spectre TUI cannot share a console ─────────────────
    # PowerShell's progress renderer owns its own screen region and paints straight over the
    # live-rendered UI. It does not repaint when Spectre redraws and it is not cleared by Clear-Host,
    # so a bar (classically Remove-Item's "Removed N of M files [MB/s]") is left stranded across the
    # menu until the console scrolls it away.
    #
    # Silencing it HERE — once, at the TUI root — is the whole fix: $ProgressPreference is DYNAMICALLY
    # scoped, so every command the menu launches inherits it (package / test / publish and their
    # helpers), including implicit cmdlet bars (Invoke-WebRequest, Expand-Archive, Copy-Item,
    # Remove-Item -Recurse, Install-Module) and the explicit Write-Progress countdowns in
    # New-TargetedDocumentation and Invoke-AzBlobUpload. Guarding each call site instead is
    # whack-a-mole: it is how a bar leaked back in after the first round of per-site fixes.
    #
    # The existing per-site guards stay — they matter for DIRECT, non-TUI calls, where progress is
    # useful and harmless — and they keep composing correctly: the "previous" value each one saves and
    # restores is simply this one.
    #
    # Restored in the finally so a scripted caller's own preference survives the TUI.
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    # ── UTF-8 output so Spectre renders in full, not the cramped OEM/code-page fallback ──────────
    # PwshSpectreConsole warns that a non-UTF-8 console "limits Spectre Console functionality": tables
    # and borders render in a degraded mode (mis-measured columns, mid-word wrapping). Set UTF-8 for the
    # life of the TUI and restore it in the finally so a scripted caller's console is left unchanged.
    # Guarded so a host that rejects the change never blocks launch.
    $prevOutputEncoding = $null
    try {
        $prevOutputEncoding = [System.Console]::OutputEncoding
        [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    }
    catch { }

    # Hyper-V speed-up PR 4 (D13, A-14, V-2): the TUI session owns asynchronous teardowns (HyperVAsyncTeardown): a test's
    # checkpoint restore may finish in the background while the menu is back, and the finally below waits for it before
    # the TUI returns. The token stays $null when an owner is already running (it then joins, not this one).
    $w32tOwner = $null; if (-not (Get-Win32ToolkitAsyncTeardownOwner)) { $w32tOwner = [guid]::NewGuid(); $script:W32TAsyncTeardownOwner = @{ Token = $w32tOwner; Command = 'Show-Win32Toolkit' } }
    try {
        # ── Resolve the base folder (first-run setup via the UI if unset) ──────────
        $base = Get-Win32ToolkitBasePath -BasePath $BasePath -NonInteractive
        Clear-Host
        Write-SpectreFigletText -Text 'win32-toolkit' -Color Blue
        if (-not $base) {
            # First-run saves the chosen folder to the registry; re-read it instead of capturing the
            # screen's output (TUI screens render THROUGH their success stream — see 'settings' below).
            Show-Win32ToolkitFirstRun
            $base = Get-Win32ToolkitBasePath -NonInteractive
        }

        # ── Main loop ──────────────────────────────────────────────────────────────
        while ($true) {
            Clear-Host
            Write-SpectreFigletText -Text 'win32-toolkit' -Color Blue
            $w32tVersion = Get-Win32ToolkitVersion
            if ($w32tVersion) { Write-SpectreHost "[grey]v$w32tVersion[/]" }
            Show-Win32ToolkitHealth -BasePath $base
            Show-Win32ToolkitUpdateNotice

            $choice = Show-Win32ToolkitMainMenu
            # Only the screen dispatch is guarded (TUI audit G7): an error a screen did not handle (an unreadable
            # AppConfig.json, a failing helper) shows a red panel and the menu comes back, instead of ending the
            # TUI. The header, health check, update notice and the menu stay OUTSIDE the try: an error there fails
            # every pass the same way, so catching it would loop forever with 'exit' unreachable; it ends the TUI
            # as before, through the finally below. W32T.* errors are shown too (the TUI is the display sink,
            # Dv8). Ctrl+C (a pipeline stop) is not caught and still ends the TUI.
            try {
                switch ($choice) {
                    'winget'    { Invoke-Win32ToolkitWingetWizard -BasePath $base }
                    'manual'    { Invoke-Win32ToolkitManualWizard -BasePath $base }
                    'project'   { Show-Win32ToolkitProjectActions -BasePath $base }
                    'browse'    { Show-Win32ToolkitBrowse   -BasePath $base }
                    'templates' { Show-Win32ToolkitTemplates -BasePath $base }
                    'intune'    { Show-Win32ToolkitIntuneConnection -BasePath $base }
                    'settings'  {
                        # NEVER capture a TUI screen's output (issue #67): PwshSpectreConsole 2.6.x render
                        # commands RETURN their rendered ANSI text — it only displays when the stream
                        # reaches Out-Default — so capturing a screen both blanks its rendering and turns
                        # the captured "value" into an array (the next Show-Win32ToolkitHealth -BasePath
                        # then failed to bind [string]). Settings persists a base-folder change to the
                        # registry; adopt it by re-reading, so an unchanged registry keeps a session
                        # -BasePath override intact.
                        $before = Get-Win32ToolkitBasePath -NonInteractive
                        Show-Win32ToolkitSettings -BasePath $base
                        $after = Get-Win32ToolkitBasePath -NonInteractive
                        if ($after -and $after -ne $before) { $base = $after }
                    }
                    'exit'      { Write-SpectreHost '[grey]Goodbye.[/]'; return }
                    default     { return }
                }
            }
            catch { Show-Win32ToolkitScreenError -ErrorRecord $_ }
        }
    }
    finally {
        $ProgressPreference = $prevProgress
        if ($prevOutputEncoding) { try { [System.Console]::OutputEncoding = $prevOutputEncoding } catch { } }
        $null = Wait-Win32ToolkitHyperVTeardown -ReleaseOwner $w32tOwner
    }
}
