function Get-Win32ToolkitTenantInfo {
    <#
    .SYNOPSIS
        Resolves a friendly tenant name for the CURRENT Graph session, cached on disk.

    .DESCRIPTION
        A tenant GUID is unreadable, and the signed-in ACCOUNT is not identity either: a consultant's
        UPN looks identical in every customer tenant they are a guest in. The organisation's display
        name is the only thing a human reliably recognises, so the connection banner leads with it.

        Uses Invoke-MgGraphRequest against /v1.0/organization rather than Get-MgOrganization, so the
        module keeps its single Microsoft.Graph.Authentication dependency instead of pulling in
        Microsoft.Graph.Identity.DirectoryManagement for one call.

        NOTE the response shape: /organization returns a COLLECTION ({ value: [ {...} ] }), and
        Invoke-MgGraphRequest returns a HASHTABLE by default, not a PSObject. Both matter for the
        tests as much as the code.

        Cached under LOCALAPPDATA keyed by tenant id, so the banner costs one call per tenant ever.
        Fails OPEN: no name simply means the GUID is shown. Never blocks a publish.

    .OUTPUTS
        [pscustomobject] TenantId / DisplayName / DefaultDomain. DisplayName/DefaultDomain may be empty.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $ctx = try { Get-MgContext } catch { $null }
    if (-not $ctx -or -not $ctx.TenantId) { return $null }

    $cacheDir  = Join-Path $env:LOCALAPPDATA 'CloudFlow\win32-toolkit'
    $cacheFile = Join-Path $cacheDir 'tenants.json'
    $cache = @{}
    if (Test-Path -LiteralPath $cacheFile) {
        try {
            $raw = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) { $cache[$p.Name] = $p.Value }
        } catch { $cache = @{} }
    }

    $key = "$($ctx.TenantId)"
    if ($cache.ContainsKey($key) -and $cache[$key].DisplayName) {
        return [pscustomobject]@{
            TenantId      = $key
            DisplayName   = [string]$cache[$key].DisplayName
            DefaultDomain = [string]$cache[$key].DefaultDomain
        }
    }

    $name = ''; $domain = ''
    try {
        $resp = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization' -ErrorAction Stop
        # Collection + HashTable: resp['value'] is an array of hashtables.
        $org = @($resp['value'])[0]
        if ($org) {
            $name = [string]$org['displayName']
            $default = @($org['verifiedDomains']) | Where-Object { $_['isDefault'] } | Select-Object -First 1
            if ($default) { $domain = [string]$default['name'] }
        }
    }
    catch {
        # Reading the org needs a directory-read permission the publish scope does not include. That is
        # fine and expected: degrade to the GUID rather than asking for more privilege than we need.
        Write-Verbose "Could not resolve the tenant name: $($_.Exception.Message)"
    }

    if ($name) {
        try {
            if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
            $cache[$key] = @{ DisplayName = $name; DefaultDomain = $domain }
            ($cache | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $cacheFile -Encoding UTF8
        } catch { Write-Verbose "Tenant-name cache write skipped: $($_.Exception.Message)" }
    }

    return [pscustomobject]@{ TenantId = $key; DisplayName = $name; DefaultDomain = $domain }
}
