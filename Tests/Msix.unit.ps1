<#
    Unit tests for MSIX/APPX support (no PSADT / no sandbox needed):
    - Get-Win32ToolkitMsixIdentity: reads Identity from a real (synthetic) .msix zip, hostile values
      returned as data; $null + warning for zip-without-manifest and non-zip input.
    - Update-PSADTMsixUninstallLogic: writes the identity-driven AppConfig.Uninstall section.

    Run:  pwsh -File Tests\Msix.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitMsixIdentity.ps1')
. (Join-Path $repo 'Private\Update-PSADTMsixUninstallLogic.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')  # installer-extension source of truth (bundle support)
. (Join-Path $repo 'Private\Get-InstallerFileInfo.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitAppConfig.ps1')

$base = Join-Path ([System.IO.Path]::GetTempPath()) ("w32msix_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
    # Synthetic .msix: a zip with a root AppxManifest.xml. Publisher is hostile (apostrophe + XML-escaped
    # double quotes); the RETURNED value must contain the literal characters.
    $mfDir = Join-Path $base 'mf'
    New-Item -ItemType Directory -Path $mfDir -Force | Out-Null
    @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="Evil.App" Publisher="CN=O'Evil, O=&quot;Q&quot;" Version="1.2.3.0" />
</Package>
'@ | Set-Content -Path (Join-Path $mfDir 'AppxManifest.xml') -Encoding UTF8
    $fakeMsix = Join-Path $base 'EvilApp.msix'
    Compress-Archive -Path (Join-Path $mfDir 'AppxManifest.xml') -DestinationPath "$fakeMsix.zip" -Force
    Move-Item "$fakeMsix.zip" $fakeMsix -Force

    Write-Host "[1] Get-Win32ToolkitMsixIdentity" -ForegroundColor Cyan
    $id = Get-Win32ToolkitMsixIdentity -Path $fakeMsix
    if ($id -and $id.PackageName -eq 'Evil.App') { Ok 'PackageName read from Identity' } else { Bad "PackageName: [$($id.PackageName)]" }
    if ($id.Publisher -eq 'CN=O''Evil, O="Q"') { Ok 'hostile Publisher returned as literal data (quote + apostrophe)' } else { Bad "Publisher: [$($id.Publisher)]" }
    if ($id.Version -eq '1.2.3.0') { Ok 'Version read' } else { Bad "Version: [$($id.Version)]" }

    # Zip without a manifest -> $null + warning
    $emptyZipDir = Join-Path $base 'ez'; New-Item -ItemType Directory -Path $emptyZipDir -Force | Out-Null
    Set-Content (Join-Path $emptyZipDir 'readme.txt') 'x'
    $noMf = Join-Path $base 'nomanifest.msix'
    Compress-Archive -Path (Join-Path $emptyZipDir 'readme.txt') -DestinationPath "$noMf.zip" -Force
    Move-Item "$noMf.zip" $noMf -Force
    $r = Get-Win32ToolkitMsixIdentity -Path $noMf -WarningVariable wNoMf -WarningAction SilentlyContinue
    if ($null -eq $r -and $wNoMf) { Ok 'zip without AppxManifest.xml -> $null + warning' } else { Bad 'no-manifest case wrong' }

    # Non-zip file -> $null + warning
    $notZip = Join-Path $base 'broken.msix'
    Set-Content $notZip 'this is not a zip'
    $r2 = Get-Win32ToolkitMsixIdentity -Path $notZip -WarningVariable wNz -WarningAction SilentlyContinue
    if ($null -eq $r2 -and $wNz) { Ok 'non-zip file -> $null + warning' } else { Bad 'non-zip case wrong' }

    # Identity WITHOUT a Name attribute -> $null (NOT PackageName='Identity' via the XmlNode.Name
    # base-property fallback — that produced a silent false uninstall success downstream)
    $nnDir = Join-Path $base 'nn'; New-Item -ItemType Directory -Path $nnDir -Force | Out-Null
    '<?xml version="1.0"?><Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Publisher="CN=X" Version="1.0.0.0" /></Package>' |
        Set-Content -Path (Join-Path $nnDir 'AppxManifest.xml') -Encoding UTF8
    $noName = Join-Path $base 'noname.msix'
    Compress-Archive -Path (Join-Path $nnDir 'AppxManifest.xml') -DestinationPath "$noName.zip" -Force
    Move-Item "$noName.zip" $noName -Force
    $r4 = Get-Win32ToolkitMsixIdentity -Path $noName -WarningVariable wNn -WarningAction SilentlyContinue
    if ($null -eq $r4 -and (@($wNn) -match 'no Identity Name')) { Ok 'nameless Identity -> $null + warning (no XmlNode.Name fallback)' } else { Bad "nameless: [$($r4 | ConvertTo-Json -Compress)]" }

    # ── BUNDLES ──────────────────────────────────────────────────────────────────────────────────
    # A bundle carries AppxMetadata/AppxBundleManifest.xml (root element <Bundle>, different XML
    # namespace) instead of a root AppxManifest.xml, and NESTED per-architecture .msix payloads.
    # Regression for the real failure: C:\Win32Apps\...\PowerShell_x64_7.6.3.0 — winget names
    # Microsoft's .msixbundle '.msix' (its manifest says InstallerType: msix), identity returned $null,
    # so NO Uninstall section was written and the deployed app's uninstall silently did nothing.
    function New-FakeBundle {
        param([string]$Path, [string]$Name = 'Contoso.App', [string]$Version = '2026.610.237.0')
        $d = Join-Path $base ('bundle_' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path (Join-Path $d 'AppxMetadata') -Force | Out-Null
        # Deliberately a DIFFERENT namespace from the package manifest — selection must not hard-code one.
        @"
<?xml version="1.0" encoding="utf-8"?>
<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle">
  <Identity Name="$Name" Publisher="CN=Contoso" Version="$Version" />
  <Packages>
    <Package Type="application" Version="7.6.3.0" Architecture="x64" FileName="App-x64.msix" />
    <Package Type="application" Version="7.6.3.0" Architecture="arm64" FileName="App-arm64.msix" />
  </Packages>
</Bundle>
"@ | Set-Content -Path (Join-Path $d 'AppxMetadata\AppxBundleManifest.xml') -Encoding UTF8
        # A nested payload whose own manifest must NEVER be mistaken for the root one.
        '<?xml version="1.0"?><Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="WRONG.Nested" Publisher="CN=X" Version="9.9.9.9" /></Package>' |
            Set-Content -Path (Join-Path $d 'AppxManifest-nested-decoy.xml') -Encoding UTF8
        Compress-Archive -Path (Join-Path $d '*') -DestinationPath "$Path.zip" -Force
        Move-Item "$Path.zip" $Path -Force
    }

    Write-Host "[1b] Bundles: identity read from AppxBundleManifest.xml" -ForegroundColor Cyan
    $bundle = Join-Path $base 'App.msixbundle'
    New-FakeBundle -Path $bundle
    $bid = Get-Win32ToolkitMsixIdentity -Path $bundle -WarningVariable wB -WarningAction SilentlyContinue
    if ($bid -and $bid.PackageName -eq 'Contoso.App') { Ok 'bundle PackageName read from AppxBundleManifest.xml' } else { Bad "bundle PackageName: [$($bid.PackageName)] warn=[$($wB -join ';')]" }
    if ($bid -and $bid.IsBundle) { Ok 'IsBundle = $true' } else { Bad "IsBundle: [$($bid.IsBundle)]" }
    if ($bid -and $bid.Version -eq '2026.610.237.0') { Ok 'bundle Version read (the BUNDLE version, not the app version)' } else { Bad "bundle Version: [$($bid.Version)]" }
    if ($bid -and $bid.PackageName -ne 'WRONG.Nested') { Ok 'a nested/decoy package manifest is never used as the identity' } else { Bad 'nested manifest leaked into identity' }
    if (-not $wB) { Ok 'no warning for a valid bundle' } else { Bad "unexpected warning: [$($wB -join ';')]" }

    # THE REAL BUG: a bundle whose EXTENSION says .msix (winget names by manifest InstallerType).
    Write-Host "[1c] A bundle wearing a .msix extension is still detected by CONTENT" -ForegroundColor Cyan
    $liar = Join-Path $base 'PowerShell_x64_7.6.3.0.msix'
    New-FakeBundle -Path $liar -Name 'Microsoft.PowerShell'
    $lid = Get-Win32ToolkitMsixIdentity -Path $liar -WarningVariable wL -WarningAction SilentlyContinue
    if ($lid -and $lid.PackageName -eq 'Microsoft.PowerShell' -and $lid.IsBundle) {
        Ok 'bundle-as-.msix -> identity found (was: $null -> no Uninstall section -> silent no-op uninstall)'
    } else { Bad "bundle-as-.msix: [$($lid | ConvertTo-Json -Compress)] warn=[$($wL -join ';')]" }

    Write-Host "[1d] Update-PSADTMsixUninstallLogic writes the Uninstall section for a BUNDLE" -ForegroundColor Cyan
    $bp = Join-Path $base 'bundleproj'
    New-Item -ItemType Directory -Path (Join-Path $bp 'Files') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $bp 'SupportFiles') -Force | Out-Null
    Copy-Item $liar (Join-Path $bp 'Files\PowerShell_x64_7.6.3.0.msix')
    $okB = Update-PSADTMsixUninstallLogic -ProjectPath $bp 6>$null
    $cfgB = Get-Win32ToolkitAppConfig -ProjectPath $bp
    if ($okB -and $cfgB.Uninstall.Uninstallers[0].PackageName -eq 'Microsoft.PowerShell' -and $cfgB.Uninstall.Uninstallers[0].Type -eq 'msix') {
        Ok 'bundle project gets an identity-driven Uninstall section (the reported bug is fixed)'
    } else { Bad "bundle uninstall section: ok=$okB cfg=[$($cfgB.Uninstall | ConvertTo-Json -Compress -Depth 5)]" }

    # EXE + MSIX side by side -> EXE wins but the shadowed package is named in a warning
    $shDir = Join-Path $base 'shadow\Files'; New-Item -ItemType Directory -Path $shDir -Force | Out-Null
    Copy-Item $fakeMsix (Join-Path $shDir 'App.msix')
    Set-Content (Join-Path $shDir 'helper.exe') 'stub'
    $fi = Get-InstallerFileInfo -FilesPath $shDir -WarningVariable wSh -WarningAction SilentlyContinue
    if ($fi.Type -eq 'exe' -and (@($wSh) -match 'App\.msix')) { Ok 'stray EXE shadows msix -> warning names the ignored package' } else { Bad "shadow: type=$($fi.Type) warn=[$($wSh -join ';')]" }

    Write-Host "`n[2] Update-PSADTMsixUninstallLogic" -ForegroundColor Cyan
    $proj = Join-Path $base 'proj'
    New-Item -ItemType Directory -Path (Join-Path $proj 'Files') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles') -Force | Out-Null
    Copy-Item $fakeMsix (Join-Path $proj 'Files\EvilApp.msix')
    [System.IO.File]::WriteAllText((Join-Path $proj 'SupportFiles\AppConfig.json'),
        '{"SchemaVersion":"1.0","App":{"Name":"","DisplayName":"Evil App","Version":"1.2.3"}}',
        (New-Object System.Text.UTF8Encoding($false)))

    if (Update-PSADTMsixUninstallLogic -ProjectPath $proj) { Ok 'returns $true' } else { Bad 'returned $false' }
    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $proj
    $u = @($cfg.Uninstall.Uninstallers)[0]
    if ($u.Type -eq 'msix' -and $u.PackageName -eq 'Evil.App' -and $null -eq $u.ProductCode) { Ok "Uninstall.Uninstallers[0]: Type=msix, PackageName=Evil.App" } else { Bad "uninstaller: $($u | ConvertTo-Json -Compress)" }
    if ($cfg.Uninstall.AppName -eq 'Evil.App') { Ok 'Uninstall.AppName = identity name' } else { Bad "AppName: $($cfg.Uninstall.AppName)" }
    if ($u.Publisher -match '"Q"') { Ok 'hostile publisher stored as JSON data' } else { Bad 'publisher lost' }

    # Idempotent re-run (belt-and-braces call from Wait-ForDocumentationAndProcess)
    if ((Update-PSADTMsixUninstallLogic -ProjectPath $proj) -and (@((Get-Win32ToolkitAppConfig -ProjectPath $proj).Uninstall.Uninstallers).Count -eq 1)) { Ok 'idempotent re-run (single uninstaller entry)' } else { Bad 're-run not idempotent' }

    # Project without an msix -> $false + warning
    $proj2 = Join-Path $base 'proj2'
    New-Item -ItemType Directory -Path (Join-Path $proj2 'Files') -Force | Out-Null
    $r3 = Update-PSADTMsixUninstallLogic -ProjectPath $proj2 -WarningVariable wNo -WarningAction SilentlyContinue
    if (-not $r3 -and $wNo) { Ok 'no msix in Files -> $false + warning' } else { Bad 'missing-msix case wrong' }
}
finally { Remove-Item -Path $base -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'MSIX unit tests PASSED' -ForegroundColor Green }
else             { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 }
