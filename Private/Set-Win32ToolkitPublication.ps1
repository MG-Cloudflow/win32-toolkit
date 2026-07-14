function Set-Win32ToolkitPublication {
    <#
    .SYNOPSIS
        Remembers that this project was published to Intune as a given app id (per tenant).
    .DESCRIPTION
        Upserts <ProjectPath>\Intune\Publications.json so a LATER app can declare
        'project:<Template>\<Name>' as a dependency and be resolved to a real Intune app id without a
        tenant search. Written by Publish-Win32ToolkitIntuneApp after the app is created.

        Deliberately NOT in SupportFiles\AppConfig.json: that file ships inside the .intunewin, and tenant
        / app ids must never travel to devices. Optimize-Win32ToolkitProject strips the Intune\ folder from
        the Staging copy so this never enters a package.

        The "(Update)" app is not recorded — dependencies attach to the install app only.
    .PARAMETER ProjectPath
        The project that was published.
    .PARAMETER TenantId / AppId / DisplayName / DisplayVersion / WingetId
        What was published, and where.
    .OUTPUTS
        [string] the path of the cache file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$ProjectPath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$AppId,
        [string]$TenantId = 'unknown',
        [string]$DisplayName,
        [string]$DisplayVersion,
        [string]$WingetId
    )

    $dir  = Join-Path $ProjectPath 'Intune'
    $path = Join-Path $dir 'Publications.json'

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @(Get-Win32ToolkitPublication -ProjectPath $ProjectPath)) {
        if ($e.TenantId -ne $TenantId) { $entries.Add($e) }   # replace this tenant's entry
    }
    $entries.Add([pscustomobject]@{
        TenantId       = $TenantId
        AppId          = $AppId
        DisplayName    = $DisplayName
        DisplayVersion = $DisplayVersion
        WingetId       = $WingetId
        PublishedUtc   = (Get-Date).ToUniversalTime().ToString('o')
    })

    if ($PSCmdlet.ShouldProcess($path, 'Record the Intune publication')) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = ConvertTo-Json -InputObject ([object[]]@($entries)) -Depth 5
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $path
}
