# OrgHooks.unit.ps1 - A1/A3: org hook blocks + hook-file copy + extension-module copy (spec 3.2 task 8).
# Runs on the real PSADT 4.1.8 and 4.2.0 Zero-Config goldens AFTER Set-PSADTDataDrivenScript (and the
# org-ui blocks Apply-OrgTemplate places). Guards: copy-not-splice, constant 'hook' blocks placed through
# the toolkit block mechanism (LAST in Pre-*, FIRST in Post-*: hook < tattoo < org-ui), idempotent
# re-apply, clean removal, Fail vs Continue policy, a missing anchor is FATAL (D10), and the extension
# module rules (D11 <Dir>\<Dir>.psd1 + RootModule; ORG-08 RequiredModules satisfied by the project's PSADT:
# minimum / exact / maximum, valid for 5.1), checked before anything is placed, copied or written.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

# C-5 range + WP-A contract shadow (spec 2.2).
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }
function Test-Win32ToolkitPsadtVersionSupported {
    param([Parameter(Position = 0)][object]$Version)
    if ($null -eq $script:PsadtSupportedRange) { throw [System.InvalidOperationException]::new('win32-toolkit internal error: PsadtSupportedRange is not initialised') }
    if ($null -eq $Version) { return $false }
    $v = $null
    if ($Version -is [version]) { $v = $Version } elseif (-not [version]::TryParse((([string]$Version) -split '-', 2)[0], [ref]$v)) { return $false }
    return ($v -ge $script:PsadtSupportedRange.Min -and $v -lt $script:PsadtSupportedRange.MaxExclusive)
}
foreach ($f in 'Get-Win32ToolkitDeployScriptShape', 'Set-Win32ToolkitPhaseBlock', 'Remove-Win32ToolkitPhaseBlock',
    'Remove-Win32ToolkitPhaseDefaultUi', 'Get-Win32ToolkitDeployScriptBlock', 'Write-Win32ToolkitDeployScript',
    'Test-Win32ToolkitPS51Syntax', 'Set-PSADTDataDrivenScript', 'Add-Win32ToolkitOrgHooks', 'Assert-Win32ToolkitOrgExtensionModule') {
    . (Join-Path $repo "Private\$f.ps1")
}

