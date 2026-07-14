function ConvertTo-Win32ToolkitDependencyRef {
    <#
    .SYNOPSIS
        Parses a dependency reference string into its normalized { Source; Ref; DependencyType } form.
    .DESCRIPTION
        A dependency is declared as a short string, in one of three forms:

            winget:Microsoft.VCRedist.2015+.x64     a winget package (must be packaged + published first)
            project:Contoso\VCRedist_x64_14.38      a project already packaged by this toolkit
            intune:8d0a1f2c-....                    an app id picked straight from the tenant

        A BARE string is disambiguated: a GUID -> intune, anything containing '\' -> project, otherwise
        -> winget (winget ids look like Publisher.Package).

        PURE — no I/O, no Graph. The Ref is preserved VERBATIM: winget ids legitimately contain '.' and
        '+' (Microsoft.VCRedist.2015+.x64) and must never be run through Sanitize-ProjectName, and the
        value is stored as JSON DATA in AppConfig.json — never spliced into a generated script.
    .PARAMETER Reference
        The reference string, e.g. 'winget:Microsoft.VCRedist.2015+.x64'.
    .PARAMETER DependencyType
        'autoInstall' (default) installs the dependency first — what you want for a redistributable.
        'detect' ONLY detects it: if it is not present, the parent app install is NOT EVEN ATTEMPTED.
    .OUTPUTS
        PSCustomObject: Source ('winget'|'project'|'intune'), Ref, DependencyType.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string]$Reference,

        [ValidateSet('autoInstall', 'detect')]
        [string]$DependencyType = 'autoInstall'
    )

    process {
        $raw  = $Reference.Trim()
        $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'

        if ($raw -match '^(?<s>winget|project|intune)\s*:\s*(?<r>.+)$') {
            $source = $Matches['s'].ToLowerInvariant()
            $ref    = $Matches['r'].Trim()
        }
        elseif ($raw -match $guid) { $source = 'intune';  $ref = $raw }
        elseif ($raw -like '*\*')  { $source = 'project'; $ref = $raw }
        else                       { $source = 'winget';  $ref = $raw }

        if ([string]::IsNullOrWhiteSpace($ref)) {
            throw "Dependency reference '$Reference' has no value after the '<source>:' prefix."
        }
        if ($source -eq 'intune' -and $ref -notmatch $guid) {
            throw "Dependency 'intune:$ref' is not a valid Intune app id (expected a GUID)."
        }
        if ($source -eq 'project' -and $ref -notlike '*\*') {
            throw "Dependency 'project:$ref' must be '<Template>\<ProjectName>' (as listed by Browse projects)."
        }

        [pscustomobject]@{
            Source         = $source
            Ref            = $ref
            DependencyType = $DependencyType
        }
    }
}
