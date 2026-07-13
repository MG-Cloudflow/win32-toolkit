function Show-Win32ToolkitSettings {
    <#
    .SYNOPSIS
        Settings screen (base folder, re-check). Returns the (possibly updated) base folder.
        See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$BasePath)

    while ($true) {
        Write-SpectreRule -Title 'Settings' -Color Grey
        Write-SpectreHost "Base folder: [blue]$(Get-SpectreEscapedText -Text $BasePath)[/]"
        $choices = @(
            [pscustomobject]@{ Key = 'basepath'; Label = 'Change the base folder' }
            [pscustomobject]@{ Key = 'testvm';   Label = 'Hyper-V test VM (backend / provision / reset / remove)' }
            [pscustomobject]@{ Key = 'recheck';  Label = 'Re-run the system check' }
            [pscustomobject]@{ Key = 'back';     Label = 'Back to main menu' }
        )
        $sel = Read-SpectreSelection -Message 'Settings' -Choices $choices -ChoiceLabelProperty 'Label' -Color Blue
        switch ($sel.Key) {
            'basepath' {
                $new = Read-SpectreText -Message 'Enter the base folder for all output' -DefaultAnswer $BasePath
                if (-not [string]::IsNullOrWhiteSpace($new)) {
                    $BasePath = Get-Win32ToolkitBasePath -Set $new
                    Write-SpectreHost "[green]Saved:[/] $(Get-SpectreEscapedText -Text $BasePath)"
                }
            }
            # Out-Null so nothing this subtree emits leaks into $base (the caller captures
            # Show-Win32ToolkitSettings's output). Panels inside render via Out-SpectreHost.
            'testvm'  { Show-Win32ToolkitTestVM | Out-Null }
            'recheck' { Show-Win32ToolkitHealth -BasePath $BasePath }
            'back'    { return $BasePath }
        }
    }
}