$fail = 0
function Ok  { param($m) Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad { param($m) Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('w32oh_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$allHooks = @('PreInstall.ps1', 'PostInstall.ps1', 'PreUninstall.ps1', 'PostUninstall.ps1', 'PreRepair.ps1', 'PostRepair.ps1')
$script:Generated = @{}

# ── fixture: a generated project (+ org-ui blocks) and a template asset folder ──
function New-Fixture {
    param([string]$Golden = 'psadt-4.1.8', [bool]$HooksEnabled, [bool]$ExtModule, [string[]]$HookFiles = @('PreInstall.ps1', 'PostInstall.ps1'),
        [string]$HookBody = "Write-ADTLogEntry -Message 'org hook ran'", [scriptblock]$Mutate)
    $root = Join-Path $TMP ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $proj = Join-Path $root 'proj'
    $assets = Join-Path $root 'Templates\Contoso'
    New-Item -ItemType Directory -Path (Join-Path $proj 'PSAppDeployToolkit') -Force | Out-Null
    $script = Join-Path $proj 'Invoke-AppDeployToolkit.ps1'
    if (-not $script:Generated.ContainsKey($Golden)) {
        # Generate once per golden (each write runs a real 5.1 parse): Set-PSADTDataDrivenScript, then the
        # deploy-script part of Apply-OrgTemplate (PSADT defaults out, org-ui blocks in).
        Copy-Item -LiteralPath (Join-Path $repo "Tests\Fixtures\$Golden\Invoke-AppDeployToolkit.ps1") -Destination $script
        $null = Set-PSADTDataDrivenScript -ScriptPath $script -WarningAction SilentlyContinue
        $g = [System.IO.File]::ReadAllText($script, [System.Text.Encoding]::UTF8)
        $ui = [ordered]@{ 'Pre-Install' = 'OrgUiPreInstall'; 'Pre-Uninstall' = 'OrgUiPreMaintenance'; 'Pre-Repair' = 'OrgUiPreMaintenance'; 'Post-Install' = 'OrgUiPostInstall'; 'Post-Repair' = 'OrgUiPostRepair' }
        foreach ($ph in $ui.Keys) {
            $g = Remove-Win32ToolkitPhaseDefaultUi -Content $g -Phase $ph
            $g = Set-Win32ToolkitPhaseBlock -Content $g -Phase $ph -Slot 'org-ui' -Code (Get-Win32ToolkitDeployScriptBlock -Name $ui[$ph])
        }
        $script:Generated[$Golden] = $g
    }
    $t = $script:Generated[$Golden]
    if ($Mutate) { $t = & $Mutate $t }
    [System.IO.File]::WriteAllText($script, $t, (New-Object System.Text.UTF8Encoding($true)))
    $ver = if ($Golden -eq 'psadt-4.1.8') { '4.1.8' } else { '4.2.0' }
    Set-Content -LiteralPath (Join-Path $proj 'PSAppDeployToolkit\PSAppDeployToolkit.psd1') -Value "@{ ModuleVersion = '$ver'; RootModule = 'PSAppDeployToolkit.psm1' }" -Encoding UTF8
    if ($HooksEnabled) {
        $hd = Join-Path $assets 'Hooks'; New-Item -ItemType Directory -Path $hd -Force | Out-Null
        foreach ($f in $HookFiles) { Set-Content -LiteralPath (Join-Path $hd $f) -Value $HookBody -Encoding UTF8 }
    }
    if ($ExtModule) {
        $md = Join-Path $assets 'PSAppDeployToolkit.Contoso'; New-Item -ItemType Directory -Path $md -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $md 'PSAppDeployToolkit.Contoso.psm1') -Value "function Set-ContosoTattoo { param(`$x) }" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $md 'PSAppDeployToolkit.Contoso.psd1') -Value "@{ RootModule = 'PSAppDeployToolkit.Contoso.psm1'; ModuleVersion = '1.0.0' }" -Encoding UTF8
    }
    New-Item -ItemType Directory -Path $assets -Force | Out-Null
    [pscustomobject]@{ Root = $root; Proj = $proj; Assets = $assets; Script = $script }
}

# Shim Get-Win32ToolkitTemplateAssetFolder so the helper resolves to our fixture (no registry).
function Get-Win32ToolkitTemplateAssetFolder { param([string]$TemplateName, [string]$BasePath) $script:ASSET }

function Tmpl { param([bool]$Hooks, [string]$Fail = 'Fail', [bool]$Ext) [pscustomobject]@{
        TemplateName = 'Contoso'; Hooks = [pscustomobject]@{ Enabled = $Hooks; FailureAction = $Fail }; ExtensionModule = $Ext } }
function Get-Text([string]$Path) { ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)) -replace "`r`n", "`n" }
function Get-SlotOrder([string]$Text, [string]$Phase) {
    @([regex]::Matches($Text, '(?m)^[ \t]*## win32-toolkit:' + [regex]::Escape($Phase) + ':(?<s>[\w-]+) \(begin\)') | ForEach-Object { $_.Groups['s'].Value })
}
function Invoke-OrgHook([string]$Proj, $Template) {
    $wv = $null
    try { Add-Win32ToolkitOrgHooks -ProjectPath $Proj -Template $Template -WarningVariable wv -WarningAction SilentlyContinue; [pscustomobject]@{ Fqid = ''; Message = ''; Warnings = @($wv) } }
    catch { [pscustomobject]@{ Fqid = $_.FullyQualifiedErrorId; Message = $_.Exception.Message; Warnings = @($wv) } }
}

