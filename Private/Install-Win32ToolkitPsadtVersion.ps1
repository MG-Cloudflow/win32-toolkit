function Install-Win32ToolkitPsadtVersion {
    <#
    .SYNOPSIS
        Installs one supported, stable PSAppDeployToolkit version for the current user, next to the others (the menu's
        one install call).
    .DESCRIPTION
        Menu selectors design P1, P4 (knowledge-base/designs/menu-selectors.md). Checks again, right before the call:
          * the version is a plain stable version text (no prerelease label) inside the supported range
            (Test-Win32ToolkitPsadtVersionSupported);
          * it is not installed yet (Select-Win32ToolkitPsadtModule's candidates);
          * an installed prerelease of the same number (it shares the base-version folder, so this install replaces it)
            needs -Replace, and is refused while this process has that number loaded (one PSADT per process: its files
            are in use).
        Then exactly one call:
            Install-Module -Name PSAppDeployToolkit -Repository PSGallery -RequiredVersion <v> -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        (-Force skips PowerShellGet's own prompts; the menu asked first). Never Update-Module, Uninstall-Module,
        -AllowPrerelease, Import-Module or Remove-Module: the selection of new projects is saved separately
        (Set-Win32ToolkitPsadtPreference). A refused version throws W32T.PsadtInstallRefused (nothing installed); an
        Install-Module failure is rethrown as it is.
    .PARAMETER Version
        The version to install, as Get-Win32ToolkitPsadtGalleryVersion listed it (for example '4.2.1').
    .PARAMETER Replace
        Allow replacing an installed prerelease of the same number (the screen's "Replace" choice).
    .OUTPUTS
        [pscustomobject] The Select-Win32ToolkitPsadtModule result after the install ($null under -WhatIf).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Version,

        [switch]$Replace
    )

    $text = $Version.Trim()
    $safe = ConvertTo-Win32ToolkitSafeText -Text $text -MaxLength 40
    $refuse = {
        param([string]$Why)
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("PSAppDeployToolkit $safe was not installed: $Why"),
            'W32T.PsadtInstallRefused', [System.Management.Automation.ErrorCategory]::InvalidOperation, $safe)
    }

    if ($text -notmatch '^\d{1,9}\.\d{1,9}\.\d{1,9}(\.\d{1,9})?$') { & $refuse 'only a stable version number such as 4.2.1 can be installed from the menu.' }
    $ver = [version]$text
    if (-not (Test-Win32ToolkitPsadtVersionSupported -Version $ver)) {
        & $refuse "this win32-toolkit version supports $($script:PsadtSupportedRange.Display) only."
    }

    $sel = Select-Win32ToolkitPsadtModule
    $candidates = @(@($sel.Candidates) | Where-Object { $null -ne $_ })
    if (@($candidates | Where-Object { [string]::Equals([string]$_.VersionText, $text, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        & $refuse 'it is already installed.'
    }
    $same = @($candidates | Where-Object { ([string]$_.VersionText -replace '[-+].*$', '') -eq $text })
    if ($same.Count -gt 0) {
        $names = ($same | ForEach-Object { [string]$_.VersionText }) -join ', '
        if (-not $Replace) { & $refuse "it would replace the installed $names (the same folder). Choose the Replace item to do that on purpose." }
        $loaded = @(Get-Module -Name PSAppDeployToolkit -All | Where-Object { $_.ModuleBase -and [version]$_.Version -eq $ver })
        if ($loaded.Count -gt 0) {
            & $refuse "this PowerShell session has PSAppDeployToolkit $names loaded, and its files are in use. Start a new PowerShell session first."
        }
    }

    if (-not $PSCmdlet.ShouldProcess('PSAppDeployToolkit', "Install-Module -RequiredVersion $text -Scope CurrentUser")) { return $null }
    Install-Module -Name PSAppDeployToolkit -Repository PSGallery -RequiredVersion $text -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    return (Select-Win32ToolkitPsadtModule)
}
