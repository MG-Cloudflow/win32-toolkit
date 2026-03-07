function Get-PSADTProjects {
    param([string]$BasePath)

    $projects = @()
    $projectFolders = Get-ChildItem -Path $BasePath -Directory

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
