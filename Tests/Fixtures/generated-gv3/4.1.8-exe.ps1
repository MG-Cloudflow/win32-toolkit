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
## win32-toolkit generator 3; extension PSAppDeployToolkit.Win32Toolkit 1.0.0
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
    ## win32-toolkit:Pre-Install:prior-check (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## win32-toolkit prior-install predicate (catalog 'PriorPredicate', revision 1). The SAME text runs in the deploy
    ## script (prior-check), in the update app's requirement script and in the Update test's guest assertions, so the
    ## three can never disagree. Read-only: it reads the registry and nothing else. Versions are padded to four parts
    ## (8.9 = 8.9.0.0, 26.02 = 26.2.0.0); a part longer than 9 digits, or a fifth part, makes the version unreadable.
    $w32tPrToVersion = {
        param([string]$w32tText)
        if ($w32tText -notmatch '^\s*[vV]?(\d{1,9})(?!\d)(?:\.(\d{1,9})(?!\d))?(?:\.(\d{1,9})(?!\d))?(?:\.(\d{1,9})(?!\d))?(?!\.?\d)') { return $null }
        $w32tN = @(0, 0, 0, 0)
        for ($w32tI = 1; $w32tI -le 4; $w32tI++) { if ($Matches[$w32tI]) { $w32tN[$w32tI - 1] = [int]$Matches[$w32tI] } }
        return (New-Object System.Version -ArgumentList $w32tN[0], $w32tN[1], $w32tN[2], $w32tN[3])
    }
    $w32tPrArpRoot = @{
        'Native'  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'Wow6432' = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    }
    $w32tPrValue = {
        param($w32tObject, [string]$w32tName)
        if ($null -ne $w32tObject -and $w32tObject.PSObject.Properties[$w32tName]) { return $w32tObject.$w32tName }
        return $null
    }
    $w32tPrSame = {
        param($w32tA, $w32tB)
        return [string]::Equals([string]$w32tA, [string]$w32tB, [StringComparison]::OrdinalIgnoreCase)
    }
    ## One entry -> @{ State = 'Absent' | 'Proven' | 'Newer' | 'Unverified' | 'Invalid'; Reason; KeyPath; Props; Version; VersionText }
    $w32tPrState = {
        param($w32tE)
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { return @{ State = 'Invalid'; Reason = 'a 32-bit process cannot read the native registry view' } }
        $w32tRoot = $w32tPrArpRoot[[string](& $w32tPrValue $w32tE 'View')]
        $w32tKey = [string](& $w32tPrValue $w32tE 'Key')
        if ([string](& $w32tPrValue $w32tE 'Kind') -cne 'ArpKey' -or -not $w32tRoot -or $w32tKey -notmatch '^[^\\/*?\[\]\p{Cc}\p{Cf}]{1,255}\z' -or
            $w32tKey -eq '.' -or $w32tKey -eq '..' -or [string](& $w32tPrValue $w32tE 'Publisher') -notmatch '\S') {
            return @{ State = 'Invalid'; Reason = 'the entry has no valid Kind, Key, View or Publisher' }
        }
        $w32tPath = $w32tRoot + '\' + $w32tKey
        $w32tP = $null
        try {
            if (-not (Test-Path -LiteralPath $w32tPath)) { return @{ State = 'Absent'; KeyPath = $w32tPath } }
            $w32tP = Get-ItemProperty -LiteralPath $w32tPath -ErrorAction Stop
        }
        catch { return @{ State = 'Unverified'; Reason = 'its uninstall key could not be read'; KeyPath = $w32tPath } }
        $w32tVerText = [string](& $w32tPrValue $w32tP 'DisplayVersion')
        $w32tV = & $w32tPrToVersion $w32tVerText
        $w32tMinText = [string](& $w32tPrValue $w32tE 'VersionMin')
        $w32tMin = $null
        if ($w32tMinText) { $w32tMin = & $w32tPrToVersion $w32tMinText }
        $w32tMax = & $w32tPrToVersion ([string](& $w32tPrValue $w32tE 'VersionMax'))
        $w32tName = [string](& $w32tPrValue $w32tE 'DisplayName')
        $w32tTemplate = [string](& $w32tPrValue $w32tE 'DisplayNameTemplate')
        $w32tSeen = [string](& $w32tPrValue $w32tP 'DisplayName')
        $w32tWhy = ''
        if ([string](& $w32tPrValue $w32tP 'WindowsInstaller') -eq '1') { $w32tWhy = 'it is registered by Windows Installer' }
        elseif (-not (& $w32tPrSame (& $w32tPrValue $w32tP 'Publisher') (& $w32tPrValue $w32tE 'Publisher'))) { $w32tWhy = 'its publisher differs' }
        elseif ($w32tTemplate -and -not (& $w32tPrSame $w32tSeen $w32tTemplate.Replace('{v}', $w32tVerText))) { $w32tWhy = 'its display name differs' }
        elseif (-not $w32tTemplate -and $w32tName -and -not (& $w32tPrSame $w32tSeen $w32tName)) { $w32tWhy = 'its display name differs' }
        elseif (-not $w32tV) { $w32tWhy = 'its version cannot be read' }
        elseif ($w32tMinText -and (-not $w32tMin -or $w32tV -lt $w32tMin)) { $w32tWhy = 'its version is below the proven window' }
        if ($w32tWhy) { return @{ State = 'Unverified'; Reason = $w32tWhy; KeyPath = $w32tPath; Version = $w32tV; VersionText = $w32tVerText } }
        if (-not $w32tMax -or $w32tV -gt $w32tMax) { return @{ State = 'Newer'; KeyPath = $w32tPath; Version = $w32tV; VersionText = $w32tVerText } }
        return @{ State = 'Proven'; KeyPath = $w32tPath; Props = $w32tP; Version = $w32tV; VersionText = $w32tVerText }
    }
    ## win32-toolkit prior-install evaluation (catalog 'PriorEvaluate', revision 1): the decision for ONE entry, without
    ## side effects (no marker, no log, no exit code). Shared by the deploy script's prior-check and remove-prior and by the
    ## Update test's guest assertions. Needs the 'PriorPredicate' text above it.
    $w32tPrCode = @{ Blocked = 69101; Newer = 69102; Unverified = 69103; Invalid = 69105; OwnRegistered = 69106; Restart = 69107
        UninstallFailed = 69108; Survived = 69109; Reappeared = 69110; Disabled = 69111; Payload = 69112; Retry = 1618 }
    $w32tPrGuid = '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$'
    ## Log text from data: printable ASCII only, no CMTrace delimiters.
    $w32tPrShow = { param([string]$w32tText) $w32tText -replace '[^\x20-\x7E]|[\[\]<>]', '?' }
    ## The uninstaller runs as SYSTEM: only SYSTEM, Administrators and TrustedInstaller may own it or a folder above it, or hold
    ## a right that changes it (write data, append data, delete child, delete, change permissions, take ownership, generic
    ## all, generic write). Any other account (Users, Domain Users, one user, a service) makes it unsafe: an allow-list.
    $w32tPrTrusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $w32tPrWeakMask = 0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    $w32tPrAclProblem = {
        param([string]$w32tPath, [bool]$w32tFolder)
        try {
            if ([IO.File]::GetAttributes($w32tPath) -band [IO.FileAttributes]::ReparsePoint) { return 'it is a link (reparse point)' }
            $w32tAcl = Get-Acl -LiteralPath $w32tPath
            if ($w32tPrTrusted -notcontains [string]$w32tAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return 'it is not owned by SYSTEM, Administrators or TrustedInstaller' }
            foreach ($w32tRule in @($w32tAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
                if ($w32tRule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
                if ($w32tFolder -and ($w32tRule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
                if ($w32tPrTrusted -contains [string]$w32tRule.IdentityReference.Value) { continue }
                if (([int]$w32tRule.FileSystemRights -band $w32tPrWeakMask) -ne 0) { return 'an account other than SYSTEM, Administrators or TrustedInstaller can change it' }
            }
        }
        catch { return 'its permissions could not be read' }
        return ''
    }
    ## One entry + the AppConfig -> @{ Outcome = 'Refuse' | 'Absent' | 'Unproven' | 'Report' | 'Plan'; Code; Text; State;
    ## KeyPath; Version; VersionText; Exe; Dir; MainPath; Procs; Type }. A Report entry never refuses (D26): invalid data and
    ## an unreadable registry view give Outcome 'Report' with State 'Invalid'.
    $w32tPrEvaluate = {
        param($w32tE, $w32tCfg)
        $w32tId = [string](& $w32tPrValue $w32tE 'Id')
        $w32tMode = [string](& $w32tPrValue $w32tE 'Mode')
        $w32tPkgVer = & $w32tPrToVersion ([string](& $w32tPrValue (& $w32tPrValue $w32tCfg 'App') 'Version'))
        $w32tPkgType = [string](& $w32tPrValue (& $w32tPrValue $w32tCfg 'Installer') 'Type')
        $w32tOwnId = & $w32tPrValue $w32tCfg 'OwnIdentity'
        $w32tOwn = @()
        foreach ($w32tK in @(& $w32tPrValue $w32tOwnId 'ArpKeys')) { if ($w32tK) { $w32tOwn += [string](& $w32tPrValue $w32tK 'Key') } }
        if ([string](& $w32tPrValue $w32tOwnId 'ProductCode')) { $w32tOwn += [string](& $w32tPrValue $w32tOwnId 'ProductCode') }
        foreach ($w32tK in @(& $w32tPrValue (& $w32tPrValue $w32tCfg 'Uninstall') 'ProductCodes')) { if ($w32tK) { $w32tOwn += [string]$w32tK } }
        foreach ($w32tK in @(& $w32tPrValue (& $w32tPrValue $w32tCfg 'Uninstall') 'PrimaryKeys')) { if ($w32tK) { $w32tOwn += [string](& $w32tPrValue $w32tK 'Name') } }
        $w32tOwn = @($w32tOwn | Where-Object { $_ })
        $w32tProcs = @(@(& $w32tPrValue $w32tE 'ProcessNames') | Where-Object { $_ })
        $w32tDirT = [string](& $w32tPrValue $w32tE 'InstallDir')
        $w32tLeaf = [string](& $w32tPrValue $w32tE 'UninstallerFileName')
        $w32tMain = [string](& $w32tPrValue $w32tE 'MainExe')
        $w32tType = [string](& $w32tPrValue $w32tE 'UninstallerType')
        $w32tPub = [string](& $w32tPrValue $w32tE 'Publisher')
        $w32tName = [string](& $w32tPrValue $w32tE 'DisplayName')
        $w32tTemplate = [string](& $w32tPrValue $w32tE 'DisplayNameTemplate')
        $w32tSigner = [string](& $w32tPrValue $w32tE 'UninstallerSigner')
        $w32tMax = & $w32tPrToVersion ([string](& $w32tPrValue $w32tE 'VersionMax'))
        $w32tMinText = [string](& $w32tPrValue $w32tE 'VersionMin')
        ## The host rules again (AppConfig.json can be edited after Export).
        $w32tBad = ''
        if ($w32tId -cnotmatch '^[a-z0-9-]{1,40}\z') { $w32tBad = 'Id' }
        elseif ($w32tMode -cnotin @('Block', 'Enforce', 'Report')) { $w32tBad = 'Mode' }
        elseif ($w32tPub -notmatch '\S' -or $w32tPub -match '[\p{Cc}\p{Cf}]') { $w32tBad = 'Publisher' }
        elseif ($w32tName -match '[\p{Cc}\p{Cf}]' -or ($w32tTemplate -and ($w32tName -or $w32tTemplate -match '[\p{Cc}\p{Cf}]' -or ($w32tTemplate.Length - $w32tTemplate.Replace('{v}', '').Length) -ne 3))) { $w32tBad = 'DisplayName or DisplayNameTemplate' }
        elseif (-not $w32tMax -or -not $w32tPkgVer -or ($w32tMinText -and -not (& $w32tPrToVersion $w32tMinText))) { $w32tBad = 'VersionMin or VersionMax' }
        elseif ($w32tPkgType -eq 'exe' -and $w32tMax -ge $w32tPkgVer) { $w32tBad = 'VersionMax (a prior of this package''s own technology family must be older than it)' }
        elseif ($w32tOwn -contains [string](& $w32tPrValue $w32tE 'Key')) { $w32tBad = 'Key (it is this package''s own uninstall key)' }
        elseif ($w32tMode -eq 'Enforce' -and (
                $w32tType -cnotin @('nullsoft', 'inno') -or $w32tLeaf -notmatch '^[A-Za-z0-9 ._+-]{1,64}\.exe\z' -or
                $w32tMain -notmatch '^[A-Za-z0-9 ._+-]{1,64}\.exe\z' -or [string]::Equals($w32tMain, $w32tLeaf, [StringComparison]::OrdinalIgnoreCase) -or
                $w32tDirT -notmatch '^%ProgramFiles(\(x86\))?%(\\[A-Za-z0-9 ._+()-]{1,64}){1,4}\z' -or $w32tDirT -match '\\[. ]*(\\|\z)|[. ](\\|\z)|\\ ' -or
                $w32tProcs.Count -eq 0 -or @($w32tProcs | Where-Object { [string]$_ -notmatch '^[A-Za-z0-9 ._+-]{1,64}\z' -or [string]$_ -match '\.exe\z' }).Count -gt 0 -or
                ($w32tSigner -and ($w32tSigner.Length -gt 512 -or $w32tSigner -match '[\p{Cc}\p{Cf}]')))) {
            $w32tBad = 'removal data (UninstallerType, UninstallerFileName, MainExe, InstallDir, ProcessNames or UninstallerSigner)'
        }
        elseif ($w32tMode -eq 'Enforce' -and (-not $w32tOwnId -or $w32tOwn.Count -eq 0)) { $w32tBad = 'OwnIdentity (this package''s own identity is unknown; re-run the install capture)' }
        if ($w32tBad) {
            if ($w32tMode -ceq 'Report') { return @{ Outcome = 'Report'; State = 'Invalid'; Text = "the entry failed validation: $w32tBad; policy Report: nothing removed, the install goes on" } }
            return @{ Outcome = 'Refuse'; Code = $w32tPrCode.Invalid; Text = "the entry failed validation: $w32tBad; nothing removed, nothing installed" }
        }

        $w32tS = & $w32tPrState $w32tE
        $w32tAt = & $w32tPrShow ([string]$w32tS.KeyPath)
        $w32tVer = & $w32tPrShow ([string]$w32tS.VersionText)
        if ($w32tS.State -eq 'Invalid') {
            if ($w32tMode -ceq 'Report') { return @{ Outcome = 'Report'; State = 'Invalid'; Text = "$($w32tS.Reason); policy Report: nothing removed, the install goes on" } }
            return @{ Outcome = 'Refuse'; Code = $w32tPrCode.Invalid; Text = "$($w32tS.Reason); nothing removed, nothing installed" }
        }
        if ($w32tS.State -eq 'Absent') { return @{ Outcome = 'Absent'; State = 'Absent'; KeyPath = $w32tS.KeyPath; Text = "$w32tAt is not present" } }
        if ($w32tS.State -eq 'Unverified') {
            return @{ Outcome = 'Unproven'; Code = $w32tPrCode.Unverified; State = 'Unverified'; KeyPath = $w32tS.KeyPath; Version = $w32tS.Version; VersionText = $w32tS.VersionText
                Text = "$w32tAt exists but is not the declared prior install ($($w32tS.Reason)); it is left as it is" }
        }
        if ($w32tMode -eq 'Report') {
            return @{ Outcome = 'Report'; State = $w32tS.State; KeyPath = $w32tS.KeyPath; Version = $w32tS.Version; VersionText = $w32tS.VersionText
                Text = "$w32tAt version $w32tVer is present ($($w32tS.State)); policy Report: nothing removed" }
        }
        if ($w32tS.State -eq 'Newer') {
            return @{ Outcome = 'Refuse'; Code = $w32tPrCode.Newer; State = 'Newer'; KeyPath = $w32tS.KeyPath; Version = $w32tS.Version; VersionText = $w32tS.VersionText
                Text = "a NEWER prior install is present ($w32tAt version $w32tVer); not installing over it" }
        }
        if ($w32tMode -eq 'Block') {
            return @{ Outcome = 'Refuse'; Code = $w32tPrCode.Blocked; State = 'Proven'; KeyPath = $w32tS.KeyPath; Version = $w32tS.Version; VersionText = $w32tS.VersionText
                Text = "a prior install is present ($w32tAt version $w32tVer) and its policy is Block; nothing removed, nothing installed" }
        }
        ## Enforce, identity proven. The device supplies only the uninstaller's PATH, and it must be exactly
        ## <InstallDir>\<UninstallerFileName> (canonical: no short name, no stream, no relative part). Anything else is the proven
        ## install in another folder: refuse, never remove it and never install next to it (L9). Checked before any file exists.
        $w32tBase = [string]$env:ProgramFiles
        if ($w32tDirT.StartsWith('%ProgramFiles(x86)%', [StringComparison]::OrdinalIgnoreCase)) { $w32tBase = [string]${env:ProgramFiles(x86)} }
        $w32tDir = ($w32tBase.TrimEnd('\') + $w32tDirT.Substring($w32tDirT.IndexOf('%', 1) + 1)).TrimEnd('\')
        $w32tCmd = [string](& $w32tPrValue $w32tS.Props 'UninstallString')
        $w32tExe = ''
        if ($w32tCmd -match '^\s*"([^"]+)"') { $w32tExe = $Matches[1] }
        elseif ($w32tCmd -match '^\s*([A-Za-z]:\\[^"]*?\.exe)(\s|\z)') { $w32tExe = $Matches[1] }
        $w32tOk = [bool]$w32tBase -and $w32tExe -match '^[A-Za-z]:\\[^/:*?"<>|~\p{Cc}\p{Cf}]+\z' -and $w32tExe -notmatch '\\[. ]*(\\|\z)|[. ](\\|\z)'
        if ($w32tOk) { try { $w32tOk = [IO.Path]::GetFullPath($w32tExe) -ceq $w32tExe } catch { $w32tOk = $false } }
        if ($w32tOk) {
            $w32tOk = [string]::Equals([IO.Path]::GetDirectoryName($w32tExe), $w32tDir, [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([IO.Path]::GetFileName($w32tExe), $w32tLeaf, [StringComparison]::OrdinalIgnoreCase)
        }
        if (-not $w32tOk) {
            return @{ Outcome = 'Refuse'; Code = $w32tPrCode.Invalid; State = 'Proven'; KeyPath = $w32tS.KeyPath; Version = $w32tS.Version; VersionText = $w32tS.VersionText
                Text = "the uninstaller registered for $w32tAt is not $(& $w32tPrShow $w32tDir)\$(& $w32tPrShow $w32tLeaf) (a custom install folder?); nothing removed, nothing installed" }
        }
        ## Registered in the declared folder, but the program or the uninstaller is gone: a leftover registration (D14).
        $w32tMainPath = $w32tDir + '\' + $w32tMain
        if (-not (Test-Path -LiteralPath $w32tMainPath -PathType Leaf) -or -not (Test-Path -LiteralPath $w32tExe -PathType Leaf)) {
            return @{ Outcome = 'Unproven'; Code = $w32tPrCode.Unverified; State = 'Unverified'; KeyPath = $w32tS.KeyPath; Version = $w32tS.Version; VersionText = $w32tS.VersionText
                Text = "$w32tAt is registered but its program file or its uninstaller is missing in $(& $w32tPrShow $w32tDir); it is left as it is" }
        }
        ## Only SYSTEM, Administrators and TrustedInstaller may be able to replace the uninstaller: every folder below Program
        ## Files down to the install folder, and the uninstaller itself; no link (reparse point) on the way.
        $w32tCheck = @()
        $w32tWalk = $w32tDir
        while ($w32tWalk -and $w32tWalk.Length -gt $w32tBase.TrimEnd('\').Length) { $w32tCheck += $w32tWalk; $w32tWalk = [IO.Path]::GetDirectoryName($w32tWalk) }
        foreach ($w32tFolder in $w32tCheck) {
            $w32tWhy = & $w32tPrAclProblem $w32tFolder $true
            if ($w32tWhy) {
                return @{ Outcome = 'Refuse'; Code = $w32tPrCode.Invalid; State = 'Proven'; KeyPath = $w32tS.KeyPath; Version = $w32tS.Version; VersionText = $w32tS.VersionText
                    Text = "the folder $(& $w32tPrShow $w32tFolder) of the prior install is not safe to run its uninstaller from ($w32tWhy); nothing removed, nothing installed" }
            }
        }
        $w32tWhy = & $w32tPrAclProblem $w32tExe $false
        if (-not $w32tWhy -and $w32tSigner) {
            $w32tSig = $null
            try { $w32tSig = Get-AuthenticodeSignature -LiteralPath $w32tExe -ErrorAction Stop } catch { $w32tSig = $null }
            if (-not $w32tSig -or [string]$w32tSig.Status -ne 'Valid' -or -not $w32tSig.SignerCertificate -or
                -not [string]::Equals([string]$w32tSig.SignerCertificate.Subject, $w32tSigner, [StringComparison]::Ordinal)) { $w32tWhy = 'it is not signed by the recorded signer' }
        }
        if ($w32tWhy) {
            return @{ Outcome = 'Refuse'; Code = $w32tPrCode.Invalid; State = 'Proven'; KeyPath = $w32tS.KeyPath; Version = $w32tS.Version; VersionText = $w32tS.VersionText
                Text = "the uninstaller $(& $w32tPrShow $w32tExe) is not safe to run ($w32tWhy); nothing removed, nothing installed" }
        }
        return @{ Outcome = 'Plan'; State = 'Proven'; KeyPath = $w32tS.KeyPath; Version = $w32tS.Version; VersionText = $w32tS.VersionText; Exe = $w32tExe; Dir = $w32tDir
            MainPath = $w32tMainPath; Procs = $w32tProcs; Type = $w32tType; Text = "$w32tAt version $w32tVer, uninstaller $(& $w32tPrShow $w32tExe)" }
    }
    ## win32-toolkit remove-prior 1/2: prior-check.
    ## remove-prior catalog revision 2 (win32-toolkit)
    ## Runs BEFORE the close-apps dialog and removes nothing. Data: SupportFiles\AppConfig.json -> PriorInstalls.Entries
    ## (exact identities, validated by win32-toolkit when they are written, at Export and again here). A refusal sets its
    ## exit code (69101-69112 or 1618) and stops the deployment HERE, before any app is closed, removed or installed. An
    ## exact key that is not the declared prior install (other publisher, name or version) is left as it is and the install
    ## goes on (decision D14); a Report entry never refuses (D26). Markers: HKLM\SOFTWARE\<App.ScriptAuthor>\win32-toolkit
    ## (LastRefusal; RemovePriorDisabled, also read from the WOW6432Node view; PriorInstalls\<View>\<Key>: Removed, Version,
    ## LastSeen).
    $w32tPrPlan = @()
    $w32tPrEntries = @()
    ## The step a log line names: prior-check here, remove-prior once the removal starts.
    $w32tPrStage = 'prior-check'
    if ($appConfig -and $appConfig.PSObject.Properties['PriorInstalls'] -and $appConfig.PriorInstalls -and $appConfig.PriorInstalls.PSObject.Properties['Entries']) {
        $w32tPrEntries = @(@($appConfig.PriorInstalls.Entries) | Where-Object { $_ })
    }
    if ($w32tPrEntries.Count -gt 0) {
        $w32tPrAuthor = [string](& $w32tPrValue (& $w32tPrValue $appConfig 'App') 'ScriptAuthor')
        $w32tPrMarkRoot = ''
        $w32tPrKillRoots = @()
        if ($w32tPrAuthor -match '\S' -and $w32tPrAuthor -notmatch '[\\/*?\[\]\p{Cc}\p{Cf}]') {
            $w32tPrMarkRoot = 'HKLM:\SOFTWARE\' + $w32tPrAuthor + '\win32-toolkit'
            $w32tPrKillRoots = @($w32tPrMarkRoot, ('HKLM:\SOFTWARE\WOW6432Node\' + $w32tPrAuthor + '\win32-toolkit'))
        }
        ## Block and Enforce entries refuse on bad data; a Report-only set never refuses (D26).
        $w32tPrStrict = @($w32tPrEntries | Where-Object { [string](& $w32tPrValue $_ 'Mode') -cne 'Report' }).Count -gt 0
        $w32tPrMark = {
            param([string]$w32tPath, [string]$w32tName, [string]$w32tValue)
            if (-not $w32tPrMarkRoot -or -not $w32tPath) { return }
            try {
                if (-not (Test-Path -LiteralPath $w32tPath)) { $null = New-Item -Path $w32tPath -Force -ErrorAction Stop }
                $null = New-ItemProperty -LiteralPath $w32tPath -Name $w32tName -Value $w32tValue -PropertyType String -Force -ErrorAction Stop
            }
            catch { Write-ADTLogEntry -Message "win32-toolkit $($w32tPrStage): a marker was not written: $(& $w32tPrShow $_.Exception.Message)" -Severity 2 }
        }
        $w32tPrFail = {
            param([int]$w32tCode, [string]$w32tText)
            Write-ADTLogEntry -Message "win32-toolkit $($w32tPrStage): $w32tText (exit code $w32tCode)" -Severity 3
            & $w32tPrMark $w32tPrMarkRoot 'LastRefusal' ('{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd'), $w32tCode, (& $w32tPrShow ([string]$appConfig.App.Version)))
            $adtSession.SetExitCode($w32tCode)
            throw "win32-toolkit $($w32tPrStage): $w32tText"
        }
        ## The kill switch. An Intune remediation that runs as 32-bit PowerShell writes the WOW6432Node view: either view counts.
        $w32tPrKill = {
            $w32tOff = $false
            foreach ($w32tRoot in $w32tPrKillRoots) {
                try { if ([string](Get-ItemProperty -LiteralPath $w32tRoot -Name 'RemovePriorDisabled' -ErrorAction Stop).RemovePriorDisabled -eq '1') { $w32tOff = $true } } catch { continue }
            }
            return $w32tOff
        }
        $w32tPrPfro = { try { @((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop).PendingFileRenameOperations | Where-Object { $_ }) } catch { @() } }
        if (-not $w32tPrMarkRoot) {
            if ($w32tPrStrict) { & $w32tPrFail $w32tPrCode.Invalid 'App.ScriptAuthor cannot be used as a registry key name; nothing removed, nothing installed' }
            Write-ADTLogEntry -Message 'win32-toolkit prior-check: App.ScriptAuthor cannot be used as a registry key name; the Report markers are not written.' -Severity 2
        }
        $w32tPrDisabled = & $w32tPrKill
        ## Two entries for one uninstall key: refused unless the set is Report-only.
        $w32tPrKeys = @()
        foreach ($w32tPrE in $w32tPrEntries) {
            $w32tPrK = [string](& $w32tPrValue $w32tPrE 'View') + '\' + [string](& $w32tPrValue $w32tPrE 'Key')
            if ($w32tPrKeys -contains $w32tPrK) {
                if ($w32tPrStrict) { & $w32tPrFail $w32tPrCode.Invalid "two entries name the uninstall key $(& $w32tPrShow $w32tPrK); nothing removed, nothing installed" }
                Write-ADTLogEntry -Message "win32-toolkit prior-check: two Report entries name the uninstall key $(& $w32tPrShow $w32tPrK)." -Severity 2
            }
            $w32tPrKeys += $w32tPrK
        }
        ## Every entry is evaluated before anything is removed; the first refusal stops the deployment.
        foreach ($w32tPrE in $w32tPrEntries) {
            $w32tPrR = & $w32tPrEvaluate $w32tPrE $appConfig
            $w32tPrTag = '[' + (& $w32tPrShow ([string](& $w32tPrValue $w32tPrE 'Id'))) + ']'
            $w32tPrKeyMark = ''
            if ($w32tPrR.KeyPath -and $w32tPrMarkRoot) { $w32tPrKeyMark = $w32tPrMarkRoot + '\PriorInstalls\' + [string]$w32tPrE.View + '\' + [string]$w32tPrE.Key }
            if ($w32tPrR.Outcome -eq 'Refuse') { & $w32tPrFail $w32tPrR.Code "$w32tPrTag $($w32tPrR.Text)" }
            elseif ($w32tPrR.Outcome -eq 'Absent') { Write-ADTLogEntry -Message "win32-toolkit remove-prior $w32tPrTag $($w32tPrR.Text)." -Severity 1 }
            elseif ($w32tPrR.Outcome -eq 'Unproven') {
                Write-ADTLogEntry -Message "win32-toolkit remove-prior $w32tPrTag $($w32tPrR.Text) (code $($w32tPrR.Code); the install goes on)." -Severity 2
                & $w32tPrMark $w32tPrKeyMark 'LastSeen' ('{0} Unproven {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd'), $w32tPrR.Code, (& $w32tPrShow ([string]$w32tPrR.VersionText)))
            }
            elseif ($w32tPrR.Outcome -eq 'Report') {
                Write-ADTLogEntry -Message "win32-toolkit remove-prior $w32tPrTag $($w32tPrR.Text)." -Severity 2
                & $w32tPrMark $w32tPrKeyMark 'LastSeen' ('{0} Report {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd'), $w32tPrR.State, (& $w32tPrShow ([string]$w32tPrR.VersionText)))
            }
            else {
                if ($w32tPrDisabled) { & $w32tPrFail $w32tPrCode.Disabled "$w32tPrTag removal is disabled on this device (RemovePriorDisabled = 1); nothing removed, nothing installed" }
                $w32tPrRemoved = ''
                try { $w32tPrRemoved = [string](Get-ItemProperty -LiteralPath $w32tPrKeyMark -Name 'Removed' -ErrorAction Stop).Removed } catch { $w32tPrRemoved = '' }
                if ($w32tPrRemoved) { & $w32tPrFail $w32tPrCode.Reappeared "$w32tPrTag this prior install was removed on $(& $w32tPrShow $w32tPrRemoved) and is back (another deployment or the app's own updater installed it again); it is not removed again" }
                $w32tPrPlan += @{ Entry = $w32tPrE; Tag = $w32tPrTag; Mark = $w32tPrKeyMark; Found = $w32tPrR }
                Write-ADTLogEntry -Message "win32-toolkit remove-prior $w32tPrTag proven: $($w32tPrR.Text); it is removed after the close-apps dialog." -Severity 2
            }
        }
        if ($w32tPrPlan.Count -gt 0) {
            ## Removal cannot be undone, so everything the install needs is checked first.
            ## (1) The package's installer (69112). PSADT 4.2 holds a FileInfo in DefaultMsiFile (4.1: a string), and a FileInfo
            ## from a folder listing converts to its bare name under Windows PowerShell 5.1: take FullName, root a relative name.
            $w32tPrPcs = @()
            $w32tPrUcs = @()
            $w32tPrOwnId = & $w32tPrValue $appConfig 'OwnIdentity'
            if ([string](& $w32tPrValue $w32tPrOwnId 'ProductCode') -match $w32tPrGuid) { $w32tPrPcs += [string](& $w32tPrValue $w32tPrOwnId 'ProductCode') }
            if ([string](& $w32tPrValue $w32tPrOwnId 'UpgradeCode') -match $w32tPrGuid) { $w32tPrUcs += [string](& $w32tPrValue $w32tPrOwnId 'UpgradeCode') }
            $w32tPrPayload = ''
            if ($adtSession.UseDefaultMsi) {
                $w32tPrMsi = $adtSession.DefaultMsiFile
                if ($w32tPrMsi -is [IO.FileSystemInfo]) { $w32tPrPayload = $w32tPrMsi.FullName } else { $w32tPrPayload = [string]$w32tPrMsi }
            }
            elseif ($appConfig.Installer -and [string]$appConfig.Installer.FileName) { $w32tPrPayload = [IO.Path]::GetFileName([string]$appConfig.Installer.FileName) }
            if ($w32tPrPayload -and -not [IO.Path]::IsPathRooted($w32tPrPayload)) { $w32tPrPayload = [string](Join-Path $adtSession.DirFiles $w32tPrPayload) }
            if ($w32tPrPayload) {
                if (-not (Test-Path -LiteralPath $w32tPrPayload -PathType Leaf)) { & $w32tPrFail $w32tPrCode.Payload 'the package installer is missing; nothing removed' }
                if ($w32tPrPayload -match '\.msi\z') {
                    ## Its own ProductCode and UpgradeCode (Property table) join OwnIdentity's for (2). Database, view and record
                    ## objects have no type information for PowerShell: InvokeMember, as Get-Win32ToolkitMsiProperty does.
                    $w32tPrDbOk = $true
                    try {
                        $w32tPrWi = New-Object -ComObject WindowsInstaller.Installer
                        $w32tPrDb = $w32tPrWi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $w32tPrWi, @($w32tPrPayload, 0))
                        foreach ($w32tPrN in @('ProductCode', 'UpgradeCode')) {
                            $w32tPrView = $w32tPrDb.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $w32tPrDb, @("SELECT Value FROM Property WHERE Property='" + $w32tPrN + "'"))
                            $null = $w32tPrView.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $w32tPrView, $null)
                            $w32tPrRec = $w32tPrView.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $w32tPrView, $null)
                            $w32tPrVal = ''
                            if ($w32tPrRec) { $w32tPrVal = [string]$w32tPrRec.GetType().InvokeMember('StringData', 'GetProperty', $null, $w32tPrRec, @(1)) }
                            if ($w32tPrVal -match $w32tPrGuid) { if ($w32tPrN -eq 'ProductCode') { $w32tPrPcs += $w32tPrVal } else { $w32tPrUcs += $w32tPrVal } }
                        }
                        $w32tPrDb = $null
                    }
                    catch { $w32tPrDbOk = $false }
                    if (-not $w32tPrDbOk) { & $w32tPrFail $w32tPrCode.Payload 'the package MSI cannot be opened; nothing removed' }
                }
            }
            else { Write-ADTLogEntry -Message 'win32-toolkit prior-check: the installer payload is not checked (the install is written by hand).' -Severity 2 }
            ## (2) This package's own MSI already registered next to the prior (69106): PSADT's Zero-Config install would skip it
            ## after the prior's uninstaller deleted the shared files, and the tattoo would report a broken app as installed.
            if ($w32tPrPcs.Count -gt 0 -or $w32tPrUcs.Count -gt 0) {
                $w32tPrPkgVer = & $w32tPrToVersion ([string]$appConfig.App.Version)
                $w32tPrWi = New-Object -ComObject WindowsInstaller.Installer
                foreach ($w32tPrPc in $w32tPrPcs) {
                    if ([int]$w32tPrWi.ProductState($w32tPrPc) -eq 5) { & $w32tPrFail $w32tPrCode.OwnRegistered "this package's own product $w32tPrPc is already registered next to a prior install; nothing removed" }
                }
                foreach ($w32tPrUc in $w32tPrUcs) {
                    foreach ($w32tPrRp in @($w32tPrWi.RelatedProducts($w32tPrUc))) {
                        $w32tPrRv = $null
                        try { $w32tPrRv = & $w32tPrToVersion ([string]$w32tPrWi.ProductInfo([string]$w32tPrRp, 'VersionString')) } catch { $w32tPrRv = $null }
                        if ($w32tPrRv -and $w32tPrPkgVer -and $w32tPrRv -ge $w32tPrPkgVer) { & $w32tPrFail $w32tPrCode.OwnRegistered "a same or newer product of this package ($(& $w32tPrShow ([string]$w32tPrRp))) is already registered next to a prior install; nothing removed" }
                    }
                }
            }
            ## (3) A pending restart, or a delete-on-restart ALREADY pending under a planned prior's folder: at the next restart it
            ## would delete the new install's file of the same name (69107).
            $w32tPrReboot = Get-ADTPendingReboot
            if ($w32tPrReboot.IsCBServicingRebootPending -or $w32tPrReboot.IsWindowsUpdateRebootPending) { & $w32tPrFail $w32tPrCode.Restart 'a restart is pending; nothing removed (the install runs after the restart)' }
            $w32tPrPfroNow = @(& $w32tPrPfro)
            foreach ($w32tPrH in $w32tPrPlan) {
                if (@($w32tPrPfroNow | Where-Object { ([string]$_).IndexOf($w32tPrH.Found.Dir + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) {
                    & $w32tPrFail $w32tPrCode.Restart "$($w32tPrH.Tag) files under $(& $w32tPrShow $w32tPrH.Found.Dir) are already scheduled for deletion at the next restart; nothing removed (the install runs after the restart)"
                }
            }
            ## (4) Windows Installer busy (1618). A check that throws counts as busy: PSADT 4.2.0-rc2 throws (strict mode) while
            ## an msiexec holds the mutex.
            $w32tPrMsiFree = $false
            try { $w32tPrMsiFree = [bool](Test-ADTMutexAvailability -MutexName 'Global\_MSIExecute') } catch { $w32tPrMsiFree = $false }
            if (-not $w32tPrMsiFree) { & $w32tPrFail $w32tPrCode.Retry 'Windows Installer is busy; nothing removed (retry)' }
            ## (5) Every planned removal must be able to leave its Removed marker (69110 relies on it): write a probe now.
            foreach ($w32tPrH in $w32tPrPlan) {
                $w32tPrMarkOk = $true
                try {
                    if (-not (Test-Path -LiteralPath $w32tPrH.Mark)) { $null = New-Item -Path $w32tPrH.Mark -Force -ErrorAction Stop }
                    $null = New-ItemProperty -LiteralPath $w32tPrH.Mark -Name 'LastSeen' -Value ('{0} Planned {1}' -f (Get-Date -Format 'yyyy-MM-dd'), (& $w32tPrShow ([string]$w32tPrH.Found.VersionText))) -PropertyType String -Force -ErrorAction Stop
                }
                catch { $w32tPrMarkOk = $false }
                if (-not $w32tPrMarkOk) { & $w32tPrFail $w32tPrCode.Invalid "$($w32tPrH.Tag) its marker $(& $w32tPrShow $w32tPrH.Mark) cannot be written; nothing removed, nothing installed" }
            }
        }
    }
    ## win32-toolkit:Pre-Install:prior-check (end)
    ## win32-toolkit:Pre-Install:remove-prior (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## win32-toolkit remove-prior 2/2: remove-prior (catalog revision 2). Removes ONLY what prior-check proved, after the
    ## close-apps dialog and the org hook and before any install action. Each prior is evaluated again first and must
    ## still be exactly what prior-check found, and the kill switch is read again. Arguments are constants: NSIS
    ## '/S _?=<its folder>' (in place, no %TEMP% copy; '_?=' last and unquoted inside the one argument string), Inno Setup
    ## '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'.
    $w32tPrDo = @()
    if (Test-Path -LiteralPath 'variable:w32tPrPlan') { $w32tPrDo = @($w32tPrPlan | Where-Object { $_ }) }
    if ($w32tPrDo.Count -gt 0) {
        $w32tPrStage = 'remove-prior'
        $w32tPrLimit = New-TimeSpan -Minutes 30
        foreach ($w32tPrH in $w32tPrDo) {
            $w32tPrNow = & $w32tPrEvaluate $w32tPrH.Entry $appConfig
            $w32tPrH['Now'] = $w32tPrNow
            if ($w32tPrNow.Outcome -eq 'Absent') { Write-ADTLogEntry -Message "win32-toolkit remove-prior $($w32tPrH.Tag) is no longer present; nothing to remove." -Severity 1; continue }
            if ($w32tPrNow.Outcome -ne 'Plan' -or $w32tPrNow.KeyPath -ne $w32tPrH.Found.KeyPath -or $w32tPrNow.Exe -ne $w32tPrH.Found.Exe -or [string]$w32tPrNow.Version -ne [string]$w32tPrH.Found.Version) {
                & $w32tPrFail $w32tPrCode.Retry "$($w32tPrH.Tag) the prior install changed while the close-apps dialog was open; nothing removed (retry)"
            }
            foreach ($w32tPrPn in @($w32tPrNow.Procs)) {
                if (Get-Process -Name ([string]$w32tPrPn) -ErrorAction SilentlyContinue) { & $w32tPrFail $w32tPrCode.Retry "$($w32tPrH.Tag) '$(& $w32tPrShow ([string]$w32tPrPn))' is still running; nothing removed (retry)" }
            }
        }
        if (& $w32tPrKill) { & $w32tPrFail $w32tPrCode.Disabled 'removal was disabled on this device after prior-check (RemovePriorDisabled = 1); nothing removed, nothing installed' }
        $w32tPrPfroBefore = @(& $w32tPrPfro)
        foreach ($w32tPrH in $w32tPrDo) {
            $w32tPrR = $w32tPrH['Now']
            if ($w32tPrR.Outcome -ne 'Plan') { continue }
            ## An earlier uninstaller of this run may have removed this prior too (one vendor uninstaller for two entries).
            if (-not (Test-Path -LiteralPath $w32tPrR.KeyPath) -and -not (Test-Path -LiteralPath $w32tPrR.Exe)) {
                if (Test-Path -LiteralPath $w32tPrR.MainPath) { & $w32tPrFail $w32tPrCode.Survived "$($w32tPrH.Tag) the key and the uninstaller of $(& $w32tPrShow $w32tPrR.KeyPath) are gone but its program file is still there; nothing installed" }
                & $w32tPrMark $w32tPrH.Mark 'Removed' (Get-Date -Format 'yyyy-MM-dd')
                & $w32tPrMark $w32tPrH.Mark 'Version' (& $w32tPrShow ([string]$w32tPrR.VersionText))
                Write-ADTLogEntry -Message "win32-toolkit remove-prior $($w32tPrH.Tag): already removed by an earlier uninstaller of this run." -Severity 1
                continue
            }
            $w32tPrArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
            if ($w32tPrR.Type -eq 'nullsoft') { $w32tPrArgs = '/S _?=' + $w32tPrR.Dir }
            $w32tPrRes = $null
            $w32tPrErr = $null
            try { $w32tPrRes = Start-ADTProcess -FilePath $w32tPrR.Exe -ArgumentList $w32tPrArgs -WaitForChildProcesses -Timeout $w32tPrLimit -PassThru }
            catch { $w32tPrErr = $_ }
            if ($w32tPrErr) {
                $w32tPrWhy = 'failed'
                if ($w32tPrErr.Exception -is [System.OperationCanceledException] -or $w32tPrErr.Exception -is [System.TimeoutException] -or $w32tPrErr.Exception.InnerException -is [System.TimeoutException]) { $w32tPrWhy = 'ran longer than 30 minutes and was stopped' }
                & $w32tPrFail $w32tPrCode.UninstallFailed "$($w32tPrH.Tag) the uninstaller of $(& $w32tPrShow $w32tPrR.KeyPath) $w32tPrWhy ($(& $w32tPrShow $w32tPrErr.Exception.Message)); nothing installed"
            }
            if ($w32tPrRes -and $w32tPrRes.ExitCode -in @(1641, 3010)) { & $w32tPrFail $w32tPrCode.Restart "$($w32tPrH.Tag) removing $(& $w32tPrShow $w32tPrR.KeyPath) needs a restart; the install runs after the restart" }
            ## The key AND the prior's program file must be gone (an NSIS uninstaller deletes its key first and its files
            ## afterwards); for Inno Setup the uninstaller too. Bounded wait: 2 minutes.
            $w32tPrGone = $false
            for ($w32tPrT = 0; $w32tPrT -lt 60 -and -not $w32tPrGone; $w32tPrT++) {
                $w32tPrGone = -not (Test-Path -LiteralPath $w32tPrR.KeyPath) -and -not (Test-Path -LiteralPath $w32tPrR.MainPath) -and ($w32tPrR.Type -eq 'nullsoft' -or -not (Test-Path -LiteralPath $w32tPrR.Exe))
                if (-not $w32tPrGone) { Start-Sleep -Seconds 2 }
            }
            if (-not $w32tPrGone) { & $w32tPrFail $w32tPrCode.Survived "$($w32tPrH.Tag) $(& $w32tPrShow $w32tPrR.KeyPath) or its program file is still there after its uninstaller finished; nothing installed" }
            ## Run in place, an NSIS uninstaller cannot delete itself: delete that one validated file now, so it can never run
            ## later against the new install's files.
            if ($w32tPrR.Type -eq 'nullsoft' -and (Test-Path -LiteralPath $w32tPrR.Exe -PathType Leaf)) {
                try { Remove-Item -LiteralPath $w32tPrR.Exe -Force -ErrorAction Stop; Write-ADTLogEntry -Message "win32-toolkit remove-prior $($w32tPrH.Tag): deleted the NSIS uninstaller it left behind." -Severity 1 }
                catch { Write-ADTLogEntry -Message "win32-toolkit remove-prior $($w32tPrH.Tag): the NSIS uninstaller it left behind could not be deleted: $(& $w32tPrShow $_.Exception.Message)" -Severity 2 }
            }
            & $w32tPrMark $w32tPrH.Mark 'Removed' (Get-Date -Format 'yyyy-MM-dd')
            & $w32tPrMark $w32tPrH.Mark 'Version' (& $w32tPrShow ([string]$w32tPrR.VersionText))
            Write-ADTLogEntry -Message "win32-toolkit remove-prior $($w32tPrH.Tag): removed $($w32tPrR.Text)." -Severity 1
        }
        ## A delete-on-restart of the prior's files would remove the NEW install's files at the next restart.
        $w32tPrPfroNew = @(& $w32tPrPfro | Where-Object { $w32tPrPfroBefore -notcontains $_ })
        foreach ($w32tPrH in $w32tPrDo) {
            $w32tPrR = $w32tPrH['Now']
            if ($w32tPrR.Outcome -ne 'Plan') { continue }
            if (@($w32tPrPfroNew | Where-Object { ([string]$_).IndexOf($w32tPrR.Dir + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) {
                & $w32tPrFail $w32tPrCode.Restart "$($w32tPrH.Tag) files under $(& $w32tPrShow $w32tPrR.Dir) are deleted at the next restart; the install runs after the restart"
            }
        }
    }
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
    ## win32-toolkit:Install:install (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Data-driven install: the installer named in SupportFiles\AppConfig.json (Installer), by the toolkit extension module.
    PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $appConfig -Technology Exe
    ## win32-toolkit:Install:install (end)
    ## win32-toolkit:Install:install-done (begin) - managed by win32-toolkit; regenerated, do not edit inside
    $w32tInstallDone = $true
    ## win32-toolkit:Install:install-done (end)


    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    ## <Perform Post-Installation tasks here>
    ## win32-toolkit:Post-Install:tattoo (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## win32-toolkit install tattoo - records install state + version for the Intune detection rule (only when the Install phase ran to its end).
    PSAppDeployToolkit.Win32Toolkit\Set-W32TInstallTattoo -AppConfig $appConfig -InstallDone $w32tInstallDone
    ## win32-toolkit:Post-Install:tattoo (end)


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

    ## <Perform Uninstallation tasks here>
    ## win32-toolkit:Uninstall:uninstall (begin) - managed by win32-toolkit; regenerated, do not edit inside
    ## Uninstall revision 2 (win32-toolkit): the app's uninstall from SupportFiles\AppConfig.json (Uninstall), by the toolkit extension module.
    PSAppDeployToolkit.Win32Toolkit\Uninstall-W32TApp -AppConfig $appConfig
    ## win32-toolkit:Uninstall:uninstall (end)


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

