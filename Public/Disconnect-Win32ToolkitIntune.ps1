function Disconnect-Win32ToolkitIntune {
<#
.SYNOPSIS
    Signs out of Microsoft Intune (Entra) for this toolkit's Graph session.
.DESCRIPTION
    Clears the Microsoft Graph token this session was using, so the next publish must sign in again
    rather than silently reusing whichever customer you were last connected to.

    BE CLEAR ABOUT WHAT THIS DOES NOT DO. It signs out of the Graph SDK, not out of Entra. Your
    BROWSER (or Windows account manager) is still signed in, so the next connect can complete with no
    prompt and land straight back on the same tenant. That is a property of the identity provider, not
    something this command can revoke.

    So do not treat disconnect as the thing that keeps customers apart. The controls that actually do
    that are pinning a tenant on the org template (which publish then verifies and refuses to violate)
    and connecting with -ContextScope Process so no token outlives the session. This command is an
    honest convenience, not a security boundary.
.EXAMPLE
    Disconnect-Win32ToolkitIntune
.OUTPUTS
    [pscustomobject] Disconnected (bool) / TenantId / DisplayName of the session that was ended.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param()

    $ctx = try { Get-MgContext } catch { $null }
    if (-not $ctx) {
        Write-Host 'Not connected to Microsoft Intune.' -ForegroundColor DarkGray
        return [pscustomobject]@{ Disconnected = $false; TenantId = ''; DisplayName = '' }
    }

    $info   = Get-Win32ToolkitTenantInfo
    $name   = if ($info -and $info.DisplayName) { $info.DisplayName } else { "$($ctx.TenantId)" }
    $tenant = "$($ctx.TenantId)"

    if (-not $PSCmdlet.ShouldProcess($name, 'Disconnect the Microsoft Graph session')) {
        return [pscustomobject]@{ Disconnected = $false; TenantId = $tenant; DisplayName = $name }
    }

    try {
        Disconnect-MgGraph -ErrorAction Stop | Out-Null
        Write-Host "✓ Signed out of $name." -ForegroundColor Green
        Write-Host '  This cleared the toolkit''s token. Your browser is still signed in to Entra, so the next connect may not prompt.' -ForegroundColor DarkGray
        return [pscustomobject]@{ Disconnected = $true; TenantId = $tenant; DisplayName = $name }
    }
    catch {
        Write-Warning "Disconnect failed: $($_.Exception.Message)"
        return [pscustomobject]@{ Disconnected = $false; TenantId = $tenant; DisplayName = $name }
    }
}
