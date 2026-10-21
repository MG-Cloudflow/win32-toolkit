function Set-Win32ToolkitAppDependency {
    <#
    .SYNOPSIS
        Declares which apps must be installed BEFORE this one (Intune app dependencies).
    .DESCRIPTION
        Writes the `Dependencies` section of the project's SupportFiles\AppConfig.json. At publish time each
        declaration is resolved to a real Intune app id and attached to the published app as a
        `mobileAppDependency` relationship, so the Intune Management Extension installs the dependency FIRST
        (the classic case: a Visual C++ redistributable).

        Dependencies are stored as DATA (winget id / project name / Intune app id) and are never spliced
        into a generated script. Nothing is installed or published by this command — it only declares.

        Because Intune honours the DEPENDENCY app's own detection rule, an already-present dependency is
        skipped on the device automatically; there is no separate "skip if installed" setting.

        NOTE: a dependency must exist in the tenant as a published Win32 app before the relationship can be
        created. If it does not, publishing warns and continues (the app still publishes, just without that
        relationship) — package and publish the dependency, then re-publish this app to attach it.
    .PARAMETER ProjectPath
        The PSADT project that HAS the dependencies.
    .PARAMETER DependsOn
        One or more references. Accepts 'winget:<id>', 'project:<Template>\<Name>', 'intune:<guid>', or a
        bare string (a GUID -> intune, one containing '\' -> project, otherwise winget).
    .PARAMETER DependencyType
        'autoInstall' (default) installs the dependency first. 'detect' ONLY detects it — if it is absent
        the parent install is NOT attempted at all, so use it deliberately.
    .PARAMETER Clear
        Remove all declared dependencies (alone, or before adding the supplied set).
    .OUTPUTS
        PSCustomObject[] — the normalized dependency list now stored in AppConfig.json.
    .EXAMPLE
        Set-Win32ToolkitAppDependency -ProjectPath $p -DependsOn 'winget:Microsoft.VCRedist.2015+.x64'
    .EXAMPLE
        Set-Win32ToolkitAppDependency -ProjectPath $p -DependsOn 'project:Contoso\VCRedist_x64_14.38'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [string[]]$DependsOn,

        [ValidateSet('autoInstall', 'detect')]
        [string]$DependencyType = 'autoInstall',

        [switch]$Clear
    )

    if (-not (Test-Path -LiteralPath $ProjectPath)) { throw "Project not found: $ProjectPath" }
    if (-not $Clear -and -not $DependsOn) {
        throw 'Supply -DependsOn with at least one reference, or -Clear to remove all dependencies.'
    }

    # This project's own 'project:' identity — an app cannot depend on itself (Intune rejects it too). Compared as
    # a normalized full path too, so another spelling of the same folder (a short 8.3 name) is caught as well.
    $self         = '{0}\{1}' -f (Split-Path -Leaf (Split-Path -Parent $ProjectPath)), (Split-Path -Leaf $ProjectPath)
    $selfFull     = [System.IO.Path]::GetFullPath($PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath)).TrimEnd('\')
    $projectsRoot = Split-Path -Parent (Split-Path -Parent $selfFull)

    $existing = if ($Clear) { @() } else { @(Get-Win32ToolkitDependencies -ProjectPath $ProjectPath) }

    $added = @()
    foreach ($r in @($DependsOn)) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $parsed = ConvertTo-Win32ToolkitDependencyRef -Reference $r -DependencyType $DependencyType
        if ($parsed.Source -eq 'project') {
            # Exactly '<Template>\<ProjectName>' under Projects\: a rooted path, '..' or a third segment would be
            # joined onto Projects\ and resolve outside it when staged (test campaign 2026-10-21, S11-F5).
            $ref   = [string]$parsed.Ref
            $parts = @($ref -split '\\')
            # A segment ending in '.' or ' ' is refused too: Windows drops it, so 'T.\App' or 'T\App.' names the
            # folder 'T\App' (re-verification 2026-10-21, B3 #2: a dotted self-reference got through).
            $bad   = @($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..' -or $_ -match '[. ]$' -or $_.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 })
            if ($parts.Count -ne 2 -or $bad.Count -gt 0 -or [System.IO.Path]::IsPathRooted($ref)) {
                throw "Dependency 'project:$ref' must be '<Template>\<ProjectName>' under Projects\ (not a full path or '..')."
            }
            $refFull = [System.IO.Path]::GetFullPath((Join-Path $projectsRoot $ref)).TrimEnd('\')
            if ($ref -eq $self -or $refFull.Equals($selfFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "An app cannot depend on itself ('$self')."
            }
            # Declaring a dependency before it is packaged is legitimate: only warn (fail-open check).
            try {
                if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $projectsRoot $ref) 'Invoke-AppDeployToolkit.ps1'))) {
                    Write-Warning "Dependency 'project:$ref' is not packaged yet (no Invoke-AppDeployToolkit.ps1 under $projectsRoot): a test or capture of this app stops until it is."
                }
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Could not check whether 'project:$ref' is packaged: $($_.Exception.Message)"
            }
        }
        $added += $parsed
    }

    # Upsert by Source+Ref (the new DependencyType wins on collision), preserving declaration order.
    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($existing) + @($added)) {
        $dup = $merged | Where-Object { $_.Source -eq $d.Source -and $_.Ref -eq $d.Ref } | Select-Object -First 1
        if ($dup) { $dup.DependencyType = $d.DependencyType; continue }
        $merged.Add([pscustomobject]@{ Source = $d.Source; Ref = $d.Ref; DependencyType = $d.DependencyType })
    }

    if ($PSCmdlet.ShouldProcess($ProjectPath, "Set $($merged.Count) app dependency(ies)")) {
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $cfg | Add-Member -NotePropertyName 'Dependencies' -NotePropertyValue @($merged) -Force
        $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg
    }

    return @($merged)
}
