function Get-Win32ToolkitAppConfig {
    <#
    .SYNOPSIS
        Reads a project's data-driven deployment config (SupportFiles\AppConfig.json).
    .DESCRIPTION
        Returns the parsed AppConfig.json for a PSADT project as a PSCustomObject. If the file
        does not exist yet, returns a seed object ({ SchemaVersion = '1.0' }) so that the writers
        (Configure-PSADTForInstaller, Update-PSADTUninstallLogic, Update-PSADTProcessesToClose)
        can populate their own section regardless of pipeline stage order.

        This is the read half of the data-driven install/uninstall model — see
        knowledge-base/designs/data-driven-generation.md.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder (the folder that contains Invoke-AppDeployToolkit.ps1).
    .EXAMPLE
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath 'C:\Win32Apps\Projects\Git_x64_2.53.0'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $configPath = Join-Path $ProjectPath 'SupportFiles\AppConfig.json'
    if (Test-Path -LiteralPath $configPath) {
        return (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return [pscustomobject]@{ SchemaVersion = '1.0' }
}
