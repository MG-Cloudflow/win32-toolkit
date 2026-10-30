function Assert-Win32ToolkitDeployExtensionPackaged {
    <#
    .SYNOPSIS
        Publish's check that the .intunewin carries the project's own copy of win32-toolkit's PSADT extension module.
    .DESCRIPTION
        Lean deploy script PR 2 (design section 4.7). Export checks the project's extension folder (the package gate) and,
        after the clean-up, that the Staging copy it packages still holds the same bytes. Publish uploads that .intunewin:
        this checks again, before anything is signed in or uploaded, that the Staging copy it was built from still matches
        the project (the same project-vs-Staging comparison Assert-Win32ToolkitPriorInstallPackaged makes for the rules).

        Applies to a project that has the toolkit folder (Export already refused a GeneratorVersion 3 project without it);
        others return ''. A folder comparison only: the deploy script is not read here. The
        Staging copy is found as Assert-Win32ToolkitPriorInstallPackaged finds it: from the .intunewin
        (<BasePath>\IntuneWin\<Template>\<App>.intunewin -> <BasePath>\Staging\<Template>\<ProjectName>), else from the
        project (<BasePath>\Projects\<Template>\<App>). No Staging copy, or one whose extension differs:
        W32T.PackageNotReady ("export again").
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER IntuneWinPath
        The .intunewin being published.
    .OUTPUTS
        [string] the Staging copy that was compared ('' when nothing was checked).
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

    $name = (Get-Win32ToolkitDeployExtension).Name
    if (-not (Test-Path -LiteralPath (Join-Path $project $name) -PathType Container)) { return '' }

    # The Staging candidates (the same rule as Assert-Win32ToolkitPriorInstallPackaged).
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
    $reexport = "Export the project again (Export-Win32ToolkitIntuneWin -ProjectPath '$project') and publish the new .intunewin. Nothing was published."
    $staging = @($candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'Invoke-AppDeployToolkit.ps1') -PathType Leaf }) | Select-Object -First 1
    if (-not $staging) {
        & $refuse "Deploy extension: the Staging copy the .intunewin was built from is missing ($(if ($candidates.Count) { $candidates -join ' or ' } else { 'no Staging folder for this layout' })), so nothing proves the package carries this project's copy of win32-toolkit's PSADT extension module. $reexport"
    }
    # A neutral shape: only the folder comparison (EXTENSION-STAGING) matters here.
    $staged = @(Test-Win32ToolkitDeployExtension -ProjectPath $project -Shape ([pscustomobject]@{ GeneratorVersion = $null }) -StagingPath $staging | Where-Object { $_.Code -eq 'EXTENSION-STAGING' })
    if ($staged.Count -gt 0) { & $refuse "Deploy extension: $($staged[0].Message) $reexport" }
    return [string]$staging
}
