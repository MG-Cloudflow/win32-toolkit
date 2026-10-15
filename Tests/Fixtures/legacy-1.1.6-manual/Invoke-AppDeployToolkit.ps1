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
# Data-driven deployment values (win32-toolkit): read app-specific settings as DATA.
$appConfig = if (Test-Path -LiteralPath "$PSScriptRoot\SupportFiles\AppConfig.json") {
    # -Encoding UTF8: AppConfig.json is BOM-less UTF-8 and this runs under Windows PowerShell 5.1 on the
    # device, whose Get-Content default decodes a BOM-less file as ANSI (non-ASCII vendor/app names would
    # mojibake). 5.1's -Encoding UTF8 reader handles both BOM and BOM-less input.
    Get-Content -LiteralPath "$PSScriptRoot\SupportFiles\AppConfig.json" -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    [pscustomobject]@{ App = [pscustomobject]@{}; Installer = $null; Uninstall = $null; ProcessesToClose = @() }
}

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
    AppScriptAuthor = '<author name>'
    RequireAdmin = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName = ''
    InstallTitle = ''

    # Script variables.
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
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

    ## Show Welcome Message, close processes if specified, allow up to 3 deferrals, verify there is enough disk space to complete the install, and persist the prompt.
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

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    ## <Perform Pre-Installation tasks here>


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
    ## MANUAL APP: write your Pre-Install / Install / Post-Install logic in these regions.
    ## The uninstall is auto-generated from the sandbox capture — no action needed there.


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Installation tasks here>

    ## win32-toolkit install tattoo - records install state + version for the Intune detection rule.
    $w32tName = if ($appConfig.App.DisplayName) { $appConfig.App.DisplayName } else { $appConfig.App.Name }
    if ($w32tName -and $appConfig.App.Vendor -and $appConfig.App.Version -and $appConfig.App.ScriptAuthor) {
        Set-ADTRegistryKey -Key "HKLM:\SOFTWARE\$($appConfig.App.ScriptAuthor)\$($appConfig.App.Vendor)\$w32tName" -Name 'Version' -Value "$($appConfig.App.Version)" -Type 'String'
    }


    ## Display a message at the end of the install.
    if (!$adtSession.UseDefaultMsi)
    {
        Show-ADTInstallationPrompt -Message 'You can customize text to appear at the end of an install or remove it completely for unattended installations.' -ButtonRightText 'OK' -NoWait
    }
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

    ## If there are processes to close, show Welcome Message with a 60 second countdown before automatically closing.
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    ## <Perform Pre-Uninstallation tasks here>


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

    ## Data-driven uninstall (values from SupportFiles\AppConfig.json).
    if ($appConfig.Uninstall) {
        $uninstallSuccess = $false
        # Codes that mean "the app is gone" — checked identically by both loops below so they cannot
        # drift. 0 = removed. 1605 = "this product is not installed": the goal state already holds
        # (a user removed it by hand), which is a no-op success, matching how the msix branch treats an
        # already-absent package. 1641/3010 = removed AND a reboot was initiated/is required. Treating
        # 1641 or 1605 as failure would make the uninstall throw on a successful removal.
        $w32tUninstallOk = @(0, 1605, 1641, 3010)
        foreach ($pc in @($appConfig.Uninstall.ProductCodes)) {
            if (-not $pc -or $uninstallSuccess) { continue }
            $r = Start-ADTMsiProcess -Action Uninstall -ProductCode $pc -PassThru
            if ($r -and $r.ExitCode -in $w32tUninstallOk) { $uninstallSuccess = $true }
        }
        foreach ($u in @($appConfig.Uninstall.Uninstallers)) {
            if (-not $u -or $uninstallSuccess) { continue }
            $r = $null
            switch ($u.Type) {
                'msi' { $r = Start-ADTMsiProcess -Action Uninstall -ProductCode $u.ProductCode -PassThru }
                'exe' {
                    $spUninstall = @{ FilePath = $u.Path; PassThru = $true }
                    if ($u.Args) { $spUninstall['ArgumentList'] = $u.Args }
                    $r = Start-ADTProcess @spUninstall
                }
                'msix' {
                    # Identity-driven removal (exact Name match; Remove-AppxPackage has no exit code,
                    # so success = the package is gone for ALL users afterwards; $r stays $null).
                    if ($u.PackageName) {
                        foreach ($prov in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $u.PackageName })) {
                            try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName | Out-Null }
                            catch { Write-ADTLogEntry -Message "Deprovisioning failed: $($_.Exception.Message)" -Severity 2 }
                        }
                        foreach ($pkg in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $u.PackageName })) {
                            try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop }
                            catch { Write-ADTLogEntry -Message "Remove-AppxPackage failed: $($_.Exception.Message)" -Severity 2 }
                        }
                        if (@(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $u.PackageName }).Count -eq 0) {
                            $uninstallSuccess = $true
                        }
                    }
                }
            }
            if ($r -and $r.ExitCode -in $w32tUninstallOk) { $uninstallSuccess = $true }
        }
        # Fail loudly when nothing actually uninstalled. $uninstallSuccess used to be computed and then
        # never read: every uninstaller could fail and the script still returned 0, so Intune recorded a
        # successful uninstall and the post-uninstall tattoo removal then made the app UNDETECTED - the
        # app stays on the device and Intune believes it is gone. Only raise this when there was
        # something to do (an empty Uninstall section is a separate, configure-time problem).
        if (-not $uninstallSuccess -and (@($appConfig.Uninstall.ProductCodes).Count + @($appConfig.Uninstall.Uninstallers).Count) -gt 0) {
            throw 'Uninstall failed: no uninstaller reported success (see the entries above for the cause).'
        }
        foreach ($folder in @($appConfig.Uninstall.CleanupPaths)) {
            if (-not $folder) { continue }
            if (Test-Path -LiteralPath $folder) {
                try { Remove-ADTFolder -Path $folder }
                catch { Write-ADTLogEntry -Message "Cleanup failed for ${folder}: $($_.Exception.Message)" -Severity 2 }
            }
        }
    }


    ##================================================
    ## MARK: Post-Uninstallation
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Uninstallation tasks here>

    ## win32-toolkit install tattoo - remove the key written during install.
    $w32tName = if ($appConfig.App.DisplayName) { $appConfig.App.DisplayName } else { $appConfig.App.Name }
    if ($w32tName -and $appConfig.App.Vendor -and $appConfig.App.ScriptAuthor) {
        Remove-ADTRegistryKey -Key "HKLM:\SOFTWARE\$($appConfig.App.ScriptAuthor)\$($appConfig.App.Vendor)\$w32tName" -Recurse
    }
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

    ## If there are processes to close, show Welcome Message with a 60 second countdown before automatically closing.
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    ## <Perform Pre-Repair tasks here>


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

