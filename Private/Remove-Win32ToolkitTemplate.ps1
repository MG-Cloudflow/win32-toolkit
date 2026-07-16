function Remove-Win32ToolkitTemplate {
    <#
    .SYNOPSIS
        Deletes an org template — its .json AND its sidecar asset folder — after an in-use check (F3).

    .DESCRIPTION
        Removes Templates\<name>.json and the Templates\<name>\ folder (hooks / module / assets). It
        NEVER touches the output tiers (Projects/Staging/IntuneWin) — only the template definition. When
        the template's segment still holds projects the caller must pass -Force to proceed (the TUI
        surfaces the in-use list and asks for confirmation first).

    .OUTPUTS
        [pscustomobject] Removed (bool), InUse (string[] of tier folders), Message.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BasePath,
        [switch]$Force
    )

    $templatesDir = (Get-Win32ToolkitPaths -BasePath $BasePath).Templates
    $json   = Join-Path $templatesDir "$Name.json"
    $folder = Join-Path $templatesDir $Name

    if (-not (Test-Path -LiteralPath $json)) {
        return [pscustomobject]@{ Removed = $false; InUse = @(); Message = "Template '$Name' not found." }
    }

    $inUse = @(Get-Win32ToolkitTemplateUsage -Name $Name -BasePath $BasePath)
    if ($inUse.Count -gt 0 -and -not $Force) {
        return [pscustomobject]@{ Removed = $false; InUse = $inUse; Message = "Template '$Name' is in use by $($inUse.Count) output folder(s); re-run with -Force to delete the template anyway (the projects are left untouched)." }
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Delete org template (definition + assets only)')) {
        return [pscustomobject]@{ Removed = $false; InUse = $inUse; Message = 'Cancelled.' }
    }

    Remove-Item -LiteralPath $json -Force
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }

    return [pscustomobject]@{ Removed = $true; InUse = $inUse; Message = "Template '$Name' deleted." }
}