foreach ($golden in 'psadt-4.1.8', 'psadt-4.2.0-zeroconfig') {
    Write-Host "`n=== $golden ===" -ForegroundColor White

    Write-Host '[1] all six hooks: one hook block per phase, LAST in Pre-*, FIRST in Post-* (hook < tattoo < org-ui)' -ForegroundColor Cyan
    $fx = New-Fixture -Golden $golden -HooksEnabled $true -ExtModule $false -HookFiles $allHooks
    $script:ASSET = $fx.Assets
    $r = Invoke-OrgHook $fx.Proj (Tmpl -Hooks $true -Ext $false)
    $s = Get-Text $fx.Script
    if (-not $r.Fqid -and ([regex]::Matches($s, '(?m)^[ \t]*## win32-toolkit:[\w-]+:hook \(begin\)')).Count -eq 6) { Ok '6 hook blocks placed' } else { Bad "hook blocks: $(([regex]::Matches($s, ':hook \(begin\)')).Count) $($r.Message)" }
    $expect = @{ 'Pre-Install' = 'org-ui,hook'; 'Pre-Uninstall' = 'org-ui,hook'; 'Pre-Repair' = 'org-ui,hook'; 'Post-Install' = 'hook,tattoo,org-ui'; 'Post-Uninstall' = 'hook,tattoo'; 'Post-Repair' = 'hook,org-ui' }
    $wrong = @(foreach ($ph in $expect.Keys) { $o = (Get-SlotOrder $s $ph) -join ','; if ($o -ne $expect[$ph]) { "$ph=[$o]" } })
    if ($wrong.Count -eq 0) { Ok 'block order per phase is canonical' } else { Bad "order: $($wrong -join '; ')" }
    if ($golden -eq 'psadt-4.2.0-zeroconfig') {
        if ($s.Contains("New-Variable -Name Post-Install -Force -Value {`n    ## win32-toolkit:Post-Install:hook (begin)")) { Ok '4.2: the Post-Install hook is the first statement of the phase' } else { Bad '4.2: Post-Install hook not first' }
        if ($s -match "## win32-toolkit:Pre-Install:hook \(end\)\n\}") { Ok '4.2: the Pre-Install hook is the last statement of the phase' } else { Bad '4.2: Pre-Install hook not last' }
    } else {
        if ($s.Contains("    ## <Perform Post-Installation tasks here>`n    ## win32-toolkit:Post-Install:hook (begin)")) { Ok '4.1: the Post-Install hook directly follows its marker (first in the phase)' } else { Bad '4.1: Post-Install hook not after the marker' }
    }
    if (@(Get-ChildItem (Join-Path $fx.Proj 'SupportFiles\OrgHooks') -File).Count -eq 6) { Ok 'six hook files copied into SupportFiles\OrgHooks' } else { Bad 'hook files not copied' }
    if ($s -notmatch 'org hook ran') { Ok 'hook body NOT spliced into the deploy script (copy-not-splice)' } else { Bad 'hook body leaked into deploy script' }
    if ($s.Contains("Join-Path -Path `$adtSession.DirSupportFiles -ChildPath 'OrgHooks\PostInstall.ps1'")) { Ok 'the block dot-sources from $adtSession.DirSupportFiles' } else { Bad 'hook path wrong' }
    $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($fx.Script, [ref]$null, [ref]$errs)
    $ps51 = @(Test-Win32ToolkitPS51Syntax -Path $fx.Script)
    if (@($errs).Count -eq 0 -and $ps51.Count -eq 0) { Ok 'deploy script parses (host + Windows PowerShell 5.1)' } else { Bad "parse: host=$(@($errs).Count) 5.1=[$($ps51 -join '; ')]" }
    $sh = Get-Win32ToolkitDeployScriptShape -Path $fx.Script
    if ($sh.Support -eq 'Supported' -and $sh.GeneratorVersion -eq 2) { Ok "shape intact ($($sh.Shape))" } else { Bad "shape $($sh.Shape) $($sh.Support)" }

    Write-Host '[2] idempotent re-apply' -ForegroundColor Cyan
    $before = Get-FileHash -LiteralPath $fx.Script
    $r = Invoke-OrgHook $fx.Proj (Tmpl -Hooks $true -Ext $false)
    if ((Get-FileHash -LiteralPath $fx.Script).Hash -eq $before.Hash -and -not $r.Fqid) { Ok 're-apply is byte-identical' } else { Bad 're-apply changed the script' }

    Write-Host '[3] removing a hook file + re-apply removes its block' -ForegroundColor Cyan
    Remove-Item (Join-Path $fx.Assets 'Hooks\PostInstall.ps1') -Force
    $null = Invoke-OrgHook $fx.Proj (Tmpl -Hooks $true -Ext $false)
    $s3 = Get-Text $fx.Script
    if ($s3 -notmatch 'Post-Install:hook') { Ok 'Post-Install hook block removed' } else { Bad 'block not removed' }
    if (((Get-SlotOrder $s3 'Post-Install') -join ',') -eq 'tattoo,org-ui' -and $s3.Contains('win32-toolkit install tattoo - records')) { Ok 'tattoo and org-ui untouched' } else { Bad "Post-Install now [$((Get-SlotOrder $s3 'Post-Install') -join ',')]" }
    if ($s3 -match 'Pre-Install:hook \(begin') { Ok 'PreInstall hook still present (its file remains)' } else { Bad 'PreInstall wrongly removed' }

    Write-Host '[4] FailureAction=Continue wraps the dot-source; Fail is a bare dot-source' -ForegroundColor Cyan
    $fx4 = New-Fixture -Golden $golden -HooksEnabled $true -ExtModule $false -HookFiles @('PreInstall.ps1')
    $script:ASSET = $fx4.Assets
    $null = Invoke-OrgHook $fx4.Proj (Tmpl -Hooks $true -Fail 'Continue' -Ext $false)
    $s4 = Get-Text $fx4.Script
    if ($s4 -match 'try \{ \. \$orgHookScript \}' -and $s4 -match 'catch \{ Write-ADTLogEntry -Message "Org hook PreInstall\.ps1 failed \(continuing\)') { Ok 'Continue -> try/catch + Write-ADTLogEntry' } else { Bad 'Continue policy not emitted' }
    $null = Invoke-OrgHook $fx4.Proj (Tmpl -Hooks $true -Fail 'Fail' -Ext $false)
    $s4b = Get-Text $fx4.Script
    if ($s4b -match 'if \(Test-Path -LiteralPath \$orgHookScript\) \{ \. \$orgHookScript \}' -and $s4b -notmatch 'continuing') { Ok 'switching to Fail re-renders the block in place' } else { Bad 'Fail policy not re-rendered' }

    Write-Host '[5] hooks disabled -> no blocks, script untouched, no warnings' -ForegroundColor Cyan
    $fx5 = New-Fixture -Golden $golden -HooksEnabled $false -ExtModule $false
    $script:ASSET = $fx5.Assets
    $orig = Get-FileHash -LiteralPath $fx5.Script
    $r = Invoke-OrgHook $fx5.Proj (Tmpl -Hooks $false -Ext $false)
    if ((Get-FileHash -LiteralPath $fx5.Script).Hash -eq $orig.Hash) { Ok 'disabled hooks leave the script byte-identical' } else { Bad 'disabled hooks modified the script' }
    if ($r.Warnings.Count -eq 0 -and -not $r.Fqid) { Ok 'no warnings when disabled' } else { Bad "unexpected: $($r.Fqid) $($r.Warnings -join '; ')" }

    Write-Host '[6] A3 extension module: <Dir>\<Dir>.psd1 with an existing RootModule is copied' -ForegroundColor Cyan
    $fx6 = New-Fixture -Golden $golden -HooksEnabled $false -ExtModule $true
    $script:ASSET = $fx6.Assets
    $r = Invoke-OrgHook $fx6.Proj (Tmpl -Hooks $false -Ext $true)
    if (-not $r.Fqid -and (Test-Path (Join-Path $fx6.Proj 'PSAppDeployToolkit.Contoso\PSAppDeployToolkit.Contoso.psd1')) -and (Test-Path (Join-Path $fx6.Proj 'PSAppDeployToolkit.Contoso\PSAppDeployToolkit.Contoso.psm1'))) {
        Ok 'extension module (psd1 + psm1) copied to the project root'
    } else { Bad "extension module not copied: $($r.Message)" }
}

