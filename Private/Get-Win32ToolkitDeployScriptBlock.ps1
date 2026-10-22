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
## Uninstall revision 2 (win32-toolkit). An EXE uninstaller may run 30 minutes and is waited for together with its
## child processes: that wait is what keeps the cleanup from racing an uninstaller that returns early (an NSIS copy
## in %TEMP%, also the one started by a vendor's NSIS wrapper around its real uninstaller). An NSIS uninstaller
## (Uninstallers[].Kind 'nullsoft') also gets '_?=<its own folder>', so a plain NSIS uninstaller runs in place
## instead of copying itself to %TEMP%. Afterwards the leftover NSIS uninstaller and the cleanup paths are deleted
## only inside Uninstall.InstallRoots; a system, shared or linked (reparse point) folder is never deleted: a refused
## path is logged and left in place.
if ($appConfig.Uninstall) {
    $uninstallSuccess = $false
    # Codes that mean "the app is gone" - checked identically by both loops below so they cannot
    # drift. 0 = removed. 1605 = "this product is not installed": the goal state already holds
    # (a user removed it by hand), which is a no-op success, matching how the msix branch treats an
    # already-absent package. 1641/3010 = removed AND a reboot was initiated/is required. Treating
    # 1641 or 1605 as failure would make the uninstall throw on a successful removal.
    $w32tUninstallOk = @(0, 1605, 1641, 3010)
    # Catalog constants: how long one EXE uninstaller may run (Intune's own run-time limit must stay above it) and
    # the exit code of a deployment whose uninstaller had to be stopped.
    $w32tUninstallLimit = New-TimeSpan -Minutes 30
    $w32tUninstallLimitCode = 69113
    # Device guard: the same rules as the host's Test-Win32ToolkitCleanupPath. '' = a plain folder path inside
    # Program Files, Program Files (x86) or ProgramData and outside every shared or system tree; else the reason.
    $w32tShellRoots = @('Program Files', 'Program Files (x86)', 'ProgramData')
    $w32tFolderProblem = {
        param([string]$w32tPath)
        $w32tPlain = (-not [string]::IsNullOrWhiteSpace($w32tPath)) -and $w32tPath.Length -le 240 -and $w32tPath -match '^[A-Za-z]:\\[^\\]' -and
            $w32tPath.IndexOfAny([char[]]'/*?"<>|[]~') -lt 0 -and $w32tPath.IndexOf(':', 2) -lt 0 -and -not $w32tPath.EndsWith('\')
        if ($w32tPlain) {
            foreach ($w32tCh in $w32tPath.ToCharArray()) {
                $w32tCat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($w32tCh)
                if ([char]::IsControl($w32tCh) -or $w32tCat -eq [Globalization.UnicodeCategory]::Format -or
                    $w32tCat -eq [Globalization.UnicodeCategory]::LineSeparator -or $w32tCat -eq [Globalization.UnicodeCategory]::ParagraphSeparator) { $w32tPlain = $false }
            }
        }
        $w32tSeg = @()
        if ($w32tPlain) {
            $w32tSeg = @($w32tPath.Split('\'))
            foreach ($w32tS in @($w32tSeg | Select-Object -Skip 1)) {
                if ($w32tS -eq '' -or $w32tS -eq '.' -or $w32tS -eq '..' -or $w32tS.EndsWith('.') -or $w32tS.EndsWith(' ') -or $w32tS.StartsWith(' ') -or
                    $w32tS -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { $w32tPlain = $false }
            }
        }
        if ($w32tPlain) {
            try { $w32tPlain = [IO.Path]::GetFullPath($w32tPath) -ceq $w32tPath } catch { $w32tPlain = $false }
        }
        if (-not $w32tPlain) { return 'not a plain folder path' }
        if ($w32tShellRoots -notcontains $w32tSeg[1]) { return 'not inside Program Files, Program Files (x86) or ProgramData' }
        if ($w32tSeg.Count -lt 3) { return 'it is a Windows system folder itself' }
        foreach ($w32tS in $w32tSeg) {
            if (@('Microsoft', 'Common Files', 'WindowsApps', 'Package Cache') -contains $w32tS) { return 'inside a shared or system folder' }
        }
        $w32tVendor = $w32tSeg[2]
        if ($w32tVendor -match '^(Microsoft|Windows)' -or @('ModifiableWindowsApps', 'Internet Explorer', 'Reference Assemblies', 'MSBuild', 'dotnet') -contains $w32tVendor -or
            ($w32tSeg[1] -eq 'ProgramData' -and @('Application Data', 'Desktop', 'Documents', 'Start Menu', 'Templates') -contains $w32tVendor)) { return 'inside a shared or system folder' }
        return ''
    }
    # The app's own install folders (recorded from its own uninstall entry at capture), re-checked here.
    $w32tRoots = @()
    if ($appConfig.Uninstall.PSObject.Properties['InstallRoots']) {
        foreach ($w32tRoot in @($appConfig.Uninstall.InstallRoots)) {
            $w32tRoot = ([string]$w32tRoot).TrimEnd('\')
            if ($w32tRoot -and -not (& $w32tFolderProblem $w32tRoot)) { $w32tRoots += $w32tRoot }
        }
    }
    # '' when $w32tPath is one of the install folders or inside one (separator-aware), else the reason.
    $w32tRootProblem = {
        param([string]$w32tPath)
        foreach ($w32tRoot in $w32tRoots) {
            if (($w32tPath + '\').StartsWith($w32tRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return '' }
        }
        return "outside the app's install folders (Uninstall.InstallRoots)"
    }
    # '' when neither the folder nor a folder above it is a link (reparse point) and, with -Walk, no folder below it
    # is one either: a recursive delete under Windows PowerShell 5.1 can follow a junction out of the app's folder.
    $w32tLinkProblem = {
        param([string]$w32tPath, [bool]$w32tWalk)
        try {
            $w32tUp = $w32tPath
            while ($w32tUp -and $w32tUp.Length -gt 3) {
                if ((Test-Path -LiteralPath $w32tUp) -and ([IO.File]::GetAttributes($w32tUp) -band [IO.FileAttributes]::ReparsePoint)) { return 'it or a folder above it is a link (reparse point)' }
                $w32tUp = [IO.Path]::GetDirectoryName($w32tUp)
            }
            if ($w32tWalk) {
                $w32tQueue = New-Object System.Collections.Queue
                $w32tQueue.Enqueue($w32tPath)
                $w32tSeen = 0
                while ($w32tQueue.Count -gt 0) {
                    foreach ($w32tSub in [IO.Directory]::GetDirectories([string]$w32tQueue.Dequeue())) {
                        $w32tSeen++
                        if ($w32tSeen -gt 50000) { return 'too many folders to check' }
                        if ([IO.File]::GetAttributes($w32tSub) -band [IO.FileAttributes]::ReparsePoint) { return 'a folder below it is a link (reparse point)' }
                        $w32tQueue.Enqueue($w32tSub)
                    }
                }
            }
        }
        catch { return 'it could not be checked' }
        return ''
    }
    # Log text for a path from AppConfig: printable ASCII only, no CMTrace delimiters.
    $w32tShow = { param([string]$w32tText) $w32tText -replace '[^\x20-\x7E]|[\[\]<>]', '?' }
    foreach ($pc in @($appConfig.Uninstall.ProductCodes)) {
        if (-not $pc -or $uninstallSuccess) { continue }
        $r = Start-ADTMsiProcess -Action Uninstall -ProductCode $pc -PassThru
        if ($r -and $r.ExitCode -in $w32tUninstallOk) { $uninstallSuccess = $true }
    }
    $w32tLeftover = @()
    $w32tRanPath = ''
    foreach ($u in @($appConfig.Uninstall.Uninstallers)) {
        if (-not $u) { continue }
        if ($uninstallSuccess) {
            # The first uninstaller that succeeds wins: an entry after it is logged as not run, so the log tells it
            # apart from an entry that was never captured. For an EXE entry the line also says whether its file is
            # still there (its own Path from AppConfig, nothing else is looked up): still there can mean that
            # product is still installed (severity 2); already gone, that the earlier uninstaller removed it. The
            # file of the uninstaller that succeeded (the same uninstaller recorded twice, for example under both
            # registry views) is not looked up: an NSIS uninstaller run in place is deleted only after this loop.
            $w32tWhat = [string]$u.Path
            if (-not $w32tWhat) { $w32tWhat = [string]$u.ProductCode }
            if (-not $w32tWhat -and $u.PSObject.Properties['PackageName']) { $w32tWhat = [string]$u.PackageName }
            $w32tLine = "win32-toolkit: uninstaller not run (an earlier one already succeeded): $(& $w32tShow $w32tWhat)"
            $w32tSeverity = 1
            if ([string]$u.Type -eq 'exe' -and $w32tRanPath -and [string]::Equals([string]$u.Path, $w32tRanPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $w32tLine += ', and it is the uninstaller that already ran'
            }
            elseif ([string]$u.Type -eq 'exe' -and [string]$u.Path -match '^[A-Za-z]:\\[^"*?<>|/:]+\.exe\z') {
                $w32tThere = $null
                try { $w32tThere = Test-Path -LiteralPath ([string]$u.Path) -PathType Leaf } catch { $w32tThere = $null }
                if ($w32tThere -eq $true) { $w32tLine += ', and its file is still there: that product may still be installed'; $w32tSeverity = 2 }
                elseif ($w32tThere -eq $false) { $w32tLine += ', and its file is already gone' }
            }
            Write-ADTLogEntry -Message $w32tLine -Severity $w32tSeverity
            continue
        }
        $r = $null
        $w32tInPlace = ''
        switch ($u.Type) {
            'msi' { $r = Start-ADTMsiProcess -Action Uninstall -ProductCode $u.ProductCode -PassThru }
            'exe' {
                $w32tArgs = ([string]$u.Args).Trim()
                if ($u.PSObject.Properties['Kind'] -and [string]$u.Kind -eq 'nullsoft') {
                    # Without '/S' an NSIS uninstaller shows its UI as SYSTEM and waits for an answer until the limit.
                    if ($w32tArgs -cnotmatch '(^|\s)/S(\s|$)') { $w32tArgs = ('/S ' + $w32tArgs).Trim() }
                    $w32tExe = [string]$u.Path
                    $w32tDir = ''
                    # A plain absolute .exe path only: '\z' ('$' also matches before a final line feed), no control or
                    # format character. Test-Path and GetFullPath sit inside the try: on Windows PowerShell 5.1 a path
                    # they cannot read throws; it is logged below instead, and Start-ADTProcess may still refuse it.
                    if ($w32tExe -match '^[A-Za-z]:\\[^"*?<>|/:\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+\.exe\z') {
                        try {
                            if ((Test-Path -LiteralPath $w32tExe -PathType Leaf) -and [IO.Path]::GetFullPath($w32tExe) -ceq $w32tExe) { $w32tDir = [IO.Path]::GetDirectoryName($w32tExe) }
                        }
                        catch { $w32tDir = '' }
                    }
                    if ($w32tDir.Length -le 3) {
                        Write-ADTLogEntry -Message 'win32-toolkit: the NSIS uninstaller is not a plain path to an existing .exe, so it is not run in place.' -Severity 2
                    }
                    elseif ($w32tArgs.Contains('_?=')) {
                        Write-ADTLogEntry -Message "win32-toolkit: the NSIS uninstaller arguments already contain '_?=' and are used as they are." -Severity 2
                    }
                    else {
                        # '_?=' must come LAST, unquoted, inside the one argument string (PSADT 4.2 quotes an argument-list
                        # element that has a space). It is the folder NSIS itself passes to the copy it starts from %TEMP%
                        # (NSIS adds a trailing '\' there and drops it when it reads the value).
                        $w32tArgs = ($w32tArgs + ' _?=' + $w32tDir).Trim()
                        $w32tInPlace = $w32tExe
                    }
                }
                $spUninstall = @{ FilePath = $u.Path; PassThru = $true; WaitForChildProcesses = $true; Timeout = $w32tUninstallLimit }
                if ($w32tArgs) { $spUninstall['ArgumentList'] = $w32tArgs }
                # PSADT's result decides: an uninstaller still running at the limit is stopped with its child processes
                # and ends the uninstall with exit code 69113; when only a child process is still running then, PSADT
                # stops that process and returns the uninstaller's own exit code, which is judged below.
                try { $r = Start-ADTProcess @spUninstall }
                catch {
                    if ($_.Exception -is [System.OperationCanceledException] -or $_.Exception -is [System.TimeoutException]) {
                        Write-ADTLogEntry -Message "win32-toolkit: the uninstaller ran longer than 30 minutes and was stopped (exit code $w32tUninstallLimitCode)." -Severity 3
                        $adtSession.SetExitCode($w32tUninstallLimitCode)
                    }
                    throw
                }
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
        if ($r -and $r.ExitCode -in $w32tUninstallOk) {
            $uninstallSuccess = $true
            if ($w32tInPlace) { $w32tLeftover += $w32tInPlace }
            if ([string]$u.Type -eq 'exe') { $w32tRanPath = [string]$u.Path }
        }
    }
    # Fail loudly when nothing actually uninstalled. $uninstallSuccess used to be computed and then
    # never read: every uninstaller could fail and the script still returned 0, so Intune recorded a
    # successful uninstall and the post-uninstall tattoo removal then made the app UNDETECTED - the
    # app stays on the device and Intune believes it is gone. Only raise this when there was
    # something to do (an empty Uninstall section is a separate, configure-time problem).
    if (-not $uninstallSuccess -and (@($appConfig.Uninstall.ProductCodes).Count + @($appConfig.Uninstall.Uninstallers).Count) -gt 0) {
        throw 'Uninstall failed: no uninstaller reported success (see the entries above for the cause).'
    }
    # Run in place, an NSIS uninstaller cannot delete itself: remove it now, only inside the install folders.
    foreach ($w32tFile in $w32tLeftover) {
        $w32tDir = [IO.Path]::GetDirectoryName($w32tFile)
        $w32tWhy = & $w32tFolderProblem $w32tDir
        if (-not $w32tWhy) { $w32tWhy = & $w32tRootProblem $w32tDir }
        if (-not $w32tWhy) { $w32tWhy = & $w32tLinkProblem $w32tDir $false }
        if ($w32tWhy) {
            Write-ADTLogEntry -Message "win32-toolkit: the NSIS uninstaller is left in place ($w32tWhy): $(& $w32tShow $w32tFile)" -Severity 2
        }
        elseif (Test-Path -LiteralPath $w32tFile -PathType Leaf) {
            $w32tGone = $false
            try { Remove-Item -LiteralPath $w32tFile -Force -ErrorAction Stop; $w32tGone = $true }
            catch { Write-ADTLogEntry -Message "win32-toolkit: the NSIS uninstaller could not be deleted: $($_.Exception.Message)" -Severity 2 }
            if ($w32tGone) { Write-ADTLogEntry -Message "win32-toolkit: deleted the NSIS uninstaller it left behind: $(& $w32tShow $w32tFile)" -Severity 1 }
        }
        else {
            # A vendor wrapper or the app's own uninstall already removed it.
            Write-ADTLogEntry -Message "win32-toolkit: the NSIS uninstaller is already gone: $(& $w32tShow $w32tFile)" -Severity 1
        }
    }
    if (@($appConfig.Uninstall.CleanupPaths | Where-Object { $_ }).Count -gt 0 -and $w32tRoots.Count -eq 0) {
        Write-ADTLogEntry -Message 'win32-toolkit: no valid install folder is recorded (Uninstall.InstallRoots), so no cleanup path is deleted. Re-create the project to record it.' -Severity 2
    }
    foreach ($folder in @($appConfig.Uninstall.CleanupPaths)) {
        if (-not $folder) { continue }
        $w32tFolder = [string]$folder
        $w32tWhy = & $w32tFolderProblem $w32tFolder
        if (-not $w32tWhy) { $w32tWhy = & $w32tRootProblem $w32tFolder }
        if (-not $w32tWhy -and -not (Test-Path -LiteralPath $w32tFolder -PathType Container)) {
            # Usually the uninstaller removed it already: logged so the PSADT log tells this apart from a refusal.
            Write-ADTLogEntry -Message "win32-toolkit: cleanup path already absent (no folder there): $(& $w32tShow $w32tFolder)" -Severity 1
            continue
        }
        if (-not $w32tWhy) { $w32tWhy = & $w32tLinkProblem $w32tFolder $true }
        if ($w32tWhy) {
            Write-ADTLogEntry -Message "win32-toolkit: cleanup path left in place ($w32tWhy): $(& $w32tShow $w32tFolder)" -Severity 2
            continue
        }
        try { Remove-ADTFolder -Path $w32tFolder }
        catch { Write-ADTLogEntry -Message "Cleanup failed for ${w32tFolder}: $($_.Exception.Message)" -Severity 2 }
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
    ## the Intune Management Extension and wrote the tattoo under WOW6432Node. Remove that copy too - only
    ## when it exists: Remove-ADTRegistryKey logs a warning for an absent key, the normal case since the
    ## exe launcher.
    $w32tLegacyKey = "HKLM:\SOFTWARE\WOW6432Node\$($appConfig.App.ScriptAuthor)\$($appConfig.App.Vendor)\$w32tName"
    if ([System.Environment]::Is64BitProcess -and (Test-Path -LiteralPath $w32tLegacyKey)) {
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
