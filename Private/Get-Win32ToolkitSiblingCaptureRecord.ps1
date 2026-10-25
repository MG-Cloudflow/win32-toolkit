function Get-Win32ToolkitSiblingCaptureRecord {
    <#
    .SYNOPSIS
        Returns a project's hash-verified sibling-capture records (Documentation\SiblingCapture\<CaptureId>.json).
    .DESCRIPTION
        Installer-identity PR 3 (L35, SV5, spec 2.14.7). The ONLY reader of capture records; every consumer
        (proposals, the proof gate, the window rule, the carry-forward copy) goes through it. A record is returned
        only when:
          - its file name is '<16 lower-case hex>.json' and the file is at most 8 MB;
          - the first 16 lower-case hex characters of the SHA-256 of the file's bytes equal that name (the
            CaptureId: a record edited after it was written no longer matches and is ignored);
          - it parses as JSON and re-types to the frozen schema (ConvertTo-Win32ToolkitSiblingCaptureRecord).
        Anything else is ignored with one Verbose line. Records are returned in CaptureId order, each as an ordered
        dictionary of the frozen shape plus a 'CaptureId' entry. Never throws (a W32T.* error is re-thrown).
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER CaptureId
        Only these records (16 lower-case hex characters each).
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary[]]
    .EXAMPLE
        $floor = Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $p -CaptureId $entry.CaptureId
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [string[]]$CaptureId
    )

    $dir = Join-Path $ProjectPath 'Documentation\SiblingCapture'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    $want = $null
    if ($PSBoundParameters.ContainsKey('CaptureId')) { $want = @($CaptureId | Where-Object { $_ }) }
    $dateKind = (Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')
    $out = [System.Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Sort-Object -Property Name)
    foreach ($f in $files) {
        try {
            if ($f.Name -cnotmatch '^[a-f0-9]{16}\.json$') { Write-Verbose "Sibling-capture record ignored (not '<16 hex>.json'): $(ConvertTo-Win32ToolkitSafeText -Text $f.Name -MaxLength 80)"; continue }
            $id = $f.Name.Substring(0, 16)
            if ($null -ne $want -and $want -cnotcontains $id) { continue }
            if ($f.Length -gt 8MB) { Write-Verbose "Sibling-capture record $id ignored: larger than 8 MB."; continue }
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $hash = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
            if ($hash.Substring(0, 16) -cne $id) { Write-Verbose "Sibling-capture record $id ignored: its content does not match its name (changed after it was written)."; continue }
            $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes)
            # Keep date-like texts as text where the reader allows it (PowerShell 7.5+); 7.4 is handled by the re-typer.
            $parsed = if ($dateKind) { $text | ConvertFrom-Json -Depth 20 -DateKind String } else { $text | ConvertFrom-Json -Depth 20 }
            $typed = ConvertTo-Win32ToolkitSiblingCaptureRecord -InputObject $parsed
            if ($null -eq $typed) { Write-Verbose "Sibling-capture record $id ignored: it does not have the record shape."; continue }
            $typed['CaptureId'] = $id
            $out.Add($typed)
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose ('Sibling-capture record ignored (unreadable): ' + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200))
        }
    }
    return $out.ToArray()
}
