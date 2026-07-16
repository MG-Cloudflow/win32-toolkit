<#
    .msixbundle / .appxbundle are SUPPORTED (replaces P1_BundleFailFast).

    HISTORY: bundles used to fail fast, because identity extraction could only read a plain package's
    root AppxManifest.xml. That guard was both incomplete and unnecessary:

      * INCOMPLETE — it keyed off the EXTENSION, and the extension lies. `winget` names a download
        after the manifest's InstallerType, not the URL: Microsoft.PowerShell declares
        InstallerType: msix while serving PowerShell-<v>.msixbundle, so a bundle sails through called
        '.msix'. The real project C:\Win32Apps\...\PowerShell_x64_7.6.3.0 hit exactly this — the guard
        never fired, identity returned $null, NO Uninstall section was written, and the deployed app's
        uninstall silently did nothing.
      * UNNECESSARY — a bundle installs and uninstalls exactly like a plain package
        (Add-AppxProvisionedPackage takes a bundle path; removal is by the same Name), and its
        AppxBundleManifest.xml carries the same Identity.

    So bundles are now ordinary Appx-family members: accepted at intake, reported as Type
    'msix'/'appx' (install semantics), with bundle-ness content-detected only where it matters —
    Get-Win32ToolkitMsixIdentity.

    winget is shadowed; nothing hits the network.
    Run:  pwsh -File Tests\BundleSupport.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')
. (Join-Path $repo 'Private\Download-WingetApp.ps1')
. (Join-Path $repo 'Private\Get-InstallerFileInfo.ps1')

# winget shadow: "succeeds" (exit 0) and writes whatever $script:wingetDrops says into the download dir.
$script:wingetExit  = 0
$script:wingetDrops = @()
function winget {
    $dir = $null
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq '--download-directory') { $dir = $args[$i + 1] }
    }
    if ($dir) { foreach ($f in $script:wingetDrops) { Set-Content -LiteralPath (Join-Path $dir $f) -Value 'stub' } }
    $global:LASTEXITCODE = $script:wingetExit
}

