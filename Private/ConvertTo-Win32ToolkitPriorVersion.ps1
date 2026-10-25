function ConvertTo-Win32ToolkitPriorVersion {
    <#
    .SYNOPSIS
        Parses a version text exactly as the remove-prior device code does (padded to four parts).
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.6 text A). The host must read a prior install's version the way the device
        does, so this helper RUNS the device parser itself: it evaluates the catalog text 'PriorPredicate' (which
        only defines scriptblocks and two tables; it reads nothing) and calls its $w32tPrToVersion. 8.9 -> 8.9.0.0,
        26.02 -> 26.2.0.0, 'v3.0.17.4' -> 3.0.17.4, '8.9-beta' -> 8.9.0.0; a part longer than 9 digits, a fifth part
        or a text without a leading number -> $null.
    .PARAMETER Text
        The version text ('' or $null -> $null).
    .OUTPUTS
        [version] or $null.
    .EXAMPLE
        ConvertTo-Win32ToolkitPriorVersion -Text '8.9.8.1'
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $predicate = [scriptblock]::Create((Get-Win32ToolkitDeployScriptBlock -Name PriorPredicate))
    $parser = & { . $predicate; $w32tPrToVersion }
    return (& $parser $Text)
}
