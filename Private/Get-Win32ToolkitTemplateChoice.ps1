function Get-Win32ToolkitTemplateChoice {
    <#
    .SYNOPSIS
        Prompts (Spectre) for an org template under BasePath\Templates, or creates a new one.
        Returns the chosen template name, or $null if cancelled. See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$BasePath)

    $templatesDir = (Get-Win32ToolkitPaths -BasePath $BasePath).Templates
    $files = if (Test-Path $templatesDir) { @(Get-ChildItem $templatesDir -Filter *.json -ErrorAction SilentlyContinue) } else { @() }

    $choices = foreach ($f in $files) {
        $name = try { (Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).TemplateName } catch { $f.BaseName }
        if (-not $name) { $name = $f.BaseName }
        [pscustomobject]@{ Key = $name; Label = $name }
    }
    $choices = @($choices)
    $choices += [pscustomobject]@{ Key = '__new__'; Label = '[ Create a new template… ]' }

    $sel = Read-SpectreSelection -Message 'Choose an org template (client)' -Choices $choices -ChoiceLabelProperty 'Label' -Color Blue -PageSize 12
    if ($sel.Key -eq '__new__') {
        Write-SpectreHost '[grey]Launching the template wizard…[/]'
        $tpl = New-OrgTemplate -BasePath $BasePath
        return $tpl.TemplateName
    }
    return $sel.Key
}
