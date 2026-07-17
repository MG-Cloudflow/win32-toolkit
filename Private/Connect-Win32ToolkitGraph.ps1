function Connect-Win32ToolkitGraph {
    <#
    .SYNOPSIS
        Ensures a Microsoft Graph session that is connected to the EXPECTED tenant.

    .DESCRIPTION
        THE BUG THIS FIXES: the previous version reused any cached context that merely carried the right
        SCOPE. It never looked at the tenant. Because Connect-MgGraph defaults to -ContextScope
        CurrentUser, that context is also persisted to disk and survives closing the session. So a
        consultant who connected to customer A and then published a customer B project got A's context
        back, a green "already connected" tick, and the app uploaded to A's tenant. The tenant id was
        read only to LOG where it went. Nothing refused.

        Now: a cached context is reused ONLY when the scope AND the tenant both match. A tenant mismatch
        disconnects and reconnects rather than silently proceeding, and the connection is verified after
        the fact so an unexpected tenant is an exception, never a warning.

    .PARAMETER TenantId
        The tenant this session must be connected to (GUID or domain). When supplied, the connection is
        pinned to it and verified afterwards. Omit only for exploratory use.

    .PARAMETER Scopes
        Delegated permissions to request. Defaults to the least privilege this module needs.

    .PARAMETER ContextScope
        'Process' keeps the token in this process only (nothing persists to disk). 'CurrentUser' caches
        it for later sessions. The TUI passes Process deliberately: a token that cannot outlive the
        session cannot be silently reused against the wrong customer next week.

    .PARAMETER UseDeviceAuthentication
        Device-code flow, for hosts with no browser.

    .PARAMETER Force
        Install a missing prerequisite module without prompting (unattended runs).

    .OUTPUTS
        The Graph context (Get-MgContext).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$TenantId,

        [string[]]$Scopes = @('DeviceManagementApps.ReadWrite.All'),

        [ValidateSet('Process', 'CurrentUser')]
        [string]$ContextScope = 'CurrentUser',

        [switch]$UseDeviceAuthentication,

        [switch]$Force
    )

    # ── Ensure Microsoft.Graph.Authentication is available ────────────────────────
    $module = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' | Select-Object -First 1
    if (-not $module) {
        Write-Warning 'Microsoft.Graph.Authentication module not found.'

        if ($Force) {
            $doInstall = $true
        }
        elseif ([Environment]::UserInteractive) {
            $answer    = Read-Host 'Install it now from PSGallery? (Y/N)'
            $doInstall = ($answer -match '^[Yy]')
        }
        else {
            throw 'Microsoft.Graph.Authentication is required but this session is non-interactive. Re-run with -Force, or install it manually: Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser'
        }

        if (-not $doInstall) {
            throw 'Microsoft.Graph.Authentication is required. Run: Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser'
        }

        Write-Verbose 'Installing Microsoft.Graph.Authentication...'
        if ($PSCmdlet.ShouldProcess('Microsoft.Graph.Authentication', 'Install-Module from PSGallery')) {
            Install-Module -Name 'Microsoft.Graph.Authentication' -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        }
        Write-Host '  ✓ Module installed.' -ForegroundColor Green
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    # ── Reuse an existing context ONLY if scope AND tenant both match ──────────────
    $ctx = Get-MgContext
    if ($ctx) {
        $scopesOk = -not (@($Scopes) | Where-Object { $_ -notin @($ctx.Scopes) })
        $tenantOk = (-not $TenantId) -or
                    ($ctx.TenantId -eq $TenantId) -or
                    ("$($ctx.TenantId)" -ieq "$TenantId")

        if ($scopesOk -and $tenantOk) {
            Write-Verbose "Reusing the existing Graph session (tenant $($ctx.TenantId))."
            return $ctx
        }

        # A cached session for a DIFFERENT tenant is the dangerous case: tear it down rather than
        # letting Connect-MgGraph decide, so the next call cannot silently land back on the old one.
        if (-not $tenantOk) {
            Write-Host "  Switching tenant: signed in to $($ctx.TenantId), need $TenantId." -ForegroundColor Yellow
            try { Disconnect-MgGraph -ErrorAction Stop | Out-Null } catch { Write-Verbose "Disconnect before switch: $($_.Exception.Message)" }
        }
    }

    # ── Connect ───────────────────────────────────────────────────────────────────
    $connectArgs = @{ Scopes = $Scopes; ContextScope = $ContextScope; ErrorAction = 'Stop' }
    if ($TenantId)                { $connectArgs['TenantId'] = $TenantId }
    if ($UseDeviceAuthentication) { $connectArgs['UseDeviceAuthentication'] = $true }
    # -NoWelcome: the SDK banner is noise that also scrolls a Spectre screen.
    if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('NoWelcome')) { $connectArgs['NoWelcome'] = $true }

    Write-Verbose "Connecting to Microsoft Graph$(if ($TenantId) { " (tenant $TenantId)" })..."
    Connect-MgGraph @connectArgs

    # ── VERIFY. A pinned tenant that did not stick is an error, not a warning ──────
    # Connect-MgGraph can succeed against a different tenant than requested (an existing IdP session,
    # a home-tenant fallback). Publishing to the wrong customer is unrecoverable-ish, so refuse.
    $ctx = Get-MgContext
    if (-not $ctx) { throw 'Connected to Microsoft Graph but no context was returned.' }
    if ($TenantId -and "$($ctx.TenantId)" -ine "$TenantId") {
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
        throw "Connected to tenant '$($ctx.TenantId)' but '$TenantId' was requested. Refusing to continue: this is how an app ends up in the wrong customer's tenant. Sign out of the other tenant in your browser, or use -UseDeviceAuthentication."
    }

    return $ctx
}
