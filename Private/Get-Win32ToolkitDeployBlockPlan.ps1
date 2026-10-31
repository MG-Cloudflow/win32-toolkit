function Get-Win32ToolkitDeployBlockPlan {
    <#
    .SYNOPSIS
        The toolkit blocks a project's deploy script gets (GeneratorVersion 3): one row per block, from the template
        shape, the installer type, manual or not, and the phases that have an org hook file. Pure.
    .DESCRIPTION
        The single answer to "which toolkit blocks does this project need" (lean deploy script design, section 4.3).
        Set-PSADTDataDrivenScript places the 'Generator' rows, Apply-OrgTemplate the 'OrgUi' rows and
        Add-Win32ToolkitOrgHooks the 'Hook' rows; Test-Win32ToolkitDeployExtension compares a script with it at Finalize
        and Export (PLAN-MISMATCH). Everything added after the build - capture data, prior-install rules, dependencies -
        is data the calls read at run time, so it is no input here:

          * always: the loader, the prior-install pair (rules are data added later, D12), install-done, both tattoos, and
            the org-ui blocks (the org template is mandatory; prior-check < org-ui < remove-prior is PriorCheckFirst);
          * msp: PSADT 4.2 Zero-Config and an MSI only (4.2's Zero-Config block no longer applies .msp files);
          * install: EXE (-Technology Exe) and MSIX/APPX (-Technology Appx), never for an MSI (PSADT's Zero-Config block
            installs it) and never for a manual app (manual-install instead);
          * uninstall: every type but MSI (an MSI project never gets an Uninstall section; Zero-Config uninstalls it);
          * Post-Install org-ui: the completion prompt, or for an MSI a comment-only block (no prompt after a Zero-Config
            install, 4.1.8 parity);
          * hook: only for the phases in -HookPhases.

        An installer type with no row (anything but msi, exe, msix, appx) throws W32T.UnsupportedInstallerType: a new
        technology needs its rows on purpose.
    .PARAMETER Shape
        The template shape (Get-Win32ToolkitDeployScriptShape): Psadt41 or Psadt42ZeroConfig.
    .PARAMETER InstallerType
        AppConfig.json Installer.Type: msi, exe, msix or appx (case-insensitive).
    .PARAMETER ManualInstall
        A manual app: the manual-install note instead of the install call.
    .PARAMETER HookPhases
        The phases that have an org hook file (Pre-Install, Post-Install, Pre-Uninstall, Post-Uninstall, Pre-Repair,
        Post-Repair).
    .OUTPUTS
        [pscustomobject] Phase, Slot, Block (the Get-Win32ToolkitDeployScriptBlock name), Technology ('' or Exe / Appx),
        Owner (Generator, OrgUi, Hook), in phase order and slot order.
    .EXAMPLE
        Get-Win32ToolkitDeployBlockPlan -Shape Psadt42ZeroConfig -InstallerType exe
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Psadt41', 'Psadt42ZeroConfig')]
        [string]$Shape,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$InstallerType,

        [switch]$ManualInstall,

        [ValidateSet('Pre-Install', 'Post-Install', 'Pre-Uninstall', 'Post-Uninstall', 'Pre-Repair', 'Post-Repair')]
        [string[]]$HookPhases = @()
    )

    $type = ([string]$InstallerType).Trim().ToLowerInvariant()
    if ($type -notin @('msi', 'exe', 'msix', 'appx')) {
        $shown = ConvertTo-Win32ToolkitSafeText -Text $InstallerType -MaxLength 40
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("win32-toolkit has no deploy-script blocks for the installer type '$shown' (SupportFiles\AppConfig.json Installer.Type; known: msi, exe, msix, appx). Re-create the project with a supported installer. Nothing was changed."),
            'W32T.UnsupportedInstallerType', [System.Management.Automation.ErrorCategory]::InvalidData, $InstallerType)
    }
    $isMsi = $type -eq 'msi'
    $technology = if ($type -eq 'exe') { 'Exe' } elseif ($isMsi) { '' } else { 'Appx' }
    $rows = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Phase, [string]$Slot, [string]$Block, [string]$Owner, [string]$Tech = '')
        $rows.Add([pscustomobject]@{ Phase = $Phase; Slot = $Slot; Block = $Block; Technology = $Tech; Owner = $Owner })
    }
    $hookPhaseList = @($HookPhases)
    $hook = { param([string]$Phase) if ($hookPhaseList -contains $Phase) { & $add $Phase 'hook' 'Hook' 'Hook' } }

    & $add 'Session' 'loader' 'Loader' 'Generator'
    & $add 'Pre-Install' 'prior-check' 'RemovePriorCheck' 'Generator'
    & $add 'Pre-Install' 'org-ui' 'OrgUiPreInstall' 'OrgUi'
    & $hook 'Pre-Install'
    & $add 'Pre-Install' 'remove-prior' 'RemovePrior' 'Generator'
    if ($Shape -eq 'Psadt42ZeroConfig' -and $isMsi) { & $add 'Install' 'msp' 'Msp' 'Generator' }
    if ($ManualInstall) { & $add 'Install' 'manual-install' 'ManualInstall' 'Generator' }
    elseif (-not $isMsi) { & $add 'Install' 'install' 'Install' 'Generator' $technology }
    & $add 'Install' 'install-done' 'InstallDone' 'Generator'
    & $hook 'Post-Install'
    & $add 'Post-Install' 'tattoo' 'TattooInstall' 'Generator'
    & $add 'Post-Install' 'org-ui' $(if ($isMsi) { 'OrgUiPostInstallMsi' } else { 'OrgUiPostInstall' }) 'OrgUi'
    & $add 'Pre-Uninstall' 'org-ui' 'OrgUiPreMaintenance' 'OrgUi'
    & $hook 'Pre-Uninstall'
    if (-not $isMsi) { & $add 'Uninstall' 'uninstall' 'Uninstall' 'Generator' }
    & $hook 'Post-Uninstall'
    & $add 'Post-Uninstall' 'tattoo' 'TattooUninstall' 'Generator'
    & $add 'Pre-Repair' 'org-ui' 'OrgUiPreMaintenance' 'OrgUi'
    & $hook 'Pre-Repair'
    & $hook 'Post-Repair'
    & $add 'Post-Repair' 'org-ui' 'OrgUiPostRepair' 'OrgUi'
    $rows.ToArray()
}
