function Get-Win32ToolkitDependencies {
    <#
    .SYNOPSIS
        Reads and normalizes a project's declared Intune app dependencies from AppConfig.json.
    .DESCRIPTION
        Single reader for the AppConfig `Dependencies` section, so the defaults live in exactly one place.
        Returns an EMPTY array for a project that declares none — every caller must behave identically to
        today for such projects (that is the regression contract).

        Dependencies are DATA (see designs/data-driven-generation.md): they are winget ids / project names /
        Intune app ids stored as JSON, never spliced into a generated script.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder.
    .OUTPUTS
        PSCustomObject[]: Source, Ref, DependencyType. Empty array when none are declared.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    if (-not ($cfg.PSObject.Properties.Name -contains 'Dependencies') -or -not $cfg.Dependencies) {
        return @()
    }

    $out = foreach ($d in @($cfg.Dependencies)) {
        if (-not $d) { continue }
        $type = if ($d.PSObject.Properties.Name -contains 'DependencyType' -and $d.DependencyType) { [string]$d.DependencyType } else { 'autoInstall' }
        [pscustomobject]@{
            Source         = [string]$d.Source
            Ref            = [string]$d.Ref
            DependencyType = $type
        }
    }
    return @($out)
}
