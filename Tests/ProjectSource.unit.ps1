<#
    Installer-identity PR 1 (spec 2.6): Get-Win32ToolkitProjectSource, the AppConfig.Source builder.

      - a persisted AppConfig.Source (SchemaVersion 1.0) is returned as-is (Rebuilt = $false);
      - otherwise it is rebuilt in memory from Files\ (Rebuilt = $true): winget projects -> 'winget-default',
        manual projects -> WingetId '', AppConfig.Installer.Type, 'parameter';
      - -Rebuild ignores a persisted Source and carries no 'Rebuilt' member (that object is what is persisted);
      - ProductCode / UpgradeCode come from the MSI Property table (shadowed here), never from the YAML;
      - nothing throws.

    Temp projects only (fixtures are written to %TEMP%). Get-Win32ToolkitMsiProperty is SHADOWED (no COM).

    Run:  pwsh -File Tests\ProjectSource.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'Get-Win32ToolkitProjectSource', 'Get-Win32ToolkitInstallerFamily', 'ConvertTo-Win32ToolkitSafeText',
               'Get-Win32ToolkitAppConfig', 'Get-YAMLInstallerInfo', 'Get-WingetManifestFile', 'Get-InstallerFileInfo',
               'Get-Win32ToolkitInstallerExtension') {   # (that file also defines Get-Win32ToolkitInstallerType)
    . (Join-Path $repo "Private\$f.ps1")
}

# MSI Property table shadow: what the real MSI would say (a GUID that is NOT the one in the YAML).
$script:msiCalls = 0
$script:msiAnswer = @{ ProductCode = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'; UpgradeCode = '{12345678-1234-1234-1234-123456789ABC}' }
function Get-Win32ToolkitMsiProperty {
    [CmdletBinding()]
    param([string]$Path, [string]$Property)
    $script:msiCalls++
    [string]$script:msiAnswer[$Property]
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32src_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
function New-Proj([string]$Name) {
    $p = Join-Path $tmpRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $p 'Files') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force | Out-Null
    $p
}
function Write-Text([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false)) }
function Write-Cfg([string]$Proj, $Obj) { Write-Text (Join-Path $Proj 'SupportFiles\AppConfig.json') ($Obj | ConvertTo-Json -Depth 8) }

# A merged winget manifest (what `winget download` writes) for an MSI, with a QUOTED ProductCode that differs
# from what the MSI itself says.
$msiManifest = @'
PackageIdentifier: Notepad++.Notepad++
PackageVersion: 8.9.8.1
PackageLocale: en-US
Publisher: Notepad++ Team
PackageName: Notepad++
InstallerLocale: en-US
Installers:
- Architecture: x64
  InstallerType: wix
  Scope: machine
  UpgradeBehavior: install
  ProductCode: '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
ManifestType: singleton
ManifestVersion: 1.6.0
'@
$exeManifest = @'
PackageIdentifier: Notepad++.Notepad++
PackageVersion: 8.9.8.1
Installers:
- Architecture: x64
  InstallerType: nullsoft
  Scope: machine
  ProductCode: Notepad++
ManifestType: singleton
ManifestVersion: 1.6.0
'@

# --- [1] winget MSI project, no persisted Source -------------------------------------------------
Write-Host '[1] winget MSI project without a persisted Source -> rebuilt in memory, codes from the MSI' -ForegroundColor Cyan
$p1 = New-Proj 'msi'
Write-Text (Join-Path $p1 'Files\Notepad++.Notepad++.yaml') $msiManifest
Write-Text (Join-Path $p1 'Files\npp.8.9.8.1.Installer.x64.msi') 'not really an msi'
Write-Cfg $p1 ([pscustomobject]@{ SchemaVersion = '1.0'; App = [pscustomobject]@{ Arch = 'x64' }; Installer = [pscustomobject]@{ Type = 'msi' } })
$script:msiCalls = 0
$s = Get-Win32ToolkitProjectSource -ProjectPath $p1
$exp = [ordered]@{
    SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; InstallerType = 'wix'; Family = 'msi'
    Scope = 'machine'; Architecture = 'x64'; Locale = 'en-US'; PinnedBy = 'winget-default'; RequestedInstallerType = ''
    WingetClient = ''; ProductCode = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'; UpgradeCode = '{12345678-1234-1234-1234-123456789ABC}'
    UpgradeBehavior = 'install'; Rebuilt = $true
}
foreach ($k in $exp.Keys) {
    if ("$($s.$k)" -ceq "$($exp[$k])") { Ok "$k = '$($exp[$k])'" } else { Bad "$k = '$($s.$k)' (expected '$($exp[$k])')" }
}
if ($s.ProductCode -ne '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}' -and $script:msiCalls -eq 2) { Ok 'ProductCode/UpgradeCode come from the MSI Property table (2 reads), never from the YAML' } else { Bad "msi reads $($script:msiCalls), ProductCode $($s.ProductCode)" }
$names = @($s.PSObject.Properties.Name) -join ','
if ($names -ceq 'SchemaVersion,WingetId,Version,InstallerType,Family,Scope,Architecture,Locale,PinnedBy,RequestedInstallerType,WingetClient,ProductCode,UpgradeCode,UpgradeBehavior,Rebuilt') { Ok 'the property order follows the data contract (+ Rebuilt)' } else { Bad "properties: $names" }

