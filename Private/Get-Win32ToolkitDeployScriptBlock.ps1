function Get-Win32ToolkitDeployScriptBlock {
    <#
    .SYNOPSIS
        Returns one constant, value-free code block of the generated deploy script (the block catalog).
    .DESCRIPTION
        The SINGLE source of every line of code win32-toolkit writes into Invoke-AppDeployToolkit.ps1.
        Set-PSADTDataDrivenScript, Apply-OrgTemplate and Add-Win32ToolkitOrgHooks contain no code text of
        their own: they place these blocks with Set-Win32ToolkitPhaseBlock, which wraps each one in its
        '## win32-toolkit:<Phase>:<Slot>' sentinels and indents it.

        Every block is VALUE-FREE: app data is read at runtime from SupportFiles\AppConfig.json
        ($appConfig, loaded by the 'Loader' block) or from $adtSession; no winget, registry or org-template
        value is ever spliced in. The only substitutions are -Phase and -HookFile of the 'Hook' block,
        both compile-time constants restricted by ValidateSet.

        The blocks run on the device under Windows PowerShell 5.1 (Intune), so they are 5.1-safe (no
        ternary, ??, ?., && or ||). They contain no here-strings (the formatter re-indents every line).
        Returned text has zero base indentation, LF line endings and no trailing newline.
    .PARAMETER Name
        The block to return.
    .PARAMETER Phase
        'Hook' only: the deploy phase the hook runs in.
    .PARAMETER HookFile
        'Hook' only: the hook file in SupportFiles\OrgHooks (must match -Phase).
    .PARAMETER FailureAction
        'Hook' only: Fail (a throwing hook fails the deployment) or Continue (logged, deployment continues).
    .EXAMPLE
        Get-Win32ToolkitDeployScriptBlock -Name Hook -Phase Pre-Install -HookFile PreInstall.ps1 -FailureAction Continue
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Loader', 'Install', 'ManualInstall', 'Msp', 'InstallDone', 'Uninstall', 'TattooInstall',
            'TattooUninstall', 'OrgUiPreInstall', 'OrgUiPreMaintenance', 'OrgUiPostInstall', 'OrgUiPostRepair', 'Hook')]
        [string]$Name,

        [ValidateSet('Pre-Install', 'Post-Install', 'Pre-Uninstall', 'Post-Uninstall', 'Pre-Repair', 'Post-Repair')]
        [string]$Phase,

        [ValidateSet('PreInstall.ps1', 'PostInstall.ps1', 'PreUninstall.ps1', 'PostUninstall.ps1', 'PreRepair.ps1', 'PostRepair.ps1')]
        [string]$HookFile,

        [ValidateSet('Fail', 'Continue')]
        [string]$FailureAction = 'Fail'
    )

    # Shared by OrgUiPreInstall and OrgUiPreMaintenance.
    $orgUiHeader = @'
## Org template dialogs - policy is DATA in SupportFiles\AppConfig.json (OrgUi); nothing is spliced here.
## PSADT 4.2 note: DeployMode Auto resolves to Silent when no listed process is running (or the list is
## empty), so these dialogs only show when the user must close an app.
'@
    $orgUiProgress = @'
