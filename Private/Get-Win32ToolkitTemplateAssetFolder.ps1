function Get-Win32ToolkitTemplateAssetFolder {
    <#
    .SYNOPSIS
        Resolves the on-disk asset folder that a template owns: Templates\<TemplateName>\.

    .DESCRIPTION
        Templates are stored as a flat Templates\<name>.json. From schema 3.0 a template may ALSO own a
        sidecar folder Templates\<name>\ holding operator-authored content that ships with every project
        built from it:
          * Hooks\{Pre,Post}{Install,Uninstall,Repair}.ps1  — org deploy-phase scripts (A1)
          * PSAppDeployToolkit.<Org>\                        — org PSADT extension module (A3)
          * Assets\{AppIcon.png, AppIconDark.png, Banner.Classic.png} — org branding (B1)

        The sidecar folder is OPTIONAL — a plain .json template with no folder is fully valid; this just
        returns the conventional path so callers can test for its existence.

    .PARAMETER TemplateName
        The template's name (its .json basename).

    .PARAMETER BasePath
        Toolkit base path; resolved from the registry-backed default when omitted.

    .OUTPUTS
        [string] the folder path (may not exist).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$TemplateName,

        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($BasePath)) { $BasePath = Get-Win32ToolkitBasePath }
    $templatesRoot = (Get-Win32ToolkitPaths -BasePath $BasePath).Templates
    return (Join-Path $templatesRoot $TemplateName)
}
