<#
    win32-toolkit's PSADT extension module (lean deploy script PR 1; design knowledge-base/designs/lean-deploy-script-extension.md
    sections 4.1, 4.7, 10): DeployExtension\PSAppDeployToolkit.Win32Toolkit\ and its host helpers.

    THE RISK: the module runs as SYSTEM on every device, is copied byte for byte into every package and is identified by
    the SHA-256 of its two files. A changed byte must be a deliberate new version; a value, a code-from-data construct or
    an app name must never get in; its functions must behave exactly like the block-catalog texts they carry; and a
    project's copy must never be replaced by an org folder or edited unnoticed.

    Covered here:
      [1]  the folder holds exactly the manifest and the module: UTF-8 with BOM, ASCII only, CRLF only.
      [2]  the known-versions table: the current row's hashes and version equal the files and the manifest; rows ascend;
           -Version / -All / -Verify; the reserved name is the same literal in every file that guards it.
      [3]  the manifest: RootModule, PowerShellVersion 5.1, one RequiredModules entry (PSADT's GUID, ModuleVersion 4.1.0 -
           a minimum), an explicit FunctionsToExport equal to Export-ModuleMember and to the module's functions, approved
           verbs, no cmdlet / variable / alias exports.
      [4]  value-free: no Invoke-Expression, Add-Type, [scriptblock]::Create, ExpandString, NewScriptBlock, web or
           process commands, Import-Module; '&' / '.' only on a variable the same function assigns a scriptblock literal
           to, or one assigned once at module level inside the prior-install regions (lean deploy script PR 3); no global
           writes; no app or vendor name.
      [5]  the catalog's call blocks (PR 2, PR 3): one module-qualified call each, into an exported function with
           parameters it declares and constant arguments; every export has a caller; the Loader marker, the uninstall
           revision marker and the prior-install revision marker name the current row.
      [6]  under Windows PowerShell 5.1, the module imported with PSADT's commands stubbed (and no $adtSession /
           $appConfig variable anywhere): module-level preferences; Install-W32TApp (EXE, APPX for a non-SYSTEM user,
           missing file, the 69114 refusal for every mismatch); Install-W32TMsiPatch; the two tattoo functions;
           the three org-ui functions; module-qualified calls.
      [7]  with the real PSADT the selector picks (SKIP without one, FAIL with W32T_REQUIRE_PSADT): Windows PowerShell 5.1
           imports PSADT by path, then the extension by its manifest - RequiredModules is satisfied by the loaded PSADT
           and exactly the ten functions are exported.
      [8]  Copy-Win32ToolkitDeployExtension (copy, replace, link / file / missing project refused, -WhatIf, a changed
           source refused), Get-Win32ToolkitDeployExtension -Verify on a changed / extended / incomplete source, and
           Test-Win32ToolkitDeployExtension (stray folders as warning or error, missing / unknown / mismatch, Staging).

    Nothing is installed or executed (PSADT commands are stubs; the real PSADT is only imported); everything is written
    below %TEMP% and removed.

    Run:  pwsh -File Tests\DeployExtension.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
$skip = 0
function Ok($m) { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# C-5 range (Select-Win32ToolkitPsadtModule and the shape reader read it).
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }
foreach ($f in 'Get-Win32ToolkitDeployExtension', 'Copy-Win32ToolkitDeployExtension', 'Test-Win32ToolkitDeployExtension',
    'Get-Win32ToolkitDeployScriptBlock', 'Get-Win32ToolkitDeployScriptShape', 'Test-Win32ToolkitPsadtVersionSupported',
    'Select-Win32ToolkitPsadtModule', 'Get-Win32ToolkitConfigValue', 'Test-Win32ToolkitPS51Syntax') {
    . (Join-Path $repo "Private\$f.ps1")
}

$ext = Get-Win32ToolkitDeployExtension
$extDir = Join-Path $repo "DeployExtension\$($ext.Name)"
$psd1Path = Join-Path $extDir "$($ext.Name).psd1"
$psm1Path = Join-Path $extDir "$($ext.Name).psm1"
$exports = @('Install-W32TApp', 'Install-W32TMsiPatch', 'Uninstall-W32TApp', 'Set-W32TInstallTattoo', 'Remove-W32TInstallTattoo',
    'Show-W32TInstallWelcome', 'Show-W32TMaintenanceWelcome', 'Show-W32TCompletionPrompt', 'Assert-W32TPriorInstall', 'Remove-W32TPriorInstall')

