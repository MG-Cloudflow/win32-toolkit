<#
    PSAppDeployToolkit version policy (impact analysis D1/D3/L1/L4; SCF-01, SCF-03, SCF-05/06, SCF-10, DOC-07).

    win32-toolkit supports PSADT 4.1.x and 4.2.x side by side. This suite proves the policy WITHOUT
    a real PSADT and without touching the machine's module folders:

      [1] Test-Win32ToolkitPsadtVersionSupported - the range check (4.1.0 <= v < 4.3.0), prerelease
          labels, garbage, and fail-closed when the range constant is missing.
      [2] Select-Win32ToolkitPsadtModule - ordering 4.2.1 > 4.2.0 > 4.2.0-rc2 > 4.1.8 (4.3.0 ignored),
          pins (parameter > environment > registry, exact and Major.Minor), PreferredNotFound,
          NoneInstalled, NoneInRange. Uses REAL Get-Module -ListAvailable against fake module folders.
      [3] Test-Win32ToolkitPrerequisites - the range-aware PSADT health row (Warn for a prerelease or an
          ignored unsupported install).
      [4] Create-PSADTProject end to end, each case in its OWN child pwsh (module state cannot be
          unloaded): win32-toolkit is imported for real and the call runs inside its module scope, so
          the guarded import is exercised where it matters (an import from module code is invisible to
          a plain global Get-Module). PSADT is a fake module whose New-ADTTemplate writes a minimal
          project; Find-Module / Install-Module / Update-Module / Read-Host are shadowed and record
          their calls (Install-Module "installs" by copying a fake module into the fake user root; it,
          Find-Module and the fake New-ADTTemplate can be made to throw to drive the failure paths).

    Fake module roots live under %TEMP% and PSModulePath is replaced IN THIS PROCESS (and in each
    child) only, so the machine's real PSADT copies are invisible. $env:W32T_PSADT_VERSION is cleared
    and Get-Win32ToolkitConfigValue is shadowed, so a maintainer's registry pin never leaks in.

    Run:  pwsh -File Tests\PsadtVersionPolicy.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }
. (Join-Path $repo 'Private\Test-Win32ToolkitPsadtVersionSupported.ps1')
. (Join-Path $repo 'Private\Select-Win32ToolkitPsadtModule.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitPrerequisites.ps1')

# Shadows for the in-process parts. Registry pin = $script:regPin; nothing reads the real hive.
$script:regPin = $null
function Get-Win32ToolkitConfigValue { if ($args -contains 'PreferredPsadtVersion') { $script:regPin } }
function Get-Win32ToolkitBasePath { 'C:\FakeBase' }

$savedModulePath = $env:PSModulePath
$savedPin        = $env:W32T_PSADT_VERSION
Remove-Item Env:W32T_PSADT_VERSION -ErrorAction SilentlyContinue

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('w32pv_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$null = New-Item -ItemType Directory -Path $work -Force

# -- Fake PSAppDeployToolkit --------------------------------------------------------------------------
# One generic psm1 for every version: it reads its own manifest, offers New-ADTTemplate -ZeroConfig only
# from 4.2.0 on (like the real module), logs IMPORT/NTT lines to $env:W32T_FAKE_LOG and scaffolds a
# minimal project: deploy script with DeployAppScriptVersion, launcher, bundled manifest (a copy of its
# own, or with ModuleVersion overridden by $env:W32T_FAKE_BUNDLE_VERSION). Files\ and SupportFiles\ are
# created only by 4.1.x (4.2 creates them only with content - V2).
$fakePsm1 = @'
$script:FakeManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'PSAppDeployToolkit.psd1')
$script:FakeVersion  = [version]$script:FakeManifest.ModuleVersion
$script:FakePre      = [string]$script:FakeManifest.PrivateData.PSData.Prerelease
$script:FakeText     = if ($script:FakePre) { "$($script:FakeVersion)-$($script:FakePre)" } else { "$($script:FakeVersion)" }
if ($env:W32T_FAKE_LOG) { Add-Content -LiteralPath $env:W32T_FAKE_LOG -Value "IMPORT $($script:FakeText)" }

function Invoke-FakeScaffold {
    param([string]$Destination, [string]$Name, [bool]$PassThru, [bool]$ZeroConfig)
    $proj = Join-Path $Destination $Name
    if ($env:W32T_FAKE_LOG) { Add-Content -LiteralPath $env:W32T_FAKE_LOG -Value "NTT $($script:FakeText) ZeroConfig=$ZeroConfig PassThru=$PassThru Name=$Name" }
    $null = New-Item -ItemType Directory -Path (Join-Path $proj 'PSAppDeployToolkit') -Force
    Set-Content -LiteralPath (Join-Path $proj 'Invoke-AppDeployToolkit.ps1') -Value ("`$adtSession = @{`r`n    DeployAppScriptVersion = '" + $script:FakeVersion + "'`r`n}")
    if ($env:W32T_FAKE_SCAFFOLD_THROWS) { throw 'Could not find a part of the path (simulated MAX_PATH while copying Assets).' }
    if (-not $env:W32T_FAKE_NO_EXE) { Set-Content -LiteralPath (Join-Path $proj 'Invoke-AppDeployToolkit.exe') -Value 'MZ' }
    $psd1 = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'PSAppDeployToolkit.psd1') -Raw
    if ($env:W32T_FAKE_BUNDLE_VERSION) { $psd1 = $psd1 -replace "ModuleVersion\s*=\s*'[^']*'", "ModuleVersion = '$($env:W32T_FAKE_BUNDLE_VERSION)'" }
    Set-Content -LiteralPath (Join-Path $proj 'PSAppDeployToolkit\PSAppDeployToolkit.psd1') -Value $psd1
    if ($script:FakeVersion -lt [version]'4.2.0') {
        $null = New-Item -ItemType Directory -Path (Join-Path $proj 'Files') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles') -Force
    }
    if ($PassThru) { Get-Item -LiteralPath $proj }
}

if ($script:FakeVersion -ge [version]'4.2.0' -and -not $env:W32T_FAKE_NO_ZEROCONFIG) {
    function New-ADTTemplate {
        [CmdletBinding()]
        param([string]$Destination, [string]$Name, [switch]$PassThru, [switch]$ZeroConfig)
        Invoke-FakeScaffold -Destination $Destination -Name $Name -PassThru $PassThru.IsPresent -ZeroConfig $ZeroConfig.IsPresent
    }
}
else {
    function New-ADTTemplate {
        [CmdletBinding()]
        param([string]$Destination, [string]$Name, [switch]$PassThru)
        Invoke-FakeScaffold -Destination $Destination -Name $Name -PassThru $PassThru.IsPresent -ZeroConfig $false
    }
}
Export-ModuleMember -Function New-ADTTemplate
'@
$fakePsm1Path = Join-Path $work 'fake.psm1'
Set-Content -LiteralPath $fakePsm1Path -Value $fakePsm1 -Encoding utf8