$script:msiAnswer = @{ ProductCode = 'not-a-guid'; UpgradeCode = '{12345678-1234-1234-1234-123456789ABC}; DROP' }
$s = Get-Win32ToolkitProjectSource -ProjectPath $p1
if ($s.ProductCode -eq '' -and $s.UpgradeCode -eq '') { Ok 'MSI values that are not strict GUIDs -> ''''' } else { Bad "junk MSI values kept: $($s.ProductCode) / $($s.UpgradeCode)" }
$script:msiAnswer = @{ ProductCode = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'; UpgradeCode = '{12345678-1234-1234-1234-123456789ABC}' }

# --- [2] winget EXE project -------------------------------------------------------------------
Write-Host '[2] winget EXE project -> no ProductCode/UpgradeCode, the MSI reader is not called' -ForegroundColor Cyan
$p2 = New-Proj 'exe'
Write-Text (Join-Path $p2 'Files\Notepad++.Notepad++.yaml') $exeManifest
Write-Text (Join-Path $p2 'Files\npp.8.9.8.1.Installer.x64.exe') 'MZ'
$script:msiCalls = 0
$s = Get-Win32ToolkitProjectSource -ProjectPath $p2
if ($s.InstallerType -eq 'nullsoft' -and $s.Family -eq 'exe' -and $s.ProductCode -eq '' -and $s.UpgradeCode -eq '' -and $script:msiCalls -eq 0) {
    Ok "nullsoft / exe, ProductCode '' (the manifest's 'Notepad++' is not used), MSI reader not called"
} else { Bad "exe: $($s | ConvertTo-Json -Compress), msi reads $($script:msiCalls)" }
if ($s.PinnedBy -eq 'winget-default' -and $s.Rebuilt -and $s.UpgradeBehavior -eq '' -and $s.Locale -eq '') { Ok "pre-PR-1 winget project -> PinnedBy winget-default, Rebuilt; absent fields -> ''" } else { Bad "exe pin: $($s.PinnedBy) $($s.Rebuilt)" }

# --- [3] persisted Source returned as-is ----------------------------------------------------------
Write-Host '[3] A persisted Source (SchemaVersion 1.0) is returned as-is' -ForegroundColor Cyan
$persisted = [pscustomobject]@{
    SchemaVersion = '1.0'; WingetId = 'Contoso.Persisted'; Version = '1.2.3'; InstallerType = 'inno'; Family = 'exe'; Scope = 'user'
    Architecture = 'x86'; Locale = 'de-DE'; PinnedBy = 'parameter'; RequestedInstallerType = 'inno'; WingetClient = '1.29.380'
    ProductCode = ''; UpgradeCode = ''; UpgradeBehavior = 'uninstallPrevious'
}
Write-Cfg $p2 ([pscustomobject]@{ SchemaVersion = '1.0'; Installer = [pscustomobject]@{ Type = 'exe' }; Source = $persisted })
$s = Get-Win32ToolkitProjectSource -ProjectPath $p2
$same = $true
foreach ($k in $persisted.PSObject.Properties.Name) { if ("$($s.$k)" -cne "$($persisted.$k)") { $same = $false; Bad "persisted $k = '$($s.$k)'" } }
if ($same -and $s.Rebuilt -eq $false) { Ok 'every persisted field returned unchanged, Rebuilt = $false (the Files\ manifest is not read)' } else { Bad "Rebuilt = $($s.Rebuilt)" }

# --- [4] -Rebuild ignores the persisted Source --------------------------------------------------
Write-Host '[4] -Rebuild ignores a persisted Source; parameters land in the result; no Rebuilt member' -ForegroundColor Cyan
$s = Get-Win32ToolkitProjectSource -ProjectPath $p2 -Rebuild -PinnedBy parameter -RequestedInstallerType 'NULLSOFT' -WingetClient 'v1.29.380' -Architecture arm64
if ($s.WingetId -eq 'Notepad++.Notepad++' -and $s.InstallerType -eq 'nullsoft' -and $s.PinnedBy -eq 'parameter' -and
    $s.RequestedInstallerType -eq 'nullsoft' -and $s.WingetClient -eq '1.29.380') {
    Ok "built from Files\ with PinnedBy parameter, RequestedInstallerType nullsoft, WingetClient 1.29.380 (leading v dropped)"
} else { Bad "-Rebuild: $($s | ConvertTo-Json -Compress)" }
if ($s.Architecture -eq 'x64') { Ok 'the manifest Architecture wins over -Architecture' } else { Bad "Architecture = $($s.Architecture)" }
if (-not $s.PSObject.Properties['Rebuilt']) { Ok "-Rebuild output has no 'Rebuilt' member (it is persisted as-is)" } else { Bad '-Rebuild output carries Rebuilt' }
$s = Get-Win32ToolkitProjectSource -ProjectPath $p2 -Rebuild -PinnedBy continuity -RequestedInstallerType wix
if ($s.PinnedBy -eq 'continuity' -and $s.RequestedInstallerType -eq 'wix') { Ok 'continuity pin recorded with its requested type' } else { Bad "continuity: $($s.PinnedBy)/$($s.RequestedInstallerType)" }
$s = Get-Win32ToolkitProjectSource -ProjectPath $p2 -Rebuild -PinnedBy winget-default -RequestedInstallerType wix
if ($s.PinnedBy -eq 'winget-default' -and $s.RequestedInstallerType -eq '') { Ok "winget-default -> RequestedInstallerType ''" } else { Bad "winget-default requested = '$($s.RequestedInstallerType)'" }
$threw = $false
try { Get-Win32ToolkitProjectSource -ProjectPath $p2 -Rebuild -PinnedBy 'whatever' | Out-Null } catch { $threw = $true }
if ($threw) { Ok '-PinnedBy is a ValidateSet' } else { Bad '-PinnedBy accepted an unknown value' }

# --- [5] newer SchemaVersion -> rebuilt -----------------------------------------------------------
Write-Host '[5] A persisted Source with another SchemaVersion is not trusted -> rebuilt' -ForegroundColor Cyan
$persisted.SchemaVersion = '2.0'
Write-Cfg $p2 ([pscustomobject]@{ SchemaVersion = '1.0'; Source = $persisted })
$s = Get-Win32ToolkitProjectSource -ProjectPath $p2
if ($s.Rebuilt -and $s.WingetId -eq 'Notepad++.Notepad++') { Ok 'SchemaVersion 2.0 -> rebuilt from Files\' } else { Bad "schema 2.0: $($s | ConvertTo-Json -Compress)" }

# --- [6] manual project -----------------------------------------------------------------------------
Write-Host '[6] Manual project (no winget manifest) -> WingetId '''', AppConfig.Installer.Type, PinnedBy parameter' -ForegroundColor Cyan
$p6 = New-Proj 'manual'
Write-Text (Join-Path $p6 'Files\setup.exe') 'MZ'
Write-Cfg $p6 ([pscustomobject]@{ SchemaVersion = '1.0'; App = [pscustomobject]@{ Arch = 'x86'; Name = 'Tool' }; Installer = [pscustomobject]@{ Type = 'exe'; FileName = 'setup.exe' } })
$s = Get-Win32ToolkitProjectSource -ProjectPath $p6
if ($s.WingetId -eq '' -and $s.InstallerType -eq 'exe' -and $s.Family -eq 'exe' -and $s.PinnedBy -eq 'parameter' -and $s.Rebuilt -and
    $s.Architecture -eq 'x86' -and $s.Version -eq '' -and $s.Scope -eq '') {
    Ok "WingetId '', InstallerType exe (AppConfig), Family exe, PinnedBy parameter, Rebuilt, Architecture from App.Arch"
} else { Bad "manual: $($s | ConvertTo-Json -Compress)" }
$s = Get-Win32ToolkitProjectSource -ProjectPath $p6 -Architecture arm64
if ($s.Architecture -eq 'arm64') { Ok '-Architecture wins over App.Arch when the manifest has none' } else { Bad "Architecture = $($s.Architecture)" }
Remove-Item -LiteralPath (Join-Path $p6 'SupportFiles\AppConfig.json')
$s = Get-Win32ToolkitProjectSource -ProjectPath $p6
if ($s.InstallerType -eq 'exe' -and $s.PinnedBy -eq 'parameter') { Ok 'manual project without AppConfig -> the installer file type' } else { Bad "manual no cfg: $($s.InstallerType)" }

# --- [7] nothing there / corrupt -> no throw ------------------------------------------------------
Write-Host '[7] No manifest, no AppConfig, no Files\, a corrupt AppConfig -> no throw' -ForegroundColor Cyan
$p7 = Join-Path $tmpRoot 'empty'; New-Item -ItemType Directory -Path $p7 -Force | Out-Null
$threw = $false
try { $s = Get-Win32ToolkitProjectSource -ProjectPath $p7 } catch { $threw = $true }
if (-not $threw -and $s.InstallerType -eq '' -and $s.Family -eq '' -and $s.Rebuilt -and $s.WingetId -eq '') { Ok 'an empty folder -> blank fields, no throw' } else { Bad "empty: threw=$threw" }
$threw = $false
try { $s = Get-Win32ToolkitProjectSource -ProjectPath (Join-Path $tmpRoot 'does-not-exist') } catch { $threw = $true }
if (-not $threw) { Ok 'a missing project folder -> no throw' } else { Bad 'missing folder threw' }
$p7b = New-Proj 'corrupt'
Write-Text (Join-Path $p7b 'Files\Notepad++.Notepad++.yaml') $exeManifest
Write-Text (Join-Path $p7b 'SupportFiles\AppConfig.json') '{ this is : not json ]['
$threw = $false
try { $s = Get-Win32ToolkitProjectSource -ProjectPath $p7b } catch { $threw = $true }
if (-not $threw -and $s.InstallerType -eq 'nullsoft' -and $s.Rebuilt) { Ok 'a corrupt AppConfig -> rebuilt from Files\, no throw' } else { Bad "corrupt: threw=$threw" }
$threw = $false
try { $s = Get-Win32ToolkitProjectSource -ProjectPath $p7b -ErrorAction Stop } catch { $threw = $true }
if (-not $threw) { Ok 'no throw under -ErrorAction Stop' } else { Bad 'threw under -ErrorAction Stop' }

# --- [8] untrusted manifest values are sanitised ----------------------------------------------------
Write-Host '[8] Hostile manifest values are sanitised (C-6)' -ForegroundColor Cyan
$esc = [char]0x1B; $rlo = [char]0x202E
$p8 = New-Proj 'hostile'
Write-Text (Join-Path $p8 'Files\Evil.App.yaml') ("PackageIdentifier: Evil.App${rlo}gpj`nPackageVersion: 1.0${esc}[2J`nInstallers:`n- Architecture: x64`n  InstallerType: nullsoft`n  InstallerLocale: en${esc}US`n")
$s = Get-Win32ToolkitProjectSource -ProjectPath $p8
$all = (@($s.PSObject.Properties.Value) | ForEach-Object { [string]$_ }) -join '|'
if ($all -notmatch '[\x00-\x1F\u202E]' -and $s.WingetId -ceq 'Evil.App?gpj' -and $s.Version -ceq '1.0?[2J' -and $s.Locale -ceq 'en?US') { Ok 'control and bidi characters -> ?' } else { Bad "not sanitised: $($s | ConvertTo-Json -Compress)" }

# --- [9] source hygiene -------------------------------------------------------------------------
Write-Host '[9] Source: every catch starts with the C-2 line; every Get-Content passes -Encoding; ASCII-only' -ForegroundColor Cyan
$file = Join-Path $repo 'Private\Get-Win32ToolkitProjectSource.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
$catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
$badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
if ($catches.Count -ge 1 -and $badCatch.Count -eq 0) { Ok "$($catches.Count) catch clause(s), each starts with the C-2 line" } else { Bad 'a catch does not start with the C-2 line' }
$gc = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Get-Content', 'gc') }, $true))
$bare = @($gc | Where-Object { -not ($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Encoding' }) })
if ($bare.Count -eq 0) { Ok "$($gc.Count) Get-Content call(s), all with -Encoding" } else { Bad 'Get-Content without -Encoding' }
if (@([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'ASCII-only' } else { Bad 'non-ASCII bytes' }

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail -eq 0) { Write-Host 'All ProjectSource tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail ProjectSource test(s) FAILED." -ForegroundColor Red; exit 1 }
