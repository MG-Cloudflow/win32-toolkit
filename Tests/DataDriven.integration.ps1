<#
    Integration test for the data-driven install/uninstall generation (Phase 1-2).

    Generates a pristine PSADT v4 project with New-ADTTemplate, runs the data-driven
    generators against a HOSTILE winget manifest and sandbox capture, and proves the key
    security property: untrusted payloads land only in SupportFiles\AppConfig.json (data),
    never in the generated Invoke-AppDeployToolkit.ps1 (code).

    Requires PSAppDeployToolkit installed (New-ADTTemplate). Skips (exit 0) if unavailable.
    Run:  pwsh -File Tests\DataDriven.integration.ps1
    See knowledge-base/designs/data-driven-generation.md.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m){ Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m){ Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

if (-not (Get-Module -ListAvailable PSAppDeployToolkit)) {
    Write-Host 'SKIP: PSAppDeployToolkit not installed (New-ADTTemplate unavailable).' -ForegroundColor DarkYellow
    exit 0
}

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
$script:OrgTemplate = $null

$INSTALL_PAYLOAD = "/S'; `$global:PWNED_INSTALL = `$true; #"
$UNINST_PAYLOAD  = "/S'; `$global:PWNED_UNINST = `$true; #"
$DISPLAYNAME     = "Evil'App `$(calc)"

$base = Join-Path ([System.IO.Path]::GetTempPath()) ("w32kb_p12_" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
    Import-Module PSAppDeployToolkit -Force
    New-ADTTemplate -Destination $base -Name 'App' | Out-Null
    $proj  = Join-Path $base 'App'
    $files = Join-Path $proj 'Files'
    New-Item -ItemType Directory -Path $files -Force | Out-Null
    Set-Content -Path (Join-Path $files 'EvilApp_x64_1.2.3.exe') -Value 'stub' -Encoding ASCII

    Set-Content -Path (Join-Path $files 'EvilApp.installer.yaml') -Encoding UTF8 -Value @"
PackageName: Evil'App
Publisher: O'Reilly
PackageVersion: 1.2.3
Architecture: x64
InstallerSwitches:
  Silent: $INSTALL_PAYLOAD
"@

    Write-Host "[1] Configure (install + patch)" -ForegroundColor Cyan
    $ok = Configure-PSADTForInstaller -ProjectPath $proj -AppInfo ([pscustomobject]@{ Name='EvilApp'; Version='1.2.3'; Id='Evil.App' }) -Architecture 'x64'
    if ($ok) { Ok 'Configure returned true' } else { Bad 'Configure failed' }

    $capture = @{
        NewRegistryKeys = @(
            @{ Path='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\EvilApp'; KeyName='EvilApp';
               Values = @{ DisplayName=$DISPLAYNAME;
                           UninstallString="`"C:\Program Files\EvilApp\unins000.exe`" $UNINST_PAYLOAD";
                           InstallLocation='C:\Program Files\EvilApp';
                           DisplayIcon='C:\Program Files\EvilApp\evil.exe,0' } },
            @{ Path='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\evil.exe'; KeyName='evil.exe'; Values=@{} },
            @{ Path='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\bad.exe';  KeyName="bad'; calc.exe"; Values=@{} }
        )
        NewFiles = @( @{ Type='File'; Path='C:\Program Files\EvilApp\evil.exe' } )
        # Shape produced by the registry-diff NewPrograms derivation (replaces Win32_Product) —
        # present in the fixture to prove all writers tolerate the field end-to-end.
        NewPrograms = @( @{ Name=$DISPLAYNAME; DisplayName=$DISPLAYNAME; DisplayVersion='1.2.3'; Publisher="O'Reilly"
                            UninstallString="`"C:\Program Files\EvilApp\unins000.exe`" $UNINST_PAYLOAD"
                            Path='C:\Program Files\EvilApp'; Source='UninstallRegistry' } )
    }
    $capPath = Join-Path $proj 'InstallationChanges_test.json'
    ($capture | ConvertTo-Json -Depth 8) | Set-Content -Path $capPath -Encoding UTF8

    Write-Host "`n[2] Data writers" -ForegroundColor Cyan
    if (Update-PSADTUninstallLogic   -ProjectPath $proj -JsonFilePath $capPath) { Ok 'uninstall writer' } else { Bad 'uninstall writer' }
    if (Update-PSADTProcessesToClose -ProjectPath $proj -JsonFilePath $capPath) { Ok 'processes writer' } else { Bad 'processes writer' }

    Write-Host "`n[3] Patched script structure" -ForegroundColor Cyan
    $scriptPath = Join-Path $proj 'Invoke-AppDeployToolkit.ps1'
    $errs=$null; [System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$null,[ref]$errs)|Out-Null
    if (-not ($errs -and $errs.Count)) { Ok 'patched script parses' } else { Bad "parse: $($errs[0].Message)" }
    $ps1 = Get-Content -LiteralPath $scriptPath -Raw
    if ($ps1 -match [regex]::Escape('$appConfig =')) { Ok 'loader present' } else { Bad 'no loader' }
    if ($ps1 -match 'Data-driven install' -and $ps1 -match 'Data-driven uninstall') { Ok 'routines present' } else { Bad 'routines' }
    if ($ps1 -match 'Set-ADTRegistryKey' -and $ps1 -match 'Remove-ADTRegistryKey -Key' -and
        $ps1 -match [regex]::Escape('$($appConfig.App.ScriptAuthor)\$($appConfig.App.Vendor)\$w32tName') -and
        $ps1 -match [regex]::Escape('$appConfig.App.DisplayName')) {
        Ok 'install tattoo present (DisplayName-driven, value-free, no MSI exclusion)'
    } else { Bad 'install tattoo missing' }

    Write-Host "`n[4] KEY PROOF: payloads only in data, never in code" -ForegroundColor Cyan
    if ($ps1 -notmatch [regex]::Escape($INSTALL_PAYLOAD)) { Ok 'install payload absent from .ps1' } else { Bad 'install payload LEAKED' }
    if ($ps1 -notmatch [regex]::Escape($UNINST_PAYLOAD))  { Ok 'uninstall payload absent from .ps1' } else { Bad 'uninstall payload LEAKED' }
    if ($ps1 -notmatch [regex]::Escape($DISPLAYNAME))     { Ok 'display name absent from .ps1' } else { Bad 'display name LEAKED' }

    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $proj
    if ($cfg.Installer.SilentArgs -eq $INSTALL_PAYLOAD) { Ok 'install payload stored as data' } else { Bad "install data [$($cfg.Installer.SilentArgs)]" }
    $exeU = @($cfg.Uninstall.Uninstallers) | Where-Object { $_.Type -eq 'exe' } | Select-Object -First 1
    if ($exeU.Args -eq $UNINST_PAYLOAD) { Ok 'uninstall payload stored as data' } else { Bad "uninstall data [$($exeU.Args)]" }
    if ($cfg.App.Vendor -eq "O'Reilly" -and $cfg.App.Name -eq "Evil'App") { Ok 'apostrophe metadata stored as data' } else { Bad 'metadata' }

    Write-Host "`n[5] Process-name validation" -ForegroundColor Cyan
    $procs = @($cfg.ProcessesToClose)
    if ($procs -contains 'evil') { Ok "valid process kept" } else { Bad "procs=[$($procs -join ',')]" }
    if (-not ($procs | Where-Object { $_ -like '*calc*' -or $_ -like "*'*" })) { Ok 'malicious process rejected' } else { Bad 'bad proc leaked' }

    Write-Host "`n[6] Detection rule keys off the tattoo (installed + correct version)" -ForegroundColor Cyan
    # The org template normally supplies AppScriptAuthor; inject it here to exercise the rule.
    $cfg6 = Get-Win32ToolkitAppConfig -ProjectPath $proj
    $cfg6.App.ScriptAuthor = 'Contoso IT'
    Set-Win32ToolkitAppConfig -ProjectPath $proj -Config $cfg6 | Out-Null
    $rules = @(Get-Win32DetectionRules -ProjectPath $proj)
    if ($rules.Count -eq 1 -and
        $rules[0]['detectionType']  -eq 'version' -and
        $rules[0]['operator']       -eq 'equal'   -and
        $rules[0]['valueName']      -eq 'Version'  -and
        $rules[0]['keyPath']        -eq "HKEY_LOCAL_MACHINE\SOFTWARE\Contoso IT\O'Reilly\Evil'App" -and
        $rules[0]['detectionValue'] -eq '1.2.3') {
        Ok 'registry version detection built from tattoo'
    } else { Bad "detection rule: $($rules[0] | ConvertTo-Json -Compress)" }

    Write-Host "`n[7] Apostrophes in org-template fields never break the generated files" -ForegroundColor Cyan
    # Every free-text template value is spliced into a single-quoted literal in config.psd1 / strings.psd1 /
    # the deploy script; a quote must stay escaped (regression for the Apply-OrgTemplate splices).
    $escTmpl = [pscustomobject]@{
        CompanyName            = "O'Reilly Media"
        DialogStyle            = 'Fluent'
        FluentAccentColor      = ''
        LogPath                = "C:\Logs\O'Brien"
        AppScriptAuthor        = "O'Brien IT"
        TemplateName           = 'EscTest'
        BalloonComplete        = [pscustomobject]@{ Install="Installed O'Reilly"; Repair="Repair's done"; Uninstall="Removed O'Brien" }
        ProgressMessage        = [pscustomobject]@{ Install="Installing O'Brien's app"; Repair="Repairin'"; Uninstall="Uninstallin'" }
        ProgressMessageDetail  = [pscustomobject]@{ Install="It's working"; Repair="almost'"; Uninstall="bye'" }
        WelcomeDialog          = [pscustomobject]@{ Enabled=$false }
        ProgressDialog         = [pscustomobject]@{ Enabled=$true; StatusMessage="It's installing"; StatusMessageDetail="Please wait, it's almost done" }
        CompletionPrompt       = [pscustomobject]@{ Enabled=$false }
        UninstallWelcomeDialog = [pscustomobject]@{ Enabled=$false }
    }
    Apply-OrgTemplate -ProjectPath $proj -Template $escTmpl | Out-Null

    # config.psd1 + strings.psd1 must parse AND round-trip their apostrophe values
    try { $cfgData = Import-PowerShellDataFile -Path (Join-Path $proj 'Config\config.psd1')
          if ($cfgData.Toolkit.CompanyName -eq "O'Reilly Media" -and $cfgData.Toolkit.LogPath -eq "C:\Logs\O'Brien") { Ok 'config.psd1 parses + CompanyName/LogPath round-trip' } else { Bad "config values: [$($cfgData.Toolkit.CompanyName)] [$($cfgData.Toolkit.LogPath)]" } }
    catch { Bad "config.psd1 parse: $($_.Exception.Message)" }
    try { $strData = Import-PowerShellDataFile -Path (Join-Path $proj 'Strings\strings.psd1')
          if ($strData.BalloonTip.Complete.Install -eq "Installed O'Reilly" -and $strData.ProgressPrompt.Message.Install -eq "Installing O'Brien's app") { Ok 'strings.psd1 parses + balloon/progress round-trip' } else { Bad 'strings values did not round-trip' } }
    catch { Bad "strings.psd1 parse: $($_.Exception.Message)" }

    # deploy script must parse; author + status message escaped; tattoo survives branding
    $errsB=$null; [System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$null,[ref]$errsB)|Out-Null
    if (-not ($errsB -and $errsB.Count)) { Ok 'deploy script parses with apostrophe author + status message' } else { Bad "parse: $($errsB[0].Message)" }
    $ps1b = Get-Content -LiteralPath $scriptPath -Raw
    if ($ps1b -match [regex]::Escape("AppScriptAuthor = 'O''Brien IT'")) { Ok "author literal escaped (O''Brien IT)" } else { Bad 'author literal not escaped' }
    if ($ps1b -match [regex]::Escape("-StatusMessage 'It''s installing'")) { Ok 'progress StatusMessage escaped' } else { Bad 'StatusMessage not escaped' }
    if (([regex]::Matches($ps1b,'Set-ADTRegistryKey')).Count -eq 1) { Ok 'tattoo survived org-template branding' } else { Bad 'tattoo clobbered by branding' }

    Write-Host "`n[8] Update requirement rule (presence check; hostile values escaped)" -ForegroundColor Cyan
    $rr = Get-Win32ToolkitRequirementRule -ProjectPath $proj
    if ($rr -and $rr['@odata.type'] -eq '#microsoft.graph.win32LobAppPowerShellScriptRequirement' -and
        $rr['detectionType'] -eq 'integer' -and $rr['operator'] -eq 'equal' -and $rr['detectionValue'] -eq '1' -and
        $rr['runAsAccount'] -eq 'system') {
        Ok 'requirement rule shape (script requirement, integer/equal/1, system)'
    } else { Bad "requirement rule: $($rr | ConvertTo-Json -Compress)" }
    $rrScript = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rr['scriptContent']))
    $rrErrs=$null; [System.Management.Automation.Language.Parser]::ParseInput($rrScript,[ref]$null,[ref]$rrErrs)|Out-Null
    if (-not ($rrErrs -and $rrErrs.Count)) { Ok 'requirement script parses' } else { Bad "req parse: $($rrErrs[0].Message)" }
    if ($rrScript -notmatch [regex]::Escape($UNINST_PAYLOAD) -and $rrScript -notmatch 'PWNED' -and $rrScript -notmatch 'calc\.exe') {
        Ok 'no injection payload in requirement script (values escaped as data)'
    } else { Bad 'payload leaked into requirement script' }
    if ($rrScript -match 'Write-Output 1; exit 0' -and $rrScript -match 'ErrorActionPreference') { Ok 'presence logic + STDERR suppression present' } else { Bad 'presence/stderr logic missing' }
    if ($rrScript -notmatch '-like' -and $rrScript -match [regex]::Escape('$targets -contains $_.DisplayName') -and $rrScript -match 'Test-Path -LiteralPath') {
        Ok 'exact/literal presence only (no substring -like; -LiteralPath tattoo/product-code)'
    } else { Bad 'presence match not exact/literal' }

    Write-Host "`n[9] MSI update requirement uses the UpgradeCode (stubbed MSI read)" -ForegroundColor Cyan
    # Override the COM MSI reader so no real .msi is needed; confirms the MSI Zero-Config path builds a rule.
    function Get-Win32ToolkitMsiProperty { param([string]$Path, [string]$Property)
        if ($Property -eq 'UpgradeCode') { return '{CDB13460-04DF-4708-A7FD-4CB4A0684605}' }
        if ($Property -eq 'ProductName') { return 'Stub MSI App' }
        return ''
    }
    $mproj = Join-Path $base 'MsiApp'
    New-Item -ItemType Directory -Path (Join-Path $mproj 'Files') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mproj 'SupportFiles') -Force | Out-Null
    Set-Content -Path (Join-Path $mproj 'Files\stub.msi') -Value 'x'   # presence only; the read is stubbed
    $mcfg = [pscustomobject]@{ App = [pscustomobject]@{ Name=''; Version='1.0'; Vendor='' }; Installer = [pscustomobject]@{ Type='msi'; FileName='stub.msi' } }
    [System.IO.File]::WriteAllText((Join-Path $mproj 'SupportFiles\AppConfig.json'), ($mcfg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    $mrule = Get-Win32ToolkitRequirementRule -ProjectPath $mproj
    if ($mrule) { Ok 'MSI Zero-Config builds a rule (no abort)' } else { Bad 'MSI aborted despite UpgradeCode' }
    if ($mrule) {
        $ms = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($mrule['scriptContent']))
        if ($ms -match 'RelatedProducts' -and $ms -match [regex]::Escape('{CDB13460-04DF-4708-A7FD-4CB4A0684605}')) { Ok 'RelatedProducts + real UpgradeCode embedded' } else { Bad 'UpgradeCode presence check missing' }
        if ($mrule['displayName'] -eq 'Stub MSI App is installed') { Ok 'displayName from MSI ProductName' } else { Bad "displayName: $($mrule['displayName'])" }
    }

    Write-Host "`n[10] MSI Zero-Config gets the tattoo + version detection via DisplayName" -ForegroundColor Cyan
    $msiP = Join-Path $base 'MsiTattoo'
    New-Item -ItemType Directory -Path (Join-Path $msiP 'SupportFiles') -Force | Out-Null
    $mtCfg = [pscustomobject]@{ App = [pscustomobject]@{ Vendor='Notepad++ Team'; Name=''; DisplayName='Notepad++'; Version='8.9.6.4'; ScriptAuthor='Contoso IT' } }
    [System.IO.File]::WriteAllText((Join-Path $msiP 'SupportFiles\AppConfig.json'), ($mtCfg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $msiP 'Invoke-AppDeployToolkit.ps1') -Force   # deploy script carries the tattoo
    $mdet = @(Get-Win32DetectionRules -ProjectPath $msiP 6>$null)
    if ($mdet.Count -eq 1 -and $mdet[0]['detectionType'] -eq 'version' -and
        $mdet[0]['keyPath'] -eq 'HKEY_LOCAL_MACHINE\SOFTWARE\Contoso IT\Notepad++ Team\Notepad++' -and
        $mdet[0]['detectionValue'] -eq '8.9.6.4') {
        Ok 'MSI (empty Name) -> version tattoo rule via DisplayName'
    } else { Bad "MSI detection: $($mdet[0] | ConvertTo-Json -Compress)" }

    Write-Host "`n[11] Exact-path wait ignores decoy/stale captures" -ForegroundColor Cyan
    # A decoy capture that any glob would satisfy the wait with; the expected file describes FreshApp.
    $docDir = Join-Path $proj 'Documentation'
    New-Item -ItemType Directory -Path $docDir -Force | Out-Null
    $decoyCap = Join-Path $docDir 'InstallationChanges_00000000_000000.json'
    ([pscustomobject]@{ NewRegistryKeys = @([pscustomobject]@{
        Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DecoyApp'; KeyName = 'DecoyApp'
        Values = @{ DisplayName = 'DecoyApp'; UninstallString = '"C:\Program Files\Decoy\unins000.exe" /S' } }) } |
        ConvertTo-Json -Depth 8) | Set-Content $decoyCap -Encoding UTF8
    $freshCap2 = Join-Path $docDir 'InstallationChanges_99999999_999999.json'
    ([pscustomobject]@{ NewRegistryKeys = @([pscustomobject]@{
        Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\FreshApp'; KeyName = 'FreshApp'
        Values = @{ DisplayName = 'FreshApp'; UninstallString = '"C:\Program Files\Fresh\unins000.exe" /S' } }) } |
        ConvertTo-Json -Depth 8) | Set-Content $freshCap2 -Encoding UTF8
    (Get-Item $decoyCap).LastWriteTime = (Get-Date)   # decoy is even NEWER by time — exact path must still win
    $waitOk = Wait-ForDocumentationAndProcess -ProjectPath $proj -InstallerType exe -ExpectedJsonPath $freshCap2 6>$null
    if ($waitOk) { Ok 'wait satisfied by the exact expected file' } else { Bad 'exact-path wait failed' }
    $cfgW = Get-Win32ToolkitAppConfig -ProjectPath $proj
    if ($cfgW.Uninstall.AppName -eq 'FreshApp') { Ok 'AppConfig.Uninstall driven by the EXPECTED capture, not the decoy' } else { Bad "Uninstall.AppName = $($cfgW.Uninstall.AppName)" }

    Write-Host "`n[12] Anchor verification (PSADT template drift protection)" -ForegroundColor Cyan
    New-ADTTemplate -Destination $base -Name 'Drift' | Out-Null
    $drift = Join-Path $base 'Drift'

    # (1) any scaffold date is handled (item-5 regression) + clean run has zero warnings + idempotent
    $p1 = Join-Path $base 'Drift1'; Copy-Item $drift $p1 -Recurse
    $dep1 = Join-Path $p1 'Invoke-AppDeployToolkit.ps1'
    Set-Content $dep1 -Value ([regex]::Replace((Get-Content $dep1 -Raw), "AppScriptDate = '\d{4}-\d{2}-\d{2}'", "AppScriptDate = '2031-01-15'")) -Encoding UTF8
    $r1 = Set-PSADTDataDrivenScript -ScriptPath $dep1 -WarningVariable wv1 -WarningAction SilentlyContinue
    $c1 = Get-Content $dep1 -Raw
    if ($r1 -and $c1 -match [regex]::Escape('AppScriptDate = $appConfig.App.ScriptDate') -and $c1 -notmatch '2031-01-15') { Ok 'any scaffold date -> data-driven (item-5 regression)' } else { Bad "date test: r=$r1" }
    if (-not $wv1) { Ok 'clean scaffold patches with zero warnings' } else { Bad "unexpected warnings: $($wv1 -join '; ')" }
    $r1b = Set-PSADTDataDrivenScript -ScriptPath $dep1 -WarningVariable wv1b -WarningAction SilentlyContinue
    if ($r1b -and -not $wv1b) { Ok 'idempotent re-run: $true, no warnings' } else { Bad 're-run regressed' }

    # (2) NON-critical anchor removed -> $false + named warning, file still written/patched
    $p2 = Join-Path $base 'Drift2'; Copy-Item $drift $p2 -Recurse
    $dep2 = Join-Path $p2 'Invoke-AppDeployToolkit.ps1'
    Set-Content $dep2 -Value ((Get-Content $dep2 -Raw).Replace('## <Perform Post-Installation tasks here>', '## drifted away')) -Encoding UTF8
    $r2 = Set-PSADTDataDrivenScript -ScriptPath $dep2 -WarningVariable wv2 -WarningAction SilentlyContinue
    if (-not $r2 -and (@($wv2) -match 'Post-Install marker')) { Ok 'non-critical miss -> $false + warning naming the anchor' } else { Bad "r2=$r2 wv=[$($wv2 -join ';')]" }
    if ((Get-Content $dep2 -Raw) -match [regex]::Escape('$appConfig =')) { Ok 'non-critical miss still writes the patched file' } else { Bad 'file not patched on non-critical miss' }

    # (3) CRITICAL anchor removed -> $false + file left byte-identical (no half-patch)
    $p3 = Join-Path $base 'Drift3'; Copy-Item $drift $p3 -Recurse
    $dep3 = Join-Path $p3 'Invoke-AppDeployToolkit.ps1'
    Set-Content $dep3 -Value ((Get-Content $dep3 -Raw).Replace('$adtSession = @{', '$adtSessionDrifted = @{')) -Encoding UTF8
    $before3 = Get-Content $dep3 -Raw
    $r3 = Set-PSADTDataDrivenScript -ScriptPath $dep3 -WarningVariable wv3 -WarningAction SilentlyContinue
    if (-not $r3 -and ((Get-Content $dep3 -Raw) -eq $before3) -and (@($wv3) -match 'Critical anchor')) { Ok 'critical miss -> $false, file UNCHANGED' } else { Bad "r3=$r3" }

    # (4) org-template: re-apply is warning-free; a genuinely drifted script warns
    $null = Apply-OrgTemplate -ProjectPath $proj -Template $escTmpl -WarningVariable wv4 -WarningAction SilentlyContinue 6>$null
    if (-not (@($wv4) -match 'drift')) { Ok 're-applying the org template raises no drift warnings' } else { Bad "re-apply warned: $($wv4 -join ';')" }
    $p5 = Join-Path $base 'Drift5'; New-Item -ItemType Directory -Path $p5 -Force | Out-Null
    Set-Content (Join-Path $p5 'Invoke-AppDeployToolkit.ps1') -Value ((Get-Content $dep1 -Raw).Replace('Show-ADTInstallationProgress', 'X-NoProgress')) -Encoding UTF8
    $null = Apply-OrgTemplate -ProjectPath $p5 -Template $escTmpl -WarningVariable wv5 -WarningAction SilentlyContinue 6>$null
    if (@($wv5) -match 'progress dialog') { Ok 'drifted script -> org-template drift warning fired' } else { Bad "no drift warning: [$($wv5 -join ';')]" }

    Write-Host "`n[13] MSIX end-to-end: configure -> identity uninstall -> patched snippets -> tattoo detection" -ForegroundColor Cyan
    New-ADTTemplate -Destination $base -Name 'MsixApp' | Out-Null
    $mxProj = Join-Path $base 'MsixApp'
    New-Item -ItemType Directory -Path (Join-Path $mxProj 'Files') -Force | Out-Null
    # Synthetic .msix (zip with a root AppxManifest.xml; hostile publisher)
    $mxMf = Join-Path $base 'mxmf'; New-Item -ItemType Directory -Path $mxMf -Force | Out-Null
    @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="Evil.Msix" Publisher="CN=O'Evil, O=&quot;Q&quot;" Version="2.0.0.0" />
</Package>
'@ | Set-Content -Path (Join-Path $mxMf 'AppxManifest.xml') -Encoding UTF8
    Compress-Archive -Path (Join-Path $mxMf 'AppxManifest.xml') -DestinationPath (Join-Path $base 'mx.zip') -Force
    Move-Item (Join-Path $base 'mx.zip') (Join-Path $mxProj 'Files\EvilMsix.msix') -Force

    $okMx = Configure-PSADTForInstaller -ProjectPath $mxProj -AppInfo ([pscustomobject]@{ Name = 'Evil Msix'; Version = '2.0.0'; Id = 'Evil.Msix' }) -Architecture 'x64'
    if ($okMx) { Ok 'Configure succeeded for msix' } else { Bad 'Configure failed' }
    $mxCfg = Get-Win32ToolkitAppConfig -ProjectPath $mxProj
    if ($mxCfg.Installer.Type -eq 'msix' -and $mxCfg.Installer.SilentArgs -eq '') { Ok 'Installer.Type=msix, SilentArgs empty' } else { Bad "installer: $($mxCfg.Installer | ConvertTo-Json -Compress)" }
    $mxU = @($mxCfg.Uninstall.Uninstallers)[0]
    if ($mxU.Type -eq 'msix' -and $mxU.PackageName -eq 'Evil.Msix') { Ok 'identity uninstall written at CONFIGURE time (capture-independent)' } else { Bad "uninstall: $($mxU | ConvertTo-Json -Compress)" }

    $mxScript = Join-Path $mxProj 'Invoke-AppDeployToolkit.ps1'
    $errsMx = $null; [System.Management.Automation.Language.Parser]::ParseFile($mxScript, [ref]$null, [ref]$errsMx) | Out-Null
    if (-not ($errsMx -and $errsMx.Count)) { Ok 'patched msix deploy script parses' } else { Bad "parse: $($errsMx[0].Message)" }
    $mxPs1 = Get-Content $mxScript -Raw
    if ($mxPs1 -match 'Add-AppxProvisionedPackage' -and $mxPs1 -match 'IsSystem') { Ok 'install snippet: SYSTEM provisioning + interactive Add-AppxPackage branch' } else { Bad 'msix install branch missing' }
    if ($mxPs1 -match 'Remove-AppxPackage' -and $mxPs1 -match [regex]::Escape('Where-Object { $_.Name -eq $u.PackageName }')) { Ok 'uninstall snippet: exact-Name Remove-AppxPackage' } else { Bad 'msix uninstall branch missing' }
    if ($mxPs1 -notmatch [regex]::Escape('O''Evil') -and $mxPs1 -notmatch 'Evil\.Msix') { Ok 'identity values only in AppConfig.json, never in the .ps1 (data-vs-code)' } else { Bad 'identity leaked into code' }

    # Tattoo detection: inject ScriptAuthor+Vendor (org template is $null in this harness)
    $mxCfg2 = Get-Win32ToolkitAppConfig -ProjectPath $mxProj
    $mxCfg2.App.ScriptAuthor = 'Contoso IT'; $mxCfg2.App.Vendor = 'Evil Vendor'
    Set-Win32ToolkitAppConfig -ProjectPath $mxProj -Config $mxCfg2 | Out-Null
    $mxDet = @(Get-Win32DetectionRules -ProjectPath $mxProj 6>$null)
    if ($mxDet.Count -eq 1 -and $mxDet[0]['detectionType'] -eq 'version') { Ok 'msix project gets the tattoo version detection rule' } else { Bad "detection: $($mxDet[0] | ConvertTo-Json -Compress)" }
}
finally { Remove-Item -Path $base -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'Data-driven integration test PASSED' -ForegroundColor Green }
else             { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 }
