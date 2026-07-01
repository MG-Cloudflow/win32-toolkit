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
        $ps1 -match [regex]::Escape('$($adtSession.AppScriptAuthor)\$($adtSession.AppVendor)\$($adtSession.AppName)')) {
        Ok 'install tattoo present (post-install write + post-uninstall remove, value-free)'
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
    if ($rrScript -notmatch '-like' -and $rrScript -match [regex]::Escape('$_.DisplayName -eq $target') -and $rrScript -match 'Test-Path -LiteralPath') {
        Ok 'exact/literal presence only (no substring -like; -LiteralPath tattoo/product-code)'
    } else { Bad 'presence match not exact/literal' }
}
finally { Remove-Item -Path $base -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'Data-driven integration test PASSED' -ForegroundColor Green }
else             { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 }
