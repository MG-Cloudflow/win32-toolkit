function Get-PSADTProjects {
    <#
    .SYNOPSIS
        Enumerates PSADT projects under Projects\<Template>\<Project>.
    .DESCRIPTION
        Scans the template-grouped Projects tier and returns one object per project folder that
        contains an Invoke-AppDeployToolkit.ps1, capturing the owning template name. See
        knowledge-base/01-architecture.md.
    .PARAMETER BasePath
        Base folder containing the Projects tier.
    .OUTPUTS
        PSCustomObject[] with properties: Template, Name, Path, ScriptPath.
    #>
    [CmdletBinding()]
    param([string]$BasePath)

    $paths    = Get-Win32ToolkitPaths -BasePath $BasePath
    $scanPath = $paths.Projects

    # Ensure the Projects tier exists so the scan never throws on a fresh install
    if (-not (Test-Path $scanPath)) {
        New-Item -Path $scanPath -ItemType Directory -Force | Out-Null
    }

    $projects = @()
    foreach ($templateFolder in Get-ChildItem -Path $scanPath -Directory) {
        foreach ($folder in Get-ChildItem -Path $templateFolder.FullName -Directory) {
            $psadtScript = Join-Path $folder.FullName 'Invoke-AppDeployToolkit.ps1'
            if (Test-Path $psadtScript) {
                $projects += [PSCustomObject]@{
                    Template   = $templateFolder.Name
                    Name       = $folder.Name
                    Path       = $folder.FullName
                    ScriptPath = $psadtScript
                }
            }
        }
    }

    return $projects
}
