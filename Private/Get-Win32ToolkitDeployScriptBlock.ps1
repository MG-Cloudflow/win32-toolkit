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
        value is ever spliced in. The only substitutions are -Phase and -HookFile of the 'Hook' block and
        -Technology of the 'Install' block, all compile-time constants restricted by ValidateSet.

        GeneratorVersion 3 (lean deploy script PR 2 and PR 3): the install, msp, uninstall, tattoo, org-ui and prior-install
        blocks are one module-qualified call each into win32-toolkit's PSADT extension module (DeployExtension\
        PSAppDeployToolkit.Win32Toolkit, copied into every project by Copy-Win32ToolkitDeployExtension), whose functions
        hold the code these blocks used to carry; the Loader's first line names the generator and the extension version.
        The loader, install-done, the manual note, the hooks and the Post-Repair note stay inline.
        Get-Win32ToolkitDeployBlockPlan says which blocks a project gets.

        The blocks run on the device under Windows PowerShell 5.1 (Intune), so they are 5.1-safe (no
        ternary, ??, ?., && or ||). They contain no here-strings (the formatter re-indents every line).
        Returned text has zero base indentation, LF line endings and no trailing newline.

        Installer-identity PR 3 (remove-prior; catalog revision 3 since lean deploy script PR 3): 'RemovePriorCheck' (slot
        Pre-Install:prior-check, the revision marker + Assert-W32TPriorInstall) and 'RemovePrior' (slot
        Pre-Install:remove-prior, Remove-W32TPriorInstall). 'PriorPredicate' and 'PriorEvaluate' are the extension's
        module-level regions of those names, read from the installed, hash-verified copy (Get-Win32ToolkitDeployExtension
        -Verify; W32T.DeployExtensionInvalid otherwise): 'PriorPredicate' is embedded verbatim in the update requirement
        script and, with 'PriorEvaluate', in the Update test's guest assertions. Two names return values, not code:
        'RemovePriorCatalogVersion' (the first 16 hex characters of the SHA-256 of the three prior regions and the two
        functions; it binds a proof to the device code) and 'RemovePriorRevision' (the catalog revision number, [int],
        read from the prior-check text).
    .PARAMETER Name
        The block to return.
    .PARAMETER Phase
        'Hook' only: the deploy phase the hook runs in.
    .PARAMETER HookFile
        'Hook' only: the hook file in SupportFiles\OrgHooks (must match -Phase).
    .PARAMETER FailureAction
        'Hook' only: Fail (a throwing hook fails the deployment) or Continue (logged, deployment continues).
    .PARAMETER Technology
        'Install' only: Exe (Installer.Type exe) or Appx (msix, appx) - a constant the generator maps from Installer.Type.
    .EXAMPLE
        Get-Win32ToolkitDeployScriptBlock -Name Hook -Phase Pre-Install -HookFile PreInstall.ps1 -FailureAction Continue
    #>
    [CmdletBinding()]
    [OutputType([string], [int])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Loader', 'Install', 'ManualInstall', 'Msp', 'InstallDone', 'Uninstall', 'TattooInstall',
            'TattooUninstall', 'OrgUiPreInstall', 'OrgUiPreMaintenance', 'OrgUiPostInstall', 'OrgUiPostInstallMsi', 'OrgUiPostRepair', 'Hook',
            'PriorPredicate', 'PriorEvaluate', 'RemovePriorCheck', 'RemovePrior', 'RemovePriorCatalogVersion', 'RemovePriorRevision')]
        [string]$Name,

        [ValidateSet('Pre-Install', 'Post-Install', 'Pre-Uninstall', 'Post-Uninstall', 'Pre-Repair', 'Post-Repair')]
        [string]$Phase,

        [ValidateSet('PreInstall.ps1', 'PostInstall.ps1', 'PreUninstall.ps1', 'PostUninstall.ps1', 'PreRepair.ps1', 'PostRepair.ps1')]
        [string]$HookFile,

        [ValidateSet('Fail', 'Continue')]
        [string]$FailureAction = 'Fail',

        [ValidateSet('Exe', 'Appx')]
        [string]$Technology
    )

    # ---- the remove-prior pair (installer-identity PR 3; lean deploy script PR 3: catalog revision 3) ----
    # The code lives in the toolkit extension module: Assert-W32TPriorInstall, Remove-W32TPriorInstall and the module-level
    # regions win32-toolkit:PriorPredicate, :PriorEvaluate and :PriorRuntime. The two blocks are calls; the revision marker
    # in the prior-check block names the revision of that code (Get-Win32ToolkitDeployExtension RemovePriorRevision). A
    # change of the code bumps the extension's ModuleVersion AND this revision (Tests\RemovePriorBlock.unit.ps1 pins the
    # pair revision <-> RemovePriorCatalogVersion, L38).
    $removePriorCheck = @'
