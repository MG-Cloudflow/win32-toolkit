function Initialize-Win32ToolkitRunResult {
    <#
    .SYNOPSIS
        Creates the mutable collector behind a Win32Toolkit.RunResult (TUI audit G2, S8-F3).
    .DESCRIPTION
        Invoke-Win32Toolkit, New-Win32ToolkitManualApp and Complete-Win32ToolkitManualApp create one collector
        at the start of their run; Invoke-Win32ToolkitFinalize fills in the capture, the test verdicts, the
        .intunewin path, the published apps and the problems; Complete-Win32ToolkitRunResult turns it into
        the Win32Toolkit.RunResult the command returns. Pure: no I/O.
    .PARAMETER Command
        The public command the result belongs to (Invoke-Win32Toolkit, New-Win32ToolkitManualApp or
        Complete-Win32ToolkitManualApp).
    .PARAMETER Mode
        Winget (Invoke-Win32Toolkit), Easy or Advanced (New-Win32ToolkitManualApp, set once known), Finalize
        (Complete-Win32ToolkitManualApp); empty until known.
    .OUTPUTS
        [pscustomobject] with Command, ProjectPath, ProjectName, Mode, Status ('Running'), Capture ('NotRun'),
        Tests and Published (List[object]), IntuneWinPath and Problems (List[string]).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$Mode = ''
    )

    [pscustomobject][ordered]@{
        Command       = $Command
        ProjectPath   = ''
        ProjectName   = ''
        Mode          = $Mode
        Status        = 'Running'
        Capture       = 'NotRun'
        Tests         = [System.Collections.Generic.List[object]]::new()
        IntuneWinPath = ''
        Published     = [System.Collections.Generic.List[object]]::new()
        Problems      = [System.Collections.Generic.List[string]]::new()
    }
}