$base = Join-Path ([System.IO.Path]::GetTempPath()) ('w32bundle_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
function New-Dir { $p = Join-Path $base ([guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }
New-Item -ItemType Directory -Path $base -Force | Out-Null

try {
    Write-Host '[1] Download-WingetApp ACCEPTS a bundle-only download' -ForegroundColor Cyan
    foreach ($name in 'Foo.msixbundle', 'Foo.appxbundle') {
        $d = New-Dir
        $script:wingetExit  = 0
        $script:wingetDrops = @($name)
        $err = $null
        $r = Download-WingetApp -AppId 'Foo.Bar' -AppName 'Foo' -DownloadPath $d -Architecture 'x64' `
                -ErrorAction SilentlyContinue -ErrorVariable err 6>$null
        if ($r -eq $true -and -not $err) { Ok "'$name' -> `$true, no error (bundles are installers)" }
        else { Bad "'$name' rejected: returned '$r', err=[$(($err | ForEach-Object { $_.ToString() }) -join ' ')]" }
    }

    Write-Host '[2] NO REGRESSION: plain .msix / .appx / .exe / .msi still accepted' -ForegroundColor Cyan
    foreach ($name in 'App.msix', 'App.appx', 'App.exe', 'App.msi') {
        $d = New-Dir
        $script:wingetDrops = @($name)
        $ok = Download-WingetApp -AppId 'Some.App' -DownloadPath $d -ErrorAction SilentlyContinue 6>$null
        if ($ok -eq $true) { Ok "'$name' still accepted" } else { Bad "'$name' regressed: returned '$ok'" }
    }

    Write-Host '[3] A download with NOTHING installable still fails (the real fail-fast survives)' -ForegroundColor Cyan
    $dz = New-Dir
    $script:wingetDrops = @('Foo.yaml', 'readme.txt')
    $errZ = $null
    $rz = Download-WingetApp -AppId 'Zip.App' -DownloadPath $dz -ErrorAction SilentlyContinue -ErrorVariable errZ 6>$null
    if ($rz -eq $false -and $errZ) { Ok 'zip/portable/store package (no installer) -> $false + error' }
    else { Bad "no-installer download wrongly succeeded (returned '$rz')" }

    Write-Host '[4] Get-InstallerFileInfo: a bundle IS the installer, typed by family' -ForegroundColor Cyan
    foreach ($case in @(
        @{ File = 'Foo.msixbundle'; Type = 'msix' }
        @{ File = 'Foo.appxbundle'; Type = 'appx' }
    )) {
        $f = New-Dir
        Set-Content -LiteralPath (Join-Path $f $case.File) 'stub'
        $errG = $null
        $fi = Get-InstallerFileInfo -FilesPath $f -ErrorAction SilentlyContinue -ErrorVariable errG 3>$null
        if ($fi.FileName -eq $case.File -and $fi.Type -eq $case.Type -and -not $errG) {
            Ok "'$($case.File)' -> installer, Type '$($case.Type)' (install semantics, not extension)"
        } else { Bad "'$($case.File)': file=$($fi.FileName) type=$($fi.Type) err=[$(($errG | ForEach-Object { $_.ToString() }) -join ' ')]" }
    }

    Write-Host '[5] An EMPTY Files\ folder still returns quietly' -ForegroundColor Cyan
    $f2 = New-Dir
    $errE = $null
    $fiE = Get-InstallerFileInfo -FilesPath $f2 -ErrorAction SilentlyContinue -ErrorVariable errE
    if (-not $fiE.FileName -and -not $errE) { Ok 'empty folder -> no installer, no error' }
    else { Bad "empty folder: file=$($fiE.FileName) err=[$(($errE | ForEach-Object { $_.ToString() }) -join ' ')]" }

    Write-Host '[6] Precedence unchanged: .msi > .exe > package' -ForegroundColor Cyan
    $f4 = New-Dir
    Set-Content -LiteralPath (Join-Path $f4 'App.msixbundle') 'stub'
    Set-Content -LiteralPath (Join-Path $f4 'App.msi') 'stub'
    $fi4 = Get-InstallerFileInfo -FilesPath $f4 -ErrorAction SilentlyContinue 3>$null
    if ($fi4.Type -eq 'msi') { Ok '.msi still outranks a bundle' } else { Bad "precedence broke: type=$($fi4.Type)" }

    Write-Host '[7] G13: multiple packages in Files\ WARN and name every candidate' -ForegroundColor Cyan
    # winget downloads framework dependencies (VCLibs/WinUI) next to the app — a dependency sorting
    # first must never silently become "the installer" without the operator being told.
    $f5 = New-Dir
    Set-Content -LiteralPath (Join-Path $f5 'Microsoft.VCLibs.140.00.appx') 'stub'
    Set-Content -LiteralPath (Join-Path $f5 'RealApp.appx') 'stub'
    $wv = $null
    $fi5 = Get-InstallerFileInfo -FilesPath $f5 -WarningVariable wv -WarningAction SilentlyContinue
    $wmsg = ($wv | ForEach-Object { $_.ToString() }) -join ' '
    if ($wmsg -match 'VCLibs' -and $wmsg -match 'RealApp') { Ok 'warning names BOTH candidate packages' }
    else { Bad "no multi-package warning naming both: [$wmsg]" }
    if ($wmsg -match '(?i)dependenc') { Ok 'warning explains the framework-dependency trap' } else { Bad "warning lacks the dependency hint: [$wmsg]" }
    if ($fi5.FileName -eq 'Microsoft.VCLibs.140.00.appx') { Ok 'still deterministic (first by name) — but now loudly' }
    else { Bad "unexpected pick: $($fi5.FileName)" }
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All BundleSupport tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail BundleSupport test(s) FAILED." -ForegroundColor Red; exit 1 }
