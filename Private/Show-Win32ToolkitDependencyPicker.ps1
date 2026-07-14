function Show-Win32ToolkitDependencyPicker {
    <#
    .SYNOPSIS
        Spectre picker for declaring app dependencies — choose from winget or an already-packaged project.
    .DESCRIPTION
        Returns the chosen dependencies as reference STRINGS ('winget:<id>' / 'project:<Template>\<Name>'),
        ready to hand to Set-Win32ToolkitAppDependency or -DependsOn. Purely a chooser: it declares nothing
        and installs nothing.

        Used by the packaging wizards ("does this app need something installed first?" — e.g. a Visual C++
        redistributable) and by the project-actions dependency editor.
    .PARAMETER BasePath
        Base folder, used to list already-packaged projects.
    .PARAMETER Existing
        References already declared, shown so the operator can see what is set and does not re-add it.
    .OUTPUTS
        [string[]] the FULL dependency reference list (existing + newly chosen). Empty array if none.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$BasePath,
        [string[]]$Existing = @()
    )

    $refs = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($Existing)) { if ($e) { $refs.Add([string]$e) } }

    while ($true) {
        Write-SpectreHost ''
        if ($refs.Count -gt 0) {
            Write-SpectreHost "[grey]Dependencies (installed BEFORE this app):[/] $(Get-SpectreEscapedText -Text ($refs -join ', '))"
        }
        else {
            Write-SpectreHost '[grey]No dependencies declared — this app installs on its own.[/]'
        }

        $choices = @(
            [pscustomobject]@{ Key = 'winget';  Label = 'Add a dependency from winget (e.g. the VC++ redistributable)' }
            [pscustomobject]@{ Key = 'project'; Label = 'Add a dependency from an already-packaged project' }
        )
        if ($refs.Count -gt 0) { $choices += [pscustomobject]@{ Key = 'remove'; Label = 'Remove a dependency' } }
        $choices += [pscustomobject]@{ Key = 'done'; Label = 'Done' }

        $sel = Read-SpectreSelection -Message 'Dependencies' -Choices $choices -ChoiceLabelProperty 'Label' -Color Blue

        switch ($sel.Key) {
            'winget' {
                $term = Read-SpectreText -Message 'Search winget for the dependency (blank to cancel)' -DefaultAnswer ''
                if ([string]::IsNullOrWhiteSpace($term)) { break }
                $hits = @(Search-WingetApps -SearchTerm $term)
                if ($hits.Count -eq 0) {
                    Write-SpectreHost "[yellow]No winget results for[/] $(Get-SpectreEscapedText -Text $term)."
                    break
                }
                $pick = Read-SpectreSelection -Message 'Which package?' -Choices @(
                    $hits | ForEach-Object { [pscustomobject]@{ Key = $_.Id; Label = "$($_.Name)  [grey]($($_.Id))[/]" } }
                ) -ChoiceLabelProperty 'Label' -Color Blue -PageSize 12
                # Store the winget ID VERBATIM — ids legitimately contain '.' and '+'.
                $ref = "winget:$($pick.Key)"
                if ($refs -notcontains $ref) { $refs.Add($ref) }
            }
            'project' {
                $projects = @(Get-PSADTProjects -BasePath $BasePath)
                if ($projects.Count -eq 0) {
                    Write-SpectreHost '[yellow]No packaged projects found yet — package the dependency first, or pick it from winget.[/]'
                    break
                }
                $pick = Read-SpectreSelection -Message 'Which packaged project?' -Choices @(
                    $projects | ForEach-Object { [pscustomobject]@{ Key = "$($_.Template)\$($_.Name)"; Label = "$($_.Name)  [grey]($($_.Template))[/]" } }
                ) -ChoiceLabelProperty 'Label' -Color Blue -PageSize 12
                $ref = "project:$($pick.Key)"
                if ($refs -notcontains $ref) { $refs.Add($ref) }
            }
            'remove' {
                $pick = Read-SpectreSelection -Message 'Remove which dependency?' -Choices @(
                    $refs | ForEach-Object { [pscustomobject]@{ Key = $_; Label = $_ } }
                ) -ChoiceLabelProperty 'Label' -Color Blue
                [void]$refs.Remove($pick.Key)
            }
            'done' { return @($refs) }
        }
    }
}
