function ConvertFrom-Win32ToolkitDisplayIcon {
    <#
    .SYNOPSIS
        Parses an Add/Remove-Programs 'DisplayIcon' value into a resolved path + resource index.
    .DESCRIPTION
        The ARP DisplayIcon registry value points at the file that holds the app's icon. It comes in a
        few shapes:

            "C:\Program Files\App\app.exe",0     quoted path, explicit resource index
            C:\Program Files\App\app.exe,-3      unquoted path, negative index (a resource ID)
            C:\App\app.ico                       bare path, no index (defaults to 0)
            %SystemRoot%\system32\x.dll,12       environment variables to expand

        Returns [pscustomobject]@{ Path; Index } with environment variables expanded, or $null when the
        value is empty. A NEGATIVE index is preserved verbatim (PrivateExtractIcons / ExtractIconEx treat
        |index| as a resource ID in that case) — never clamp it to 0.

        NOTE: the guest capture script (New-TargetedDocumentation) inlines a byte-for-byte mirror of this
        logic as `ConvertFrom-DisplayIcon` so it can run under Windows PowerShell 5.1 with no module. Keep
        the two in sync; this host copy is the one covered by Tests\IconFromInstall.unit.ps1.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Value
    )

    if (-not $Value) { return $null }
    $v = $Value.Trim()
    if (-not $v) { return $null }

    $idx = 0
    if ($v.StartsWith('"')) {
        # Quoted path: take everything up to the closing quote, then an optional ,<index> after it.
        $end = $v.IndexOf('"', 1)
        if ($end -lt 0) { return $null }
        $p    = $v.Substring(1, $end - 1)
        $rest = $v.Substring($end + 1).Trim()
        if ($rest -match '^,\s*(-?\d+)') { $idx = [int]$matches[1] }
    }
    else {
        # Unquoted: a trailing ,<index> (last one wins) is the resource index; the rest is the path.
        if ($v -match '^(.*),\s*(-?\d+)\s*$') { $p = $matches[1].Trim(); $idx = [int]$matches[2] }
        else { $p = $v }
    }

    if (-not $p) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($p)

    [pscustomobject]@{ Path = $p; Index = $idx }
}
