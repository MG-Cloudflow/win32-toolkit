function Add-Win32ToolkitPriorInstallDropped {
    <#
    .SYNOPSIS
        Records prior-install rules a project has lost (Documentation\PriorInstallDropped.json).
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.13, L4). The only writer of the host file Get-Win32ToolkitPriorInstallDropped reads
        (the schema and the rules for an entry are there). Copy-Win32ToolkitPriorInstallState calls it when a re-created
        project keeps none of the rules of the version a test guest changed, or carries a version whose rules were lost.
        Each -Entry is reduced to its identity { Id; Kind; Key; View; From }; an entry that is not a rule identity is
        skipped; one entry per Kind + Key + View (the one already in the file wins); at most 64. The file is merged with
        what it already holds and rewritten BOM-less through '<file>.tmp' and Move-Item, entries sorted by Id. Nothing is
        written when nothing is new.
        A file that exists but cannot be read is NOT overwritten: the reader's error is thrown (the Export check reports
        it); a W32T.* error is re-thrown.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Entry
        The rules (or identities) that were lost: objects with Id, Kind, Key, View and optionally From.
    .PARAMETER From
        The project the rules were lost from, for the entries that do not name one.
    .OUTPUTS
        [string[]] the ids recorded by this call (an identity already in the file is not repeated).
    .EXAMPLE
        $null = Add-Win32ToolkitPriorInstallDropped -ProjectPath $p -Entry $snapshot.Lost
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Entry,

        [AllowEmptyString()]
        [string]$From = ''
    )

    $existing = @(Get-Win32ToolkitPriorInstallDropped -ProjectPath $ProjectPath)
    $text = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $Object.$Name -is [string]) { [string]$Object.$Name } else { '' } }
    $all = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($d in $existing) { $null = $seen.Add("$($d.Kind)|$($d.Key.ToUpperInvariant())|$($d.View)"); $all.Add($d) }
    $added = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($Entry)) {
        if ($all.Count -ge 64) { Write-Verbose 'Add-Win32ToolkitPriorInstallDropped: 64 entries recorded - the rest is not.'; break }
        if ($e -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $id = & $text $e 'Id'; $kind = & $text $e 'Kind'; $key = & $text $e 'Key'; $view = & $text $e 'View'
        if ($id -cnotmatch '^[a-z0-9-]{1,40}$' -or $kind -cnotmatch '^[A-Za-z]{1,32}$' -or -not $key -or $key.Length -gt 256 -or $key -match '[\x00-\x1f\x7f]' -or $view.Length -gt 16 -or $view -match '[\x00-\x1f\x7f]') { continue }
        if (-not $seen.Add("$kind|$($key.ToUpperInvariant())|$view")) { continue }
        $src = & $text $e 'From'
        if (-not $src) { $src = $From }
        $all.Add([pscustomobject]@{ Id = $id; Kind = $kind; Key = $key; View = $view; From = (ConvertTo-Win32ToolkitSafeText -Text $src -MaxLength 128) })
        $added.Add($id)
    }
    if ($added.Count -eq 0) { return [string[]]@() }

    $ids = [string[]]@($all | ForEach-Object { $_.Id })
    $order = [int[]]@(0..($all.Count - 1))
    if ($all.Count -gt 1) { [Array]::Sort($ids, $order, [System.StringComparer]::Ordinal) }
    $doc = [ordered]@{ SchemaVersion = '1.0'; Entries = @($order | ForEach-Object { $d = $all[$_]; [ordered]@{ Id = $d.Id; Kind = $d.Kind; Key = $d.Key; View = $d.View; From = $d.From } }) }
    $docDir = Join-Path $ProjectPath 'Documentation'
    $file = Join-Path $docDir 'PriorInstallDropped.json'
    if (-not $PSCmdlet.ShouldProcess($file, 'Record the prior-install rules that were not kept')) { return [string[]]@() }
    if (-not (Test-Path -LiteralPath $docDir)) { $null = New-Item -ItemType Directory -Path $docDir -Force }
    $tmp = "$file.tmp"
    [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $doc -Depth 4), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $file -Force
    return [string[]]$added.ToArray()
}