# Writes <Root>\PSAppDeployToolkit\<base version>\ (a prerelease lives in its BASE-version folder, as
# PowerShellGet installs it).
function MakeFakePsadt([string]$Root, [string]$Version) {
    $base = $Version -replace '[-+].*$', ''
    $pre  = if ($Version -match '-(.+)$') { $Matches[1] } else { '' }
    $dir  = Join-Path $Root (Join-Path 'PSAppDeployToolkit' $base)
    $null = New-Item -ItemType Directory -Path $dir -Force
    $psData = if ($pre) { "@{ Prerelease = '$pre' }" } else { '@{ Tags = @(''fake'') }' }
    $psd1 = @(
        '@{'
        "    RootModule        = 'PSAppDeployToolkit.psm1'"
        "    ModuleVersion     = '$base'"
        "    GUID              = '8c3c366b-8606-4576-9f2d-4051144f7ca2'"
        "    FunctionsToExport = @('New-ADTTemplate')"
        "    PrivateData       = @{ PSData = $psData }"
        '}'
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $dir 'PSAppDeployToolkit.psd1') -Value $psd1 -Encoding utf8
    Copy-Item -LiteralPath $fakePsm1Path -Destination (Join-Path $dir 'PSAppDeployToolkit.psm1')
    return (Join-Path $dir 'PSAppDeployToolkit.psd1')
}

# Store of "gallery" builds the Install-Module shadow copies from (stable only, like Find-Module
# without -AllowPrerelease).
$store = Join-Path $work 'store'
foreach ($v in '4.1.8', '4.2.0', '4.2.1', '4.3.0') { $null = MakeFakePsadt $store $v }

# ===================================================================================================
Write-Host "`n[1] Test-Win32ToolkitPsadtVersionSupported: 4.1.0 <= v < 4.3.0" -ForegroundColor Cyan
$expect = [ordered]@{ '4.1.0' = $true; '4.1.8' = $true; '4.2.0' = $true; '4.2.0-rc2' = $true; '4.2.99' = $true; '4.1' = $true
                      '4.0.9' = $false; '4.3.0' = $false; '4.3.0-beta1' = $false; '5.0.0' = $false; '3.10.0' = $false
                      'garbage' = $false; '' = $false }
foreach ($k in $expect.Keys) {
    $got = Test-Win32ToolkitPsadtVersionSupported $k
    if ($got -eq $expect[$k]) { Ok "'$k' -> $got" } else { Bad "'$k' -> $got (expected $($expect[$k]))" }
}
if ((Test-Win32ToolkitPsadtVersionSupported ([version]'4.2.1')) -and -not (Test-Win32ToolkitPsadtVersionSupported ([version]'4.3.0'))) { Ok '[version] objects are accepted' } else { Bad '[version] input mishandled' }
if (-not (Test-Win32ToolkitPsadtVersionSupported $null)) { Ok '$null -> $false' } else { Bad '$null accepted' }
$savedRange = $script:PsadtSupportedRange
$script:PsadtSupportedRange = $null
$err = $null
try { $null = Test-Win32ToolkitPsadtVersionSupported '4.2.0' } catch { $err = $_ }
$script:PsadtSupportedRange = $savedRange
if ($err -and $err.Exception -is [System.InvalidOperationException] -and $err.Exception.Message -match 'PsadtSupportedRange is not initialised' -and $err.FullyQualifiedErrorId -notlike 'W32T.*') {
    Ok 'a missing range constant fails closed with a plain InvalidOperationException (not a W32T.* error)'
} else { Bad "missing range constant: $(if ($err) { "$($err.FullyQualifiedErrorId): $($err.Exception.Message)" } else { 'no error' })" }

# ===================================================================================================
Write-Host "`n[2] Select-Win32ToolkitPsadtModule against fake module folders (real Get-Module -ListAvailable)" -ForegroundColor Cyan
$rootA = Join-Path $work 'selA'    # the rc2 sits in a root that comes FIRST in PSModulePath
$rootB = Join-Path $work 'selB'
$null = MakeFakePsadt $rootA '4.2.0-rc2'
foreach ($v in '4.1.8', '4.2.0', '4.2.1', '4.3.0') { $null = MakeFakePsadt $rootB $v }
$env:PSModulePath = "$rootA;$rootB"

$s = Select-Win32ToolkitPsadtModule
$order = @($s.Candidates | ForEach-Object { $_.VersionText }) -join ' > '
if ($order -eq '4.3.0 > 4.2.1 > 4.2.0 > 4.2.0-rc2 > 4.1.8') { Ok "candidate order: $order (stable before its prerelease, despite PSModulePath order)" } else { Bad "candidate order: $order" }
if ($s.Status -eq 'Selected' -and $s.VersionText -eq '4.2.1' -and $s.Version -eq [version]'4.2.1') { Ok 'newest IN-RANGE version selected (4.2.1); 4.3.0 ignored' } else { Bad "selected $($s.Status) $($s.VersionText)" }
if ($s.Module -and $s.Module.Path -like "$rootB*4.2.1*") { Ok 'Module is the 4.2.1 PSModuleInfo (path)' } else { Bad "Module path '$($s.Module.Path)'" }
if ($s.NewestInstalledText -eq '4.3.0' -and -not $s.NewestInstalledInRange) { Ok 'NewestInstalled = 4.3.0, flagged out of range' } else { Bad "NewestInstalled $($s.NewestInstalledText) InRange=$($s.NewestInstalledInRange)" }
if ($s.Reason -match '4\.3\.0' -and $s.Reason -match '4\.2\.1' -and $s.Reason -match [regex]::Escape('4.1.x and 4.2.x')) { Ok "Reason names the ignored and the used version and the range: $($s.Reason)" } else { Bad "Reason: $($s.Reason)" }
if (-not $s.IsPinned -and $s.PreferredSource -eq '' -and -not $s.IsPrerelease) { Ok 'not pinned, not prerelease' } else { Bad "IsPinned=$($s.IsPinned) Source='$($s.PreferredSource)' IsPrerelease=$($s.IsPrerelease)" }
$c43 = $s.Candidates | Where-Object VersionText -eq '4.3.0'
$crc = $s.Candidates | Where-Object VersionText -eq '4.2.0-rc2'
if ($c43 -and -not $c43.InRange -and $crc.InRange -and $crc.IsPrerelease) { Ok 'Candidates carry InRange / IsPrerelease' } else { Bad 'Candidates flags wrong' }

