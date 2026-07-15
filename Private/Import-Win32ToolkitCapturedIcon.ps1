function Import-Win32ToolkitCapturedIcon {
    <#
    .SYNOPSIS
        Promotes the icon captured during the install run to Assets\AppIcon.png, respecting precedence.
    .DESCRIPTION
        The documentation/capture run extracts the installed app's real icon to
        Sandbox\Logs\AppIcon_Captured.png (see New-TargetedDocumentation's guest script). This runs in the
        finalize tail, after the capture has been copied back, and decides whether that captured icon becomes
        the project's AppIcon.png.

        Precedence (the winget-primary decision): if an authoritative icon is already applied — the
        Assets\.iconsource marker says 'winget' or 'manual' — the captured icon is IGNORED and the existing
        one is kept. Otherwise (no winget IconUrl, or a manual app with no -IconPath) the captured icon is
        promoted: validated as a real image, written to Assets\AppIcon.png (and the PSAppDeployToolkit\Assets
        mirror so PSADT's own dialogs use it too), and the marker is set to 'captured'.

        Returns $true when the captured icon was promoted, $false otherwise (nothing captured, precedence
        kept the existing icon, or the captured file was not a valid image).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $captured = Join-Path $ProjectPath 'Sandbox\Logs\AppIcon_Captured.png'
    if (-not (Test-Path -LiteralPath $captured)) { return $false }

    # Precedence: an authoritative winget/manual icon always wins over the captured one.
    $existingSource = Get-Win32ToolkitIconSource -ProjectPath $ProjectPath
    if ($existingSource -eq 'winget' -or $existingSource -eq 'manual') {
        Write-Verbose "Captured icon ignored — an authoritative '$existingSource' icon is already applied."
        return $false
    }

    # Validate the captured file is a real, decodable image before overwriting the PSADT default.
    try { $bytes = [System.IO.File]::ReadAllBytes($captured) }
    catch {
        Write-Warning "Could not read the captured icon '$captured': $($_.Exception.Message)"
        return $false
    }
    $png = ConvertTo-Win32ToolkitPngBytes -Bytes $bytes
    if (-not $png) {
        Write-Warning 'The icon captured from the install run is not a valid image — keeping the existing icon.'
        return $false
    }

    $assets = Join-Path $ProjectPath 'Assets'
    if (-not (Test-Path -LiteralPath $assets)) { New-Item -ItemType Directory -Path $assets -Force | Out-Null }
    [System.IO.File]::WriteAllBytes((Join-Path $assets 'AppIcon.png'), $png)

    # Mirror into the toolkit's own Assets so PSADT's on-device dialogs use the real icon too.
    $psadtAssets = Join-Path $ProjectPath 'PSAppDeployToolkit\Assets'
    if (Test-Path -LiteralPath $psadtAssets) {
        try { [System.IO.File]::WriteAllBytes((Join-Path $psadtAssets 'AppIcon.png'), $png) }
        catch { Write-Verbose "Could not mirror the icon into PSAppDeployToolkit\Assets: $($_.Exception.Message)" }
    }

    Set-Win32ToolkitIconSource -ProjectPath $ProjectPath -Source 'captured'
    Write-Host '✓ Applied the icon captured from the install run to Assets\AppIcon.png' -ForegroundColor Green
    return $true
}
