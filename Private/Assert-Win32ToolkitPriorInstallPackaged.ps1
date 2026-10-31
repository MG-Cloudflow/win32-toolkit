function Assert-Win32ToolkitPriorInstallPackaged {
    <#
    .SYNOPSIS
        Refuses to publish a package whose prior-install rules are not the project's current ones.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.11 Publish, L40). Export checks the prior-install rules (PRIOR-PROOF and the
        other rows of Get-Win32ToolkitPriorInstallFinding) and packages the Staging copy; a rule changed after that
        Export (a mode set to Enforce, a re-capture that moved OwnIdentity) would ship rules nobody checked. So, when the
        project's SupportFiles\AppConfig.json or its Staging copy has prior-install entries, the Staging copy must exist
        and both must have the same binding hash (Get-Win32ToolkitPriorInstallHash -Kind Binding: the entries, the own
        identity, App.Version, App.ScriptAuthor, Installer.Type and FileName). Otherwise: W32T.PackageNotReady
        "Prior install: ... re-export". No entries on either side: nothing is checked.

        The Staging copy is found from the .intunewin (<BasePath>\IntuneWin\<Template>\<App>.intunewin ->
        <BasePath>\Staging\<Template>\<ProjectName>), else from the project (<BasePath>\Projects\<Template>\<App>).
        Pure read; needs no sign-in (Publish runs it before the -WhatIf gate).
    .PARAMETER ProjectPath
        The PSADT project folder being published.
    .PARAMETER IntuneWinPath
        The .intunewin being published.
    .OUTPUTS
        [string] the Staging copy that was compared ('' when nothing was checked).
    .EXAMPLE
        $null = Assert-Win32ToolkitPriorInstallPackaged -ProjectPath $proj -IntuneWinPath $win
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IntuneWinPath
    )

    $count = {
        param($Config)
        if ($null -eq $Config -or -not $Config.PSObject.Properties['PriorInstalls'] -or $null -eq $Config.PriorInstalls -or -not $Config.PriorInstalls.PSObject.Properties['Entries']) { return 0 }
        @(@($Config.PriorInstalls.Entries) | Where-Object { $null -ne $_ }).Count
    }
    $refuse = {
        param([string]$Message)
        throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($Message), 'W32T.PackageNotReady',
            [System.Management.Automation.ErrorCategory]::InvalidData, $ProjectPath)
    }

    $project = $ProjectPath.TrimEnd('\')
    try { $project = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ProjectPath).TrimEnd('\') }
    catch { Write-Verbose "ProjectPath not resolved ($($_.Exception.Message)); used as given." }
    $intuneWin = $IntuneWinPath
    try { $intuneWin = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($IntuneWinPath) }
    catch { Write-Verbose "IntuneWinPath not resolved ($($_.Exception.Message)); used as given." }
    $projectName = Split-Path -Path $project -Leaf

    $candidates = [System.Collections.Generic.List[string]]::new()
    $iwTemplateDir = Split-Path -Path $intuneWin -Parent
    $iwTier = if ($iwTemplateDir) { Split-Path -Path $iwTemplateDir -Parent } else { '' }
    $iwBase = if ($iwTier) { Split-Path -Path $iwTier -Parent } else { '' }
    if ($iwBase) {
        $paths = Get-Win32ToolkitPaths -BasePath $iwBase
        if ([string]::Equals($paths.IntuneWin.TrimEnd('\'), $iwTier.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            $candidates.Add((Join-Path (Join-Path $paths.Staging (Split-Path -Path $iwTemplateDir -Leaf)) $projectName))
        }
    }
    $templateDir = Split-Path -Path $project -Parent
    $projectsTier = if ($templateDir) { Split-Path -Path $templateDir -Parent } else { '' }
    $projectBase = if ($projectsTier) { Split-Path -Path $projectsTier -Parent } else { '' }
    if ($projectBase) {
        $paths = Get-Win32ToolkitPaths -BasePath $projectBase
        if ([string]::Equals($paths.Projects.TrimEnd('\'), $projectsTier.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            $candidates.Add((Join-Path (Join-Path $paths.Staging (Split-Path -Path $templateDir -Leaf)) $projectName))
        }
    }

    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $project
    $staging = @($candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'SupportFiles\AppConfig.json') -PathType Leaf }) | Select-Object -First 1
    $stageCfg = $null
    if ($staging) {
        try { $stageCfg = Get-Content -LiteralPath (Join-Path $staging 'SupportFiles\AppConfig.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            $stageCfg = $null
        }
    }
    if ((& $count $cfg) -eq 0 -and (& $count $stageCfg) -eq 0) { return '' }
    $reexport = "Re-export the project (Export-Win32ToolkitIntuneWin -ProjectPath '$project') and publish the new .intunewin. Nothing was published."
    if ($null -eq $stageCfg) {
        & $refuse "Prior install: this project has prior-install rules, but the Staging copy the .intunewin was built from is missing or unreadable ($(if ($candidates.Count) { $candidates -join ' or ' } else { 'no Staging folder for this layout' })), so nothing proves the package carries them. $reexport"
    }
    if ((Get-Win32ToolkitPriorInstallHash -Config $cfg -Kind Binding) -cne (Get-Win32ToolkitPriorInstallHash -Config $stageCfg -Kind Binding)) {
        & $refuse "Prior install: the prior-install rules changed after Export (the Staging copy '$staging' holds others, or the package's own identity or version changed): the .intunewin does not carry the rules that were checked. $reexport"
    }
    return [string]$staging
}