# rc2 only in range -> selectable (L4), flagged prerelease
Remove-Item -LiteralPath (Join-Path $rootB 'PSAppDeployToolkit\4.2.1'), (Join-Path $rootB 'PSAppDeployToolkit\4.2.0') -Recurse -Force
$s = Select-Win32ToolkitPsadtModule
if ($s.VersionText -eq '4.2.0-rc2' -and $s.IsPrerelease -and $s.Prerelease -eq 'rc2' -and $s.Version -eq [version]'4.2.0') { Ok 'an installed in-range prerelease is selectable (4.2.0-rc2 over 4.1.8)' } else { Bad "selected $($s.VersionText)" }
$null = MakeFakePsadt $rootB '4.2.0'
$null = MakeFakePsadt $rootB '4.2.1'

# pins
$s = Select-Win32ToolkitPsadtModule -PreferredVersion '4.1.8'
if ($s.Status -eq 'Selected' -and $s.VersionText -eq '4.1.8' -and $s.IsPinned -and $s.PreferredSource -eq 'Parameter') { Ok '-PreferredVersion 4.1.8 -> 4.1.8 (Parameter)' } else { Bad "param pin: $($s.Status) $($s.VersionText) $($s.PreferredSource)" }
$s = Select-Win32ToolkitPsadtModule -PreferredVersion '4.2.0-RC2'
if ($s.VersionText -eq '4.2.0-rc2') { Ok 'exact pin matches case-insensitively (4.2.0-RC2)' } else { Bad "pin 4.2.0-RC2 -> $($s.Status) $($s.VersionText)" }
$script:regPin = '4.1.8'
$s = Select-Win32ToolkitPsadtModule
if ($s.VersionText -eq '4.1.8' -and $s.PreferredSource -eq 'Registry') { Ok 'registry pin PreferredPsadtVersion=4.1.8 is honoured' } else { Bad "registry pin: $($s.VersionText) $($s.PreferredSource)" }
$env:W32T_PSADT_VERSION = '4.2.0-rc2'
$s = Select-Win32ToolkitPsadtModule
if ($s.VersionText -eq '4.2.0-rc2' -and $s.PreferredSource -eq 'Environment') { Ok '$env:W32T_PSADT_VERSION beats the registry pin' } else { Bad "env vs registry: $($s.VersionText) $($s.PreferredSource)" }
$s = Select-Win32ToolkitPsadtModule -PreferredVersion '4.2.0'
if ($s.VersionText -eq '4.2.0' -and $s.PreferredSource -eq 'Parameter') { Ok '-PreferredVersion beats the environment' } else { Bad "param vs env: $($s.VersionText) $($s.PreferredSource)" }
Remove-Item Env:W32T_PSADT_VERSION
$script:regPin = $null
$s = Select-Win32ToolkitPsadtModule -PreferredVersion '4.1'
if ($s.VersionText -eq '4.1.8') { Ok "Major.Minor pin '4.1' -> best 4.1.x (4.1.8)" } else { Bad "pin 4.1 -> $($s.VersionText)" }
$s = Select-Win32ToolkitPsadtModule -PreferredVersion '4.2'
if ($s.VersionText -eq '4.2.1') { Ok "Major.Minor pin '4.2' -> best 4.2.x (4.2.1)" } else { Bad "pin 4.2 -> $($s.VersionText)" }
foreach ($p in '4.1.7', '4.3.0', '4.3') {
    $s = Select-Win32ToolkitPsadtModule -PreferredVersion $p
    if ($s.Status -eq 'PreferredNotFound' -and $null -eq $s.Module -and $s.Reason -match [regex]::Escape("'$p'") -and $s.Reason -match [regex]::Escape('4.1.x and 4.2.x')) {
        Ok "pin '$p' (absent or unsupported) -> PreferredNotFound, no silent fallback"
    } else { Bad "pin '$p' -> $($s.Status) $($s.VersionText): $($s.Reason)" }
}
$script:regPin = '4.1.7'
$s = Select-Win32ToolkitPsadtModule
if ($s.Status -eq 'PreferredNotFound' -and $s.Reason -match 'from the registry') { Ok "registry pin that is not installed -> PreferredNotFound: $($s.Reason)" } else { Bad "registry 4.1.7 -> $($s.Status): $($s.Reason)" }
$script:regPin = $null

# none installed / none in range
$env:PSModulePath = (Join-Path $work 'empty')
$s = Select-Win32ToolkitPsadtModule
if ($s.Status -eq 'NoneInstalled' -and $null -eq $s.Module -and $s.Reason -match [regex]::Escape('4.1.x and 4.2.x') -and @($s.Candidates).Count -eq 0) { Ok "nothing installed -> NoneInstalled: $($s.Reason)" } else { Bad "empty -> $($s.Status): $($s.Reason)" }
$rootC = Join-Path $work 'selC'
$null = MakeFakePsadt $rootC '4.3.0'
$null = MakeFakePsadt $rootC '4.0.5'
$env:PSModulePath = $rootC
$s = Select-Win32ToolkitPsadtModule
if ($s.Status -eq 'NoneInRange' -and $null -eq $s.Module -and $s.Reason -match '4\.3\.0' -and $s.NewestInstalledText -eq '4.3.0') { Ok "only 4.3.0/4.0.5 installed -> NoneInRange: $($s.Reason)" } else { Bad "out of range -> $($s.Status): $($s.Reason)" }

