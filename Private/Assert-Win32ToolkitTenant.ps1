function Assert-Win32ToolkitTenant {
    <#
    .SYNOPSIS
        Throws unless the live Graph session is the tenant this project is pinned to.

    .DESCRIPTION
        The last line of defence before anything is written to a customer's Intune tenant.

        Connect-Win32ToolkitGraph already refuses to reuse a foreign session, but that only helps when
        the caller passed a tenant. This runs at the point of no return: right before the app shell is
        created. If the project's org template pins a TenantId and the live session is a different
        tenant, this throws instead of publishing.

        An UNPINNED template (TenantId empty) cannot be checked, so it warns once and proceeds. That is
        the honest behaviour: the toolkit does not know which tenant is correct, and silently doing
        nothing would be worse than saying so.

    .PARAMETER ProjectPath
        Project whose org template carries the expected TenantId.

    .PARAMETER Operation
        What is about to happen, for the error text (e.g. 'publish', 'dependency sync').

    .OUTPUTS
        [pscustomobject] TenantId / DisplayName / Pinned. Throws on mismatch.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [string]$Operation = 'this operation'
    )

    $ctx = try { Get-MgContext } catch { $null }
    if (-not $ctx) { throw "Not connected to Microsoft Graph. Run Connect-Win32ToolkitIntune first." }

    $expected = ''
    $cfg = try { Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath } catch { $null }
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'Intune' -and $cfg.Intune) {
        $expected = [string]$cfg.Intune.TenantId
    }
    # Fall back to the org template loaded for this run (a project configured before pinning existed).
    if (-not $expected -and $script:OrgTemplate -and $script:OrgTemplate.PSObject.Properties['TenantId']) {
        $expected = [string]$script:OrgTemplate.TenantId
    }

    $info = Get-Win32ToolkitTenantInfo
    $friendly = if ($info -and $info.DisplayName) { "$($info.DisplayName) ($($ctx.TenantId))" } else { "$($ctx.TenantId)" }

    if (-not $expected) {
        Write-Warning "This project's template does not pin a tenant, so $Operation cannot be checked against one. You are connected to: $friendly. Pin a tenant on the org template to have the toolkit refuse the wrong one."
        return [pscustomobject]@{ TenantId = "$($ctx.TenantId)"; DisplayName = $(if ($info) { $info.DisplayName } else { '' }); Pinned = $false }
    }

    if ("$($ctx.TenantId)" -ine $expected) {
        throw "REFUSING $($Operation): this project is pinned to tenant '$expected' but the current session is '$friendly'. Publishing now would push this customer's app into a different customer's tenant. Run Connect-Win32ToolkitIntune -TenantId '$expected' (or Disconnect-Win32ToolkitIntune first)."
    }

    return [pscustomobject]@{ TenantId = "$($ctx.TenantId)"; DisplayName = $(if ($info) { $info.DisplayName } else { '' }); Pinned = $true }
}
