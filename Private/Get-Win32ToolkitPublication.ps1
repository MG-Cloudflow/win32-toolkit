function Get-Win32ToolkitPublication {
    <#
    .SYNOPSIS
        Reads a project's remembered Intune publication (app id) from <ProjectPath>\Intune\Publications.json.
    .DESCRIPTION
        The toolkit publishes an app and then forgets its id, so nothing can later say "app X depends on the
        thing I published from project Y". This cache remembers it, keyed by tenant.

        It lives in <ProjectPath>\Intune\ and NOT in SupportFiles\AppConfig.json, because AppConfig SHIPS
        inside the .intunewin — tenant and app ids must never be baked into a package that lands on devices.
        Optimize-Win32ToolkitProject strips the Intune\ folder from the Staging copy for the same reason.

        A CACHE only: the app may have been deleted in the portal, so callers must tolerate a stale entry
        and fall back to a tenant search.
    .PARAMETER ProjectPath
        The project whose publication should be read.
    .PARAMETER TenantId
        Only return the entry for this tenant. Omit to return them all.
    .OUTPUTS
        PSCustomObject[] (TenantId, AppId, DisplayName, DisplayVersion, WingetId, PublishedUtc), or empty.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [string]$TenantId
    )

    $path = Join-Path $ProjectPath 'Intune\Publications.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    try   { $entries = @(Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-Warning "Could not read $path — ignoring the publication cache: $($_.Exception.Message)"; return @() }

    if ($TenantId) { return @($entries | Where-Object { $_.TenantId -eq $TenantId }) }
    return @($entries)
}