# == [1] files ===========================================================================================
Write-Host '[1] the folder: exactly the manifest and the module, UTF-8 with BOM, ASCII only, CRLF only' -ForegroundColor Cyan
$items = @(Get-ChildItem -LiteralPath $extDir -Force | Sort-Object Name | ForEach-Object { $_.Name })
if (($items -join '|') -ceq ((@("$($ext.Name).psd1", "$($ext.Name).psm1") | Sort-Object) -join '|')) { Ok "DeployExtension\$($ext.Name)\ holds exactly the .psd1 and the .psm1" } else { Bad "folder items: $($items -join ', ')" }
foreach ($p in $psd1Path, $psm1Path) {
    $b = [System.IO.File]::ReadAllBytes($p)
    $leaf = Split-Path $p -Leaf
    if ($b.Length -gt 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { Ok "$leaf starts with a UTF-8 BOM (5.1 reads a BOM-less file as ANSI)" } else { Bad "$leaf has no UTF-8 BOM" }
    if (@($b | Select-Object -Skip 3 | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok "$leaf is ASCII only" } else { Bad "$leaf has non-ASCII bytes" }
    $t = [System.IO.File]::ReadAllText($p)
    if ([regex]::Matches($t, '(?<!\r)\n').Count -eq 0 -and [regex]::Matches($t, '\r(?!\n)').Count -eq 0 -and $t.EndsWith("`r`n")) { Ok "$leaf has CRLF line ends only and ends with one" } else { Bad "$leaf has a bare LF / CR or no final CRLF" }
}
$attr = (& git -C $repo check-attr text -- "DeployExtension/$($ext.Name)/$($ext.Name).psm1" 2>$null) -join ''
if ($attr -match ': text: unset$') { Ok '.gitattributes: DeployExtension/** -text (no checkout changes the bytes)' } else { Bad ".gitattributes does not unset text for DeployExtension: '$attr'" }

# == [2] the known-versions table =========================================================================
Write-Host '[2] the known-versions table and the pin' -ForegroundColor Cyan
$manifest = Import-PowerShellDataFile -LiteralPath $psd1Path
$all = @(Get-Win32ToolkitDeployExtension -All)
if ($ext.Version -eq [version]$manifest.ModuleVersion -and $ext.IsCurrent) { Ok "the current row is the manifest's ModuleVersion $($ext.Version)" } else { Bad "current row $($ext.Version) vs manifest $($manifest.ModuleVersion)" }
$diff = @(foreach ($k in $ext.Files.Keys) { $h = (Get-FileHash -LiteralPath (Join-Path $extDir $k) -Algorithm SHA256).Hash; if ($h -ne $ext.Files[$k]) { "$k (pinned $($ext.Files[$k]), file $h)" } })
if ($diff.Count -eq 0 -and @($ext.Files.Keys).Count -eq 2) { Ok 'the current row pins the SHA-256 of both files (a changed file needs a new ModuleVersion and a new row)' } else { Bad "pin differs - bump ModuleVersion and add a row in Get-Win32ToolkitDeployExtension: $($diff -join '; ')" }
$ascending = $true
for ($i = 1; $i -lt $all.Count; $i++) { if ($all[$i].Version -le $all[$i - 1].Version) { $ascending = $false } }
if ($ascending -and @($all | Where-Object IsCurrent).Count -eq 1 -and $all[-1].IsCurrent) { Ok "$($all.Count) known row(s), versions ascending, only the last is current" } else { Bad 'known rows not ascending or IsCurrent wrong' }
$old = Get-Win32ToolkitDeployExtension -Version '1.0.0'
if ($ext.Name -ceq (Split-Path $extDir -Leaf) -and $ext.UninstallRevision -eq 2 -and $ext.RemovePriorRevision -eq 3 -and $old.UninstallRevision -eq 2 -and $old.RemovePriorRevision -eq 0) {
    Ok "the current row $($ext.Version): uninstall revision 2, prior-install revision 3; the 1.0.0 row (lean deploy script PR 2): no prior-install pair"
} else { Bad "rows: $($ext | Out-String) $($old | Out-String)" }
if ((Get-Win32ToolkitDeployExtension -Version '1.0.0').Version -eq [version]'1.0.0' -and $null -eq (Get-Win32ToolkitDeployExtension -Version '9.9.9')) { Ok '-Version returns the known row, $null for an unknown version' } else { Bad '-Version lookup' }
try { $v = Get-Win32ToolkitDeployExtension -Verify; if ($v.Version -eq $ext.Version) { Ok '-Verify passes on the repository copy' } else { Bad '-Verify returned another row' } } catch { Bad "-Verify on the repository copy: $($_.Exception.Message)" }
if ($all[0].Version -eq [version]'1.0.0') { Ok 'the oldest row is 1.0.0 (rows are never removed)' } else { Bad "first row: $($all[0].Version)" }
foreach ($guard in 'Private\Get-Win32ToolkitOrgExtensionLayoutFinding.ps1', 'Private\Add-Win32ToolkitOrgHooks.ps1') {
    if ((Get-Content -LiteralPath (Join-Path $repo $guard) -Raw).Contains("'$($ext.Name)'")) { Ok "$((Split-Path $guard -Leaf)) guards the same reserved name '$($ext.Name)'" } else { Bad "$guard does not name '$($ext.Name)'" }
}

# == [3] manifest =========================================================================================
Write-Host '[3] the manifest: layout, RequiredModules, explicit exports' -ForegroundColor Cyan
$psadtGuid = [guid]'8c3c366b-8606-4576-9f2d-4051144f7ca2'
if ($manifest.RootModule -ceq "$($ext.Name).psm1" -and $manifest.PowerShellVersion -eq '5.1' -and [guid]$manifest.GUID -ne $psadtGuid) { Ok "RootModule '$($ext.Name).psm1', PowerShellVersion 5.1, its own GUID (PSADT 4.2 imports <Dir>\<Dir>.psd1, 4.1 the folder)" } else { Bad "manifest keys: $($manifest.RootModule) $($manifest.PowerShellVersion) $($manifest.GUID)" }
$req = @($manifest.RequiredModules)
if ($req.Count -eq 1 -and $req[0] -is [hashtable] -and $req[0].ModuleName -ceq 'PSAppDeployToolkit' -and [guid]$req[0].Guid -eq $psadtGuid -and $req[0].ModuleVersion -ceq '4.1.0' -and
    -not $req[0].ContainsKey('RequiredVersion') -and -not $req[0].ContainsKey('MaximumVersion')) {
    Ok 'RequiredModules: PSAppDeployToolkit by GUID with ModuleVersion 4.1.0 - a minimum, so one copy serves 4.1.x and 4.2.x'
} else { Bad "RequiredModules: $($req | Out-String)" }
$psm1Ast = [System.Management.Automation.Language.Parser]::ParseFile($psm1Path, [ref]$null, [ref]$null)
$topFunctions = @($psm1Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Name })
$allFunctions = @($psm1Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$emm = $psm1Ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-ModuleMember' }, $true)
$emmNames = if ($emm) { @($emm.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Parent -isnot [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.Value }) } else { @() }
$fte = @($manifest.FunctionsToExport)
if (($fte -join '|') -ceq ($exports -join '|') -and ($emmNames -join '|') -ceq ($exports -join '|') -and ($topFunctions -join '|') -ceq ($exports -join '|') -and $allFunctions.Count -eq $exports.Count) {
    Ok "FunctionsToExport = Export-ModuleMember = the module's $($exports.Count) functions (explicit, no nested functions)"
} else { Bad "exports: manifest=$($fte -join ',') emm=$($emmNames -join ',') functions=$($topFunctions -join ',')" }
if (@($manifest.CmdletsToExport).Count -eq 0 -and @($manifest.VariablesToExport).Count -eq 0 -and @($manifest.AliasesToExport).Count -eq 0) { Ok 'no cmdlet, variable or alias exports' } else { Bad 'manifest exports cmdlets, variables or aliases' }
$approved = @(Get-Verb | ForEach-Object { $_.Verb })
$badVerb = @($exports | Where-Object { $approved -notcontains ($_ -split '-', 2)[0] -or ($_ -split '-', 2)[1] -notlike 'W32T*' })
if ($badVerb.Count -eq 0) { Ok 'approved verbs, every noun starts with W32T' } else { Bad "verb / noun: $($badVerb -join ', ')" }

# == [4] value-free ========================================================================================
Write-Host '[4] value-free: no code from data, no app names' -ForegroundColor Cyan
$forbidden = @('Invoke-Expression', 'iex', 'Add-Type', 'Invoke-WebRequest', 'Invoke-RestMethod', 'iwr', 'irm', 'Start-BitsTransfer', 'Import-Module',
    'New-Module', 'Invoke-Command', 'Start-Process', 'Set-ExecutionPolicy', 'Invoke-Item', 'New-PSDrive')
$cmds = @($psm1Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
$hits = @($cmds | Where-Object { $forbidden -contains $_.GetCommandName() } | ForEach-Object { $_.GetCommandName() })
if ($hits.Count -eq 0) { Ok "no $($forbidden.Count) forbidden commands (code from data, downloads, processes outside PSADT, imports)" } else { Bad "forbidden commands: $($hits -join ', ')" }
$members = @($psm1Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and @('Create', 'ExpandString', 'NewScriptBlock', 'InvokeScript') -contains $n.Member.Extent.Text }, $true))
if ($members.Count -eq 0 -and $psm1Ast.Extent.Text -notmatch '(?i)-EncodedCommand|\[scriptblock\]::') { Ok 'no [scriptblock]::Create / ExpandString / NewScriptBlock / InvokeScript / -EncodedCommand' } else { Bad "code-from-text members: $($members.Extent.Text -join ' | ')" }
$invokes = @($cmds | Where-Object { $_.InvocationOperator -in @([System.Management.Automation.Language.TokenKind]::Ampersand, [System.Management.Automation.Language.TokenKind]::Dot) })
$badInvoke = [System.Collections.Generic.List[string]]::new()
$isBlock = { param($n, [string]$Name) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq "`$$Name" -and
    $n.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and $n.Right.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }
# Lean deploy script PR 3: the prior-install regions assign their scriptblocks once at module level (outside every function),
# and the two prior-install functions and those scriptblocks call them.
$priorSpans = @([regex]::Matches($psm1Ast.Extent.Text, '(?ms)^#region win32-toolkit:Prior\w+\r?\n.*?^#endregion win32-toolkit:Prior\w+') | ForEach-Object { @{ Start = $_.Index; End = $_.Index + $_.Length } })
$moduleBlocks = @{}
foreach ($a in @($psm1Ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and $_.Right.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst] })) {
    $inRegion = @($priorSpans | Where-Object { $a.Extent.StartOffset -ge $_.Start -and $a.Extent.EndOffset -le $_.End }).Count -eq 1
    $n = $a.Left.Extent.Text.TrimStart('$')
    if ($inRegion) { if ($moduleBlocks.ContainsKey($n)) { $moduleBlocks[$n] = 2 } else { $moduleBlocks[$n] = 1 } }
}
foreach ($c in $invokes) {
    $target = $c.CommandElements[0]
    $fn = $c.Parent; while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
    $ok = $false
    if ($target -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = $target.VariablePath.UserPath
        $own = if ($fn) { @($fn.FindAll({ param($n) & $isBlock $n $name }, $true)).Count } else { 0 }
        $ok = $own -eq 1 -or ($own -eq 0 -and $moduleBlocks[$name] -eq 1)
    }
    if (-not $ok) { $badInvoke.Add($c.Extent.Text) }
}
$stray = @($psm1Ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] } | Where-Object { $s = $_; @($priorSpans | Where-Object { $s.Extent.StartOffset -ge $_.Start -and $s.Extent.EndOffset -le $_.End }).Count -eq 0 } | ForEach-Object { $_.Extent.Text.Split("`n")[0] })
if ($stray.Count -eq 4 -and $stray[0] -like '$ErrorActionPreference = *' -and $stray[-1] -like 'Export-ModuleMember *') { Ok 'module-level code outside a function: the three preferences, the prior-install regions and Export-ModuleMember only' } else { Bad "module-level statements outside the prior regions: $($stray -join ' | ')" }
if ($invokes.Count -gt 0 -and $badInvoke.Count -eq 0) { Ok "every '&' / '.' ($($invokes.Count)) runs a scriptblock literal its own function assigned once, or one a prior-install region assigned once at module level ($($moduleBlocks.Count))" } else { Bad "invocations of something else: $($badInvoke -join ' | ')" }
$globals = @($psm1Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsGlobal }, $true))
if ($globals.Count -eq 0 -and $psm1Ast.Extent.Text -notmatch '(?i)-Scope\s+Global') { Ok 'no $global: variable and no -Scope Global' } else { Bad "global state: $($globals.Extent.Text -join ', ')" }
$appNames = '(?i)firefox|mozilla|helper\.exe|notepad|7-zip|chrome|google|adobe|zoom|contoso'
$named = @([regex]::Matches([System.IO.File]::ReadAllText($psm1Path), $appNames) | ForEach-Object { $_.Value })
if ($named.Count -eq 0) { Ok 'no app or vendor name (the module ships in every package)' } else { Bad "app / vendor names: $($named -join ', ')" }

