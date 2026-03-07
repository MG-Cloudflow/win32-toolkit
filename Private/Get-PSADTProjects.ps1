function Get-PSADTProjects {
    param([string]$BasePath)

    $paths      = Get-Win32ToolkitPaths -BasePath $BasePath
    $scanPath   = $paths.Projects

    # Ensure the Projects tier exists so the scan never throws on a fresh install
    if (-not (Test-Path $scanPath)) {
        New-Item -Path $scanPath -ItemType Directory -Force | Out-Null
    }

    $projects = @()
    $projectFolders = Get-ChildItem -Path $scanPath -Directory

    foreach ($folder in $projectFolders) {
        $psadtScript = Join-Path $folder.FullName 'Invoke-AppDeployToolkit.ps1'
        if (Test-Path $psadtScript) {
            $projects += [PSCustomObject]@{
                Name       = $folder.Name
                Path       = $folder.FullName
                ScriptPath = $psadtScript
            }
        }
    }

    return $projects
}