Write-Host "`n[7] extension module rules (D11 / ORG-08) fail hard with W32T.OrgExtensionInvalid" -ForegroundColor Cyan
function Test-Ext([string]$Name, [string]$Golden, [scriptblock]$Prepare, [bool]$ExpectFail, [string]$Expect) {
    $fx = New-Fixture -Golden $Golden -HooksEnabled $false -ExtModule $true
    $script:ASSET = $fx.Assets
    & $Prepare (Join-Path $fx.Assets 'PSAppDeployToolkit.Contoso')
    $r = Invoke-OrgHook $fx.Proj (Tmpl -Hooks $false -Ext $true)
    $copied = Test-Path (Join-Path $fx.Proj 'PSAppDeployToolkit.Contoso')
    if ($ExpectFail) {
        if ($r.Fqid -eq 'W32T.OrgExtensionInvalid' -and -not $copied -and $r.Message -match $Expect) { Ok "$Name -> W32T.OrgExtensionInvalid, nothing copied" } else { Bad "$Name -> fqid='$($r.Fqid)' copied=$copied $($r.Message)" }
    } else {
        if (-not $r.Fqid -and $copied) { Ok "$Name -> accepted and copied" } else { Bad "$Name -> fqid='$($r.Fqid)' $($r.Message)" }
    }
}
Test-Ext 'psm1-only folder' 'psadt-4.2.0-zeroconfig' { param($d) Remove-Item (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') } $true 'rename/add .PSAppDeployToolkit\.Contoso\.psd1.*Save-Module'
Test-Ext 'Save-Module 1.0.0\ layout' 'psadt-4.1.8' { param($d) $v = Join-Path $d '1.0.0'; New-Item -ItemType Directory -Path $v | Out-Null; Move-Item (Join-Path $d '*.ps*1') $v } $true 'Save-Module'
Test-Ext 'psd1 without RootModule' 'psadt-4.2.0-zeroconfig' { param($d) Set-Content (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') "@{ ModuleVersion = '1.0.0' }" } $true 'no RootModule'
Test-Ext 'RootModule file missing' 'psadt-4.2.0-zeroconfig' { param($d) Set-Content (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') "@{ RootModule = 'Missing.psm1' }" } $true "RootModule 'Missing\.psm1'"
Test-Ext 'RequiredModules PSADT 4.2.0 in a 4.1.8 project' 'psadt-4.1.8' { param($d) Set-Content (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') "@{ RootModule = 'PSAppDeployToolkit.Contoso.psm1'; RequiredModules = @(@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.2.0'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2' }) }" } $true 'requires PSAppDeployToolkit 4\.2\.0.*bundles PSAppDeployToolkit 4\.1\.8'
Test-Ext 'RequiredModules PSADT 4.2.0 in a 4.2 project' 'psadt-4.2.0-zeroconfig' { param($d) Set-Content (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') "@{ RootModule = 'PSAppDeployToolkit.Contoso.psm1'; RequiredModules = @(@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.2.0'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2' }) }" } $false ''
Test-Ext 'RequiredModules RequiredVersion 4.1.8 in a 4.1.8 project' 'psadt-4.1.8' { param($d) Set-Content (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') "@{ RootModule = 'PSAppDeployToolkit.Contoso.psm1'; RequiredModules = @(@{ ModuleName = 'PSAppDeployToolkit'; RequiredVersion = '4.1.8' }) }" } $false ''
Test-Ext "RequiredModules as a bare 'PSAppDeployToolkit' string" 'psadt-4.1.8' { param($d) Set-Content (Join-Path $d 'PSAppDeployToolkit.Contoso.psd1') "@{ RootModule = 'PSAppDeployToolkit.Contoso.psm1'; RequiredModules = @('PSAppDeployToolkit') }" } $false ''

# RequiredModules checked key by key, as PowerShell does on the device (runtime-01): ModuleVersion is a
# minimum, RequiredVersion an exact pin, MaximumVersion an upper bound ('*' wildcard); the entry must be
# a valid 5.1 module specification. The 4.2 fixture bundles 4.2.0, psadt-4.1.8 bundles 4.1.8.
function Write-ExtManifest([string]$Dir, [string]$Entry) {
    Set-Content (Join-Path $Dir 'PSAppDeployToolkit.Contoso.psd1') "@{ RootModule = 'PSAppDeployToolkit.Contoso.psm1'; RequiredModules = @($Entry) }"
}
$g42 = 'psadt-4.2.0-zeroconfig'
Test-Ext 'RequiredVersion 4.1.8 in a 4.2 project' $g42 { param($d) Write-ExtManifest $d "@{ ModuleName = 'PSAppDeployToolkit'; RequiredVersion = '4.1.8' }" } $true "requires exactly PSAppDeployToolkit 4\.1\.8 .*bundles PSAppDeployToolkit 4\.2\.0.*ModuleVersion = '4\.1\.0' \(a minimum\)"
Test-Ext 'ModuleVersion 4.1.0 + MaximumVersion 4.1.99 in a 4.2 project' $g42 { param($d) Write-ExtManifest $d "@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.1.0'; MaximumVersion = '4.1.99' }" } $true '4\.1\.99 at most.*bundles PSAppDeployToolkit 4\.2\.0'
Test-Ext "MaximumVersion '4.1.*' in a 4.2 project" $g42 { param($d) Write-ExtManifest $d "@{ ModuleName = 'PSAppDeployToolkit'; MaximumVersion = '4.1.*' }" } $true '4\.1\.\* at most.*bundles PSAppDeployToolkit 4\.2\.0'
Test-Ext 'RequiredVersion 4.2.0.0 in a 4.2 project (4.2.0.0 is not 4.2.0)' $g42 { param($d) Write-ExtManifest $d "@{ ModuleName = 'PSAppDeployToolkit'; RequiredVersion = '4.2.0.0' }" } $true 'requires exactly PSAppDeployToolkit 4\.2\.0\.0 .*bundles PSAppDeployToolkit 4\.2\.0,'
Test-Ext 'ModuleVersion 4.2.0-rc2 (prerelease label) in a 4.2 project' $g42 { param($d) Write-ExtManifest $d "@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.2.0-rc2' }" } $true "ModuleVersion = '4\.2\.0-rc2'\) is not valid for Windows PowerShell 5\.1"
Test-Ext 'ModuleVersion and RequiredVersion together' $g42 { param($d) Write-ExtManifest $d "@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.1.0'; RequiredVersion = '4.2.0' }" } $true 'not valid for Windows PowerShell 5\.1: .*cannot be used together'
Test-Ext 'a GUID that is not PSAppDeployToolkit''s' $g42 { param($d) Write-ExtManifest $d "@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.1.0'; Guid = '00000000-0000-0000-0000-000000000001' }" } $true 'GUID 00000000-0000-0000-0000-000000000001'
Test-Ext 'RequiredVersion 4.2.0 in a 4.2 project' $g42 { param($d) Write-ExtManifest $d "@{ ModuleName = 'PSAppDeployToolkit'; RequiredVersion = '4.2.0' }" } $false ''
Test-Ext "MaximumVersion '4.*' in a 4.2 project" $g42 { param($d) Write-ExtManifest $d "@{ ModuleName = 'PSAppDeployToolkit'; MaximumVersion = '4.*' }" } $false ''
Test-Ext 'ModuleVersion 4.1.0 + MaximumVersion 4.2.99 in a 4.2 project' $g42 { param($d) Write-ExtManifest $d "@{ ModuleName = 'PSAppDeployToolkit'; ModuleVersion = '4.1.0'; MaximumVersion = '4.2.99'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2' }" } $false ''

Write-Host "`n[7b] an invalid extension module stops the helper before it places, copies or writes anything" -ForegroundColor Cyan
foreach ($golden in 'psadt-4.1.8', 'psadt-4.2.0-zeroconfig') {
    $fx7 = New-Fixture -Golden $golden -HooksEnabled $true -ExtModule $true -HookFiles @('PreInstall.ps1', 'PostInstall.ps1')
    $script:ASSET = $fx7.Assets
    Remove-Item (Join-Path $fx7.Assets 'PSAppDeployToolkit.Contoso\PSAppDeployToolkit.Contoso.psd1')
    $h7 = (Get-FileHash -LiteralPath $fx7.Script).Hash
    $r = Invoke-OrgHook $fx7.Proj (Tmpl -Hooks $true -Ext $true)
    if ($r.Fqid -eq 'W32T.OrgExtensionInvalid' -and (Get-FileHash -LiteralPath $fx7.Script).Hash -eq $h7 -and
        -not (Test-Path (Join-Path $fx7.Proj 'SupportFiles\OrgHooks')) -and -not (Test-Path (Join-Path $fx7.Proj 'PSAppDeployToolkit.Contoso'))) {
        Ok "$golden : psm1-only extension + hooks -> W32T.OrgExtensionInvalid; deploy script byte-identical, no hook file, no module copied"
    } else { Bad "$golden : fqid='$($r.Fqid)' script changed=$((Get-FileHash -LiteralPath $fx7.Script).Hash -ne $h7) hooks=$(Test-Path (Join-Path $fx7.Proj 'SupportFiles\OrgHooks')) $($r.Message)" }
}

Write-Host "`n[8] a missing hook anchor is FATAL (D10), the script is left untouched" -ForegroundColor Cyan
$fx8 = New-Fixture -Golden 'psadt-4.1.8' -HooksEnabled $true -ExtModule $false -HookFiles @('PostRepair.ps1') `
    -Mutate { param($t) $t.Replace('## win32-toolkit:Post-Repair:org-ui', '## removed:Post-Repair:org-ui').Replace('## <Perform Post-Repair tasks here>', '## (marker removed by hand)') }
$script:ASSET = $fx8.Assets
$h = (Get-FileHash -LiteralPath $fx8.Script).Hash
$r = Invoke-OrgHook $fx8.Proj (Tmpl -Hooks $true -Ext $false)
if ($r.Fqid -eq 'W32T.PhaseAnchorMissing' -and (Get-FileHash -LiteralPath $fx8.Script).Hash -eq $h) { Ok 'no anchor for the Post-Repair hook -> W32T.PhaseAnchorMissing propagates; script unchanged' } else { Bad "fqid='$($r.Fqid)' $($r.Message)" }

Write-Host "`n[9] 5.1 syntax check flags a PS7-only ternary in a hook (warn-only)" -ForegroundColor Cyan
$fx9 = New-Fixture -HooksEnabled $true -ExtModule $false -HookFiles @('PreInstall.ps1') -HookBody '$x = $true ? 1 : 2'
$script:ASSET = $fx9.Assets
$r = Invoke-OrgHook $fx9.Proj (Tmpl -Hooks $true -Ext $false)
if (($r.Warnings -join ' ') -match '5\.1 syntax' -and -not $r.Fqid) { Ok 'PS7 ternary in a hook warns (real 5.1 parse), hook still placed' }
else { Bad "expected a 5.1 syntax warning; got: $($r.Warnings -join '; ') $($r.Fqid)" }

Remove-Item -LiteralPath $TMP -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
if ($fail -eq 0) { Write-Host "OrgHooks unit test PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILURE(S)" -ForegroundColor Red; exit 1 }
