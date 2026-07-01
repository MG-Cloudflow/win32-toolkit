<#
    Self-contained smoke test for the data-driven AppConfig helpers
    (Get-Win32ToolkitAppConfig / Set-Win32ToolkitAppConfig).

    No test framework required — run directly:
        pwsh -File Tests\AppConfig.smoke.ps1
    Exits non-zero on any failure. See knowledge-base/designs/data-driven-generation.md.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Assert-True($cond, $msg) {
    if ($cond) { Write-Host "  PASS: $msg" -ForegroundColor Green }
    else       { Write-Host "  FAIL: $msg" -ForegroundColor Red; $script:fail++ }
}

. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitAppConfig.ps1')

$proj = Join-Path ([System.IO.Path]::GetTempPath()) ("w32kb_" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $proj -Force | Out-Null
try {
    # seed when absent
    $c = Get-Win32ToolkitAppConfig -ProjectPath $proj
    Assert-True ($c.SchemaVersion -eq '1.0') 'Get returns seed object when AppConfig.json is absent'

    # write hostile values, confirm they round-trip as inert DATA
    $c | Add-Member App ([pscustomobject]@{ Vendor="O'Reilly"; Name='App $(calc)'; Version='1.2.3'; Arch='x64' }) -Force
    $c | Add-Member Installer ([pscustomobject]@{ Type='exe'; FileName='x.exe'; SilentArgs="/S'; iex 'bad'; #" }) -Force
    $path = Set-Win32ToolkitAppConfig -ProjectPath $proj -Config $c

    Assert-True (Test-Path $path) 'Set writes SupportFiles\AppConfig.json'
    Assert-True (([System.IO.File]::ReadAllBytes($path))[0] -ne 0xEF) 'JSON is written without a UTF-8 BOM'

    $r = Get-Win32ToolkitAppConfig -ProjectPath $proj
    Assert-True ($r.App.Vendor -eq "O'Reilly")                     "apostrophe value round-trips (O'Reilly)"
    Assert-True ($r.App.Name -eq 'App $(calc)')                    'subexpression text round-trips as a literal'
    Assert-True ($r.Installer.SilentArgs -eq "/S'; iex 'bad'; #")  'injection payload is stored/read as inert data'

    # read-modify-write preserves other sections
    $c2 = Get-Win32ToolkitAppConfig -ProjectPath $proj
    $c2 | Add-Member Uninstall ([pscustomobject]@{
        ProductCodes = @('{0F1B2C3D-4E5F-6789-ABCD-0123456789AB}')
        Uninstallers = @()
        CleanupPaths = @("C:\Program Files\x' ; rm")
    }) -Force
    Set-Win32ToolkitAppConfig -ProjectPath $proj -Config $c2 | Out-Null
    $r2 = Get-Win32ToolkitAppConfig -ProjectPath $proj
    Assert-True ($r2.Installer.SilentArgs -eq "/S'; iex 'bad'; #") 'earlier Installer section survives a later write'
    Assert-True ($r2.Uninstall.ProductCodes.Count -eq 1)          'newly added Uninstall section is present'
    Assert-True ($r2.Uninstall.CleanupPaths[0] -eq "C:\Program Files\x' ; rm") 'cleanup path with quote round-trips'
}
finally {
    Remove-Item -Path $proj -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'AppConfig smoke test PASSED' -ForegroundColor Green }
else             { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 }
