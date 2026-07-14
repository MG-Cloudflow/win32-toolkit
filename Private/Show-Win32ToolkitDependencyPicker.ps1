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
            [pscustomobject]@{ Key = 'intune';  Label = 'Pick an app already published in Intune (you will sign in)' }
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
            'intune' {
                # Live tenant list. Stored as 'intune:<guid>' — an app id needs no resolution at publish
                # time. NOTE: an intune: dependency cannot be STAGED into the test guest (the toolkit has
                # no package for it), so the test run will not install it — the picker says so.
                try {
                    Write-SpectreHost '[grey]Signing in to Intune to list published Win32 apps...[/]'
                    Connect-Win32ToolkitGraph
                    $apps = @(Find-Win32ToolkitIntuneApp -All)
                }
                catch {
                    Write-SpectreHost "[red]Could not list Intune apps: $(Get-SpectreEscapedText -Text $_.Exception.Message)[/]"
                    break
                }
                if ($apps.Count -eq 0) { Write-SpectreHost '[yellow]No Win32 apps found in the tenant.[/]'; break }

                # NOTE: displayVersion is NOT selectable here — /mobileApps is a collection of the BASE type
                # microsoft.graph.mobileApp, which has no such property (isof() filters, it does not cast).
                # So the label shows the publisher instead.
                $pick = Read-SpectreSelection -Message 'Which published app?' -Choices @(
                    $apps | ForEach-Object { [pscustomobject]@{ Key = $_.Id; Label = "$($_.DisplayName)  [grey]$($_.Publisher)[/]" } }
                ) -ChoiceLabelProperty 'Label' -Color Blue -PageSize 12
                $ref = "intune:$($pick.Key)"
                if ($refs -notcontains $ref) { $refs.Add($ref) }
                Write-SpectreHost '[yellow]Note:[/] an Intune-picked app cannot be installed in the test/capture guest (no local package), so the test run will not have it. Use winget/project if you need it during testing.'
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
