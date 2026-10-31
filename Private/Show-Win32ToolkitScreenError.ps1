function Show-Win32ToolkitScreenError {
    <#
    .SYNOPSIS
        Shows an error that ended a TUI screen in a red panel, then waits for a key (TUI audit G7).
    .DESCRIPTION
        The main menu (Show-Win32Toolkit) guards its screen dispatch with a catch that calls this, so an
        error a screen did not handle (an unreadable AppConfig.json, a failing helper, a W32T.* error: the TUI
        is the display sink, Dv8) no longer ends the TUI: the operator reads the error and is back in the menu.

        Red panel 'Something went wrong': the error message, then (when it carries one that is not just the
        message again) 'Error id: <FullyQualifiedErrorId>' in grey, then 'You are back in the menu: fix the
        cause and try again.' Message and id are escaped (Spectre markup). One pause.

        Renders through its success stream and returns nothing (designs/tui.md 7a): call it as a bare
        statement, never capture it.
    .PARAMETER ErrorRecord
        The error that ended the screen ($_ in the caller's catch).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = if ($ErrorRecord.Exception) { [string]$ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    # Get-SpectreEscapedText refuses an empty string: an error without a message must not end the TUI from here.
    $shown = if ([string]::IsNullOrWhiteSpace($message)) { 'The screen stopped on an error that carries no message.' } else { $message }
    $data = "[red]$(Get-SpectreEscapedText -Text $shown)[/]"
    # A plain 'throw "text"' carries the message itself as its FullyQualifiedErrorId: no id to show then.
    $errorId = [string]$ErrorRecord.FullyQualifiedErrorId
    if (-not [string]::IsNullOrWhiteSpace($errorId) -and $errorId -cne $message) {
        $data += "`n[grey]Error id: $(Get-SpectreEscapedText -Text $errorId)[/]"
    }
    $data += "`n`nYou are back in the menu: fix the cause and try again."
    Format-SpectrePanel -Data $data -Header 'Something went wrong' -Border Rounded -Color Red
    Read-SpectrePause -Message 'Press any key to return to the menu' -AnyKey | Out-Null
}
