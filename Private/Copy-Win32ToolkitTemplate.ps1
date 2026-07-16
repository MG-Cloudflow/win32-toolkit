function Copy-Win32ToolkitTemplate {
    <#
    .SYNOPSIS
        Duplicates an org template: clones its .json AND its sidecar asset folder under a new name (F3).

    .DESCRIPTION
        Once templates own a Templates\<name>\ folder (hooks / extension module / branding assets), the
        name→folder link is load-bearing, so a duplicate must copy the whole folder — not just the JSON.
        The clone's TemplateName is updated to the new name and its PSADT version re-stamped is left as-is
        (it still targets the same PSADT). Fails (throws) on a blank name or a name collision.

    .OUTPUTS
        [string] path to the new template .json.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SourceName,
        [Parameter(Mandatory)][string]$NewName,
        [Parameter(Mandatory)][string]$BasePath
    )

    $NewName = $NewName.Trim()
    if ([string]::IsNullOrWhiteSpace($NewName)) { throw 'The new template name cannot be empty.' }
    if ($NewName -match '[<>:"/\\|?*]') { throw "The template name '$NewName' contains characters that are not allowed in a file name." }
    # '.'/'..' pass the char guard but resolve outside Templates (Join-Path templatesDir '..' = BasePath),
    # scattering the sidecar folder into the base — reject the relative segments explicitly.
    if ($NewName -in @('.', '..')) { throw "The template name '$NewName' is not allowed." }

    $templatesDir = (Get-Win32ToolkitPaths -BasePath $BasePath).Templates
    $srcJson = Join-Path $templatesDir "$SourceName.json"
    $dstJson = Join-Path $templatesDir "$NewName.json"
    if (-not (Test-Path -LiteralPath $srcJson)) { throw "Source template '$SourceName' not found ($srcJson)." }
    if (Test-Path -LiteralPath $dstJson) { throw "A template named '$NewName' already exists." }

    if (-not $PSCmdlet.ShouldProcess($NewName, "Duplicate template '$SourceName'")) { return $null }

    # Clone + rename the JSON.
    $obj = Get-Content -LiteralPath $srcJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $obj.TemplateName = $NewName
    $obj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $dstJson -Encoding UTF8

    # Clone the sidecar asset folder wholesale, if present.
    $srcFolder = Join-Path $templatesDir $SourceName
    $dstFolder = Join-Path $templatesDir $NewName
    if (Test-Path -LiteralPath $srcFolder) {
        Copy-Item -LiteralPath $srcFolder -Destination $dstFolder -Recurse -Force
    }

    return $dstJson
}
