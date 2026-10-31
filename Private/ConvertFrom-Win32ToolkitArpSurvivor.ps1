function ConvertFrom-Win32ToolkitArpSurvivor {
    <#
    .SYNOPSIS
        Parses the old-version ARP entries named by a failed OldArpGone-PostUpdate assertion line.
    .DESCRIPTION
        The Update test's guest script (New-UpdateAssertionScript) writes one line when the old version is
        still registered after the update:

            ASSERT OldArpGone-PostUpdate = FAIL (old version still registered: <name> [<keypath>]; <name> [<keypath>])

        where <keypath> is the registry provider path of the surviving Add/Remove Programs key, e.g.
        Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++.

        This helper turns that line into data on the host (installer-identity PR 1, spec 2.11; no guest change):
          - the provider prefix is dropped; HKEY_LOCAL_MACHINE -> HKLM, HKEY_CURRENT_USER -> HKCU;
          - View = 'Wow6432' when the key contains \WOW6432Node\, 'User' for HKCU, else 'Native';
          - KeyLeaf = the last key segment (the ARP key name, e.g. 'Notepad++');
          - every string passes ConvertTo-Win32ToolkitSafeText (the line comes from the guest: untrusted data);
          - at most 10 entries.
        Any other line (PASS, SKIP, garbage, $null) returns nothing (an empty array under @()). Pure: nothing
        is read or executed.
    .PARAMETER Line
        One line of Sandbox\Logs\UpdateAssertions.log (a leading '[timestamp] ' is allowed).
    .OUTPUTS
        [pscustomobject[]] DisplayName, Key, KeyLeaf, View.
    .EXAMPLE
        ConvertFrom-Win32ToolkitArpSurvivor -Line $failLine | Select-Object -First 1 -ExpandProperty KeyLeaf
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    $head = [regex]::Match($Line, 'ASSERT\s+OldArpGone-PostUpdate\s*=\s*FAIL\s*\(old version still registered:\s*(?<list>.+)$')
    if (-not $head.Success) { return }
    $list = $head.Groups['list'].Value.TrimEnd("`r", "`n", ' ')

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($list, '(?<name>.+?) \[(?<key>[^\]]+)\](?:; |\)?$)')) {
        if ($out.Count -ge 10) { break }
        $name = $m.Groups['name'].Value.Trim()
        $key  = $m.Groups['key'].Value.Trim()
        # Drop the provider prefix ('Microsoft.PowerShell.Core\Registry::'), then shorten the hive.
        $key = $key -replace '^.*?::', ''
        $key = $key -replace '^(?i)HKEY_LOCAL_MACHINE\\', 'HKLM\' -replace '^(?i)HKEY_CURRENT_USER\\', 'HKCU\'
        $key = $key -replace '^(?i)(HKLM|HKCU):\\', '$1\'
        $view = if ($key -match '^(?i)HKCU\\') { 'User' }
                elseif ($key -match '(?i)\\WOW6432Node\\') { 'Wow6432' }
                else { 'Native' }
        $leaf = ($key.TrimEnd('\') -split '\\')[-1]
        $out.Add([pscustomobject]@{
                DisplayName = ConvertTo-Win32ToolkitSafeText -Text $name -MaxLength 256
                Key         = ConvertTo-Win32ToolkitSafeText -Text $key -MaxLength 256
                KeyLeaf     = ConvertTo-Win32ToolkitSafeText -Text $leaf -MaxLength 256
                View        = $view
            })
    }
    return $out.ToArray()
}