if ($w32tUi -and $w32tUi.Progress -and $w32tUi.Progress.Enabled) {
    $w32tProgress = @{}
    if (-not [string]::IsNullOrWhiteSpace([string]$w32tUi.Progress.StatusMessage)) { $w32tProgress['StatusMessage'] = [string]$w32tUi.Progress.StatusMessage }
    if (-not [string]::IsNullOrWhiteSpace([string]$w32tUi.Progress.StatusMessageDetail)) { $w32tProgress['StatusMessageDetail'] = [string]$w32tUi.Progress.StatusMessageDetail }
    Show-ADTInstallationProgress @w32tProgress
}
'@

    $text = switch ($Name) {
        'Loader' {
            @'
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
'@
        }
        'Install' {
            @'
## Data-driven install (values from SupportFiles\AppConfig.json).
if ($appConfig.Installer -and $appConfig.Installer.Type -in @('msix', 'appx')) {
    $installerPath = Join-Path $adtSession.DirFiles $appConfig.Installer.FileName
    if (Test-Path -LiteralPath $installerPath) {
        Write-ADTLogEntry -Message "Installing AppX/MSIX package from: $installerPath" -Severity 1
        # SYSTEM (Intune): provision for all users. Interactive (sandbox tests): register for the
        # current user - a provisioned-only package would be invisible to the logged-on operator.
        if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
            # -Regions 'all' is REQUIRED, not cosmetic. Per the DISM reference: "When a list of
            # regions is not specified, the package will be provisioned only if it is pinned to
            # start layout." Without it, provisioning silently no-ops for most packages: the
            # command succeeds, the tattoo is written, Intune reports Installed, and no user ever
            # gets the app.
            #
            # There is deliberately NO Add-AppxPackage fallback here. It would run AS SYSTEM and
            # register the package into SYSTEM's own profile, where no real user can ever see it -
            # and since it wouldn't throw, the tattoo would still be written and Intune would
            # report Installed for an app nobody has. A provisioning failure must fail the
            # deployment loudly. -ErrorAction Stop is what makes that happen: these Appx cmdlets
            # emit NON-TERMINATING errors by default, so without it a failure would just be logged
            # and the script would sail on to write the tattoo.
            try { Add-AppxProvisionedPackage -Online -PackagePath $installerPath -SkipLicense -Regions 'all' -ErrorAction Stop | Out-Null }
            catch {
                Write-ADTLogEntry -Message "Provisioning failed: $($_.Exception.Message)" -Severity 3
                throw
            }
        } else {
            Add-AppxPackage -Path $installerPath -ErrorAction Stop
        }
    } else {
        Write-ADTLogEntry -Message "Installer file not found: $installerPath" -Severity 3
        throw "Installer file not found: $installerPath"
    }
}
elseif ($appConfig.Installer -and $appConfig.Installer.Type -ne 'msi') {
    $installerPath = Join-Path $adtSession.DirFiles $appConfig.Installer.FileName
    if (Test-Path -LiteralPath $installerPath) {
        Write-ADTLogEntry -Message "Installing $($appConfig.App.Name) from: $installerPath" -Severity 1
        $spInstall = @{ FilePath = $installerPath; PassThru = $true }
        if ($appConfig.Installer.SilentArgs) { $spInstall['ArgumentList'] = $appConfig.Installer.SilentArgs }
        Start-ADTProcess @spInstall
    } else {
        Write-ADTLogEntry -Message "Installer file not found: $installerPath" -Severity 3
        throw "Installer file not found: $installerPath"
    }
}
'@
        }
        'ManualInstall' {
            @'
## MANUAL APP: write your install code BETWEEN this block and the 'install-done' block below.
## Never edit inside a '## win32-toolkit:' block - those are regenerated.
## Fail with 'throw', never 'return' (on PSADT 4.2 a 'return' does not skip Post-Install).
## Never assign PSADT variable names ($Culture, $envTemp, ...): they are read-only on PSADT 4.2.
## The uninstall is generated from the documentation capture - no action needed there.
'@
        }
        'Msp' {
            @'
## PSADT 4.2's Zero-Config block no longer applies .msp patches (4.1.8 did): keep 4.1.8 parity.
if ($adtSession.UseDefaultMsi) {
    foreach ($w32tMsp in @($adtSession.DefaultMspFiles)) {
        if ($w32tMsp) { Start-ADTMsiProcess -Action Patch -FilePath $w32tMsp.FullName }
    }
}
'@
        }
        'InstallDone' {
            @'
$w32tInstallDone = $true
'@
        }
        'Uninstall' {
            @'
## Data-driven uninstall (values from SupportFiles\AppConfig.json).
if ($appConfig.Uninstall) {
    $uninstallSuccess = $false
    # Codes that mean "the app is gone" - checked identically by both loops below so they cannot
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
'@
        }
        'TattooInstall' {
            @'
## win32-toolkit install tattoo - records install state + version for the Intune detection rule.
## Written only when the Install phase reached its end ($w32tInstallDone, set by the install-done block).
$w32tName = if ($appConfig.App.DisplayName) { $appConfig.App.DisplayName } else { $appConfig.App.Name }
if (-not $w32tInstallDone) {
    Write-ADTLogEntry -Message 'win32-toolkit: the Install phase did not run to its end - the detection tattoo was NOT written.' -Severity 2
}
elseif ($w32tName -and $appConfig.App.Vendor -and $appConfig.App.Version -and $appConfig.App.ScriptAuthor) {
    Set-ADTRegistryKey -Key "HKLM:\SOFTWARE\$($appConfig.App.ScriptAuthor)\$($appConfig.App.Vendor)\$w32tName" -Name 'Version' -Value "$($appConfig.App.Version)" -Type 'String'
}
'@
        }
        'TattooUninstall' {
            @'
## win32-toolkit install tattoo - remove the key written during install.
$w32tName = if ($appConfig.App.DisplayName) { $appConfig.App.DisplayName } else { $appConfig.App.Name }
if ($w32tName -and $appConfig.App.Vendor -and $appConfig.App.ScriptAuthor) {
    $w32tTattooKey = "HKLM:\SOFTWARE\$($appConfig.App.ScriptAuthor)\$($appConfig.App.Vendor)\$w32tName"
    Remove-ADTRegistryKey -Key $w32tTattooKey -Recurse
    ## Legacy cleanup: packages published with the old 'powershell.exe -File' command line ran 32-bit under
    ## the Intune Management Extension and wrote the tattoo under WOW6432Node. Remove that copy too.
    if ([System.Environment]::Is64BitProcess) {
        Remove-ADTRegistryKey -Key $w32tTattooKey -Wow6432Node -Recurse
    }
}
'@
        }
        'OrgUiPreInstall' {
            $orgUiHeader + "`n" + @'
$w32tUi = $appConfig.OrgUi
if ($w32tUi -and $w32tUi.Welcome -and $w32tUi.Welcome.Enabled) {
    $w32tWelcome = @{}
    if ($w32tUi.Welcome.AllowDefer) {
        $w32tWelcome['AllowDefer'] = $true
        if ([int]$w32tUi.Welcome.DeferTimes -gt 0) { $w32tWelcome['DeferTimes'] = [int]$w32tUi.Welcome.DeferTimes }
    }
    if ($w32tUi.Welcome.CheckDiskSpace) { $w32tWelcome['CheckDiskSpace'] = $true }
    if ($w32tUi.Welcome.PersistPrompt) { $w32tWelcome['PersistPrompt'] = $true }
    if ($adtSession.AppProcessesToClose.Count -gt 0) {
        $w32tWelcome['CloseProcesses'] = $adtSession.AppProcessesToClose
        if ($w32tUi.Welcome.BlockExecution) { $w32tWelcome['BlockExecution'] = $true }
        $w32tCountdown = [int]$w32tUi.Welcome.CloseProcessesCountdown
        if ($w32tCountdown -gt 0 -and $w32tCountdown -le 86400) { $w32tWelcome['CloseProcessesCountdown'] = $w32tCountdown }
    }
    Show-ADTInstallationWelcome @w32tWelcome
}
'@ + "`n" + $orgUiProgress
        }
        'OrgUiPreMaintenance' {
            $orgUiHeader + "`n" + @'
$w32tUi = $appConfig.OrgUi
if ($w32tUi -and $w32tUi.UninstallWelcome -and $w32tUi.UninstallWelcome.Enabled -and $adtSession.AppProcessesToClose.Count -gt 0) {
    $w32tWelcome = @{ CloseProcesses = $adtSession.AppProcessesToClose }
    $w32tCountdown = [int]$w32tUi.UninstallWelcome.CloseProcessesCountdown
    if ($w32tCountdown -gt 0 -and $w32tCountdown -le 86400) { $w32tWelcome['CloseProcessesCountdown'] = $w32tCountdown }
    if ($w32tUi.UninstallWelcome.PersistPrompt) { $w32tWelcome['PersistPrompt'] = $true }
    if ($w32tUi.UninstallWelcome.BlockExecution) { $w32tWelcome['BlockExecution'] = $true }
    Show-ADTInstallationWelcome @w32tWelcome
}
'@ + "`n" + $orgUiProgress
        }
        'OrgUiPostInstall' {
            @'
## Org template completion prompt - policy is DATA in AppConfig.json (OrgUi.Completion). Never shown for a
## Zero-Config MSI (4.1.8 parity: the PSADT 4.2 template prompts unconditionally).
$w32tUi = $appConfig.OrgUi
if ($w32tUi -and $w32tUi.Completion -and $w32tUi.Completion.Enabled -and -not $adtSession.UseDefaultMsi -and
    -not [string]::IsNullOrWhiteSpace([string]$w32tUi.Completion.Message)) {
    $w32tButton = [string]$w32tUi.Completion.ButtonRightText
    if ([string]::IsNullOrWhiteSpace($w32tButton)) { $w32tButton = 'OK' }
    Show-ADTInstallationPrompt -Message ([string]$w32tUi.Completion.Message) -ButtonRightText $w32tButton -NoWait
}
'@
        }
        'OrgUiPostRepair' {
            @'
## Org template policy: no completion prompt after a repair (the PSADT default prompt was removed).
'@
        }
        'Hook' {
            if (-not $Phase -or -not $HookFile) {
                throw [System.ArgumentException]::new("Get-Win32ToolkitDeployScriptBlock -Name Hook needs -Phase and -HookFile.")
            }
            if (($Phase -replace '-', '') + '.ps1' -ne $HookFile) {
                throw [System.ArgumentException]::new("Hook file '$HookFile' does not belong to phase '$Phase'.")
            }
            $hook = if ($FailureAction -eq 'Continue') {
                @'
## Org hook <Phase>: runs SupportFiles\OrgHooks\<File> when present (edit that file, not this block).
$orgHookScript = Join-Path -Path $adtSession.DirSupportFiles -ChildPath 'OrgHooks\<File>'
if (Test-Path -LiteralPath $orgHookScript) {
    try { . $orgHookScript }
    catch { Write-ADTLogEntry -Message "Org hook <File> failed (continuing): $($_.Exception.Message)" -Severity 2 }
}
'@
            }
            else {
                @'
## Org hook <Phase>: runs SupportFiles\OrgHooks\<File> when present (edit that file, not this block).
$orgHookScript = Join-Path -Path $adtSession.DirSupportFiles -ChildPath 'OrgHooks\<File>'
if (Test-Path -LiteralPath $orgHookScript) { . $orgHookScript }
'@
            }
            $hook.Replace('<Phase>', $Phase).Replace('<File>', $HookFile)
        }
    }

    # Here-string line endings follow this file's checkout (CRLF or LF): normalise to LF.
    return (([string]$text) -replace "`r`n", "`n").TrimEnd("`n")
}
