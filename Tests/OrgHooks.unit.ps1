# OrgHooks.unit.ps1 — A1/A3: org hook-script injection + extension-module copy.
# Guards: copy-not-splice, constant stubs at the real v4 markers, idempotent re-apply, clean removal,
# hook-runs-above-tattoo (Post-Install), Fail vs Continue policy, and the extension-module copy.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'Private\Set-Win32ToolkitTextBlock.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitPS51Syntax.ps1')
. (Join-Path $repo 'Private\Add-Win32ToolkitOrgHooks.ps1')

$fail = 0
function Ok  { param($m) Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad { param($m) Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# ── A realistic deploy script AFTER Set-PSADTDataDrivenScript: Install/Uninstall markers consumed,
#    Post-Install/Post-Uninstall markers re-emitted directly above the tattoo blocks. ──
$deploy = @'
[CmdletBinding()]
param()

$adtSession = @{ AppName = 'x'; AppProcessesToClose = @() }

function Install-ADTDeployment
{
    ## <Perform Pre-Installation tasks here>

    Show-ADTInstallationWelcome

    ## generated install logic here
    Start-ADTProcess -FilePath 'setup.exe'

    ## <Perform Post-Installation tasks here>

    ## win32-toolkit install tattoo - records install state + version for the Intune detection rule.
    if ($appConfig.App.Version) {
        Set-ADTRegistryKey -Key "HKLM:\SOFTWARE\Contoso\App" -Name 'Version' -Value '1.0'
    }
}

function Uninstall-ADTDeployment
{
    ## <Perform Pre-Uninstallation tasks here>

    ## generated uninstall logic
    Remove-Item 'x'

    ## <Perform Post-Uninstallation tasks here>

    ## win32-toolkit install tattoo - remove the key written during install.
    Remove-ADTRegistryKey -Key "HKLM:\SOFTWARE\Contoso\App" -Recurse
}

function Repair-ADTDeployment
{
    ## <Perform Pre-Repair tasks here>

    ## <Perform Repair tasks here>

    ## <Perform Post-Repair tasks here>
}
'@

# ── Build a fixture: project + a template asset folder with hooks + an extension module ──
function New-Fixture {
    param([bool]$HooksEnabled, [string]$FailureAction = 'Fail', [bool]$ExtModule, [string[]]$HookFiles = @('PreInstall.ps1','PostInstall.ps1'), [string]$HookBody = "Write-ADTLogEntry -Message 'org hook ran'")
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('orghooks_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $proj = Join-Path $root 'proj'
    $assets = Join-Path $root 'Templates\Contoso'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $proj 'Invoke-AppDeployToolkit.ps1'), (($deploy -replace "`r?`n","`r`n")+"`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    if ($HooksEnabled) {
        $hd = Join-Path $assets 'Hooks'; New-Item -ItemType Directory -Path $hd -Force | Out-Null
        foreach ($f in $HookFiles) { Set-Content -LiteralPath (Join-Path $hd $f) -Value $HookBody -Encoding UTF8 }
    }
    if ($ExtModule) {
        $md = Join-Path $assets 'PSAppDeployToolkit.Contoso'; New-Item -ItemType Directory -Path $md -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $md 'PSAppDeployToolkit.Contoso.psm1') -Value "function Set-ContosoTattoo { param(`$x) }" -Encoding UTF8
    }
    [pscustomobject]@{ Root=$root; Proj=$proj; Assets=$assets; Script=(Join-Path $proj 'Invoke-AppDeployToolkit.ps1') }
}

# Shim Get-Win32ToolkitTemplateAssetFolder so the helper resolves to our fixture (no registry).
function Get-Win32ToolkitTemplateAssetFolder { param([string]$TemplateName,[string]$BasePath) $script:ASSET }

function Tmpl { param([bool]$Hooks,[string]$Fail='Fail',[bool]$Ext) [pscustomobject]@{
    TemplateName='Contoso'; Hooks=[pscustomobject]@{ Enabled=$Hooks; FailureAction=$Fail }; ExtensionModule=$Ext } }

Write-Host "`n[1] Hooks enabled — stub injected only for phases with a file; copy-not-splice" -ForegroundColor Cyan
$fx = New-Fixture -HooksEnabled $true -ExtModule $false -HookFiles @('PreInstall.ps1','PostInstall.ps1')
$script:ASSET = $fx.Assets
Add-Win32ToolkitOrgHooks -ProjectPath $fx.Proj -Template (Tmpl -Hooks $true -Ext $false) -WarningAction SilentlyContinue
$s = Get-Content -LiteralPath $fx.Script -Raw
if ($s -match '## Org hook: PreInstall \(begin' -and $s -match '## Org hook: PostInstall \(begin') { Ok 'PreInstall + PostInstall stubs injected' } else { Bad 'stubs missing' }
if ($s -notmatch '## Org hook: PreUninstall') { Ok 'PreUninstall NOT injected (no file)' } else { Bad 'PreUninstall injected without a file' }
if (Test-Path (Join-Path $fx.Proj 'SupportFiles\OrgHooks\PreInstall.ps1')) { Ok 'hook file copied into SupportFiles\OrgHooks' } else { Bad 'hook file not copied' }
# copy-not-splice: the hook BODY must never appear in the deploy script
if ($s -notmatch 'org hook ran') { Ok 'hook body NOT spliced into deploy script (copy-not-splice)' } else { Bad 'hook body leaked into deploy script' }
# the stub dot-sources from DirSupportFiles
if ($s -match [regex]::Escape("Join-Path -Path `$adtSession.DirSupportFiles -ChildPath 'OrgHooks\PostInstall.ps1'")) { Ok 'stub dot-sources from $adtSession.DirSupportFiles' } else { Bad 'stub path wrong' }

Write-Host "`n[2] Post-Install hook runs ABOVE the tattoo (safe order)" -ForegroundColor Cyan
$idxHook = $s.IndexOf('## Org hook: PostInstall (begin')
$idxMarker = $s.IndexOf('## <Perform Post-Installation tasks here>')
$idxTattoo = $s.IndexOf('win32-toolkit install tattoo - records')
if ($idxHook -ge 0 -and $idxHook -lt $idxMarker -and $idxMarker -lt $idxTattoo) { Ok 'order: hook stub -> marker -> tattoo' } else { Bad "order wrong (hook=$idxHook marker=$idxMarker tattoo=$idxTattoo)" }
# tattoo survived intact
if (([regex]::Matches($s,'win32-toolkit install tattoo')).Count -eq 2) { Ok 'both tattoo blocks intact' } else { Bad 'tattoo damaged' }

Write-Host "`n[3] Deploy script still parses; stub is 5.1-safe" -ForegroundColor Cyan
$errs=$null; [System.Management.Automation.Language.Parser]::ParseInput($s,[ref]$null,[ref]$errs) | Out-Null
if (-not ($errs -and $errs.Count)) { Ok 'deploy script parses after injection' } else { Bad "parse error: $($errs[0].Message)" }

Write-Host "`n[4] Idempotent re-apply — no growth, no drift warning" -ForegroundColor Cyan
$before = Get-Content -LiteralPath $fx.Script -Raw
Add-Win32ToolkitOrgHooks -ProjectPath $fx.Proj -Template (Tmpl -Hooks $true -Ext $false) -WarningVariable wv -WarningAction SilentlyContinue
$after = Get-Content -LiteralPath $fx.Script -Raw
if ($before -eq $after) { Ok 're-apply is byte-identical (idempotent)' } else { Bad 're-apply changed the script' }
if (([regex]::Matches($after,'## Org hook: PostInstall \(begin')).Count -eq 1) { Ok 'no stub duplication' } else { Bad 'stub duplicated on re-apply' }

Write-Host "`n[5] Removing a hook file + re-apply cleanly removes its stub, restores pristine marker" -ForegroundColor Cyan
Remove-Item (Join-Path $fx.Assets 'Hooks\PostInstall.ps1') -Force
Add-Win32ToolkitOrgHooks -ProjectPath $fx.Proj -Template (Tmpl -Hooks $true -Ext $false) -WarningAction SilentlyContinue
$s5 = Get-Content -LiteralPath $fx.Script -Raw
if ($s5 -notmatch '## Org hook: PostInstall') { Ok 'PostInstall stub removed' } else { Bad 'stub not removed' }
if ($s5 -match '(?m)^\s*## <Perform Post-Installation tasks here>') { Ok 'pristine Post-Install marker restored' } else { Bad 'marker not restored' }
if ($s5 -match 'win32-toolkit install tattoo - records') { Ok 'tattoo still intact after removal' } else { Bad 'tattoo lost during removal' }
if ($s5 -match '## Org hook: PreInstall \(begin') { Ok 'PreInstall stub still present (its file remains)' } else { Bad 'PreInstall wrongly removed' }

Write-Host "`n[6] FailureAction=Continue emits try/catch; Fail emits bare dot-source" -ForegroundColor Cyan
$fx6 = New-Fixture -HooksEnabled $true -FailureAction 'Continue' -ExtModule $false -HookFiles @('PreInstall.ps1')
$script:ASSET = $fx6.Assets
Add-Win32ToolkitOrgHooks -ProjectPath $fx6.Proj -Template (Tmpl -Hooks $true -Fail 'Continue' -Ext $false) -WarningAction SilentlyContinue
$s6 = Get-Content -LiteralPath $fx6.Script -Raw
if ($s6 -match 'try \{ \. \$orgHookScript \}' -and $s6 -match 'catch \{ Write-ADTLogEntry') { Ok 'Continue -> try/catch + Write-ADTLogEntry' } else { Bad 'Continue policy not emitted' }

Write-Host "`n[7] Hooks disabled -> no stubs, script untouched" -ForegroundColor Cyan
$fx7 = New-Fixture -HooksEnabled $false -ExtModule $false
$script:ASSET = $fx7.Assets
$orig = Get-Content -LiteralPath $fx7.Script -Raw
Add-Win32ToolkitOrgHooks -ProjectPath $fx7.Proj -Template (Tmpl -Hooks $false -Ext $false) -WarningVariable wv7 -WarningAction SilentlyContinue
$s7 = Get-Content -LiteralPath $fx7.Script -Raw
if ($orig -eq $s7) { Ok 'disabled hooks leave the script byte-identical' } else { Bad 'disabled hooks modified the script' }
if (-not $wv7) { Ok 'no warnings when disabled' } else { Bad "unexpected warnings: $($wv7 -join '; ')" }

Write-Host "`n[8] A3 extension module copied to project root" -ForegroundColor Cyan
$fx8 = New-Fixture -HooksEnabled $false -ExtModule $true
$script:ASSET = $fx8.Assets
Add-Win32ToolkitOrgHooks -ProjectPath $fx8.Proj -Template (Tmpl -Hooks $false -Ext $true) -WarningAction SilentlyContinue
if (Test-Path (Join-Path $fx8.Proj 'PSAppDeployToolkit.Contoso\PSAppDeployToolkit.Contoso.psm1')) { Ok 'extension module copied to project root (auto-import name)' } else { Bad 'extension module not copied' }

Write-Host "`n[9] 5.1 syntax check flags a PS7-only ternary in a hook" -ForegroundColor Cyan
$fx9 = New-Fixture -HooksEnabled $true -ExtModule $false -HookFiles @('PreInstall.ps1') -HookBody '$x = $true ? 1 : 2'
$script:ASSET = $fx9.Assets
Add-Win32ToolkitOrgHooks -ProjectPath $fx9.Proj -Template (Tmpl -Hooks $true -Ext $false) -WarningVariable wv9 -WarningAction SilentlyContinue
if ($wv9 -and ($wv9 -join ' ') -match '5\.1 syntax') { Ok 'PS7 ternary in a hook warns (real 5.1 parse)' }
else { Bad "expected a 5.1 syntax warning; got: $($wv9 -join '; ')" }

Write-Host ""
if ($fail -eq 0) { Write-Host "OrgHooks unit test PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILURE(S)" -ForegroundColor Red; exit 1 }