# == [5] the catalog's call blocks ===========================================================================
Write-Host "[5] the catalog's call blocks: one module-qualified call each, into a function the module exports" -ForegroundColor Cyan
# Lean deploy script PR 2: the generator places these blocks; their code is one call into this module. Every call names an
# exported function with parameters it declares and constant arguments only; every exported function has a caller; the
# loader marker and the uninstall revision marker name the current row of the known-versions table.
$calls = [ordered]@{ 'Install (Exe)' = @{ Name = 'Install'; Tech = 'Exe' }; 'Install (Appx)' = @{ Name = 'Install'; Tech = 'Appx' }; 'Msp' = @{ Name = 'Msp' }; 'Uninstall' = @{ Name = 'Uninstall' }
    'TattooInstall' = @{ Name = 'TattooInstall' }; 'TattooUninstall' = @{ Name = 'TattooUninstall' }; 'OrgUiPreInstall' = @{ Name = 'OrgUiPreInstall' }
    'OrgUiPreMaintenance' = @{ Name = 'OrgUiPreMaintenance' }; 'OrgUiPostInstall' = @{ Name = 'OrgUiPostInstall' }
    'RemovePriorCheck' = @{ Name = 'RemovePriorCheck' }; 'RemovePrior' = @{ Name = 'RemovePrior' } }
