function Search-WingetApps {
    <#
    .SYNOPSIS
        Runs `winget search` and returns {Name, Id, Version, Source} rows parsed from its table.
    .DESCRIPTION
        The console-scraping itself is isolated in ConvertFrom-WingetTable (header-offset column
        slicing, locale-independent) — this function only shells out and hands the text over. The
        old inline parser split on 2+ spaces and silently dropped any row whose cells were the
        widest in their columns (ALWAYS true for a single-row exact-Id search), which surfaced as
        "Selected: <Id> vUnknown" and *_Unknown project names.
    .PARAMETER SearchTerm
        Passed to winget as an argument (never spliced into a command line).
    .OUTPUTS
        [pscustomobject] { Name; Id; Version; Source } per result row (possibly none).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$SearchTerm)

    Write-Verbose "Searching for apps matching: $SearchTerm"

    $searchResults = winget search $SearchTerm --accept-source-agreements | Out-String

    return @(ConvertFrom-WingetTable -Text $searchResults)
}
