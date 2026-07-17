function Sync-Win32ToolkitAppDependency {
    <#
    .SYNOPSIS
        Pushes a project's declared dependencies onto the app it ALREADY published in Intune, without
        re-publishing it.
    .DESCRIPTION
        Publish-Win32ToolkitIntuneApp always creates a NEW app (it has no update path), so "just re-publish
        it" is NOT a way to fix an app's dependencies: it would create a DUPLICATE app and leave the
        original — the one that is actually assigned to your users — still without them.

        This is the supported way to change the dependencies of an app that is already live:

            1. edit the declaration   (Set-Win32ToolkitAppDependency / the TUI)
            2. Sync-Win32ToolkitAppDependency -ProjectPath <the project>

        The app id comes from the project's publication cache (<ProjectPath>\Intune\Publications.json,
        written when it was published from this machine). Declared dependencies are AUTHORITATIVE: the app's
        dependency set is replaced, so removing a declaration here really does remove the relationship in
        Intune. Supersedence is preserved untouched (see Set-Win32ToolkitAppRelationships).

        Typical use: you published an app whose dependency was not in the tenant yet (it warned and
        published anyway). You then package + publish the dependency — and run this to link them.
    .PARAMETER ProjectPath
        The project whose declared dependencies should be pushed to its published app.
    .PARAMETER AppId
        Override the app to update (e.g. it was published from another machine, so there is no local cache
        entry — copy the id from the Intune portal).
    .OUTPUTS
        [int] the number of dependency relationships now attached.
    .EXAMPLE
        Set-Win32ToolkitAppDependency -ProjectPath $p -DependsOn 'winget:Microsoft.VCRedist.2015+.x64'
        Sync-Win32ToolkitAppDependency -ProjectPath $p
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [string]$AppId
    )

    if (-not (Test-Path -LiteralPath $ProjectPath)) { throw "Project not found: $ProjectPath" }

    $baseUri = 'https://graph.microsoft.com/beta/deviceAppManagement'

    # Pin to the project's tenant so a cached session for another customer is not reused, then verify
    # before any relationship is written.
    $pinnedTenant = ''
    $syncCfg = try { Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath } catch { $null }
    if ($syncCfg -and $syncCfg.PSObject.Properties.Name -contains 'Intune' -and $syncCfg.Intune) {
        $pinnedTenant = [string]$syncCfg.Intune.TenantId
    }
    if ($pinnedTenant) { Connect-Win32ToolkitGraph -TenantId $pinnedTenant } else { Connect-Win32ToolkitGraph }
    $null   = Assert-Win32ToolkitTenant -ProjectPath $ProjectPath -Operation 'dependency sync'
    $tenant = try { (Get-MgContext).TenantId } catch { 'unknown' }

    if (-not $AppId) {
        $pub = @(Get-Win32ToolkitPublication -ProjectPath $ProjectPath -TenantId $tenant)
        if ($pub.Count -eq 0 -or -not $pub[0].AppId) {
            throw @"
This project has no recorded Intune publication for tenant '$tenant', so there is no app to update.
Publish it first (Export-Win32ToolkitIntuneWin -PublishIntune), or pass -AppId with the id from the
Intune portal if it was published from another machine.
"@
        }
        $AppId = $pub[0].AppId
        Write-Host "Target app: $($pub[0].DisplayName) ($AppId)" -ForegroundColor Cyan
    }

    $resolved = @(Resolve-Win32ToolkitDependencies -ProjectPath $ProjectPath -TenantId $tenant -BaseUri $baseUri)

    if ($PSCmdlet.ShouldProcess($AppId, "Set $($resolved.Count) dependency relationship(s)")) {
        $n = Set-Win32ToolkitAppRelationships -AppId $AppId -Dependency $resolved -BaseUri $baseUri
        if ($n -gt 0) {
            Write-Host "✓ Attached $n dependency(ies): $(($resolved | ForEach-Object { $_.Ref }) -join ', ')" -ForegroundColor Green
        }
        else {
            Write-Host '✓ App now has no dependencies (existing supersedence was preserved).' -ForegroundColor Green
        }
        Write-Host "  https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$AppId" -ForegroundColor DarkGray
        return $n
    }
    return $resolved.Count
}
