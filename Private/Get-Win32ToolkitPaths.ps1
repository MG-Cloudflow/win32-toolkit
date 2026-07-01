function Get-Win32ToolkitPaths {
<#
.SYNOPSIS
    Returns the three canonical tier paths used by win32-toolkit under a given BasePath.
.DESCRIPTION
    Centralises the folder-name conventions so every function in the module
    refers to the same paths without hard-coding tier names.

    Tier layout (projects/staging/output are grouped by org template):
        <BasePath>\
          Templates\   org template JSON files
          Projects\    <Template>\<Project>  — raw PSADT projects, never modified after creation
          Staging\     <Template>\<Project>  — cleaned copies used during .intunewin packaging
          IntuneWin\   <Template>\<Project>.intunewin  — finished output files

    The function does NOT create the folders — callers are responsible for
    ensuring a tier exists before writing to it.
.PARAMETER BasePath
    The root directory that contains (or will contain) the tiers.
.OUTPUTS
    PSCustomObject with properties: BasePath, Templates, Projects, Staging, IntuneWin.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    [PSCustomObject]@{
        BasePath  = $BasePath
        Templates = Join-Path $BasePath 'Templates'
        Projects  = Join-Path $BasePath 'Projects'
        Staging   = Join-Path $BasePath 'Staging'
        IntuneWin = Join-Path $BasePath 'IntuneWin'
    }
}
