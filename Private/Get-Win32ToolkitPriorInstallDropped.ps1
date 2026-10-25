function Get-Win32ToolkitPriorInstallDropped {
    <#
    .SYNOPSIS
        Reads the prior-install rules a project has lost (Documentation\PriorInstallDropped.json).
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.13, L4). A project that is re-created after a test guest changed it (GUEST-TAMPER)
        keeps none of its prior-install rules, and a version carried from such a project gets none of them. So that the
        rules are not lost without notice, Copy-Win32ToolkitPriorInstallState records WHICH rules there were in this
        host file (Add-Win32ToolkitPriorInstallDropped; Documentation\ never ships, L16), and
        Get-Win32ToolkitPriorInstallFinding lists each one as ID-PRIOR-DROPPED until a rule of the same Kind, Key and View is
        declared again or the drop is acknowledged:

          { "SchemaVersion": "1.0", "Entries": [ { "Id", "Kind", "Key", "View", "From" } ] }

        An entry is an identity only, never a rule (no window, no uninstaller, no decision). From names the project the
        rule was lost from. An entry that is not an object, whose Id is not a rule id (^[a-z0-9-]{1,40}$), whose Kind is
        not a word, whose Key is empty, longer than 256 characters or holds a control character, or whose View is longer
        than 16 characters is skipped (it was never a valid rule); one entry per Kind + Key + View (the first); at most
        64 entries.
        A missing file gives nothing. A file that exists but cannot be read (larger than 1 MB, not JSON, no Entries list)
        THROWS (fail-closed: the Export check then reports that the rules could not be checked); a W32T.* error is
        re-thrown as it is.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .OUTPUTS
        [pscustomobject[]] Id, Kind, Key, View, From.
    .EXAMPLE
        $lost = @(Get-Win32ToolkitPriorInstallDropped -ProjectPath $p)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $file = Join-Path $ProjectPath 'Documentation\PriorInstallDropped.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @() }
    $raw = $null
    try {
        if ((Get-Item -LiteralPath $file).Length -gt 1MB) { throw 'the file is larger than 1 MB' }
        $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 6
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        throw [System.IO.InvalidDataException]::new('Documentation\PriorInstallDropped.json cannot be read (' + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200) + ')')
    }
    if ($raw -isnot [System.Management.Automation.PSCustomObject] -or -not $raw.PSObject.Properties['Entries']) {
        throw [System.IO.InvalidDataException]::new('Documentation\PriorInstallDropped.json cannot be read (it has no Entries list)')
    }

    $text = { param($Object, [string]$Name) if ($Object.PSObject.Properties[$Name] -and $Object.$Name -is [string]) { [string]$Object.$Name } else { '' } }
    $out = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($e in @($raw.Entries)) {
        if ($out.Count -ge 64) { Write-Verbose 'Get-Win32ToolkitPriorInstallDropped: more than 64 entries - the rest is not read.'; break }
        if ($e -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $id = & $text $e 'Id'; $kind = & $text $e 'Kind'; $key = & $text $e 'Key'; $view = & $text $e 'View'
        if ($id -cnotmatch '^[a-z0-9-]{1,40}$' -or $kind -cnotmatch '^[A-Za-z]{1,32}$' -or -not $key -or $key.Length -gt 256 -or $key -match '[\x00-\x1f\x7f]' -or $view.Length -gt 16 -or $view -match '[\x00-\x1f\x7f]') {
            Write-Verbose "Get-Win32ToolkitPriorInstallDropped: an entry that is not a rule identity is skipped ('$(ConvertTo-Win32ToolkitSafeText -Text $id -MaxLength 40)')."
            continue
        }
        if (-not $seen.Add("$kind|$($key.ToUpperInvariant())|$view")) { continue }
        $out.Add([pscustomobject]@{ Id = $id; Kind = $kind; Key = $key; View = $view; From = (ConvertTo-Win32ToolkitSafeText -Text (& $text $e 'From') -MaxLength 128) })
    }
    return @($out.ToArray())
}