## remove-prior catalog revision 3 (win32-toolkit): the exact prior installs in SupportFiles\AppConfig.json (PriorInstalls), checked before any dialog; nothing is removed here.
PSAppDeployToolkit.Win32Toolkit\Assert-W32TPriorInstall -AppConfig $appConfig
'@
    $removePrior = @'
## remove-prior: removes only what prior-check planned in this deployment, after the close-apps dialog, by the toolkit extension module.
PSAppDeployToolkit.Win32Toolkit\Remove-W32TPriorInstall -AppConfig $appConfig
'@
    $removePriorCheck = ($removePriorCheck -replace "`r`n", "`n").TrimEnd("`n")
    $removePrior = ($removePrior -replace "`r`n", "`n").TrimEnd("`n")
    if ($Name -eq 'RemovePriorRevision') {
        # The same rule as Get-Win32ToolkitDeployScriptShape (RemovePriorRevision) reads from a project's prior-check block.
        $rev = [regex]::Match($removePriorCheck, '## remove-prior catalog revision (\d{1,4}) \(win32-toolkit\)')
        return [int]$rev.Groups[1].Value
    }
    if ($Name -in @('PriorPredicate', 'PriorEvaluate', 'RemovePriorCatalogVersion')) {
        # Read ONLY from the installed, hash-verified copy (never a project's): the predicate is embedded in the update
        # requirement script, which runs as SYSTEM on every targeted device. A changed copy fails closed
        # (W32T.DeployExtensionInvalid). The psm1 is CRLF: everything is LF-normalised, so the predicate and evaluation stay
        # byte-identical to the revision 1 texts. The texts are kept for the rest of the session once read from verified
        # bytes (ConvertTo-Win32ToolkitPriorVersion runs the predicate for every version it parses).
        $current = Get-Win32ToolkitDeployExtension
        $cacheKey = "$($current.SourcePath)|$($current.Version)"
        if (-not (Get-Variable -Name W32TPriorSourceCache -Scope Script -ErrorAction SilentlyContinue)) { $script:W32TPriorSourceCache = @{} }
        if (-not $script:W32TPriorSourceCache.ContainsKey($cacheKey)) {
            $extension = Get-Win32ToolkitDeployExtension -Verify
            $psm1Name = "$($extension.Name).psm1"
            $psm1Path = Join-Path $extension.SourcePath $psm1Name
            $invalid = {
                param([string]$What)
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("win32-toolkit's own PSADT extension module at '$psm1Path' has $What. Reinstall win32-toolkit. Nothing was written."),
                    'W32T.DeployExtensionInvalid', [System.Management.Automation.ErrorCategory]::InvalidData, $psm1Path)
            }
            # The bytes used are the bytes hashed: the file could change between -Verify and this read.
            $psm1Bytes = [System.IO.File]::ReadAllBytes($psm1Path)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $readHash = -join ($sha.ComputeHash($psm1Bytes) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
            if ($readHash -ne $extension.Files[$psm1Name]) { & $invalid 'changed while it was read' }
            $psm1Text = [System.Text.Encoding]::UTF8.GetString($psm1Bytes).TrimStart([char]0xFEFF) -replace "`r`n", "`n"
            $region = {
                param([string]$RegionName)
                $m = [regex]::Match($psm1Text, '(?ms)^#region win32-toolkit:' + $RegionName + '\n(.*?)\n#endregion win32-toolkit:' + $RegionName + '$')
                if (-not $m.Success) { & $invalid "no region 'win32-toolkit:$RegionName'" }
                $m.Groups[1].Value
            }
            # RemovePriorCatalogVersion: the first 16 hex characters of the SHA-256 of the three regions and the two functions
            # (their text as written, LF); it binds a proof to the device code.
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($psm1Text, [ref]$null, [ref]$null)
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($r in 'PriorPredicate', 'PriorEvaluate', 'PriorRuntime') { $parts.Add((& $region $r)) }
            foreach ($f in 'Assert-W32TPriorInstall', 'Remove-W32TPriorInstall') {
                $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $f }, $false)
                if (-not $fn) { & $invalid "no function $f" }
                $parts.Add($fn.Extent.Text)
            }
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($parts -join "`n")) } finally { $sha.Dispose() }
            $script:W32TPriorSourceCache[$cacheKey] = @{
                PriorPredicate            = $parts[0]
                PriorEvaluate             = $parts[1]
                RemovePriorCatalogVersion = (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
            }
        }
        return $script:W32TPriorSourceCache[$cacheKey][$Name]
    }

    $text = switch ($Name) {
        'Loader' {
            # The first line marks GeneratorVersion 3 and the extension version this script calls (Get-Win32ToolkitDeployScriptShape
            # reads it; Test-Win32ToolkitDeployExtension holds the project's copy to it). It is the current row of
            # Get-Win32ToolkitDeployExtension (DeployExtension.unit pins the pair).
            @'
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
'@
        }
        'Install' {
            if (-not $Technology) {
                throw [System.ArgumentException]::new('Get-Win32ToolkitDeployScriptBlock -Name Install needs -Technology (Exe or Appx).')
            }
            (@'
## Data-driven install: the installer named in SupportFiles\AppConfig.json (Installer), by the toolkit extension module.
PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $appConfig -Technology <Technology>
'@).Replace('<Technology>', $Technology)
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
PSAppDeployToolkit.Win32Toolkit\Install-W32TMsiPatch
'@
        }
        'InstallDone' {
            @'
$w32tInstallDone = $true
'@
        }
        'Uninstall' {
            # The revision marker is the uninstall revision of the extension version the Loader names
            # (Get-Win32ToolkitDeployExtension UninstallRevision; DeployExtension.unit pins the pair).
            @'
## Uninstall revision 2 (win32-toolkit): the app's uninstall from SupportFiles\AppConfig.json (Uninstall), by the toolkit extension module.
PSAppDeployToolkit.Win32Toolkit\Uninstall-W32TApp -AppConfig $appConfig
'@
        }
        'TattooInstall' {
            @'
## win32-toolkit install tattoo - records install state + version for the Intune detection rule (only when the Install phase ran to its end).
PSAppDeployToolkit.Win32Toolkit\Set-W32TInstallTattoo -AppConfig $appConfig -InstallDone $w32tInstallDone
'@
        }
        'TattooUninstall' {
            @'
## win32-toolkit install tattoo - removed at uninstall, with its legacy WOW6432Node copy.
PSAppDeployToolkit.Win32Toolkit\Remove-W32TInstallTattoo -AppConfig $appConfig
'@
        }
        'OrgUiPreInstall' {
            @'
## Org template dialogs - policy is DATA in SupportFiles\AppConfig.json (OrgUi); nothing is spliced here.
PSAppDeployToolkit.Win32Toolkit\Show-W32TInstallWelcome -AppConfig $appConfig
'@
        }
        'OrgUiPreMaintenance' {
            @'
## Org template dialogs - policy is DATA in SupportFiles\AppConfig.json (OrgUi); nothing is spliced here.
PSAppDeployToolkit.Win32Toolkit\Show-W32TMaintenanceWelcome -AppConfig $appConfig
'@
        }
        'OrgUiPostInstall' {
            @'
## Org template completion prompt - policy is DATA in SupportFiles\AppConfig.json (OrgUi.Completion).
PSAppDeployToolkit.Win32Toolkit\Show-W32TCompletionPrompt -AppConfig $appConfig
'@
        }
        'OrgUiPostInstallMsi' {
            @'
## Org template policy: no completion prompt after a Zero-Config MSI install (4.1.8 parity; the PSADT default prompt was removed).
'@
        }
        'OrgUiPostRepair' {
            @'
## Org template policy: no completion prompt after a repair (the PSADT default prompt was removed).
'@
        }
        'RemovePriorCheck' { $removePriorCheck }
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
