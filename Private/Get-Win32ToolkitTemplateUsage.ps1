function Get-Win32ToolkitTemplateUsage {
    <#
    .SYNOPSIS
        Returns the output-tier folders that reference a template's segment (Projects/Staging/IntuneWin).

    .DESCRIPTION
        Tiers are grouped per template: <tier>\<TemplateSegment>\..., where TemplateSegment =
        Sanitize-ProjectName(templateName). Deleting a template whose segment still holds projects would
        orphan them, so F3's delete checks this first. Returns the existing, NON-EMPTY tier folders for
        the segment (empty array when the template is unused).

    .OUTPUTS
        [string[]] full paths of in-use tier folders (Projects/Staging/IntuneWin under the segment).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BasePath
    )

    # Mirror the tier writers' empty→'Default' fallback (Invoke-Win32Toolkit / New-Win32ToolkitManualApp):
    # a template whose name sanitizes to '' still lands its projects under <tier>\Default, so the usage
    # check must look there too or an in-use delete would give no warning.
    $segment = Sanitize-ProjectName -Name $Name
    if ([string]::IsNullOrWhiteSpace($segment)) { $segment = 'Default' }

    $paths = Get-Win32ToolkitPaths -BasePath $BasePath
    $inUse = [System.Collections.Generic.List[string]]::new()
    foreach ($tier in @($paths.Projects, $paths.Staging, $paths.IntuneWin)) {
        $seg = Join-Path $tier $segment
        if (Test-Path -LiteralPath $seg) {
            $hasChild = @(Get-ChildItem -LiteralPath $seg -Force -ErrorAction SilentlyContinue).Count -gt 0
            if ($hasChild) { $inUse.Add($seg) }
        }
    }
    return $inUse.ToArray()
}
