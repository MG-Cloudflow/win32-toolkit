function Set-Win32ToolkitAppDependency {
    <#
    .SYNOPSIS
        Sets the apps that Intune must install before this app.
    .DESCRIPTION
        Set-Win32ToolkitAppDependency saves the dependencies of a project: the apps that Intune
        must install before this app, for example the Visual C++ redistributable. New references
        are added to the list that the project already has. The command changes only
        SupportFiles\AppConfig.json in the project: it installs nothing and changes nothing in
        Intune.

        The install capture and the tests install winget and project dependencies first on the
        test machine. When you publish, the toolkit links each dependency to the new install app.
        The dependency must already be published in the same tenant, or the app is published
        without it, with a warning. A winget reference finds only an app that the toolkit
        published from winget. Intune uses the detection rule of each dependency, so a device that
        already has it does not install it again.

        After a change, run Complete-Win32ToolkitManualApp so that the install capture uses the
        new list. For an app that is already in Intune, also run Sync-Win32ToolkitAppDependency.
        Do not publish the app again: that creates a new app. In the menu: Work with an existing
        project > Dependencies.

        It stops with the error W32T.InvalidDependencyReference, and writes nothing, when a
        reference is wrong or names this project itself.
    .PARAMETER ProjectPath
        The project that needs the dependencies, for example
        <base folder>\Projects\<template>\<project>.
    .PARAMETER DependsOn
        One or more references: 'winget:<id>', 'project:<template>\<project>' or
        'intune:<app ID>'. Without a prefix, a GUID counts as intune, text with a backslash as
        project, and anything else as winget. Use intune for an app that the toolkit did not
        publish. The test machine cannot install an intune dependency. Needed unless you use
        the -Clear switch.
    .PARAMETER DependencyType
        How Intune treats the references of this call. Default: autoInstall (Intune installs the
        dependency first). With detect, Intune only checks that the dependency is there and does
        not install this app when it is missing. Command line only: saving in the menu sets every
        dependency back to autoInstall.
    .PARAMETER Clear
        Removes all dependencies. With -DependsOn, it replaces the whole list with the new
        references. There is no option to remove one dependency: use -Clear with -DependsOn and
        give the ones to keep.
    .EXAMPLE
        $project = 'C:\Win32Apps\Projects\Contoso\Contoso_Reader_x64_3.2.0'   # your project folder
        $vcredist = 'winget:Microsoft.VCRedist.2015+.x64'
        Set-Win32ToolkitAppDependency -ProjectPath $project -DependsOn $vcredist

        This adds the Visual C++ redistributable from winget to the project. The install capture
        and the tests now install it first. If the app is already in Intune, also run
        Sync-Win32ToolkitAppDependency.
    .EXAMPLE
        Set-Win32ToolkitAppDependency -ProjectPath $project -Clear -DependsOn $vcredist

        This replaces the whole list with the Visual C++ redistributable ($project and $vcredist as
        in the first example). Use this form to remove one dependency.
    .EXAMPLE
        Set-Win32ToolkitAppDependency -ProjectPath $project -Clear
        Sync-Win32ToolkitAppDependency -ProjectPath $project

        This removes all dependencies from the project, then from its app in Intune ($project as
        in the first example). Supersedence in Intune is kept.
    .EXAMPLE
        $git = 'project:Contoso\Git_x64_2.53.0'
        Set-Win32ToolkitAppDependency -ProjectPath $project -DependsOn $git -DependencyType detect

        This adds Git, packaged with the toolkit, as a dependency that Intune only checks. Intune
        installs Contoso Reader only on devices that already have Git.
    .OUTPUTS
        The full list of dependencies that the project now has, with Source, Ref and DependencyType.
        With -WhatIf, the list that would be saved.
    .LINK
        https://win32toolkit.com/reference/Set-Win32ToolkitAppDependency/
    .LINK
        https://win32toolkit.com/dependencies/
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
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.ArgumentException]::new('Supply -DependsOn with at least one reference, or -Clear to remove all dependencies.'),
            'W32T.InvalidDependencyReference', [System.Management.Automation.ErrorCategory]::InvalidArgument, $ProjectPath)
    }

    # Every reference is validated before anything is written: the shape ('project:' = exactly
    # '<Template>\<ProjectName>' under Projects\, an 'intune:' GUID, ...) and never this project itself (by its
    # '<Template>\<Leaf>' and its normalized full path, so an 8.3 alias too). A refusal is a terminating
    # W32T.InvalidDependencyReference (re-verification 2026-10-21, B3 r2.1: the same check the pipelines now run
    # before the download and the scaffold).
    $added = @(Assert-Win32ToolkitDependencyRef -Reference $DependsOn -DependencyType $DependencyType -ProjectPath $ProjectPath)

    $selfFull     = [System.IO.Path]::GetFullPath($PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath)).TrimEnd('\')
    $projectsRoot = Split-Path -Parent (Split-Path -Parent $selfFull)
    foreach ($parsed in @($added | Where-Object { $_.Source -eq 'project' })) {
        $ref = [string]$parsed.Ref
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

    $existing = if ($Clear) { @() } else { @(Get-Win32ToolkitDependencies -ProjectPath $ProjectPath) }

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
