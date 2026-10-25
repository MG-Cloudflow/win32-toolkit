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

        Installer-identity PR 3 (remove-prior, catalog revision 2): 'RemovePriorCheck' (slot Pre-Install:prior-check)
        = 'PriorPredicate' + 'PriorEvaluate' + the prior-check body; 'RemovePrior' (slot Pre-Install:remove-prior).
        'PriorPredicate' is also embedded verbatim in the update requirement script and, with 'PriorEvaluate', in
        the Update test's guest assertions. Two names return values, not code: 'RemovePriorCatalogVersion' (the
        first 16 hex characters of the SHA-256 of the four texts; it binds a proof to the device text) and
        'RemovePriorRevision' (the catalog revision number, [int], read from the prior-check text).
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
    [OutputType([string], [int])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Loader', 'Install', 'ManualInstall', 'Msp', 'InstallDone', 'Uninstall', 'TattooInstall',
            'TattooUninstall', 'OrgUiPreInstall', 'OrgUiPreMaintenance', 'OrgUiPostInstall', 'OrgUiPostRepair', 'Hook',
            'PriorPredicate', 'PriorEvaluate', 'RemovePriorCheck', 'RemovePrior', 'RemovePriorCatalogVersion', 'RemovePriorRevision')]
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

    # ---- installer-identity PR 3: the remove-prior catalog (spec 2.6; revision 2). Each text is stored exactly as it
    # ships (zero base indentation). PriorPredicate is ALSO embedded verbatim in the update app's requirement script and,
    # with PriorEvaluate, in the Update test's guest assertions: one predicate, three consumers (S13). Any change of
    # these four texts must bump the revision marker in the prior-check text (Tests\RemovePriorBlock.unit.ps1 pins the
    # pair revision <-> RemovePriorCatalogVersion, L38).
    $priorPredicate = @'
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
'@
    $priorEvaluate = @'
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
'@
    $priorCheckBody = @'
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
'@
    $removePrior = @'
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
'@
    $priorPredicate = ($priorPredicate -replace "`r`n", "`n").TrimEnd("`n")
    $priorEvaluate = ($priorEvaluate -replace "`r`n", "`n").TrimEnd("`n")
    $priorCheckBody = ($priorCheckBody -replace "`r`n", "`n").TrimEnd("`n")
    $removePrior = ($removePrior -replace "`r`n", "`n").TrimEnd("`n")
    if ($Name -eq 'RemovePriorCatalogVersion') {
        $catalogText = $priorPredicate + "`n" + $priorEvaluate + "`n" + $priorCheckBody + "`n" + $removePrior
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($catalogText)) } finally { $sha.Dispose() }
        return (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
    }
    if ($Name -eq 'RemovePriorRevision') {
        # The same rule as Get-Win32ToolkitDeployScriptShape (RemovePriorRevision) reads from a project's prior-check block.
        $rev = [regex]::Match($priorCheckBody, '## remove-prior catalog revision (\d{1,4}) \(win32-toolkit\)')
        return [int]$rev.Groups[1].Value
    }

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
        'PriorPredicate' { $priorPredicate }
        'PriorEvaluate' { $priorEvaluate }
        'RemovePriorCheck' { $priorPredicate + "`n" + $priorEvaluate + "`n" + $priorCheckBody }
        'RemovePrior' { $removePrior }
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
