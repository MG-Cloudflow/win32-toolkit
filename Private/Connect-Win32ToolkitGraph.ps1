function Connect-Win32ToolkitGraph {
    # ── Ensure Microsoft.Graph.Authentication is available ────────────────────────
    $module = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' | Select-Object -First 1
    if (-not $module) {
        Write-Host 'Microsoft.Graph.Authentication module not found.' -ForegroundColor Yellow
        $answer = Read-Host 'Install it now from PSGallery? (Y/N)'
        if ($answer -notmatch '^[Yy]') {
            throw 'Microsoft.Graph.Authentication is required. Run: Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser'
        }
        Write-Host 'Installing Microsoft.Graph.Authentication...' -ForegroundColor Yellow
        Install-Module -Name 'Microsoft.Graph.Authentication' -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        Write-Host '  ✓ Module installed.' -ForegroundColor Green
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    # ── Check existing context ─────────────────────────────────────────────────────
    $ctx = Get-MgContext
    if ($ctx -and ($ctx.Scopes -contains 'DeviceManagementApps.ReadWrite.All')) {
        Write-Host "✓ Already connected to Microsoft Graph as: $($ctx.Account)" -ForegroundColor Green
        return $ctx
    }

    # ── Interactive auth ───────────────────────────────────────────────────────────
    Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Yellow
    Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All' -ErrorAction Stop

    $ctx = Get-MgContext
    Write-Host "  ✓ Connected as: $($ctx.Account)" -ForegroundColor Green
    return $ctx
}
