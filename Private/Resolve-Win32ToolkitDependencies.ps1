function Resolve-Win32ToolkitDependencies {
    <#
    .SYNOPSIS
        Turns a project's declared dependencies into real Intune app ids, ready to be related.
    .DESCRIPTION
        A mobileAppDependency can only point at an app that ALREADY EXISTS in the tenant, by id. Each
        declaration is resolved:

          intune:<guid>              -> used as-is.
          project:<Template>\<Name>  -> that project's publication cache (Intune\Publications.json), else a
                                        tenant search by its display name.
          winget:<id>                -> a tenant search for the app the toolkit stamped with that winget id
                                        (notes = 'win32-toolkit; <id>').

        Resolution is VERSION-AGNOSTIC by design: any published version of the dependency satisfies it.
        Pinning a version would invalidate the dependency of every dependent app each time the dependency
        is repackaged.

        NOT FOUND IS NOT FATAL. The dependency is simply not in the tenant yet — we warn (naming it and
        what to do), skip it, and let the app publish. Nothing is auto-published: publishing app X must
        never silently create other apps in the tenant as a side effect.
    .PARAMETER ProjectPath
        The project whose dependencies are being resolved.
    .PARAMETER TenantId
        Tenant, used to select the right publication-cache entry.
    .PARAMETER BaseUri
        Graph base.
    .OUTPUTS
        PSCustomObject[]: TargetId, DependencyType, Ref (for messages). Empty when nothing resolved.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [string]$TenantId = 'unknown',
        [string]$BaseUri  = 'https://graph.microsoft.com/beta/deviceAppManagement'
    )

    $declared = @(Get-Win32ToolkitDependencies -ProjectPath $ProjectPath)
    if ($declared.Count -eq 0) { return @() }

    $resolved = [System.Collections.Generic.List[object]]::new()

    foreach ($d in $declared) {
        $id  = $null
        $how = $null

        switch ($d.Source) {

            'intune' { $id = $d.Ref; $how = 'explicit app id' }

            'project' {
                $projects = (Get-Win32ToolkitPaths -BasePath (Get-Win32ToolkitBasePath)).Projects
                $depPath  = Join-Path $projects $d.Ref

                $cached = @(Get-Win32ToolkitPublication -ProjectPath $depPath -TenantId $TenantId)
                if ($cached.Count -gt 0 -and $cached[0].AppId) {
                    $id  = $cached[0].AppId
                    $how = 'publication cache'
                }
                else {
                    # Not published from here (or a different machine) — fall back to the tenant, matching
                    # the display name the dependency project would publish under.
                    $name = $null
                    if (Test-Path -LiteralPath $depPath) {
                        $cfg  = Get-Win32ToolkitAppConfig -ProjectPath $depPath
                        $app  = if ($cfg.PSObject.Properties.Name -contains 'App') { $cfg.App } else { $null }
                        $name = if ($app -and $app.Name) { $app.Name }
                                elseif ($app -and $app.DisplayName) { $app.DisplayName }
                                else { Split-Path -Leaf $d.Ref }
                    }
                    if ($name) {
                        $hits = @(Find-Win32ToolkitIntuneApp -DisplayName $name -BaseUri $BaseUri)
                        if ($hits.Count -eq 1) { $id = $hits[0].Id; $how = "tenant search '$name'" }
                        elseif ($hits.Count -gt 1) {
                            Write-Warning "Dependency 'project:$($d.Ref)' matched $($hits.Count) apps named '$name' in the tenant — refusing to guess. Declare it explicitly as 'intune:<app id>'."
                            continue
                        }
                    }
                }
            }

            'winget' {
                $hits = @(Find-Win32ToolkitIntuneApp -WingetId $d.Ref -BaseUri $BaseUri)
                if ($hits.Count -eq 1) { $id = $hits[0].Id; $how = "tenant search (winget id)" }
                elseif ($hits.Count -gt 1) {
                    Write-Warning "Dependency 'winget:$($d.Ref)' matched $($hits.Count) apps in the tenant — refusing to guess. Declare it explicitly as 'intune:<app id>'."
                    continue
                }
            }
        }

        if ($id) {
            Write-Host "  Dependency resolved: $($d.Source):$($d.Ref) -> $id  [$how]" -ForegroundColor Gray
            $resolved.Add([pscustomobject]@{
                TargetId       = $id
                DependencyType = $d.DependencyType
                Ref            = "$($d.Source):$($d.Ref)"
            })
        }
        else {
            # Chosen behaviour: publish anyway, but say clearly what is missing and how to fix it.
            Write-Warning @"
Dependency '$($d.Source):$($d.Ref)' is NOT published in this Intune tenant, so it cannot be linked.
This app WILL still publish — but WITHOUT that dependency, so Intune will not install it first.
To fix: package and publish the dependency as its own app, then re-publish this one to attach it.
"@
        }
    }

    return @($resolved)
}
