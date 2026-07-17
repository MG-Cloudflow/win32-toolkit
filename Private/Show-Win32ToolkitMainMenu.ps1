function Show-Win32ToolkitMainMenu {
    <#
    .SYNOPSIS
        Renders the main menu and returns the chosen action key. See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $choices = @(
        [pscustomobject]@{ Key = 'winget';    Label = 'Package an app from winget (search)' }
        [pscustomobject]@{ Key = 'manual';    Label = 'Package a manual app (not in winget)' }
        [pscustomobject]@{ Key = 'project';   Label = 'Work with an existing project (test / package / publish)' }
        [pscustomobject]@{ Key = 'browse';    Label = 'Browse projects' }
        [pscustomobject]@{ Key = 'templates'; Label = 'Org templates' }
        [pscustomobject]@{ Key = 'intune';    Label = 'Microsoft Intune connection (connect / sign out)' }
        [pscustomobject]@{ Key = 'settings';  Label = 'Settings' }
        [pscustomobject]@{ Key = 'exit';      Label = 'Exit' }
    )
    $sel = Read-SpectreSelection -Message 'What would you like to do?' -Choices $choices -ChoiceLabelProperty 'Label' -Color Blue -PageSize 10
    return $sel.Key
}
