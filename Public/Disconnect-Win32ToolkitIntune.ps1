function Disconnect-Win32ToolkitIntune {
<#
.SYNOPSIS
    Signs out of the Intune session that win32-toolkit uses.
.DESCRIPTION
    Disconnect-Win32ToolkitIntune ends the Microsoft Graph session that win32-toolkit uses for
    Intune, and prints the tenant that you signed out of. The next connect or publish starts a new
    sign-in.

    Use it when you finish the work for a customer. In the menu: Microsoft Intune connection >
    Sign out. The menu shows Sign out only when you are connected.

    Your browser stays signed in to Microsoft Entra, so the next connect may not ask you to sign
    in. It can land on the same tenant again. Signing out is a convenience, not a safety control.
    The tenant ID on each org template keeps customers apart. Also, by default a sign-in with
    Connect-Win32ToolkitIntune ends when you close the PowerShell window.

    If you are not connected, the command prints "Not connected to Microsoft Intune." and changes
    nothing. If the sign-out fails, it shows a warning that starts with "Disconnect failed:" and
    does not stop.
.EXAMPLE
    Disconnect-Win32ToolkitIntune

    This signs out and prints the tenant. Your browser stays signed in.
.EXAMPLE
    Disconnect-Win32ToolkitIntune -WhatIf

    This shows the tenant that the command would sign out of, and changes nothing.
.OUTPUTS
    An object with Disconnected, TenantId and DisplayName.
    Disconnected is False when you were not connected, when the sign-out failed, or with -WhatIf.
.LINK
    https://win32toolkit.com/reference/Disconnect-Win32ToolkitIntune/
.LINK
    https://win32toolkit.com/intune-connection/
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