$called = [System.Collections.Generic.List[string]]::new()
$allowedArgs = @('$appConfig', '$w32tInstallDone', 'Exe', 'Appx')
foreach ($label in $calls.Keys) {
    $c = $calls[$label]
    $text = if ($c.Tech) { Get-Win32ToolkitDeployScriptBlock -Name $c.Name -Technology $c.Tech } else { Get-Win32ToolkitDeployScriptBlock -Name $c.Name }
    $code = @(($text -split "`n") | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
    $blockAst = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
    $cmd = @($blockAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    $ok = $code.Count -eq 1 -and $cmd.Count -eq 1 -and $cmd[0].GetCommandName() -like "$($ext.Name)\*"
    $fnName = if ($cmd.Count -eq 1) { ($cmd[0].GetCommandName() -split '\\', 2)[1] } else { '' }
    $fnAst = $allFunctions | Where-Object { $_.Name -eq $fnName } | Select-Object -First 1
    $declared = if ($fnAst -and $fnAst.Body.ParamBlock) { @($fnAst.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) } else { @() }
    $named = if ($cmd.Count -eq 1) { @($cmd[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName }) } else { @() }
    $values = if ($cmd.Count -eq 1) { @($cmd[0].CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.Extent.Text }) } else { @() }
    if ($ok -and $fnAst -and $exports -contains $fnName -and @($named | Where-Object { $declared -notcontains $_ }).Count -eq 0 -and @($values | Where-Object { $allowedArgs -cnotcontains $_ }).Count -eq 0) {
        Ok "catalog '$label': $($cmd[0].Extent.Text)"
        $called.Add($fnName)
    } else { Bad "catalog '$label' is not one module-qualified call to an exported function with declared parameters and constant arguments: $($code -join ' | ')" }
}
$unused = @($exports | Where-Object { $called -notcontains $_ })
if ($unused.Count -eq 0) { Ok 'every exported function has a caller in the catalog' } else { Bad "exported but never called: $($unused -join ', ')" }
$loader = Get-Win32ToolkitDeployScriptBlock -Name Loader
if (($loader -split "`n")[0] -ceq "## win32-toolkit generator 3; extension $($ext.Name) $($ext.Version)") { Ok "the Loader's first line names generator 3 and the current extension $($ext.Name) $($ext.Version)" } else { Bad "Loader marker: $(($loader -split "`n")[0])" }
$un = [regex]::Match((Get-Win32ToolkitDeployScriptBlock -Name Uninstall), '## Uninstall revision (\d+) \(win32-toolkit\)')
if ($un.Success -and [int]$un.Groups[1].Value -eq $ext.UninstallRevision) { Ok "the Uninstall call block names uninstall revision $($ext.UninstallRevision), the extension's" } else { Bad 'Uninstall revision marker does not match the extension row' }
$pr = [regex]::Match((Get-Win32ToolkitDeployScriptBlock -Name RemovePriorCheck), '## remove-prior catalog revision (\d+) \(win32-toolkit\)')
if ($pr.Success -and [int]$pr.Groups[1].Value -eq $ext.RemovePriorRevision -and $ext.RemovePriorRevision -eq (Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision)) { Ok "the prior-check call block names prior-install revision $($ext.RemovePriorRevision), the extension's" } else { Bad 'prior-install revision marker does not match the extension row' }
# == [6] Windows PowerShell 5.1: the functions with PSADT stubbed ===========================================
Write-Host '[6] the functions under Windows PowerShell 5.1 (PSADT commands stubbed)' -ForegroundColor Cyan
$ps51 = Get-Command powershell.exe -ErrorAction SilentlyContinue
$parse51 = @(Test-Win32ToolkitPS51Syntax -Path $psm1Path) + @(Test-Win32ToolkitPS51Syntax -Path $psd1Path)
if ($ps51 -and $parse51.Count -eq 0) { Ok 'the .psm1 and the .psd1 parse under Windows PowerShell 5.1' } elseif (-not $ps51) { Write-Host '  SKIP: no Windows PowerShell 5.1' -ForegroundColor DarkYellow; $skip++ } else { Bad "5.1 parse: $($parse51 -join ' | ')" }

$harness = @'
param([string]$ModulePath)
# Run with -File: Windows PowerShell 5.1 runs it in the global scope, so the stubs below are global and the module's
# functions resolve them, while the module keeps its own variables. There is no $adtSession / $appConfig variable anywhere.
Set-StrictMode -Version 1
$ErrorActionPreference = 'Stop'
$fail = 0
function Ok($m) { Write-Output "PASS: $m" }
function Bad($m) { Write-Output "FAIL: $m"; $script:fail++ }

$root = Join-Path $env:TEMP ('w32tde-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$filesDir = Join-Path $root 'Files'
New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
$calls = New-Object System.Collections.ArrayList
function Copy-Bound($b) { $h = @{}; foreach ($k in @($b.Keys)) { $h[$k] = $b[$k] }; $h }
function Rec([string]$Cmd, $Bound) { [void]$calls.Add((New-Object psobject -Property @{ Cmd = $Cmd; Bound = (Copy-Bound $Bound) })) }
function Get-Calls([string]$Cmd) { @($calls | Where-Object { $_.Cmd -eq $Cmd }) }

$w32tFake = New-Object psobject -Property @{ DirFiles = $filesDir; DirSupportFiles = (Join-Path $root 'SupportFiles'); UseDefaultMsi = $false; DefaultMspFiles = @(); AppProcessesToClose = @(); ExitCode = $null }
$w32tFake | Add-Member -MemberType ScriptMethod -Name SetExitCode -Value { param($c) $this.ExitCode = $c }
function Get-ADTSession { $w32tFake }
function Write-ADTLogEntry { [CmdletBinding()] param([string]$Message, [int]$Severity = 1) Rec 'Write-ADTLogEntry' $PSBoundParameters }
function Start-ADTProcess { [CmdletBinding()] param([string]$FilePath, [string[]]$ArgumentList, [switch]$PassThru, [switch]$WaitForChildProcesses, $Timeout) Rec 'Start-ADTProcess' $PSBoundParameters; New-Object psobject -Property @{ ExitCode = 0 } }
function Start-ADTMsiProcess { [CmdletBinding()] param($Action, $FilePath, $ProductCode, [switch]$PassThru) Rec 'Start-ADTMsiProcess' $PSBoundParameters }
function Show-ADTInstallationWelcome { [CmdletBinding()] param([switch]$AllowDefer, [int]$DeferTimes, [switch]$CheckDiskSpace, [switch]$PersistPrompt, $CloseProcesses, [switch]$BlockExecution, [int]$CloseProcessesCountdown) Rec 'Show-ADTInstallationWelcome' $PSBoundParameters }
function Show-ADTInstallationProgress { [CmdletBinding()] param([string]$StatusMessage, [string]$StatusMessageDetail) Rec 'Show-ADTInstallationProgress' $PSBoundParameters }
function Show-ADTInstallationPrompt { [CmdletBinding()] param([string]$Message, [string]$ButtonRightText, [switch]$NoWait) Rec 'Show-ADTInstallationPrompt' $PSBoundParameters }
function Set-ADTRegistryKey { [CmdletBinding()] param([string]$Key, [string]$Name, $Value, [string]$Type) Rec 'Set-ADTRegistryKey' $PSBoundParameters }
function Remove-ADTRegistryKey { [CmdletBinding()] param([string]$Key, [switch]$Recurse, [switch]$Wow6432Node) Rec 'Remove-ADTRegistryKey' $PSBoundParameters }
function Add-AppxPackage { [CmdletBinding()] param([string]$Path) Rec 'Add-AppxPackage' $PSBoundParameters }
function Add-AppxProvisionedPackage { [CmdletBinding()] param([switch]$Online, [string]$PackagePath, [switch]$SkipLicense, $Regions) Rec 'Add-AppxProvisionedPackage' $PSBoundParameters }

function Run([scriptblock]$Call) {
    $calls.Clear(); $w32tFake.ExitCode = $null
    try { $null = & $Call; 'ok' } catch { "threw: $($_.Exception.Message)" }
}
function Log { @(Get-Calls 'Write-ADTLogEntry' | ForEach-Object { "[$($_.Bound.Severity)] $($_.Bound.Message)" }) -join ' | ' }

try {
    $mod = Import-Module -Name $ModulePath -PassThru
    if (-not (Get-Variable -Name adtSession, appConfig -Scope Global -ErrorAction SilentlyContinue)) { Ok 'no $adtSession / $appConfig variable exists: the functions must use Get-ADTSession and -AppConfig' } else { Bad 'a global $adtSession / $appConfig exists' }
    # StrictMode 1 exempts variables inside strings: probe outside one.
    $strict = & $mod { try { $null = $w32tStrictProbe; 'loose' } catch { 'strict' } }
    $prefs = (& $mod { "$ErrorActionPreference|$ProgressPreference" }) + "|$strict"
    if ($prefs -eq 'Stop|SilentlyContinue|strict') { Ok 'module-level preferences: ErrorAction Stop, Progress SilentlyContinue, StrictMode 1 (an unset variable throws)' } else { Bad "module preferences: $prefs" }
    if (@(Get-Command -Module $mod.Name | ForEach-Object { $_.Name } | Sort-Object).Count -eq 10) { Ok 'the module exports its 10 functions' } else { Bad "exported: $((Get-Command -Module $mod.Name).Name -join ', ')" }

    # ---- Install-W32TApp ----
    $exe = Join-Path $filesDir 'App_x64_1.0.exe'; Set-Content -LiteralPath $exe -Value 'x'
    $cfg = New-Object psobject -Property @{ App = (New-Object psobject -Property @{ Name = 'App' }); Installer = (New-Object psobject -Property @{ Type = 'exe'; FileName = 'App_x64_1.0.exe'; SilentArgs = '/S /norestart' }) }
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $cfg -Technology Exe }
    $s = @(Get-Calls 'Start-ADTProcess')
    if ($r -eq 'ok' -and $s.Count -eq 1 -and $s[0].Bound.FilePath -ceq $exe -and (@($s[0].Bound.ArgumentList) -join '|') -ceq '/S /norestart' -and $s[0].Bound.PassThru -and $null -eq $w32tFake.ExitCode) { Ok 'Exe: Start-ADTProcess with the installer path, SilentArgs as one argument string, -PassThru (module-qualified call)' } else { Bad "Exe: $r $(Log)" }
    $cfg.Installer.SilentArgs = ''
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $cfg -Technology Exe }
    $s = @(Get-Calls 'Start-ADTProcess')
    if ($r -eq 'ok' -and $s.Count -eq 1 -and -not $s[0].Bound.ContainsKey('ArgumentList')) { Ok 'Exe without SilentArgs: no -ArgumentList' } else { Bad "Exe no args: $r" }
    $cfg.Installer.FileName = 'missing.exe'
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $cfg -Technology Exe }
    if ($r -like 'threw: Installer file not found:*' -and (Log).Contains('[3] Installer file not found:') -and @(Get-Calls 'Start-ADTProcess').Count -eq 0) { Ok 'a missing installer file: severity-3 line, throws, nothing started' } else { Bad "missing: $r $(Log)" }
    $cfg.Installer.FileName = 'App_x64_1.0.exe'
    foreach ($c in @(
            @{ T = 'Appx'; Type = 'exe'; L = "-Technology Appx with Installer.Type 'exe'" }
            @{ T = 'Exe'; Type = 'msix'; L = "-Technology Exe with Installer.Type 'msix'" }
            @{ T = 'Exe'; Type = 'msi'; L = "-Technology Exe with Installer.Type 'msi' (Zero-Config owns it)" }
            @{ T = 'Exe'; Type = ''; L = 'an empty Installer.Type' }
        )) {
        $cfg.Installer.Type = $c.Type
        $tech = $c.T
        $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $cfg -Technology $tech }
        if ($r -like '*nothing installed (exit code 69114)*' -and $w32tFake.ExitCode -eq 69114 -and (Log) -like '`[3`] win32-toolkit: the deploy script calls Install-W32TApp*' -and @(Get-Calls 'Start-ADTProcess').Count -eq 0 -and @(Get-Calls 'Add-AppxPackage').Count -eq 0) {
            Ok "$($c.L) -> SetExitCode(69114), one severity-3 line, throws, nothing installed"
        } else { Bad "$($c.L): $r code=$($w32tFake.ExitCode) $(Log)" }
    }
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $null -Technology Exe }
    if ($w32tFake.ExitCode -eq 69114 -and $r -like '*69114*') { Ok 'AppConfig $null -> 69114' } else { Bad "null config: $r" }
    $noInst = New-Object psobject -Property @{ App = (New-Object psobject); Installer = $null }
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $noInst -Technology Appx }
    if ($w32tFake.ExitCode -eq 69114 -and $r -like '*69114*') { Ok "the loader's fallback (no AppConfig.json: Installer `$null) -> 69114 (today's block installs nothing silently)" } else { Bad "no installer: $r" }
    $cfg.Installer.Type = "e`nx[e]"
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $cfg -Technology Exe }
    if ((Log) -like "*has Installer.Type 'e?x?e?'; nothing installed*") { Ok 'the refused type is logged as printable ASCII without CMTrace delimiters' } else { Bad "shown type: $(Log)" }
    $cfg.Installer.Type = 'EXE'
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $cfg -Technology Exe }
    if ($r -eq 'ok' -and @(Get-Calls 'Start-ADTProcess').Count -eq 1) { Ok "Installer.Type 'EXE' matches Exe (case-insensitive, as the block's -ne 'msi')" } else { Bad "upper case: $r" }
    $msix = Join-Path $filesDir 'App_x64_1.0.msix'; Set-Content -LiteralPath $msix -Value 'x'
    $cfg.Installer.Type = 'msix'; $cfg.Installer.FileName = 'App_x64_1.0.msix'
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $cfg -Technology Appx }
    $a = @(Get-Calls 'Add-AppxPackage')
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { Ok 'SKIP-equivalent: the test runs as SYSTEM (provisioning branch not asserted here)' }
    elseif ($r -eq 'ok' -and $a.Count -eq 1 -and $a[0].Bound.Path -ceq $msix -and @(Get-Calls 'Add-AppxProvisionedPackage').Count -eq 0 -and @(Get-Calls 'Start-ADTProcess').Count -eq 0) { Ok 'Appx for a non-SYSTEM user: Add-AppxPackage -Path <package>, no provisioning, no Start-ADTProcess' }
    else { Bad "Appx: $r $(Log)" }
    $cfg.Installer.Type = 'appx'
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TApp -AppConfig $cfg -Technology Appx }
    if ($r -eq 'ok' -and @(Get-Calls 'Add-AppxPackage').Count -eq 1) { Ok "Installer.Type 'appx' matches Appx" } else { Bad "appx: $r" }

    # ---- Install-W32TMsiPatch ----
    $msp1 = New-Item -ItemType File -Path (Join-Path $filesDir 'a.msp') -Force; $msp2 = New-Item -ItemType File -Path (Join-Path $filesDir 'b.msp') -Force
    $w32tFake.UseDefaultMsi = $true; $w32tFake.DefaultMspFiles = @($msp1, $msp2)
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TMsiPatch }
    $m = @(Get-Calls 'Start-ADTMsiProcess')
    if ($r -eq 'ok' -and $m.Count -eq 2 -and $m[0].Bound.Action -eq 'Patch' -and $m[0].Bound.FilePath -ceq $msp1.FullName -and $m[1].Bound.FilePath -ceq $msp2.FullName) { Ok 'msp: one Start-ADTMsiProcess -Action Patch per .msp (FullName) when the session uses the default MSI' } else { Bad "msp: $r $($m.Count)" }
    $w32tFake.UseDefaultMsi = $false
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Install-W32TMsiPatch }
    if ($r -eq 'ok' -and @(Get-Calls 'Start-ADTMsiProcess').Count -eq 0) { Ok 'msp: nothing without the default MSI' } else { Bad 'msp ran without UseDefaultMsi' }

    # ---- tattoo ----
    $tc = New-Object psobject -Property @{ App = (New-Object psobject -Property @{ ScriptAuthor = 'Org'; Vendor = 'Vendor'; DisplayName = 'App Display'; Name = ''; Version = '1.2.3' }) }
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Set-W32TInstallTattoo -AppConfig $tc -InstallDone $true }
    $k = @(Get-Calls 'Set-ADTRegistryKey')
    if ($r -eq 'ok' -and $k.Count -eq 1 -and $k[0].Bound.Key -ceq 'HKLM:\SOFTWARE\Org\Vendor\App Display' -and $k[0].Bound.Name -ceq 'Version' -and $k[0].Bound.Value -ceq '1.2.3' -and $k[0].Bound.Type -ceq 'String') { Ok 'tattoo: HKLM:\SOFTWARE\<Author>\<Vendor>\<DisplayName>\Version = App.Version when the Install phase ran to its end' } else { Bad "tattoo: $r $($k | Out-String)" }
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Set-W32TInstallTattoo -AppConfig $tc -InstallDone $false }
    if ($r -eq 'ok' -and @(Get-Calls 'Set-ADTRegistryKey').Count -eq 0 -and (Log) -ceq '[2] win32-toolkit: the Install phase did not run to its end - the detection tattoo was NOT written.') { Ok 'tattoo: -InstallDone $false -> the severity-2 line, no key' } else { Bad "tattoo not done: $r $(Log)" }
    $tc.App.ScriptAuthor = ''
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Set-W32TInstallTattoo -AppConfig $tc -InstallDone $true }
    if ($r -eq 'ok' -and @(Get-Calls 'Set-ADTRegistryKey').Count -eq 0) { Ok 'tattoo: no ScriptAuthor -> no key (no empty registry segment)' } else { Bad 'tattoo without author wrote a key' }
    $tc.App.ScriptAuthor = 'Org'; $tc.App.DisplayName = ''; $tc.App.Name = 'AppName'
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Remove-W32TInstallTattoo -AppConfig $tc }
    $k = @(Get-Calls 'Remove-ADTRegistryKey')
    if ($r -eq 'ok' -and $k.Count -eq 1 -and $k[0].Bound.Key -ceq 'HKLM:\SOFTWARE\Org\Vendor\AppName' -and $k[0].Bound.Recurse -and -not $k[0].Bound.ContainsKey('Wow6432Node')) { Ok 'remove tattoo: the key (App.Name when DisplayName is empty), -Recurse; no legacy copy -> no WOW6432Node call' } else { Bad "remove tattoo: $r $($k.Count)" }
    function Test-Path { [CmdletBinding()] param([string]$LiteralPath, [string]$PathType) if ($LiteralPath -ceq 'HKLM:\SOFTWARE\WOW6432Node\Org\Vendor\AppName') { return $true }; Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Remove-W32TInstallTattoo -AppConfig $tc }
    Remove-Item -LiteralPath Function:\Test-Path
    $k = @(Get-Calls 'Remove-ADTRegistryKey')
    if ($r -eq 'ok' -and $k.Count -eq 2 -and $k[1].Bound.Wow6432Node -and $k[1].Bound.Key -ceq 'HKLM:\SOFTWARE\Org\Vendor\AppName') { Ok 'remove tattoo: a legacy WOW6432Node copy present -> also removed with -Wow6432Node (64-bit 5.1)' } else { Bad "legacy: $r $($k.Count)" }

    # ---- org-ui ----
    $w32tFake.AppProcessesToClose = @('app')
    $ui = New-Object psobject -Property @{ OrgUi = (New-Object psobject -Property @{
                Welcome          = (New-Object psobject -Property @{ Enabled = $true; AllowDefer = $true; DeferTimes = 3; CheckDiskSpace = $true; PersistPrompt = $false; BlockExecution = $true; CloseProcessesCountdown = 90000 })
                UninstallWelcome = (New-Object psobject -Property @{ Enabled = $true; CloseProcessesCountdown = 60; PersistPrompt = $true; BlockExecution = $false })
                Progress         = (New-Object psobject -Property @{ Enabled = $true; StatusMessage = 'Installing'; StatusMessageDetail = '' })
                Completion       = (New-Object psobject -Property @{ Enabled = $true; Message = 'Done'; ButtonRightText = '' }) }) }
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Show-W32TInstallWelcome -AppConfig $ui }
    $w = @(Get-Calls 'Show-ADTInstallationWelcome'); $p = @(Get-Calls 'Show-ADTInstallationProgress')
    if ($r -eq 'ok' -and $w.Count -eq 1 -and $w[0].Bound.AllowDefer -and $w[0].Bound.DeferTimes -eq 3 -and $w[0].Bound.CheckDiskSpace -and -not $w[0].Bound.ContainsKey('PersistPrompt') -and
        (@($w[0].Bound.CloseProcesses) -join ',') -eq 'app' -and $w[0].Bound.BlockExecution -and -not $w[0].Bound.ContainsKey('CloseProcessesCountdown') -and
        $p.Count -eq 1 -and $p[0].Bound.StatusMessage -ceq 'Installing' -and -not $p[0].Bound.ContainsKey('StatusMessageDetail')) {
        Ok 'install welcome: the OrgUi policy as parameters, the session processes to close, an out-of-range countdown dropped; progress with its message only'
    } else { Bad "install welcome: $r $($w | ForEach-Object { $_.Bound | Out-String })" }
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Show-W32TMaintenanceWelcome -AppConfig $ui }
    $w = @(Get-Calls 'Show-ADTInstallationWelcome')
    if ($r -eq 'ok' -and $w.Count -eq 1 -and $w[0].Bound.CloseProcessesCountdown -eq 60 -and $w[0].Bound.PersistPrompt -and -not $w[0].Bound.ContainsKey('BlockExecution') -and @(Get-Calls 'Show-ADTInstallationProgress').Count -eq 1) { Ok 'maintenance welcome: close-apps with its countdown and PersistPrompt; progress' } else { Bad "maintenance: $r" }
    $w32tFake.AppProcessesToClose = @()
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Show-W32TMaintenanceWelcome -AppConfig $ui }
    if ($r -eq 'ok' -and @(Get-Calls 'Show-ADTInstallationWelcome').Count -eq 0) { Ok 'maintenance welcome: no process to close -> no welcome' } else { Bad 'maintenance welcome without processes' }
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Show-W32TCompletionPrompt -AppConfig $ui }
    $c = @(Get-Calls 'Show-ADTInstallationPrompt')
    if ($r -eq 'ok' -and $c.Count -eq 1 -and $c[0].Bound.Message -ceq 'Done' -and $c[0].Bound.ButtonRightText -ceq 'OK' -and $c[0].Bound.NoWait) { Ok "completion prompt: the message, 'OK' for an empty button text, -NoWait" } else { Bad "completion: $r" }
    $w32tFake.UseDefaultMsi = $true
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Show-W32TCompletionPrompt -AppConfig $ui }
    if ($r -eq 'ok' -and @(Get-Calls 'Show-ADTInstallationPrompt').Count -eq 0) { Ok 'completion prompt: never for a Zero-Config MSI (UseDefaultMsi)' } else { Bad 'completion prompt shown for UseDefaultMsi' }
    $w32tFake.UseDefaultMsi = $false
    $r = Run { PSAppDeployToolkit.Win32Toolkit\Show-W32TInstallWelcome -AppConfig (New-Object psobject -Property @{ App = $null }) }
    if ($r -eq 'ok' -and $calls.Count -eq 0) { Ok 'org-ui with no OrgUi section: nothing shown, no error' } else { Bad "no OrgUi: $r" }
}
catch { Bad "the harness stopped: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage -replace '\s*[\r\n]+\s*', ' ')" }
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "RESULT: $fail"
exit $fail
'@

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('w32de_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    if ($ps51) {
        $harnessFile = Join-Path $work 'harness.ps1'
        [System.IO.File]::WriteAllText($harnessFile, $harness, (New-Object System.Text.UTF8Encoding($true)))
        $out = @(& $ps51.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harnessFile -ModulePath $psm1Path 2>&1 | ForEach-Object { "$_" })
        $childExit = $LASTEXITCODE
        $passes = 0
        foreach ($line in $out) {
            if ($line -like 'PASS: *') { Ok "5.1: $($line.Substring(6))"; $passes++ }
            elseif ($line -like 'FAIL: *') { Bad "5.1: $($line.Substring(6))" }
        }
        $result = @($out | Where-Object { $_ -like 'RESULT: *' })
        if ($result.Count -eq 1 -and $childExit -eq [int]$result[0].Substring(8) -and $passes -ge 25) { Ok "the 5.1 child ran to its end ($passes checks, exit $childExit)" }
        else { Bad "the 5.1 child did not finish: exit $childExit, $passes passes, output:`n$($out -join "`n")" }
    }

    # == [7] the real PSADT ===================================================================================
    Write-Host '[7] Windows PowerShell 5.1 imports the real PSADT, then the extension by its manifest' -ForegroundColor Cyan
    $sel = Select-Win32ToolkitPsadtModule
    if (-not $ps51 -or $sel.Status -ne 'Selected') {
        if ($env:W32T_REQUIRE_PSADT) { Bad "no PSADT selected ($($sel.Status)) and W32T_REQUIRE_PSADT is set" }
        else { Write-Host "  SKIP: no PSADT selected ($($sel.Status)) or no Windows PowerShell 5.1" -ForegroundColor DarkYellow; $skip++ }
    }
    else {
        $probe = Join-Path $work 'probe.ps1'
        @'
param([string]$Psadt, [string]$Ext)
$ErrorActionPreference = 'Stop'
try {
    Import-Module -Name $Psadt
    $m = Import-Module -Name $Ext -PassThru
    Write-Output ('NAMES ' + ((Get-Command -Module $m.Name | ForEach-Object { $_.Name } | Sort-Object) -join ','))
    Write-Output ('QUALIFIED ' + (Get-Command -Name 'PSAppDeployToolkit.Win32Toolkit\Install-W32TApp').Source)
    Write-Output ('SESSIONCMD ' + (Get-Command -Name Get-ADTSession).Source)
    Write-Output ('PSADT ' + (Get-Module -Name PSAppDeployToolkit).Version)
}
catch { Write-Output "ERROR $($_.Exception.Message)" }
'@ | Set-Content -LiteralPath $probe -Encoding UTF8
        $out = @(& $ps51.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe -Psadt $sel.Module.Path -Ext $psd1Path 2>&1 | ForEach-Object { "$_" })
        $names = ($out | Where-Object { $_ -like 'NAMES *' } | Select-Object -First 1)
        $want = 'NAMES ' + (($exports | Sort-Object) -join ',')
        if ($names -ceq $want -and ($out -contains "QUALIFIED $($ext.Name)") -and ($out -contains 'SESSIONCMD PSAppDeployToolkit')) {
            Ok "PSADT $($sel.VersionText) by path, then the extension by its manifest: RequiredModules satisfied by the loaded PSADT, the 10 functions exported, a module-qualified name resolves, Get-ADTSession is PSADT's"
        } else { Bad "real import:`n$($out -join "`n")" }
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# == [8] host helpers ======================================================================================
Write-Host '[8] Copy- / Get- (-Verify) / Test-Win32ToolkitDeployExtension' -ForegroundColor Cyan
$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('w32dx_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
function Get-Fqid([scriptblock]$Do) { try { $null = & $Do; '' } catch { $_.FullyQualifiedErrorId } }
try {
    $proj = Join-Path $TMP 'proj'; New-Item -ItemType Directory -Path $proj -Force | Out-Null
    $dest = Join-Path $proj $ext.Name
    $null = Copy-Win32ToolkitDeployExtension -ProjectPath $proj -WhatIf
    if (-not (Test-Path -LiteralPath $dest)) { Ok '-WhatIf copies nothing' } else { Bad '-WhatIf created the folder' }
    $d = Copy-Win32ToolkitDeployExtension -ProjectPath $proj
    $same = @(foreach ($k in $ext.Files.Keys) { (Get-FileHash -LiteralPath (Join-Path $dest $k) -Algorithm SHA256).Hash -eq $ext.Files[$k] }) -notcontains $false
    if ($d -is [System.IO.DirectoryInfo] -and $d.FullName -eq $dest -and $same -and @(Get-ChildItem -LiteralPath $dest).Count -eq 2) { Ok 'copied into the project root, byte for byte, exactly the two files' } else { Bad "copy: $($d.FullName) same=$same" }
    Set-Content -LiteralPath (Join-Path $dest 'stale.txt') -Value 'x'
    Add-Content -LiteralPath (Join-Path $dest "$($ext.Name).psm1") -Value '# edited'
    $null = Copy-Win32ToolkitDeployExtension -ProjectPath $proj
    if (-not (Test-Path -LiteralPath (Join-Path $dest 'stale.txt')) -and (Get-FileHash -LiteralPath (Join-Path $dest "$($ext.Name).psm1") -Algorithm SHA256).Hash -eq $ext.Files["$($ext.Name).psm1"]) { Ok 'a second copy replaces an edited project copy and drops extra files' } else { Bad 'second copy kept a stale or edited file' }
    $proj2 = Join-Path $TMP 'proj2'; New-Item -ItemType Directory -Path $proj2 -Force | Out-Null
    $target = Join-Path $TMP 'target'; New-Item -ItemType Directory -Path $target -Force | Out-Null; Set-Content -LiteralPath (Join-Path $target 'canary.txt') -Value 'keep'
    $null = New-Item -ItemType Junction -Path (Join-Path $proj2 $ext.Name) -Value $target
    $fq = Get-Fqid { Copy-Win32ToolkitDeployExtension -ProjectPath $proj2 }
    if ($fq -eq 'W32T.DeployExtensionInvalid' -and (Test-Path -LiteralPath (Join-Path $target 'canary.txt'))) { Ok 'a project folder of that name that is a link -> W32T.DeployExtensionInvalid; the link target is untouched' } else { Bad "junction: $fq" }
    [System.IO.Directory]::Delete((Join-Path $proj2 $ext.Name))
    Set-Content -LiteralPath (Join-Path $proj2 $ext.Name) -Value 'x'
    $fq = Get-Fqid { Copy-Win32ToolkitDeployExtension -ProjectPath $proj2 }
    if ($fq -eq 'W32T.DeployExtensionInvalid') { Ok 'a file of that name -> refused' } else { Bad "file: $fq" }
    $fq = Get-Fqid { Copy-Win32ToolkitDeployExtension -ProjectPath (Join-Path $TMP 'no-such-project') }
    if ($fq -eq 'W32T.DeployExtensionInvalid') { Ok 'a missing project folder -> refused' } else { Bad "missing project: $fq" }

    # A copy of the module layout (Private\ + DeployExtension\) whose source is changed: -Verify and Copy refuse.
    $fake = Join-Path $TMP 'module'
    New-Item -ItemType Directory -Path (Join-Path $fake 'Private') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'Private\Get-Win32ToolkitDeployExtension.ps1') -Destination (Join-Path $fake 'Private')
    # Lean deploy script PR 3: the catalog reads the prior-install texts from this source (the requirement script embeds them).
    Copy-Item -LiteralPath (Join-Path $repo 'Private\Get-Win32ToolkitDeployScriptBlock.ps1') -Destination (Join-Path $fake 'Private')
    Copy-Item -LiteralPath (Join-Path $repo 'DeployExtension') -Destination $fake -Recurse
    . (Join-Path $fake 'Private\Get-Win32ToolkitDeployExtension.ps1')
    . (Join-Path $fake 'Private\Get-Win32ToolkitDeployScriptBlock.ps1')
    $fakeExt = Join-Path $fake "DeployExtension\$($ext.Name)"
    foreach ($c in @(
            @{ L = 'a changed .psm1'; Do = { Add-Content -LiteralPath (Join-Path $fakeExt "$($ext.Name).psm1") -Value ' ' }; Undo = { Copy-Item -LiteralPath $psm1Path -Destination $fakeExt -Force }; W = 'was changed' }
            @{ L = 'an extra file'; Do = { Set-Content -LiteralPath (Join-Path $fakeExt 'extra.ps1') -Value 'x' }; Undo = { Remove-Item -LiteralPath (Join-Path $fakeExt 'extra.ps1') }; W = "unexpected item 'extra.ps1'" }
            @{ L = 'a missing manifest'; Do = { Remove-Item -LiteralPath (Join-Path $fakeExt "$($ext.Name).psd1") }; Undo = { Copy-Item -LiteralPath $psd1Path -Destination $fakeExt }; W = 'is missing' }
        )) {
        & $c.Do
        $msg = try { $null = Get-Win32ToolkitDeployExtension -Verify; 'no throw' } catch { "$($_.FullyQualifiedErrorId) $($_.Exception.Message)" }
        $proj3 = Join-Path $TMP ('p' + [guid]::NewGuid().ToString('N').Substring(0, 4)); New-Item -ItemType Directory -Path $proj3 | Out-Null
        $fq = Get-Fqid { Copy-Win32ToolkitDeployExtension -ProjectPath $proj3 }
        if ($msg -like "W32T.DeployExtensionInvalid*$($c.W)*Reinstall win32-toolkit*" -and $fq -eq 'W32T.DeployExtensionInvalid' -and -not (Test-Path -LiteralPath (Join-Path $proj3 $ext.Name))) { Ok "installed source with $($c.L) -> -Verify and Copy refuse (W32T.DeployExtensionInvalid), nothing copied" } else { Bad "$($c.L): $msg / copy $fq" }
        $fqPred = Get-Fqid { Get-Win32ToolkitDeployScriptBlock -Name PriorPredicate }
        if ($fqPred -eq 'W32T.DeployExtensionInvalid') { Ok "installed source with $($c.L) -> the prior-install predicate is not read (W32T.DeployExtensionInvalid; the requirement script fails closed)" } else { Bad "$($c.L): PriorPredicate read -> '$fqPred'" }
        & $c.Undo
    }
    . (Join-Path $repo 'Private\Get-Win32ToolkitDeployExtension.ps1')

    # Test-Win32ToolkitDeployExtension
    $gv2 = [pscustomobject]@{ GeneratorVersion = 2; UninstallRevision = 2; RemovePriorRevision = 2 }
    $gv3 = [pscustomobject]@{ GeneratorVersion = 3; ExtensionVersion = [string]$ext.Version; UninstallRevision = 2; RemovePriorRevision = 3 }
    $p4 = Join-Path $TMP 'p4'; New-Item -ItemType Directory -Path $p4 | Out-Null
    foreach ($n in 'PSAppDeployToolkit', 'PSAppDeployToolkit.Extensions', 'PSAppDeployToolkit.Contoso', 'Files') { New-Item -ItemType Directory -Path (Join-Path $p4 $n) | Out-Null }
    $f = @(Test-Win32ToolkitDeployExtension -ProjectPath $p4 -Shape $gv2)
    if ($f.Count -eq 0) { Ok 'GeneratorVersion 2 project with PSADT, Extensions and an org folder, no toolkit folder -> no finding' } else { Bad "clean gv2: $($f.Code -join ',')" }
    foreach ($n in 'Old.PSAppDeployToolkit.X', 'PSAppDeployToolkit.Win32Toolkit - Copy', 'psappdeploytoolkit.win32toolkitX') { New-Item -ItemType Directory -Path (Join-Path $p4 $n) | Out-Null }
    $f = @(Test-Win32ToolkitDeployExtension -ProjectPath $p4 -Shape $gv2)
    if ($f.Count -eq 3 -and @($f | Where-Object { $_.Code -ne 'EXTENSION-STRAY' -or $_.Severity -ne 'Warning' }).Count -eq 0 -and ($f.Message -join '|') -match "'Old\.PSAppDeployToolkit\.X' is imported by PSAppDeployToolkit" -and ($f.Message -join '|') -match 'reserves for its own PSADT extension module') {
        Ok "stray folders (unanchored match, reserved prefix in any case) -> 3 EXTENSION-STRAY warnings for GeneratorVersion 2 (legacy packaged unchanged)"
    } else { Bad "stray gv2: $($f | Format-Table -AutoSize | Out-String)" }
    $f = @(Test-Win32ToolkitDeployExtension -ProjectPath $p4 -Shape $gv3)
    if (@($f | Where-Object { $_.Code -eq 'EXTENSION-STRAY' -and $_.Severity -eq 'Error' }).Count -eq 3 -and @($f | Where-Object Code -eq 'EXTENSION-MISSING').Count -eq 1) { Ok 'GeneratorVersion 3: the same stray folders are errors; no toolkit folder -> EXTENSION-MISSING' } else { Bad "gv3: $($f.Code -join ',')" }
    $p5 = Join-Path $TMP 'p5'; New-Item -ItemType Directory -Path $p5 | Out-Null
    $null = Copy-Win32ToolkitDeployExtension -ProjectPath $p5
    $f = @(Test-Win32ToolkitDeployExtension -ProjectPath $p5 -Shape $gv3)
    if ($f.Count -eq 0) { Ok "GeneratorVersion 3 with the copied extension $($ext.Version) -> no finding" } else { Bad "good gv3: $($f.Code -join ',')" }
    $msiShape = [pscustomobject]@{ GeneratorVersion = 3; ExtensionVersion = [string]$ext.Version; UninstallRevision = 0; RemovePriorRevision = 3 }
    if (@(Test-Win32ToolkitDeployExtension -ProjectPath $p5 -Shape $msiShape).Count -eq 0) { Ok 'an MSI deploy script without an uninstall block (UninstallRevision 0) -> no finding' } else { Bad 'msi shape flagged' }
    foreach ($c in @(
            @{ S = [pscustomobject]@{ GeneratorVersion = 3; ExtensionVersion = '1.0.0'; UninstallRevision = 2; RemovePriorRevision = 3 }; W = 'generated for 1.0.0'; L = 'the loader marker names 1.0.0 (an older known version)' }
            @{ S = [pscustomobject]@{ GeneratorVersion = 3; ExtensionVersion = [string]$ext.Version; UninstallRevision = 3; RemovePriorRevision = 3 }; W = 'uninstall revision 3'; L = 'the script names uninstall revision 3' }
            @{ S = [pscustomobject]@{ GeneratorVersion = 3; ExtensionVersion = [string]$ext.Version; UninstallRevision = 2; RemovePriorRevision = 2 }; W = 'prior-install revision 2, the folder provides 3'; L = 'the script names prior-install revision 2 (inline, lean deploy script PR 2)' }
        )) {
        $f = @(Test-Win32ToolkitDeployExtension -ProjectPath $p5 -Shape $c.S)
        if ($f.Count -eq 1 -and $f[0].Code -eq 'EXTENSION-MISMATCH' -and $f[0].Message -match [regex]::Escape($c.W)) { Ok "$($c.L) -> EXTENSION-MISMATCH" } else { Bad "$($c.L): $($f | Out-String)" }
    }
    $stage = Join-Path $TMP 'stage5'; New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -LiteralPath (Join-Path $p5 $ext.Name) -Destination $stage -Recurse
    if (@(Test-Win32ToolkitDeployExtension -ProjectPath $p5 -Shape $gv3 -StagingPath $stage).Count -eq 0) { Ok 'a Staging copy equal to the project -> no finding' } else { Bad 'equal staging flagged' }
    Add-Content -LiteralPath (Join-Path $stage "$($ext.Name)\$($ext.Name).psd1") -Value '#'
    $f = @(Test-Win32ToolkitDeployExtension -ProjectPath $p5 -Shape $gv3 -StagingPath $stage)
    if ($f.Count -eq 1 -and $f[0].Code -eq 'EXTENSION-STAGING') { Ok 'a changed Staging copy -> EXTENSION-STAGING' } else { Bad "staging changed: $($f.Code -join ',')" }
    Remove-Item -LiteralPath (Join-Path $stage $ext.Name) -Recurse -Force
    $f = @(Test-Win32ToolkitDeployExtension -ProjectPath $p5 -Shape $gv3 -StagingPath $stage)
    if ($f.Count -eq 1 -and $f[0].Code -eq 'EXTENSION-STAGING') { Ok 'no toolkit folder in Staging -> EXTENSION-STAGING' } else { Bad "staging missing: $($f.Code -join ',')" }
    Add-Content -LiteralPath (Join-Path $p5 "$($ext.Name)\$($ext.Name).psm1") -Value '#'
    $f = @(Test-Win32ToolkitDeployExtension -ProjectPath $p5 -Shape $gv3)
    if ($f.Count -eq 1 -and $f[0].Code -eq 'EXTENSION-UNKNOWN') { Ok 'an edited project copy -> EXTENSION-UNKNOWN' } else { Bad "edited: $($f.Code -join ',')" }
    $null = Copy-Win32ToolkitDeployExtension -ProjectPath $p5
    New-Item -ItemType Directory -Path (Join-Path $p5 "$($ext.Name)\sub") | Out-Null
    $f = @(Test-Win32ToolkitDeployExtension -ProjectPath $p5 -Shape $gv3)
    if ($f.Count -eq 1 -and $f[0].Code -eq 'EXTENSION-UNKNOWN' -and $f[0].Message -match "holds a folder 'sub'") { Ok 'a sub-folder in the project copy -> EXTENSION-UNKNOWN' } else { Bad "sub-folder: $($f | Out-String)" }
    $p6 = Join-Path $TMP 'p6'; New-Item -ItemType Directory -Path $p6 | Out-Null
    if (@(Test-Win32ToolkitDeployExtension -ProjectPath $p6 -Shape $gv2).Count -eq 0) { Ok 'GeneratorVersion 2 without a toolkit folder -> no extension finding (the folder is only required from GeneratorVersion 3)' } else { Bad 'gv2 flagged a missing folder' }
}
finally {
    Get-ChildItem -LiteralPath $TMP -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.Directory]::Delete($_.FullName) }
    Remove-Item -LiteralPath $TMP -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0 -and $skip -eq 0) { Write-Host 'All DeployExtension tests passed.' -ForegroundColor Green; exit 0 }
if ($fail -eq 0) { Write-Host "All DeployExtension tests passed ($skip part(s) skipped)." -ForegroundColor Yellow; exit 0 }
Write-Host "$fail DeployExtension test(s) FAILED." -ForegroundColor Red
exit 1
