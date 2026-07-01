function Test-Win32ToolkitPrerequisites {
    <#
    .SYNOPSIS
        Returns the status of every win32-toolkit prerequisite (non-interactive).
    .DESCRIPTION
        Checks each dependency WITHOUT prompting and returns one object per check so the TUI health
        screen can render a status table and grey out actions whose prerequisites are missing.
        See knowledge-base/designs/tui.md.
    .PARAMETER BasePath
        Optional explicit base folder; otherwise the registry-stored value is checked.
    .OUTPUTS
        PSCustomObject[] with: Name, Ok (bool), Detail, Fixable (bool), Purpose.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param([string]$BasePath)

    $results = [System.Collections.Generic.List[object]]::new()
    function Add-Check($Name, $Ok, $Detail, $Fixable, $Purpose) {
        $results.Add([pscustomobject]@{ Name = $Name; Ok = [bool]$Ok; Detail = "$Detail"; Fixable = [bool]$Fixable; Purpose = $Purpose })
    }

    # PowerShell 7.2+
    $psOk = $PSVersionTable.PSVersion -ge [version]'7.2'
    Add-Check 'PowerShell 7.2+' $psOk $PSVersionTable.PSVersion $false 'core'

    # Rich UI component
    $spectre = Get-Module -ListAvailable PwshSpectreConsole | Sort-Object Version -Descending | Select-Object -First 1
    Add-Check 'PwshSpectreConsole (UI)' ([bool]$spectre) ($(if ($spectre) { "v$($spectre.Version)" } else { 'not installed' })) $true 'the text UI'

    # Base folder configured (registry) — never prompts here
    $bp = Get-Win32ToolkitBasePath -BasePath $BasePath -NonInteractive
    Add-Check 'Base folder configured' ([bool]$bp) ($(if ($bp) { $bp } else { 'not set' })) $true 'core'

    # winget
    $winget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    Add-Check 'winget' $winget ($(if ($winget) { 'available' } else { 'not on PATH' })) $false 'packaging from winget'

    # PSAppDeployToolkit v4
    $psadt   = Get-Module -ListAvailable PSAppDeployToolkit | Sort-Object Version -Descending | Select-Object -First 1
    $psadtOk = $psadt -and $psadt.Version.Major -ge 4
    Add-Check 'PSAppDeployToolkit v4' $psadtOk ($(if ($psadt) { "v$($psadt.Version)" } else { 'not installed' })) $true 'packaging'

    # Windows Sandbox feature
    $sandbox = Test-Path (Join-Path $env:WinDir 'System32\WindowsSandbox.exe')
    Add-Check 'Windows Sandbox' $sandbox ($(if ($sandbox) { 'available' } else { 'feature not enabled' })) $false 'testing & documentation'

    # Microsoft Graph (publish only)
    $graph = Get-Module -ListAvailable Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1
    Add-Check 'Microsoft.Graph.Authentication' ([bool]$graph) ($(if ($graph) { "v$($graph.Version)" } else { 'not installed' })) $true 'publishing to Intune'

    # IntuneWinAppUtil (auto-downloads on first package)
    $moduleRoot = Split-Path $PSScriptRoot -Parent
    $util = Test-Path (Join-Path $moduleRoot 'Tools\IntuneWinAppUtil.exe')
    Add-Check 'IntuneWinAppUtil.exe' $util ($(if ($util) { 'present' } else { 'downloads on first package' })) $false 'packaging'

    return $results.ToArray()
}
