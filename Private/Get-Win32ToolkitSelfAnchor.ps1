function Get-Win32ToolkitSelfAnchor {
    <#
    .SYNOPSIS
        Tells whether an existing project that is about to be rebuilt is itself a continuity anchor.
    .DESCRIPTION
        Installer-identity PR 1 (spec 2.10, D3). Rebuilding a version (Invoke-Win32Toolkit -Force, the TUI
        wizard) deletes its project folder before the installer technology is resolved, and the predecessor
        lookup excludes the project being built. A version that is itself published or explicitly pinned
        would then lose its own technology to an older anchored version. This helper reads the existing
        folder BEFORE it is deleted, with the same anchoring rule as Get-Win32ToolkitPreviousProject:

          - published: <ProjectPath>\Intune\Publications.json has an entry (for -TenantId when given, else
            any entry; Dv4);
          - pinned: the persisted AppConfig.Source.PinnedBy is 'parameter' or 'operator' ('continuity'
            alone does not anchor; a Source rebuilt in memory never counts as a pin).

        Read-only. Returns $null when the folder or SupportFiles\AppConfig.json does not exist, or when the
        project is not anchored. Fail-open: an unexpected error is one warning and $null (the rebuild then
        resolves the technology as for a new project).
    .PARAMETER ProjectPath
        The project folder that is about to be (re)created.
    .PARAMETER TenantId
        Only publications to this tenant anchor ('' = any recorded publication).
    .OUTPUTS
        [pscustomobject] Name, Path, InstallerType, Family, PinnedBy (the persisted Source.PinnedBy),
        Published, Anchored ($true), AnchorReason ('published' | 'pinned:parameter' | 'pinned:operator'),
        or $null.
    .EXAMPLE
        $selfAnchor = Get-Win32ToolkitSelfAnchor -ProjectPath $projectFullPath -TenantId $tenantId
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TenantId = ''
    )

    try {
        $path = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath).TrimEnd('\')
        if (-not (Test-Path -LiteralPath (Join-Path $path 'SupportFiles\AppConfig.json') -PathType Leaf)) { return $null }

        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $path
        if ($null -eq $cfg) { return $null }

        $pubs = if ($TenantId) { @(Get-Win32ToolkitPublication -ProjectPath $path -TenantId $TenantId) } else { @(Get-Win32ToolkitPublication -ProjectPath $path) }
        $published = $pubs.Count -ge 1
        $persisted = if ($cfg.PSObject.Properties['Source'] -and $cfg.Source) { $cfg.Source } else { $null }
        $persistedPin = if ($persisted -and $persisted.PSObject.Properties['PinnedBy']) { ([string]$persisted.PinnedBy).Trim().ToLowerInvariant() } else { '' }
        $anchorReason = if ($published) { 'published' }
                        elseif ($persistedPin -in @('parameter', 'operator')) { "pinned:$persistedPin" }
                        else { '' }
        if (-not $anchorReason) {
            Write-Verbose "Get-Win32ToolkitSelfAnchor: '$path' is neither published nor pinned; it does not anchor its own rebuild."
            return $null
        }

        $src = Get-Win32ToolkitProjectSource -ProjectPath $path
        [pscustomobject]@{
            Name          = ConvertTo-Win32ToolkitSafeText -Text (Split-Path -Path $path -Leaf) -MaxLength 128
            Path          = $path
            InstallerType = [string]$src.InstallerType
            Family        = [string]$src.Family
            PinnedBy      = $persistedPin
            Published     = $published
            Anchored      = $true
            AnchorReason  = $anchorReason
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning "Could not read the installer technology of the existing project '$ProjectPath' ($($_.Exception.Message)); it is rebuilt as if it were new."
        return $null
    }
}
