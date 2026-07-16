<#
    MSIX ProcessesToClose — read from the package manifest at configure time.

    THE BUG: Update-PSADTProcessesToClose derives processes from three CLASSIC WIN32 sources only —
    App Paths registry keys, the Uninstall key's DisplayIcon, and EXEs under InstallLocation. An MSIX
    writes NONE of them (registry-virtualized; payload lands in %ProgramFiles%\WindowsApps\<PFN>\), so
    every MSIX silently got ProcessesToClose = @() and the deployment never offered to close the
    running app. Real case: PowerShell_x64_7.6.3.0 — the package declares
    <Application Executable="pwsh.exe" /> but the config shipped an empty list.

    Same structural lesson as the uninstall identity: read it from the manifest at CONFIGURE time.

    Run:  pwsh -File Tests\MsixProcessesToClose.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('w32p2c_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $base -Force | Out-Null

# A plain .msix declaring two apps (one of them noise that must be filtered).
function New-PlainMsix {
    param([string]$Path, [string[]]$Executables = @('pwsh.exe'))
    $d = Join-Path $base ('p_' + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $apps = ($Executables | ForEach-Object { "    <Application Id=`"A$([guid]::NewGuid().ToString('N').Substring(0,4))`" Executable=`"$_`" EntryPoint=`"Windows.FullTrustApplication`" />" }) -join "`n"
    @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="Contoso.App" Publisher="CN=Contoso" Version="1.0.0.0" />
  <Applications>
$apps
  </Applications>
</Package>
"@ | Set-Content -Path (Join-Path $d 'AppxManifest.xml') -Encoding UTF8
    Compress-Archive -Path (Join-Path $d 'AppxManifest.xml') -DestinationPath "$Path.zip" -Force
    Move-Item "$Path.zip" $Path -Force
}

# A bundle: NO <Applications> in the bundle manifest — they live in the nested packages.
function New-BundleWithApps {
    param([string]$Path, [string]$Executable = 'pwsh.exe')
    $nested = Join-Path $base ('n_' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.msix')
    New-PlainMsix -Path $nested -Executables @($Executable)
    $d = Join-Path $base ('b_' + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path (Join-Path $d 'AppxMetadata') -Force | Out-Null
    @"
<?xml version="1.0" encoding="utf-8"?>
<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle">
  <Identity Name="Contoso.App" Publisher="CN=Contoso" Version="2026.1.1.0" />
  <Packages>
    <Package Type="resource" FileName="res-en.msix" />
    <Package Type="application" Architecture="x64" FileName="app-x64.msix" />
  </Packages>
</Bundle>
"@ | Set-Content -Path (Join-Path $d 'AppxMetadata\AppxBundleManifest.xml') -Encoding UTF8
    Copy-Item $nested (Join-Path $d 'app-x64.msix')
    Set-Content -LiteralPath (Join-Path $d 'res-en.msix') -Value 'not-a-package' -Encoding ASCII
    Compress-Archive -Path (Join-Path $d '*') -DestinationPath "$Path.zip" -Force
    Move-Item "$Path.zip" $Path -Force
}

function New-Proj { param([string]$PkgPath, [string]$PkgName)
    $p = Join-Path $base ('proj_' + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path (Join-Path $p 'Files') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force | Out-Null
    Copy-Item $PkgPath (Join-Path $p "Files\$PkgName")
    return $p
}

try {
    Write-Host '[1] Get-Win32ToolkitMsixApplication: plain .msix' -ForegroundColor Cyan
    $m1 = Join-Path $base 'plain.msix'; New-PlainMsix -Path $m1
    $a1 = @(Get-Win32ToolkitMsixApplication -Path $m1)
    if ($a1.Count -eq 1 -and $a1[0] -eq 'pwsh') { Ok "plain package -> 'pwsh' (extension stripped)" } else { Bad "got [$($a1 -join ',')]" }

    Write-Host '[2] Bundle: apps come from the NESTED package (bundle manifest has none)' -ForegroundColor Cyan
    $b1 = Join-Path $base 'app.msixbundle'; New-BundleWithApps -Path $b1
    $a2 = @(Get-Win32ToolkitMsixApplication -Path $b1)
    if ($a2.Count -eq 1 -and $a2[0] -eq 'pwsh') { Ok "bundle -> 'pwsh' (dived into the nested application package)" } else { Bad "got [$($a2 -join ',')]" }

    Write-Host '[3] An Executable with a path keeps only the leaf name' -ForegroundColor Cyan
    $m3 = Join-Path $base 'pathed.msix'; New-PlainMsix -Path $m3 -Executables @('bin\tools\myapp.exe')
    $a3 = @(Get-Win32ToolkitMsixApplication -Path $m3)
    if ($a3.Count -eq 1 -and $a3[0] -eq 'myapp') { Ok "'bin\tools\myapp.exe' -> 'myapp'" } else { Bad "got [$($a3 -join ',')]" }

    Write-Host '[4] Update-PSADTMsixProcessesToClose writes the config + filters noise' -ForegroundColor Cyan
    $m4 = Join-Path $base 'multi.msix'; New-PlainMsix -Path $m4 -Executables @('pwsh.exe', 'setup.exe', 'MyApp.exe')
    $p4 = New-Proj -PkgPath $m4 -PkgName 'multi.msix'
    $r4 = Update-PSADTMsixProcessesToClose -ProjectPath $p4 6>$null
    $c4 = Get-Win32ToolkitAppConfig -ProjectPath $p4
    $got = @($c4.ProcessesToClose)
    if ($r4 -and $got -contains 'pwsh' -and $got -contains 'MyApp') { Ok "real apps recorded ($($got -join ', '))" } else { Bad "got [$($got -join ',')]" }
    if ($got -notcontains 'setup') { Ok "installer noise ('setup') filtered out" } else { Bad 'setup.exe leaked into ProcessesToClose' }

    Write-Host '[5] THE REGRESSION: the capture pass must not clobber the manifest-derived list' -ForegroundColor Cyan
    # An MSIX capture finds no App Paths / Uninstall / InstallLocation artifacts, so the capture pass
    # yields nothing. It used to overwrite unconditionally -> the known-good 'pwsh' shipped as @().
    $emptyCapture = Join-Path $base 'cap_empty.json'
    (@{ NewRegistryKeys = @(); NewFiles = @() } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $emptyCapture -Encoding UTF8
    $r5 = Update-PSADTProcessesToClose -ProjectPath $p4 -JsonFilePath $emptyCapture 6>$null 3>$null
    $c5 = Get-Win32ToolkitAppConfig -ProjectPath $p4
    $got5 = @($c5.ProcessesToClose)
    if ($got5 -contains 'pwsh' -and $got5 -contains 'MyApp') { Ok 'manifest-derived processes SURVIVE an empty capture' }
    else { Bad "capture clobbered the list: [$($got5 -join ',')]" }

    Write-Host '[6] The capture still ADDS anything it genuinely finds (union, not replace)' -ForegroundColor Cyan
    $capture = Join-Path $base 'cap.json'
    (@{ NewRegistryKeys = @(
            @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\helper.exe'; KeyName = 'helper.exe'; Values = @{} }
        ); NewFiles = @() } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $capture -Encoding UTF8
    $null = Update-PSADTProcessesToClose -ProjectPath $p4 -JsonFilePath $capture 6>$null 3>$null
    $got6 = @((Get-Win32ToolkitAppConfig -ProjectPath $p4).ProcessesToClose)
    if ($got6 -contains 'pwsh' -and $got6 -contains 'helper') { Ok "captured 'helper' added alongside the manifest apps" } else { Bad "union failed: [$($got6 -join ',')]" }

    Write-Host '[7] A non-MSIX project is untouched by the MSIX writer' -ForegroundColor Cyan
    $pe = Join-Path $base ('exe_' + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path (Join-Path $pe 'Files') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $pe 'SupportFiles') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pe 'Files\App.exe') -Value 'stub'
    $r7 = Update-PSADTMsixProcessesToClose -ProjectPath $pe 6>$null 3>$null
    if ($r7 -eq $false) { Ok 'exe project -> $false (no-op)' } else { Bad "exe project returned '$r7'" }
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All MsixProcessesToClose tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail MsixProcessesToClose test(s) FAILED." -ForegroundColor Red; exit 1 }