# ===================================================================================================
Write-Host "`n[3] Health row: range-aware, prerelease and ignored versions flagged (Warn)" -ForegroundColor Cyan
function PsadtRow { @(Test-Win32ToolkitPrerequisites) | Where-Object { $_.Name -like 'PSAppDeployToolkit*' } }
$env:PSModulePath = "$rootA;$rootB"
$row = PsadtRow
if ($row.Name -eq 'PSAppDeployToolkit (4.1.x and 4.2.x)') { Ok "row name: $($row.Name)" } else { Bad "row name: $($row.Name)" }
if ($row.Ok -and $row.Warn -and $row.Detail -eq 'v4.2.1; 4.3.0 installed but unsupported' -and $row.Fixable) { Ok "4.3.0 + 4.2.1 installed -> OK with Warn: '$($row.Detail)'" } else { Bad "row: Ok=$($row.Ok) Warn=$($row.Warn) Detail='$($row.Detail)'" }
$env:PSModulePath = $rootA
$row = PsadtRow
if ($row.Ok -and $row.Warn -and $row.Detail -eq 'v4.2.0-rc2 (prerelease - testing only)') { Ok "rc2 only -> OK with Warn: '$($row.Detail)'" } else { Bad "rc2 row: Ok=$($row.Ok) Warn=$($row.Warn) Detail='$($row.Detail)'" }
$rootD = Join-Path $work 'selD'
$null = MakeFakePsadt $rootD '4.1.8'
$env:PSModulePath = $rootD
$row = PsadtRow
if ($row.Ok -and -not $row.Warn -and $row.Detail -eq 'v4.1.8') { Ok "4.1.8 only -> plain OK: '$($row.Detail)'" } else { Bad "4.1.8 row: Ok=$($row.Ok) Warn=$($row.Warn) Detail='$($row.Detail)'" }
$env:PSModulePath = $rootC
$row = PsadtRow
if (-not $row.Ok -and $row.Fixable -and $row.Detail -match '4\.3\.0') { Ok "only unsupported installed -> not OK, fixable: '$($row.Detail)'" } else { Bad "unsupported row: Ok=$($row.Ok) Detail='$($row.Detail)'" }
$allRows = @(Test-Win32ToolkitPrerequisites)
if (@($allRows | Where-Object { $null -eq $_.PSObject.Properties['Warn'] }).Count -eq 0) { Ok "every row carries a Warn property ($($allRows.Count) rows)" } else { Bad 'a row lacks Warn' }

$env:PSModulePath = $savedModulePath

# ===================================================================================================
Write-Host "`n[4] Create-PSADTProject in win32-toolkit's module scope (one child pwsh per case)" -ForegroundColor Cyan

$harness = Join-Path $work 'harness.ps1'
@'
param([string]$Repo, [string]$CaseFile)
$ErrorActionPreference = 'Stop'
$case = Get-Content -LiteralPath $CaseFile -Raw | ConvertFrom-Json
$log  = Join-Path $case.Out 'calls.log'
$null = New-Item -ItemType File -Path $log -Force

$env:PSModulePath = (@($case.Roots) -join ';')
Remove-Item Env:W32T_PSADT_VERSION -ErrorAction SilentlyContinue
if ($case.EnvPin)        { $env:W32T_PSADT_VERSION = $case.EnvPin }
if ($case.BundleVersion) { $env:W32T_FAKE_BUNDLE_VERSION = $case.BundleVersion }
if ($case.NoExe)         { $env:W32T_FAKE_NO_EXE = '1' }
if ($case.NoZeroConfig)  { $env:W32T_FAKE_NO_ZEROCONFIG = '1' }    # a 4.2.0 build whose New-ADTTemplate lacks -ZeroConfig
if ($case.ScaffoldThrows) { $env:W32T_FAKE_SCAFFOLD_THROWS = '1' } # New-ADTTemplate throws after writing part of the project
if ($case.Preload)       { Import-Module -Name $case.Preload }      # "already loaded" (global), before logging starts
$env:W32T_FAKE_LOG = $log

$mod = Import-Module -Name (Join-Path $Repo 'win32-toolkit.psd1') -Force -PassThru
$res = & $mod {
    param($case, $logPath)
    # -WhatIf:$false: a case run with -WhatIf must still record its calls (the preference reaches this shadow).
    function Log([string]$Line) { Add-Content -LiteralPath $logPath -Value $Line -WhatIf:$false }
    function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($Name -eq 'PreferredPsadtVersion' -and $case.RegPin) { return [string]$case.RegPin }; return $Default }
    function Find-Module {
        [CmdletBinding()] param($Name, $Repository, [switch]$AllVersions, [switch]$AllowPrerelease, $MinimumVersion, $MaximumVersion, $RequiredVersion)
        Log "FIND AllVersions=$($AllVersions.IsPresent) AllowPrerelease=$($AllowPrerelease.IsPresent)"
        if ($case.FindFails) { throw 'Unable to resolve package source PSGallery (simulated).' }
        foreach ($v in @($case.Gallery)) { if ($v) { [pscustomobject]@{ Name = 'PSAppDeployToolkit'; Version = [string]$v } } }
    }
    function Install-Module {
        [CmdletBinding()] param($Name, $RequiredVersion, $MinimumVersion, $MaximumVersion, $Scope, [switch]$Force, [switch]$AllowClobber, [switch]$AllowPrerelease)
        Log "INSTALL Name=$Name RequiredVersion=$RequiredVersion MinimumVersion=$MinimumVersion MaximumVersion=$MaximumVersion Scope=$Scope"
        if ($case.InstallFails) { throw 'Access to the path PSAppDeployToolkit.dll is denied (simulated: in use by another session).' }
        $dest = Join-Path $case.InstallRoot 'PSAppDeployToolkit'
        $null = New-Item -ItemType Directory -Path $dest -Force
        Copy-Item -LiteralPath (Join-Path $case.Store "PSAppDeployToolkit\$RequiredVersion") -Destination $dest -Recurse -Force
    }
    function Update-Module { [CmdletBinding()] param($Name, [switch]$Force) Log "UPDATE $Name" }
    function Read-Host { param($Prompt) Log "PROMPT $Prompt"; [string]$case.Answer }
    function Write-Host { param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, $ForegroundColor, $BackgroundColor, [switch]$NoNewline) Log ('HOST: ' + (@($Object) -join ' ')) }
    function Write-Warning { param([Parameter(Position = 0)][string]$Message) Log ('WARN: ' + $Message) }
    function Start-Process { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) Log 'START-PROCESS' }

    $returns = @(); $counts = @()
    for ($i = 1; $i -le [int]$case.Runs; $i++) {
        $r = @(Create-PSADTProject -ProjectName "App$i" -ProjectPath $case.ProjRoot -Force:([bool]$case.Force) -WhatIf:([bool]$case.WhatIf))
        $counts  += $r.Count
        $returns += ($r.Count -eq 1 -and $r[0] -eq $true)
    }
    [pscustomobject]@{ Returns = $returns; OutputCounts = $counts; LoadedAll = @(Get-Module -Name PSAppDeployToolkit -All).Count }
} $case $log
$res | Add-Member -NotePropertyName GlobalPlain -NotePropertyValue @(Get-Module -Name PSAppDeployToolkit).Count
$res | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $case.Out 'result.json')
'@ | Set-Content -LiteralPath $harness -Encoding utf8

$pwshExe = (Get-Process -Id $PID).Path

