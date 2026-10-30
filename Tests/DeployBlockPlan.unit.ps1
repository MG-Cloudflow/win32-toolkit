<#
    Get-Win32ToolkitDeployBlockPlan - which toolkit blocks a GeneratorVersion 3 deploy script gets (lean deploy script PR 2;
    design knowledge-base/designs/lean-deploy-script-extension.md section 4.3).

    The plan is the single answer the generator, Apply-OrgTemplate, the org hooks and the PLAN-MISMATCH check share. This
    suite spells every row out by hand (it does not re-derive them from the code):

      [1] EXE / MSIX / APPX on both shapes: install with -Technology Exe / Appx, uninstall, no msp.
      [2] MSI: no install and no uninstall block (PSADT's Zero-Config block does both); msp on PSADT 4.2 only; the
          Post-Install org-ui block is the comment-only OrgUiPostInstallMsi.
      [3] manual apps (EXE and MSI): manual-install instead of install; the uninstall row follows the type only.
      [4] hook rows: only for the phases given, in their canonical place (Pre-*: after org-ui, before remove-prior;
          Post-*: first).
      [5] columns: Technology only on the install row, Owner Generator / OrgUi (always 5) / Hook; the type is
          case-insensitive and trimmed; the plan is pure (same input, same rows).
      [6] an installer type without rows (zip, '', hostile text) -> W32T.UnsupportedInstallerType with the shown text made
          safe; a shape outside Psadt41 / Psadt42ZeroConfig is a parameter error.

    Run:  pwsh -File Tests\DeployBlockPlan.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitDeployBlockPlan.ps1')

# One row as 'Phase:Slot=Block' (+ '/Technology' when set, '#Owner' when not Generator).
function Format-Plan($Rows) {
    @($Rows | ForEach-Object {
            $s = "$($_.Phase):$($_.Slot)=$($_.Block)"
            if ($_.Technology) { $s += "/$($_.Technology)" }
            if ($_.Owner -ne 'Generator') { $s += "#$($_.Owner)" }
            $s
        }) -join ' | '
}
function Test-Plan([string]$Label, [hashtable]$Arguments, [string[]]$Want) {
    $got = Format-Plan @(Get-Win32ToolkitDeployBlockPlan @Arguments)
    $exp = $Want -join ' | '
    if ($got -ceq $exp) { Ok $Label } else { Bad "$Label`n      got:  $got`n      want: $exp" }
}

# The rows every project gets, around the per-type Install / Uninstall rows.
$head = 'Session:loader=Loader', 'Pre-Install:prior-check=RemovePriorCheck', 'Pre-Install:org-ui=OrgUiPreInstall#OrgUi', 'Pre-Install:remove-prior=RemovePrior'
$postInstall = 'Post-Install:tattoo=TattooInstall', 'Post-Install:org-ui=OrgUiPostInstall#OrgUi'
$postInstallMsi = 'Post-Install:tattoo=TattooInstall', 'Post-Install:org-ui=OrgUiPostInstallMsi#OrgUi'
$preUninstall = @('Pre-Uninstall:org-ui=OrgUiPreMaintenance#OrgUi')
$tail = 'Post-Uninstall:tattoo=TattooUninstall', 'Pre-Repair:org-ui=OrgUiPreMaintenance#OrgUi', 'Post-Repair:org-ui=OrgUiPostRepair#OrgUi'

Write-Host '[1] EXE / MSIX / APPX: install (-Technology), uninstall, no msp' -ForegroundColor Cyan
foreach ($shape in 'Psadt41', 'Psadt42ZeroConfig') {
    Test-Plan "$shape exe" @{ Shape = $shape; InstallerType = 'exe' } ($head + 'Install:install=Install/Exe' + 'Install:install-done=InstallDone' + $postInstall + $preUninstall + 'Uninstall:uninstall=Uninstall' + $tail)
    foreach ($t in 'msix', 'appx') {
        Test-Plan "$shape $t" @{ Shape = $shape; InstallerType = $t } ($head + 'Install:install=Install/Appx' + 'Install:install-done=InstallDone' + $postInstall + $preUninstall + 'Uninstall:uninstall=Uninstall' + $tail)
    }
}

Write-Host '[2] MSI: no install / uninstall block; msp on 4.2 only; the comment-only Post-Install org-ui block' -ForegroundColor Cyan
Test-Plan 'Psadt41 msi' @{ Shape = 'Psadt41'; InstallerType = 'msi' } ($head + 'Install:install-done=InstallDone' + $postInstallMsi + $preUninstall + $tail)
Test-Plan 'Psadt42ZeroConfig msi' @{ Shape = 'Psadt42ZeroConfig'; InstallerType = 'msi' } ($head + 'Install:msp=Msp' + 'Install:install-done=InstallDone' + $postInstallMsi + $preUninstall + $tail)

Write-Host '[3] manual apps: manual-install instead of install; uninstall by type only' -ForegroundColor Cyan
Test-Plan 'Psadt42ZeroConfig manual exe' @{ Shape = 'Psadt42ZeroConfig'; InstallerType = 'exe'; ManualInstall = $true } ($head + 'Install:manual-install=ManualInstall' + 'Install:install-done=InstallDone' + $postInstall + $preUninstall + 'Uninstall:uninstall=Uninstall' + $tail)
Test-Plan 'Psadt41 manual msi' @{ Shape = 'Psadt41'; InstallerType = 'msi'; ManualInstall = $true } ($head + 'Install:manual-install=ManualInstall' + 'Install:install-done=InstallDone' + $postInstallMsi + $preUninstall + $tail)
Test-Plan 'Psadt42ZeroConfig manual msi (msp kept)' @{ Shape = 'Psadt42ZeroConfig'; InstallerType = 'msi'; ManualInstall = $true } ($head + 'Install:msp=Msp' + 'Install:manual-install=ManualInstall' + 'Install:install-done=InstallDone' + $postInstallMsi + $preUninstall + $tail)

Write-Host '[4] hook rows: only the phases given, in their canonical place' -ForegroundColor Cyan
$all = 'Pre-Install', 'Post-Install', 'Pre-Uninstall', 'Post-Uninstall', 'Pre-Repair', 'Post-Repair'
Test-Plan 'Psadt41 exe, all six hooks' @{ Shape = 'Psadt41'; InstallerType = 'exe'; HookPhases = $all } @(
    'Session:loader=Loader', 'Pre-Install:prior-check=RemovePriorCheck', 'Pre-Install:org-ui=OrgUiPreInstall#OrgUi', 'Pre-Install:hook=Hook#Hook',
    'Pre-Install:remove-prior=RemovePrior', 'Install:install=Install/Exe', 'Install:install-done=InstallDone',
    'Post-Install:hook=Hook#Hook', 'Post-Install:tattoo=TattooInstall', 'Post-Install:org-ui=OrgUiPostInstall#OrgUi',
    'Pre-Uninstall:org-ui=OrgUiPreMaintenance#OrgUi', 'Pre-Uninstall:hook=Hook#Hook', 'Uninstall:uninstall=Uninstall',
    'Post-Uninstall:hook=Hook#Hook', 'Post-Uninstall:tattoo=TattooUninstall',
    'Pre-Repair:org-ui=OrgUiPreMaintenance#OrgUi', 'Pre-Repair:hook=Hook#Hook', 'Post-Repair:hook=Hook#Hook', 'Post-Repair:org-ui=OrgUiPostRepair#OrgUi')
Test-Plan 'Psadt42ZeroConfig msi, Post-Uninstall hook only' @{ Shape = 'Psadt42ZeroConfig'; InstallerType = 'msi'; HookPhases = @('Post-Uninstall') } ($head + 'Install:msp=Msp' + 'Install:install-done=InstallDone' + $postInstallMsi + $preUninstall + 'Post-Uninstall:hook=Hook#Hook' + $tail)
try { $null = Get-Win32ToolkitDeployBlockPlan -Shape Psadt41 -InstallerType exe -HookPhases 'Install'; Bad "a hook for the 'Install' phase was accepted" }
catch { if ($_.FullyQualifiedErrorId -like 'ParameterArgumentValidationError*') { Ok "-HookPhases 'Install' -> parameter error (hooks exist only for Pre-* / Post-*)" } else { Bad "Install hook: $($_.FullyQualifiedErrorId)" } }

Write-Host '[5] columns, case, purity' -ForegroundColor Cyan
$rows = @(Get-Win32ToolkitDeployBlockPlan -Shape Psadt42ZeroConfig -InstallerType exe -HookPhases $all)
if (@($rows | Where-Object Technology).Count -eq 1 -and ($rows | Where-Object Technology).Slot -eq 'install') { Ok 'Technology is set on the install row only' } else { Bad "Technology rows: $(Format-Plan @($rows | Where-Object Technology))" }
if (@($rows | Where-Object Owner -eq 'OrgUi').Count -eq 5 -and @($rows | Where-Object Owner -eq 'Hook').Count -eq 6 -and @($rows | Where-Object { $_.Owner -notin 'Generator', 'OrgUi', 'Hook' }).Count -eq 0) { Ok 'Owner: 5 OrgUi rows, one Hook row per hook phase, the rest Generator' } else { Bad "owners: $(@($rows | Group-Object Owner | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', ')" }
if (($rows[0].PSObject.Properties.Name -join ',') -ceq 'Phase,Slot,Block,Technology,Owner') { Ok 'row shape: Phase, Slot, Block, Technology, Owner' } else { Bad "row shape: $($rows[0].PSObject.Properties.Name -join ',')" }
if ((Format-Plan @(Get-Win32ToolkitDeployBlockPlan -Shape Psadt41 -InstallerType ' EXE ')) -ceq (Format-Plan @(Get-Win32ToolkitDeployBlockPlan -Shape Psadt41 -InstallerType exe))) { Ok "' EXE ' plans like 'exe' (trimmed, case-insensitive)" } else { Bad 'type case/trim' }
if ((Format-Plan $rows) -ceq (Format-Plan @(Get-Win32ToolkitDeployBlockPlan -Shape Psadt42ZeroConfig -InstallerType exe -HookPhases $all))) { Ok 'pure: the same input gives the same rows' } else { Bad 'not pure' }

Write-Host '[6] no rows for the type -> W32T.UnsupportedInstallerType; a refused shape is a parameter error' -ForegroundColor Cyan
foreach ($c in @(
        @{ T = 'zip'; L = "'zip'" }
        @{ T = ''; L = 'an empty type' }
        @{ T = "exe`r`nWrite-Host pwned"; L = 'a type with a line break' }
    )) {
    try { $null = Get-Win32ToolkitDeployBlockPlan -Shape Psadt41 -InstallerType $c.T; Bad "$($c.L) was planned" }
    catch {
        $m = $_.Exception.Message
        if ($_.FullyQualifiedErrorId -eq 'W32T.UnsupportedInstallerType' -and $m.Contains('Installer.Type') -and $m.Contains('Nothing was changed.') -and $m -notmatch "[`r`n]") { Ok "$($c.L) -> W32T.UnsupportedInstallerType, one line, 'Nothing was changed.'" }
        else { Bad "$($c.L): $($_.FullyQualifiedErrorId) $m" }
    }
}
try { $null = Get-Win32ToolkitDeployBlockPlan -Shape Psadt42Default -InstallerType exe; Bad 'Psadt42Default was planned' }
catch { if ($_.FullyQualifiedErrorId -like 'ParameterArgumentValidationError*') { Ok '-Shape Psadt42Default -> parameter error (never planned)' } else { Bad "Psadt42Default: $($_.FullyQualifiedErrorId)" } }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All DeployBlockPlan tests passed.' -ForegroundColor Green; exit 0 }
Write-Host "$fail DeployBlockPlan test(s) FAILED." -ForegroundColor Red
exit 1
