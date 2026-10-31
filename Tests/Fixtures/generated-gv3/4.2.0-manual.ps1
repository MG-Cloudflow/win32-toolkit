<#

.SYNOPSIS
This script invokes a PSAppDeployToolkit deployment.

.DESCRIPTION
The script imports the PSAppDeployToolkit module and executes the specified install/uninstall/repair scriptblocks.

.PARAMETER DeploymentType
The type of deployment to perform, Install, Uninstall, or Repair. Default is Install.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs), NonInteractive (dialogs without prompts) mode, or Auto (shows dialogs if a user is logged on, device is not in the OOBE, and there's no running apps to close).

Silent mode is automatically set if no users are logged on, the device is in Autopilot mode, or there's specified processes to close that are currently running.

.PARAMETER SuppressRebootPassThru
Prevents the toolkit from exiting with a defined reboot exit code (e.g. 3010), returning 0 instead.

.NOTES
For more details on all available properties you can add to `$adtSession`, please visit https://psappdeploytoolkit.com/docs/reference/adtsession-object.

.EXAMPLE
& .\Invoke-AppDeployToolkit.ps1 -DeploymentType Install -DeployMode Silent

Invokes this script directly within PowerShell.

.EXAMPLE
& .\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent

Invokes this script via our supplied executable.

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
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru
)

## MARK: Variables
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

    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.2.0'
    ExitWithMsiCodes = $true
}

## MARK: Pre-Install
New-Variable -Name Pre-Install -Force -Value {
    $saiwParams = @{
        AllowDefer = $true
        DeferTimes = 3
        CheckDiskSpace = $true
        PersistPrompt = $true
    }
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
    }
    Show-ADTInstallationWelcome @saiwParams
    Show-ADTInstallationProgress
    ## win32-toolkit:Pre-Install:prior-check (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## remove-prior catalog revision 3 (win32-toolkit): the exact prior installs in SupportFiles\AppConfig.json (PriorInstalls), checked before any dialog; nothing is removed here.
    PSAppDeployToolkit.Win32Toolkit\Assert-W32TPriorInstall -AppConfig $appConfig
    ## win32-toolkit:Pre-Install:prior-check (end)
    ## win32-toolkit:Pre-Install:remove-prior (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## remove-prior: removes only what prior-check planned in this deployment, after the close-apps dialog, by the toolkit extension module.
    PSAppDeployToolkit.Win32Toolkit\Remove-W32TPriorInstall -AppConfig $appConfig
    ## win32-toolkit:Pre-Install:remove-prior (end)
}

## MARK: Install
New-Variable -Name Install -Force -Value {
    ## Handle Zero-Config MSI actions.
    if ($adtSession.UseDefaultMsi)
    {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile)
        {
            $ExecuteDefaultMSISplat.Add('Transforms', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
    }
    ## win32-toolkit:Install:manual-install (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## MANUAL APP: write your install code BETWEEN this block and the 'install-done' block below.
    ## Never edit inside a '## win32-toolkit:' block - those are regenerated.
    ## Fail with 'throw', never 'return' (on PSADT 4.2 a 'return' does not skip Post-Install).
    ## Never assign PSADT variable names ($Culture, $envTemp, ...): they are read-only on PSADT 4.2.
    ## The uninstall is generated from the documentation capture - no action needed there.
    ## win32-toolkit:Install:manual-install (end)
    ## win32-toolkit:Install:install-done (begin) - managed by win32-toolkit; regenerated, do not edit inside
    $w32tInstallDone = $true
    ## win32-toolkit:Install:install-done (end)
}

## MARK: Post-Install
New-Variable -Name Post-Install -Force -Value {
    ## win32-toolkit:Post-Install:tattoo (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## win32-toolkit install tattoo - records install state + version for the Intune detection rule (only when the Install phase ran to its end).
    PSAppDeployToolkit.Win32Toolkit\Set-W32TInstallTattoo -AppConfig $appConfig -InstallDone $w32tInstallDone
    ## win32-toolkit:Post-Install:tattoo (end)
    Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait
}

## MARK: Pre-Uninstall
New-Variable -Name Pre-Uninstall -Force -Value {
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }
    Show-ADTInstallationProgress
}

## MARK: Uninstall
New-Variable -Name Uninstall -Force -Value {
    ## Handle Zero-Config MSI actions.
    if ($adtSession.UseDefaultMsi)
    {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile)
        {
            $ExecuteDefaultMSISplat.Add('Transforms', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
    }
    ## win32-toolkit:Uninstall:uninstall (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Uninstall revision 2 (win32-toolkit): the app's uninstall from SupportFiles\AppConfig.json (Uninstall), by the toolkit extension module.
    PSAppDeployToolkit.Win32Toolkit\Uninstall-W32TApp -AppConfig $appConfig
    ## win32-toolkit:Uninstall:uninstall (end)
}

## MARK: Post-Uninstall
New-Variable -Name Post-Uninstall -Force -Value {
    ## win32-toolkit:Post-Uninstall:tattoo (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## win32-toolkit install tattoo - removed at uninstall, with its legacy WOW6432Node copy.
    PSAppDeployToolkit.Win32Toolkit\Remove-W32TInstallTattoo -AppConfig $appConfig
    ## win32-toolkit:Post-Uninstall:tattoo (end)
}

## MARK: Pre-Repair
New-Variable -Name Pre-Repair -Force -Value {
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }
    Show-ADTInstallationProgress
}

## MARK: Repair
New-Variable -Name Repair -Force -Value {
    ## Handle Zero-Config MSI actions.
    if ($adtSession.UseDefaultMsi)
    {
        $ExecuteDefaultMSISplat = @{ Action = $adtSession.DeploymentType; FilePath = $adtSession.DefaultMsiFile }
        if ($adtSession.DefaultMstFile)
        {
            $ExecuteDefaultMSISplat.Add('Transforms', $adtSession.DefaultMstFile)
        }
        Start-ADTMsiProcess @ExecuteDefaultMSISplat
    }
}

## MARK: Post-Repair
New-Variable -Name Post-Repair -Force -Value {
    Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait
}

## MARK: Initialization
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1
try
{
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = [System.Management.Automation.WildcardPattern]::Escape("$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"); Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.2.0' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.2.0' } -Force
    }
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
    Remove-Variable -Name iadtParams -Force -Confirm:$false
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int16]::MaxValue)))
    exit 60008
}

## MARK: Invocation
try
{
    # Import any PSAppDeployToolkit.* extensions
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name ([System.Management.Automation.WildcardPattern]::Escape("$($_.FullName)\$($_.BaseName).psd1")) -Force
            }
        }
    }
    Get-Variable -Name "Pre-$($adtSession.DeploymentType)", $adtSession.DeploymentType, "Post-$($adtSession.DeploymentType)" -ErrorAction Ignore | . {
        process
        {
            if (![System.String]::IsNullOrWhiteSpace($_.Value))
            {
                $adtSession.InstallPhase = $_.Name
                . $_.Value
            }
        }
    }
    Close-ADTSession
}
catch
{
    Write-ADTLogEntry -Message "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)" -Severity Error
    # Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) failed at line $($_.InvocationInfo.ScriptLineNumber), char $($_.InvocationInfo.OffsetInLine):`n$($_.InvocationInfo.Line.Trim())`n`nMessage:`n$($_.Exception.Message)" -ButtonRightText OK -NoWait
    Close-ADTSession -ExitCode 60001
}