# Every case runs in its own child; they are independent, so they run in parallel (a child spends most
# of its time importing win32-toolkit) and are asserted afterwards, in order.
$caseSpecs = [ordered]@{
    freshPrompt   = @{ Gallery = '4.3.0', '4.2.1', '4.2.0', '4.1.8'; Answer = 'y' }
    freshForce    = @{ Gallery = '4.3.0', '4.2.1', '4.2.0', '4.1.8'; Force = $true }
    offerAccept   = @{ Installed = '4.2.0'; Gallery = '4.3.0', '4.2.1'; Answer = 'y' }
    offerGaOverRc = @{ Installed = '4.2.0-rc2'; Gallery = '4.2.0', '4.1.8'; Answer = 'y' }
    offerInstFail = @{ Installed = '4.2.0-rc2'; Gallery = '4.2.0'; Answer = 'y'; InstallFails = $true }
    offerDecline  = @{ Installed = '4.2.0'; Gallery = '4.2.1'; Answer = 'n' }
    offerWhatIf   = @{ Installed = '4.2.0'; Gallery = '4.2.1'; Answer = 'y'; WhatIf = $true }
    inRangeForce  = @{ Installed = '4.2.0'; Gallery = '4.2.1'; Force = $true }
    loadedSame    = @{ Installed = '4.2.0'; Gallery = '4.2.1'; Preload = '4.2.0'; Answer = 'y' }
    rcOnly        = @{ Installed = '4.2.0-rc2'; Force = $true }
    v418          = @{ Installed = '4.1.8'; Force = $true }
    regPin418     = @{ Installed = '4.1.8', '4.2.0'; Gallery = '4.2.1'; RegPin = '4.1.8'; Answer = 'y' }
    pinMissing    = @{ Installed = '4.2.0'; Gallery = '4.1.7', '4.2.1'; EnvPin = '4.1.7'; Answer = 'y' }
    noneInRange   = @{ Installed = '4.3.0'; Gallery = '4.3.0', '4.2.1'; Force = $true }
    bundleWrong   = @{ Installed = '4.2.0'; Force = $true; BundleVersion = '4.1.8' }
    noLauncher    = @{ Installed = '4.2.0'; Force = $true; NoExe = $true }
    noZeroConfig  = @{ Installed = '4.2.0'; Force = $true; NoZeroConfig = $true; Existing = $true }
    scaffoldThrow = @{ Installed = '4.2.0'; Force = $true; ScaffoldThrows = $true }
    findFailKeep  = @{ Force = $true; FindFails = $true; Existing = $true }
    double        = @{ Installed = '4.2.0'; Force = $true; Runs = 2 }
    loadedOther   = @{ Installed = '4.1.8', '4.2.0'; Force = $true; Preload = '4.1.8' }
}

# Builds a case's folders and case.json; returns what is needed to launch and collect it.
function PrepCase([string]$Key, [hashtable]$Spec) {
    $dir  = Join-Path $work $Key
    $inst = Join-Path $dir 'inst'; $pre = Join-Path $dir 'pre'; $out = Join-Path $dir 'out'; $proj = Join-Path $dir 'p'
    foreach ($d in $inst, $pre, $out) { $null = New-Item -ItemType Directory -Path $d -Force }
    if ($Spec.Existing) {   # the user's existing project App1, which must survive a refused run
        $null = New-Item -ItemType Directory -Path (Join-Path $proj 'App1') -Force
        Set-Content -LiteralPath (Join-Path $proj 'App1\keep.txt') -Value 'user data'
    }
    foreach ($v in @($Spec.Installed)) { if ($v) { $null = MakeFakePsadt $(if ($v -like '*-*') { $pre } else { $inst }) $v } }
    $preload = $null
    if ($Spec.Preload) { $preload = Join-Path $(if ($Spec.Preload -like '*-*') { $pre } else { $inst }) ("PSAppDeployToolkit\$($Spec.Preload -replace '-.*$', '')\PSAppDeployToolkit.psd1") }
    $case = [ordered]@{
        Roots = @($inst, $pre); InstallRoot = $inst; Store = $store; Out = $out; ProjRoot = $proj
        Gallery = @($Spec.Gallery); Answer = $Spec.Answer; Force = [bool]$Spec.Force; Runs = $(if ($Spec.Runs) { $Spec.Runs } else { 1 })
        EnvPin = $Spec.EnvPin; RegPin = $Spec.RegPin; BundleVersion = $Spec.BundleVersion; NoExe = [bool]$Spec.NoExe; Preload = $preload
        InstallFails = [bool]$Spec.InstallFails; NoZeroConfig = [bool]$Spec.NoZeroConfig
        ScaffoldThrows = [bool]$Spec.ScaffoldThrows; FindFails = [bool]$Spec.FindFails; WhatIf = [bool]$Spec.WhatIf
    }
    $caseFile = Join-Path $dir 'case.json'
    $case | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $caseFile -Encoding utf8
    [pscustomobject]@{ Key = $Key; Dir = $dir; Out = $out; Proj = $proj; CaseFile = $caseFile; Process = $null }
}

