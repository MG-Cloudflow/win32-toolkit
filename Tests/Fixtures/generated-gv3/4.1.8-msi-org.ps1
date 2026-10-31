<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- The script is provided as a template to perform an install, uninstall, or repair of an application(s).
- The script either performs an "Install", "Uninstall", or "Repair" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

.PARAMETER DeploymentType
The type of deployment to perform.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs), NonInteractive (dialogs without prompts) mode, or Auto (shows dialogs if a user is logged on, device is not in the OOBE, and there's no running apps to close).

Silent mode is automatically set if it is detected that the process is not user interactive, no users are logged on, the device is in Autopilot mode, or there's specified processes to close that are currently running.

.PARAMETER SuppressRebootPassThru
Suppresses the 3010 return code (requires restart) from being passed back to the parent process (e.g. SCCM) if detected from an installation. If 3010 is passed back to SCCM, a reboot prompt will be triggered.

.PARAMETER TerminalServerMode
Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Desktop Session Hosts/Citrix servers.

.PARAMETER DisableLogging
Disables logging to file for the script.

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1 -DeployMode Silent

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall

.EXAMPLE
Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent

.INPUTS
None. You cannot pipe objects to this script.

.OUTPUTS
None. This script does not generate any output.

.NOTES
Toolkit Exit Code Ranges:
- 60000 - 68999: Reserved for built-in exit codes in Invoke-AppDeployToolkit.ps1, and Invoke-AppDeployToolkit.exe
- 69000 - 69999: Recommended for user customized exit codes in Invoke-AppDeployToolkit.ps1
- 70000 - 79999: Recommended for user customized exit codes in PSAppDeployToolkit.Extensions module.

.LINK
https://psappdeploytoolkit.com

#>

[CmdletBinding()]
param
(
    # Default is 'Install'.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    # Default is 'Auto'. Don't hard-code this unless required.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)


##================================================
## MARK: Variables
##================================================

# Zero-Config MSI support is provided when "AppName" is null or empty.
# By setting the "AppName" property, Zero-Config MSI will be disabled.
## win32-toolkit:Session:loader (begin) - managed by win32-toolkit; regenerated, do not edit inside
## win32-toolkit generator 3; extension PSAppDeployToolkit.Win32Toolkit 1.1.0
# Data-driven deployment values (win32-toolkit): read app-specific settings as DATA.
$appConfig = if (Test-Path -LiteralPath "$PSScriptRoot\SupportFiles\AppConfig.json") {
    # -Encoding UTF8: AppConfig.json is BOM-less UTF-8 and this runs under Windows PowerShell 5.1 on the
    # device, whose Get-Content default decodes a BOM-less file as ANSI. 5.1's -Encoding UTF8 reader handles
    # both BOM and BOM-less input.
    Get-Content -LiteralPath "$PSScriptRoot\SupportFiles\AppConfig.json" -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    [pscustomobject]@{ App = [pscustomobject]@{}; Installer = $null; Uninstall = $null; ProcessesToClose = @() }
}
# Tattoo gate: the Install phase sets this to $true as its LAST statement; Post-Install writes the detection
# tattoo only when it is $true. Initialised here because the script runs under Set-StrictMode -Version 1.
$w32tInstallDone = $false
## win32-toolkit:Session:loader (end)
$adtSession = @{
    # App variables.
    AppVendor = $appConfig.App.Vendor
    AppName = $appConfig.App.Name
    AppVersion = $appConfig.App.Version
    AppArch = $appConfig.App.Arch
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @($appConfig.ProcessesToClose | Where-Object { $_ })  # Example: @('excel', @{ Name = 'winword'; Description = 'Microsoft Word' })
    AppScriptVersion = '1.0.0'
    AppScriptDate = $appConfig.App.ScriptDate
    AppScriptAuthor = $appConfig.App.ScriptAuthor
    RequireAdmin = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName = ''
    InstallTitle = ''

    # Script variables.
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
    ExitWithMsiCodes = $true
}

function Install-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## <Perform Pre-Installation tasks here>
    ## win32-toolkit:Pre-Install:prior-check (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## remove-prior catalog revision 3 (win32-toolkit): the exact prior installs in SupportFiles\AppConfig.json (PriorInstalls), checked before any dialog; nothing is removed here.
    PSAppDeployToolkit.Win32Toolkit\Assert-W32TPriorInstall -AppConfig $appConfig
    ## win32-toolkit:Pre-Install:prior-check (end)
    ## win32-toolkit:Pre-Install:org-ui (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Org template dialogs - policy is DATA in SupportFiles\AppConfig.json (OrgUi); nothing is spliced here.
    PSAppDeployToolkit.Win32Toolkit\Show-W32TInstallWelcome -AppConfig $appConfig
    ## win32-toolkit:Pre-Install:org-ui (end)
    ## win32-toolkit:Pre-Install:hook (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Org hook Pre-Install: runs SupportFiles\OrgHooks\PreInstall.ps1 when present (edit that file, not this block).
    $orgHookScript = Join-Path -Path $adtSession.DirSupportFiles -ChildPath 'OrgHooks\PreInstall.ps1'
    if (Test-Path -LiteralPath $orgHookScript) {
        try { . $orgHookScript }
        catch { Write-ADTLogEntry -Message "Org hook PreInstall.ps1 failed (continuing): $($_.Exception.Message)" -Severity 2 }
    }
    ## win32-toolkit:Pre-Install:hook (end)
    ## win32-toolkit:Pre-Install:remove-prior (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## remove-prior: removes only what prior-check planned in this deployment, after the close-apps dialog, by the toolkit extension module.
    PSAppDeployToolkit.Win32Toolkit\Remove-W32TPriorInstall -AppConfig $appConfig
    ## win32-toolkit:Pre-Install:remove-prior (end)


    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Handle Zero-Config MSI installations.
    if ($adtSession.UseDefaultMsi)
    {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile)
        {
            $ExecuteDefaultMSISplat.Add('Transforms', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
        if ($adtSession.DefaultMspFiles)
        {
            $adtSession.DefaultMspFiles | Start-ADTMsiProcess -Action Patch
        }
    }

    ## <Perform Installation tasks here>
    ## win32-toolkit:Install:install-done (begin) - managed by win32-toolkit; regenerated, do not edit inside
    $w32tInstallDone = $true
    ## win32-toolkit:Install:install-done (end)


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Installation tasks here>
    ## win32-toolkit:Post-Install:hook (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Org hook Post-Install: runs SupportFiles\OrgHooks\PostInstall.ps1 when present (edit that file, not this block).
    $orgHookScript = Join-Path -Path $adtSession.DirSupportFiles -ChildPath 'OrgHooks\PostInstall.ps1'
    if (Test-Path -LiteralPath $orgHookScript) { . $orgHookScript }
    ## win32-toolkit:Post-Install:hook (end)
    ## win32-toolkit:Post-Install:tattoo (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## win32-toolkit install tattoo - records install state + version for the Intune detection rule (only when the Install phase ran to its end).
    PSAppDeployToolkit.Win32Toolkit\Set-W32TInstallTattoo -AppConfig $appConfig -InstallDone $w32tInstallDone
    ## win32-toolkit:Post-Install:tattoo (end)
    ## win32-toolkit:Post-Install:org-ui (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Org template policy: no completion prompt after a Zero-Config MSI install (4.1.8 parity; the PSADT default prompt was removed).
    ## win32-toolkit:Post-Install:org-ui (end)


}

function Uninstall-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## <Perform Pre-Uninstallation tasks here>
    ## win32-toolkit:Pre-Uninstall:org-ui (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Org template dialogs - policy is DATA in SupportFiles\AppConfig.json (OrgUi); nothing is spliced here.
    PSAppDeployToolkit.Win32Toolkit\Show-W32TMaintenanceWelcome -AppConfig $appConfig
    ## win32-toolkit:Pre-Uninstall:org-ui (end)


    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Handle Zero-Config MSI uninstallations.
    if ($adtSession.UseDefaultMsi)
    {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile)
        {
            $ExecuteDefaultMSISplat.Add('Transforms', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
    }

    ## <Perform Uninstallation tasks here>


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Uninstallation tasks here>
    ## win32-toolkit:Post-Uninstall:tattoo (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## win32-toolkit install tattoo - removed at uninstall, with its legacy WOW6432Node copy.
    PSAppDeployToolkit.Win32Toolkit\Remove-W32TInstallTattoo -AppConfig $appConfig
    ## win32-toolkit:Post-Uninstall:tattoo (end)
}

function Repair-ADTDeployment
{
    [CmdletBinding()]
    param
    (
    )

    ##================================================
    ## MARK: Pre-Repair
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    ## <Perform Pre-Repair tasks here>
    ## win32-toolkit:Pre-Repair:org-ui (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Org template dialogs - policy is DATA in SupportFiles\AppConfig.json (OrgUi); nothing is spliced here.
    PSAppDeployToolkit.Win32Toolkit\Show-W32TMaintenanceWelcome -AppConfig $appConfig
    ## win32-toolkit:Pre-Repair:org-ui (end)


    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    ## Handle Zero-Config MSI repairs.
    if ($adtSession.UseDefaultMsi)
    {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile)
        {
            $ExecuteDefaultMSISplat.Add('Transforms', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
    }

    ## <Perform Repair tasks here>


    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Repair tasks here>
    ## win32-toolkit:Post-Repair:org-ui (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Org template policy: no completion prompt after a repair (the PSADT default prompt was removed).
    ## win32-toolkit:Post-Repair:org-ui (end)
}


##================================================
## MARK: Initialization
##================================================

# Set strict error handling across entire operation.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Import the module and instantiate a new session.
try
{
    # Import the module locally if available, otherwise try to find it from PSModulePath.
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.8' } -Force
    }

    # Open a new deployment session, replacing $adtSession with a DeploymentSession.
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

# Commence the actual deployment operation.
try
{
    # Import any found extensions before proceeding with the deployment.
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name $_.FullName -Force
            }
        }
    }

    # Invoke the deployment and close out the session.
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    # An unhandled error has been caught.
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3

    ## Error details hidden from the user by default. Show a simple dialog with full stack trace:
    # Show-ADTDialogBox -Text $mainErrorMessage -Icon Stop -NoWait

    ## Or, a themed dialog with basic error message:
    # Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) failed at line $($_.InvocationInfo.ScriptLineNumber), char $($_.InvocationInfo.OffsetInLine):`n$($_.InvocationInfo.Line.Trim())`n`nMessage:`n$($_.Exception.Message)" -ButtonRightText OK -Icon Error -NoWait

    Close-ADTSession -ExitCode 60001
}

