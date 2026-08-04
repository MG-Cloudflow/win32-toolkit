function Resolve-Win32ToolkitWingetId {
    <#
    .SYNOPSIS
        Resolves a winget package Id to its Name and Version, locale-independently.
    .DESCRIPTION
        Existence is decided by winget's EXIT CODE, never by scraping the console verb "Found". winget
        TRANSLATES its verbs and field labels on non-English PowerShell (German prints "Gefunden",
        "Version:" may differ, etc.). The old check did `winget show ... -notmatch 'Found'`, which was
        true on every localized system, so packaging failed for every package with "Package ID not
        found in winget" even though winget had found it (issue #60).

        The Name and Version instead come from the winget search TABLE, which Search-WingetApps parses
        by column position and is therefore locale-independent (the same parser the interactive search
        already uses successfully on non-English systems).
    .PARAMETER Id
        The exact winget PackageIdentifier (e.g. 'Postman.Postman'). Passed to winget as an argument,
        never spliced into a command line.
    .OUTPUTS
        PSCustomObject { Name; Id; Version; Source } when the Id exists in winget, otherwise $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id
    )

    # Existence via exit code (locale-independent). The output text is localized and unused, so discard
    # it. winget returns non-zero (APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND) when the Id is unknown.
    winget show --id "$Id" --exact --accept-source-agreements *> $null
    if ($LASTEXITCODE -ne 0) { return $null }

    # Name + Version from the column-parsed search table (locale-independent). Filter to the exact Id so
    # a fuzzy search hit for a different package cannot win.
    $hit = @(Search-WingetApps -SearchTerm $Id | Where-Object { $_.Id -ieq $Id }) | Select-Object -First 1

    [PSCustomObject]@{
        Name    = if ($hit -and $hit.Name)    { $hit.Name }    else { $Id }
        Id      = $Id
        Version = if ($hit -and $hit.Version) { $hit.Version } else { 'Unknown' }
        Source  = 'winget'
    }
}