# Reads a finished case: { Returns; OutputCounts; LoadedAll; GlobalPlain; Log[]; Proj }.
function ReadCase($c) {
    $resFile = Join-Path $c.Out 'result.json'
    if (-not (Test-Path -LiteralPath $resFile)) {
        $childOut = @(Get-ChildItem -LiteralPath $c.Dir -Filter 'child*.txt' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join ' '
        Bad "case $($c.Key): the child produced no result - $($childOut -replace '\s+', ' ')"
        return [pscustomobject]@{ Returns = @(); OutputCounts = @(); LoadedAll = -1; GlobalPlain = -1; Log = @(); Proj = $c.Proj }
    }
    $res = Get-Content -LiteralPath $resFile -Raw | ConvertFrom-Json
    $res | Add-Member -NotePropertyName Log -NotePropertyValue @(Get-Content -LiteralPath (Join-Path $c.Out 'calls.log'))
    $res | Add-Member -NotePropertyName Proj -NotePropertyValue $c.Proj
    return $res
}

$prepared = @(foreach ($k in $caseSpecs.Keys) { PrepCase $k $caseSpecs[$k] })
$throttle = [math]::Max(2, [math]::Min(8, [Environment]::ProcessorCount))
$running  = [System.Collections.Generic.List[object]]::new()
foreach ($c in $prepared) {
    while (@($running | Where-Object { -not $_.Process.HasExited }).Count -ge $throttle) { $null = $running[0].Process.WaitForExit(200); $running.RemoveAll([Predicate[object]] { param($x) $x.Process.HasExited }) | Out-Null }
    $c.Process = Start-Process -FilePath $pwshExe -PassThru -NoNewWindow `
        -ArgumentList @('-NoProfile', '-File', "`"$harness`"", '-Repo', "`"$repo`"", '-CaseFile', "`"$($c.CaseFile)`"") `
        -RedirectStandardOutput (Join-Path $c.Dir 'child.txt') -RedirectStandardError (Join-Path $c.Dir 'child-err.txt')
    $running.Add($c)
}
foreach ($c in $prepared) { if (-not $c.Process.WaitForExit(300000)) { Bad "case $($c.Key) timed out"; $c.Process.Kill() } }
$caseResults = @{}
foreach ($c in $prepared) { $caseResults[$c.Key] = ReadCase $c }

function Lines($r, [string]$Prefix) { return , @($r.Log | Where-Object { $_ -like "$Prefix*" }) }
function HasNo($r, [string]$Prefix, [string]$What) {
    $hit = Lines $r $Prefix
    if ($hit.Count -eq 0) { Ok "no $What" } else { Bad "unexpected $What`: $($hit -join ' | ')" }
}
function RetIs($r, [string]$Expected) { (@($r.Returns) -join ',') -eq $Expected }

# -- fresh host --------------------------------------------------------------------------------------
foreach ($key in 'freshPrompt', 'freshForce') {
    Write-Host "  -- fresh host (nothing installed), $key; gallery 4.3.0 / 4.2.1 / 4.2.0 / 4.1.8" -ForegroundColor DarkCyan
    $r = $caseResults[$key]
    $ins = Lines $r 'INSTALL'
    if ($ins.Count -eq 1 -and $ins[0] -match 'RequiredVersion=4\.2\.1 ' -and $ins[0] -match 'Scope=CurrentUser') { Ok "exactly one Install-Module -RequiredVersion 4.2.1 (newest in-range stable): $($ins[0])" } else { Bad "installs: $($ins -join ' | ')" }
    $find = Lines $r 'FIND'
    if ($find.Count -eq 1 -and $find[0] -eq 'FIND AllVersions=True AllowPrerelease=False') { Ok 'one Find-Module -AllVersions, without -AllowPrerelease' } else { Bad "finds: $($find -join ' | ')" }
    HasNo $r 'UPDATE' 'Update-Module call'
    HasNo $r 'PROMPT' 'prompt (a missing toolkit is installed, not offered)'
    if ((RetIs $r 'True') -and (Lines $r 'NTT 4.2.1 ZeroConfig=True PassThru=True').Count -eq 1) { Ok 'scaffolded with the installed 4.2.1, -ZeroConfig -PassThru' } else { Bad "returns $($r.Returns -join ',') / log: $($r.Log -join ' | ')" }
    if ((Test-Path (Join-Path $r.Proj 'App1\Files')) -and (Test-Path (Join-Path $r.Proj 'App1\SupportFiles'))) { Ok 'Files\ and SupportFiles\ exist after a 4.2 scaffold (created when absent)' } else { Bad 'Files\/SupportFiles\ missing' }
    if ((@($r.OutputCounts) -join ',') -eq '1') { Ok 'Create-PSADTProject emits exactly one object ($true)' } else { Bad "output counts: $($r.OutputCounts -join ',')" }
}

Write-Host '  -- installed 4.2.0; gallery 4.3.0 + 4.2.1 -> offer 4.2.1 (accepted)' -ForegroundColor DarkCyan
$r = $caseResults['offerAccept']
$prompt = Lines $r 'PROMPT'
if ($prompt.Count -eq 1 -and $prompt[0] -match '4\.2\.1' -and $prompt[0] -notmatch '4\.3\.0') { Ok "offer names 4.2.1 only: $($prompt[0])" } else { Bad "prompts: $($prompt -join ' | ')" }
$ins = Lines $r 'INSTALL'
if ($ins.Count -eq 1 -and $ins[0] -match 'RequiredVersion=4\.2\.1 ') { Ok 'offer accepted -> Install-Module -RequiredVersion 4.2.1 (side by side)' } else { Bad "installs: $($ins -join ' | ')" }
HasNo $r 'UPDATE' 'Update-Module call'
if ((RetIs $r 'True') -and (Lines $r 'IMPORT 4.2.1').Count -eq 1 -and (Lines $r 'NTT 4.2.1').Count -eq 1) { Ok 're-selected and scaffolded with 4.2.1' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- installed 4.2.0-rc2; gallery 4.2.0 -> offer 4.2.0 (GA over its own prerelease)' -ForegroundColor DarkCyan
$r = $caseResults['offerGaOverRc']
$ins = Lines $r 'INSTALL'
if ((Lines $r 'PROMPT').Count -eq 1 -and $ins.Count -eq 1 -and $ins[0] -match 'RequiredVersion=4\.2\.0 ') { Ok 'rc2 installed -> 4.2.0 offered and installed' } else { Bad "prompt/installs: $($r.Log -join ' | ')" }
if ((Lines $r 'IMPORT 4.2.0').Count -eq 1 -and (Lines $r 'IMPORT 4.2.0-rc2').Count -eq 0 -and (Lines $r 'WARN: Using PSAppDeployToolkit').Count -eq 0) { Ok 'the stable 4.2.0 wins over the rc2 afterwards (no prerelease warning)' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- installed 4.2.0-rc2; offer 4.2.0 accepted but Install-Module FAILS -> warning, continue with rc2' -ForegroundColor DarkCyan
$r = $caseResults['offerInstFail']
$ins = Lines $r 'INSTALL'
if ((Lines $r 'PROMPT').Count -eq 1 -and $ins.Count -eq 1 -and $ins[0] -match 'RequiredVersion=4\.2\.0 ') { Ok 'the offered 4.2.0 install was attempted once' } else { Bad "prompt/installs: $($r.Log -join ' | ')" }
$w = Lines $r 'WARN: Could not install PSAppDeployToolkit 4.2.0 ('
if ($w.Count -eq 1 -and $w[0] -match 'denied' -and $w[0] -like '*; continuing with the installed 4.2.0-rc2.') { Ok "a failed optional update only warns: $($w[0])" } else { Bad "log: $($r.Log -join ' | ')" }
if ((RetIs $r 'True') -and (Lines $r 'IMPORT 4.2.0-rc2').Count -eq 1 -and (Lines $r 'NTT 4.2.0-rc2 ZeroConfig=True').Count -eq 1) { Ok 'the project is still created ($true), with the installed 4.2.0-rc2' } else { Bad "returns $($r.Returns -join ',') / log: $($r.Log -join ' | ')" }
if ((Lines $r 'WARN: Failed to create PSADT project').Count -eq 0 -and (Lines $r 'HOST: Installed PSAppDeployToolkit').Count -eq 0) { Ok 'no generic "Failed to create PSADT project", no "Installed" line' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- installed 4.2.0; gallery 4.2.1 -> offer declined' -ForegroundColor DarkCyan
$r = $caseResults['offerDecline']
if ((Lines $r 'PROMPT').Count -eq 1 -and (Lines $r 'INSTALL').Count -eq 0 -and (Lines $r 'IMPORT 4.2.0').Count -eq 1 -and (RetIs $r 'True')) { Ok "declined -> nothing installed, continues with 4.2.0" } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- installed 4.2.0; offer 4.2.1 answered y but ShouldProcess declines (-WhatIf) -> no "Installed" claim' -ForegroundColor DarkCyan
$r = $caseResults['offerWhatIf']
if ((Lines $r 'PROMPT').Count -eq 1 -and (Lines $r 'INSTALL').Count -eq 0) { Ok '-WhatIf -> offer prompted, Install-Module never called' } else { Bad "log: $($r.Log -join ' | ')" }
if ((Lines $r 'HOST: Installed PSAppDeployToolkit').Count -eq 0) { Ok 'no "Installed PSAppDeployToolkit" line for an install that did not run' } else { Bad "log: $($r.Log -join ' | ')" }
if ((RetIs $r 'True') -and (Lines $r 'IMPORT 4.2.0').Count -eq 1 -and (Lines $r 'IMPORT 4.2.1').Count -eq 0 -and (Lines $r 'NTT 4.2.0 ZeroConfig=True').Count -eq 1) { Ok 'continues with the installed 4.2.0 selection' } else { Bad "returns $($r.Returns -join ',') / log: $($r.Log -join ' | ')" }

Write-Host '  -- in-range installed + -Force -> the gallery is not queried' -ForegroundColor DarkCyan
$r = $caseResults['inRangeForce']
HasNo $r 'FIND' 'Find-Module call'
HasNo $r 'INSTALL' 'Install-Module call'
HasNo $r 'PROMPT' 'prompt'
if ((RetIs $r 'True') -and (Lines $r 'NTT 4.2.0 ZeroConfig=True PassThru=True').Count -eq 1) { Ok 'scaffolded with 4.2.0 -ZeroConfig -PassThru' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- a PSADT copy already loaded (same version), no -Force -> no gallery query, reuse' -ForegroundColor DarkCyan
$r = $caseResults['loadedSame']
HasNo $r 'FIND' 'Find-Module call'
HasNo $r 'INSTALL' 'Install-Module call'
if ((Lines $r 'HOST: PSAppDeployToolkit is loaded in this session - start a new PowerShell session to check for updates').Count -eq 1) { Ok 'the grey "loaded in this session - start a new PowerShell session" line is shown' } else { Bad "log: $($r.Log -join ' | ')" }
if ((RetIs $r 'True') -and (Lines $r 'IMPORT').Count -eq 0 -and (Lines $r 'NTT 4.2.0').Count -eq 1) { Ok 'the loaded copy is reused - no second import' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- only the rc2 installed -> PRERELEASE warning' -ForegroundColor DarkCyan
$r = $caseResults['rcOnly']
$w = Lines $r 'WARN: Using PSAppDeployToolkit 4.2.0-rc2 - a PRERELEASE'
if ($w.Count -eq 1 -and (RetIs $r 'True') -and (Lines $r 'NTT 4.2.0-rc2 ZeroConfig=True').Count -eq 1) { Ok "prerelease used with a warning: $($w[0])" } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- PSADT 4.1.8 -> New-ADTTemplate WITHOUT -ZeroConfig' -ForegroundColor DarkCyan
$r = $caseResults['v418']
if ((RetIs $r 'True') -and (Lines $r 'NTT 4.1.8 ZeroConfig=False PassThru=True').Count -eq 1) { Ok '4.1.8 scaffold: no -ZeroConfig, -PassThru' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- registry pin 4.1.8 with 4.2.0 installed -> 4.1.8, no update offer' -ForegroundColor DarkCyan
$r = $caseResults['regPin418']
HasNo $r 'FIND' 'gallery query for a pinned version'
if ((RetIs $r 'True') -and (Lines $r 'IMPORT 4.1.8').Count -eq 1 -and (Lines $r 'NTT 4.1.8 ZeroConfig=False').Count -eq 1) { Ok 'pinned 4.1.8 imported and scaffolded' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- pin that is not installed -> $false, nothing installed' -ForegroundColor DarkCyan
$r = $caseResults['pinMissing']
HasNo $r 'FIND' 'Find-Module call'
HasNo $r 'INSTALL' 'Install-Module call (never install for a pin)'
if ((RetIs $r 'False') -and (Lines $r "WARN: PreferredPsadtVersion '4.1.7'").Count -eq 1 -and (Lines $r 'NTT').Count -eq 0) { Ok 'PreferredNotFound -> warning + $false, no scaffold' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- only 4.3.0 installed -> NoneInRange: install 4.2.1 side by side' -ForegroundColor DarkCyan
$r = $caseResults['noneInRange']
$ins = Lines $r 'INSTALL'
if ($ins.Count -eq 1 -and $ins[0] -match 'RequiredVersion=4\.2\.1 ' -and (RetIs $r 'True') -and (Lines $r 'NTT 4.2.1').Count -eq 1) { Ok 'out-of-range install ignored; 4.2.1 installed and used' } else { Bad "log: $($r.Log -join ' | ')" }
if ((Lines $r 'HOST: PSAppDeployToolkit 4.3.0 is installed but not supported').Count -ge 1) { Ok 'the ignored 4.3.0 is named in a yellow line' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- post-scaffold verification: bundled module does not match the selection' -ForegroundColor DarkCyan
$r = $caseResults['bundleWrong']
if ((RetIs $r 'False') -and -not (Test-Path (Join-Path $r.Proj 'App1'))) { Ok 'mismatch -> $false and the project folder is removed' } else { Bad "returns $($r.Returns -join ',') / folder exists: $(Test-Path (Join-Path $r.Proj 'App1'))" }
if ((Lines $r 'WARN: The scaffolded PSADT project failed verification').Count -eq 1 -and ($r.Log -match 'bundled PSAppDeployToolkit is 4\.1\.8, expected 4\.2\.0')) { Ok 'the warning names the mismatch' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- post-scaffold verification: launcher missing' -ForegroundColor DarkCyan
$r = $caseResults['noLauncher']
if ((RetIs $r 'False') -and -not (Test-Path (Join-Path $r.Proj 'App1')) -and ($r.Log -match 'Invoke-AppDeployToolkit\.exe is missing')) { Ok 'no Invoke-AppDeployToolkit.exe -> $false, folder removed' } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- 4.2.0 without New-ADTTemplate -ZeroConfig + an existing project (-Force) -> refused BEFORE the overwrite' -ForegroundColor DarkCyan
$r = $caseResults['noZeroConfig']
if ((RetIs $r 'False') -and ($r.Log -match 'WARN: Failed to create PSADT project: PSAppDeployToolkit 4\.2 without New-ADTTemplate -ZeroConfig is not supported')) { Ok 'capability refusal -> $false with the reason' } else { Bad "returns $($r.Returns -join ',') / log: $($r.Log -join ' | ')" }
if ((Test-Path -LiteralPath (Join-Path $r.Proj 'App1\keep.txt')) -and (Lines $r 'HOST: Overwriting existing project directory').Count -eq 0 -and (Lines $r 'NTT').Count -eq 0) { Ok 'the existing project is untouched (checked before the overwrite), nothing scaffolded' } else { Bad "keep.txt exists: $(Test-Path -LiteralPath (Join-Path $r.Proj 'App1\keep.txt')) / log: $($r.Log -join ' | ')" }

Write-Host '  -- New-ADTTemplate throws after writing part of the project -> half-written folder removed' -ForegroundColor DarkCyan
$r = $caseResults['scaffoldThrow']
$w = Lines $r 'WARN: Failed to create PSADT project: Could not find a part of the path'
if ((RetIs $r 'False') -and (Lines $r 'NTT 4.2.0').Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $r.Proj 'App1'))) { Ok 'scaffold exception -> $false and the incomplete App1 folder is gone' } else { Bad "returns $($r.Returns -join ',') / App1 exists: $(Test-Path -LiteralPath (Join-Path $r.Proj 'App1')) / log: $($r.Log -join ' | ')" }
if ($w.Count -eq 1 -and $w[0] -match 'the incomplete project folder was removed: ') { Ok "the warning says the folder was removed: $($w[0])" } else { Bad "log: $($r.Log -join ' | ')" }

Write-Host '  -- a failure BEFORE the scaffold (Find-Module throws) never removes an existing project' -ForegroundColor DarkCyan
$r = $caseResults['findFailKeep']
$w = Lines $r 'WARN: Failed to create PSADT project: Unable to resolve package source PSGallery'
if ((RetIs $r 'False') -and $w.Count -eq 1 -and $w[0] -notmatch 'removed' -and (Test-Path -LiteralPath (Join-Path $r.Proj 'App1\keep.txt'))) { Ok 'gallery failure -> $false, the existing App1\keep.txt is untouched, nothing claimed removed' } else { Bad "returns $($r.Returns -join ',') / keep.txt exists: $(Test-Path -LiteralPath (Join-Path $r.Proj 'App1\keep.txt')) / log: $($r.Log -join ' | ')" }

Write-Host '  -- double scaffold in ONE process (versioned-folder layout, module scope)' -ForegroundColor DarkCyan
$r = $caseResults['double']
if (RetIs $r 'True,True') { Ok 'both scaffolds return $true' } else { Bad "returns $($r.Returns -join ',') / log: $($r.Log -join ' | ')" }
if ((Lines $r 'IMPORT').Count -eq 1 -and (Lines $r 'NTT 4.2.0').Count -eq 2) { Ok 'PSADT imported ONCE, New-ADTTemplate ran twice' } else { Bad "log: $($r.Log -join ' | ')" }
if ($r.LoadedAll -eq 1) { Ok 'Get-Module -All sees the module-scope import (exactly one copy loaded)' } else { Bad "Get-Module -All count = $($r.LoadedAll)" }
Write-Host "  INFO: a plain global Get-Module sees $($r.GlobalPlain) copy/copies of the module-scope import (why the guard uses -All)" -ForegroundColor DarkGray

Write-Host '  -- a DIFFERENT version already loaded -> $false + new-session warning, no import' -ForegroundColor DarkCyan
$r = $caseResults['loadedOther']
$w = Lines $r 'WARN: PSAppDeployToolkit 4.1.8 is already loaded'
if ((RetIs $r 'False') -and $w.Count -eq 1 -and $w[0] -match 'needs 4\.2\.0' -and $w[0] -match 'new PowerShell session') { Ok "refused: $($w[0])" } else { Bad "log: $($r.Log -join ' | ')" }
if ((Lines $r 'IMPORT').Count -eq 0 -and (Lines $r 'NTT').Count -eq 0) { Ok 'no import and no scaffold' } else { Bad "log: $($r.Log -join ' | ')" }
HasNo $r 'START-PROCESS' 'process launch'

# -- static acceptance checks (spec 3.1) -----------------------------------------------------------
Write-Host "`n[5] Create-PSADTProject source: bounded installs only, guarded import by path" -ForegroundColor Cyan
$srcLines = @(Get-Content -LiteralPath (Join-Path $repo 'Private\Create-PSADTProject.ps1'))
$upd = @($srcLines | Where-Object { $_ -match 'Update-Module' })
if ($upd.Count -eq 0) { Ok 'no line mentions Update-Module' } else { Bad "Update-Module lines: $($upd -join ' | ')" }
$inst = @($srcLines | Where-Object { $_ -match 'Install-Module' })
if ($inst.Count -ge 2 -and @($inst | Where-Object { $_ -notmatch '-RequiredVersion' }).Count -eq 0) { Ok "every Install-Module line carries -RequiredVersion ($($inst.Count) lines)" } else { Bad "Install-Module lines: $($inst -join ' | ')" }
$imp = @($srcLines | Where-Object { $_ -match '^\s*[^#]*\bImport-Module\b' })
if ($imp.Count -eq 1 -and $imp[0] -match 'Import-Module -Name \$sel\.Module\.Path' -and ($imp[0] -replace '#.*$', '') -notmatch '-Force') { Ok 'the only Import-Module is by the selected PATH, without -Force' } else { Bad "Import-Module lines: $($imp -join ' | ')" }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
$env:PSModulePath = $savedModulePath
if ($savedPin) { $env:W32T_PSADT_VERSION = $savedPin }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PsadtVersionPolicy tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PsadtVersionPolicy test(s) FAILED." -ForegroundColor Red; exit 1 }
