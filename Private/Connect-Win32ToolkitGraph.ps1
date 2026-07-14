function Connect-Win32ToolkitGraph {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Install a missing prerequisite module without prompting (for unattended / non-interactive runs).
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

    # ── Check existing context ─────────────────────────────────────────────────────
    $ctx = Get-MgContext
    if ($ctx -and ($ctx.Scopes -contains 'DeviceManagementApps.ReadWrite.All')) {
        Write-Host "✓ Already connected to Microsoft Graph as: $($ctx.Account)" -ForegroundColor Green
        return $ctx
    }

    # ── Interactive auth ───────────────────────────────────────────────────────────
    Write-Verbose 'Connecting to Microsoft Graph...'
    Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All' -ErrorAction Stop

    $ctx = Get-MgContext
    Write-Host "  ✓ Connected as: $($ctx.Account)" -ForegroundColor Green
    return $ctx
}
