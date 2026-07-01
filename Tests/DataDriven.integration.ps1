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
}
finally { Remove-Item -Path $base -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'Data-driven integration test PASSED' -ForegroundColor Green }
else             { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 }
