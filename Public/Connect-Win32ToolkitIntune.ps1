function Connect-Win32ToolkitIntune {
<#
.SYNOPSIS
    Signs in to Intune and shows which tenant you are connected to.
.DESCRIPTION
    Connect-Win32ToolkitIntune signs you in to Microsoft Intune and shows a banner with the tenant
    name, the tenant ID and your account. You see the tenant before anything is written. If you
    are already signed in to that tenant, the command uses that sign-in. If your account may not
    read the tenant name, the banner shows "(name unavailable)" and the tenant ID.

    Use it before you publish, and always when you work for more than one customer. Publishing
    can sign in by itself, but it then saves the sign-in on disk. In the menu: Microsoft Intune
    connection > Connect using an org template's tenant.

    The command writes nothing to Intune. By default the sign-in is kept in this PowerShell window
    only. If the sign-in lands on another tenant than the one you asked for, the command signs you
    out again and stops.

    Use the tenant ID, not a domain name. win32-toolkit compares tenant IDs, so a domain name never
    matches.
.PARAMETER TenantId
    The tenant ID to connect to. If you also give -Template, this value wins.
.PARAMETER Template
    The org template whose tenant ID you connect to. This is the recommended way to connect. If
    the template has no tenant ID, the command warns and signs in without one.
.PARAMETER ContextScope
    Where the sign-in is kept. Default: Process (this PowerShell window only). Use CurrentUser only
    if you work for one tenant: the sign-in is then saved on disk for later windows.
.PARAMETER UseDeviceAuthentication
    Signs in with a code that you enter on a web page on any device. Use it when this PC has no
    browser, or when the browser keeps signing in to the wrong tenant.
.PARAMETER Scopes
    The Graph permissions to ask for. Default: DeviceManagementApps.ReadWrite.All. Leave it
    unchanged.
.PARAMETER BasePath
    The base folder to read the org template from, for this command only. Default: your saved base
    folder.
.PARAMETER Force
    Installs the Microsoft.Graph.Authentication module without asking. Use it in scripts.
.EXAMPLE
    Connect-Win32ToolkitIntune -Template 'Contoso'

    This signs in to the tenant ID saved on the Contoso org template and shows the tenant banner.
.EXAMPLE
    Connect-Win32ToolkitIntune -TenantId '11111111-2222-3333-4444-555555555555'

    This signs in to one tenant by its tenant ID, without an org template.
.EXAMPLE
    Connect-Win32ToolkitIntune -Template 'Contoso' -UseDeviceAuthentication

    This signs in with a device code, on a PC without a browser.
.EXAMPLE
    Connect-Win32ToolkitIntune -Template 'Contoso' -Force -ErrorAction Stop

    This is the form for scripts. A connect error does not stop a script unless you add
    -ErrorAction Stop.
.OUTPUTS
    An object with TenantId, DisplayName, Account and Scopes.
    If the connect fails, the command returns nothing.
    The error that it writes starts with "Connect failed:".
.LINK
    https://win32toolkit.com/reference/Connect-Win32ToolkitIntune/
.LINK
    https://win32toolkit.com/intune-connection/
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$TenantId,
        [string]$Template,
        [ValidateSet('Process', 'CurrentUser')]
        [string]$ContextScope = 'Process',
        [switch]$UseDeviceAuthentication,
        [string[]]$Scopes = @('DeviceManagementApps.ReadWrite.All'),
        [string]$BasePath,
        [switch]$Force
    )

    try {
        $templateName = $Template
        if (-not $TenantId -and $Template) {
            # Only TenantId is read here, so a template whose dialog text needs fixing must not block sign-in.
            $tpl = Get-OrgTemplate -TemplateName $Template -BasePath (Get-Win32ToolkitBasePath -BasePath $BasePath -NonInteractive) -SkipTextValidation
            if (-not $tpl) { throw "Org template '$Template' not found." }
            if ($tpl.PSObject.Properties['TenantId'] -and $tpl.TenantId) {
                $TenantId = [string]$tpl.TenantId
            } else {
                Write-Warning "Template '$Template' does not pin a tenant. Connecting without one: nothing will be able to verify you are on the right customer. Add a tenant to the template to fix that."
            }
        }

        $connectParams = @{
            Scopes       = $Scopes
            ContextScope = $ContextScope
            Force        = $Force
        }
        if ($TenantId)                { $connectParams['TenantId'] = $TenantId }
        if ($UseDeviceAuthentication) { $connectParams['UseDeviceAuthentication'] = $true }

        $ctx = Connect-Win32ToolkitGraph @connectParams

        Show-Win32ToolkitTenantBanner -ExpectedTenantId $TenantId -TemplateName $templateName

        $info = Get-Win32ToolkitTenantInfo
        return [pscustomobject]@{
            TenantId    = "$($ctx.TenantId)"
            DisplayName = $(if ($info) { $info.DisplayName } else { '' })
            Account     = "$($ctx.Account)"
            Scopes      = @($ctx.Scopes)
        }
    }
    catch {
        Write-Error "Connect failed: $($_.Exception.Message)"
    }
}
