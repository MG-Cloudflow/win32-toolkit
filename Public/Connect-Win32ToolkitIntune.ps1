function Connect-Win32ToolkitIntune {
<#
.SYNOPSIS
    Signs in to Microsoft Intune (Entra) and shows which tenant you are connected to.
.DESCRIPTION
    Publishing already connects on demand, so this exists for the two things that flow could not do:
    choose the tenant up front, and SEE which one you are on before anything is written.

    That matters when you package for several customers. The signed-in account is not identity: your
    UPN looks the same in every tenant you are a guest in. The tenant is what decides whose Intune
    receives the app, so this command leads with the tenant name.

    Pass -Template to connect to the tenant pinned on an org template. That is the recommended way:
    the same pin is then enforced at publish time, and a session for the wrong tenant is refused
    rather than used.

    The toolkit requests the least privilege it needs (DeviceManagementApps.ReadWrite.All). The tenant
    NAME shown in the banner comes from a directory read that your account may or may not be allowed;
    when it is not, the GUID is shown instead and nothing else changes.
.PARAMETER TenantId
    Tenant to connect to (GUID or domain). The connection is verified afterwards: if it lands on a
    different tenant, the command throws instead of leaving you signed in to the wrong one.
.PARAMETER Template
    Org template whose pinned TenantId to use. Ignored if -TenantId is given.
.PARAMETER ContextScope
    'Process' (default) keeps the token in this session only. 'CurrentUser' caches it on disk for
    later sessions, which is convenient for one tenant and risky across several.
.PARAMETER UseDeviceAuthentication
    Use the device-code flow (no browser on this host).
.PARAMETER Scopes
    Override the requested delegated permissions.
.PARAMETER BasePath
    Base folder (registry-backed default), used to find the template.
.PARAMETER Force
    Install the Microsoft.Graph.Authentication prerequisite without prompting.
.EXAMPLE
    Connect-Win32ToolkitIntune -Template 'Contoso'
    Connects to the tenant pinned on the Contoso template and prints the connection banner.
.EXAMPLE
    Connect-Win32ToolkitIntune -TenantId 'contoso.onmicrosoft.com' -ContextScope CurrentUser
    Connects to a named tenant and keeps the token for later sessions.
.OUTPUTS
    [pscustomobject] TenantId / DisplayName / Account / Scopes.
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
            $tpl = Get-OrgTemplate -TemplateName $Template -BasePath (Get-Win32ToolkitBasePath -BasePath $BasePath -NonInteractive)
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
