function Test-Win32ToolkitHostNonInteractive {
    <#
    .SYNOPSIS
        $true when no human can interact with this host session (service/CI/redirected stdin).
    .DESCRIPTION
        Interactive test mode blocks on Read-Host pauses — which THROW under pwsh -NonInteractive and
        hang forever on redirected stdin — and shows GUIs no one will see. Get-Win32ToolkitTestMode uses
        this to fall back to Unattended with a loud warning. Extracted as a predicate so tests can shadow
        it (the real probe depends on the host process and cannot be faked from a test).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try { return ((-not [Environment]::UserInteractive) -or [Console]::IsInputRedirected) }
    catch { return $false }
}
