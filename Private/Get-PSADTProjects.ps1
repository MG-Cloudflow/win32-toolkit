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
        PSCustomObject[] with properties: Template, Name, Path, ScriptPath, NotConfigured (Documentation\NotConfigured.json
        exists: the project's build stopped after its folder was created; Export and Publish refuse it).
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
                    # TUI audit G4: a half-built project (its build stopped after the folder was created).
                    NotConfigured = (Test-Path -LiteralPath (Join-Path $folder.FullName 'Documentation\NotConfigured.json'))
                }
            }
        }
    }

    return $projects
}
