<#
    P1 — .msixbundle / .appxbundle must FAIL FAST.

    THE BUG: Download-WingetApp counted '.msixbundle'/'.appxbundle' as "an installer landed" and returned
    $true. But Get-InstallerFileInfo only ever probes *.msi, *.exe, *.msix, *.appx — it never matches a
    bundle. Net effect: the download reported SUCCESS, the pipeline scaffolded a whole project around the
    bundle, and the run died much later with a misleading "No installer (msi/exe/msix/appx) detected".

    Bundles are deliberately NOT supported (no AppxBundleManifest parsing, no detector changes) — the fix is
    to fail immediately, naming the file, so the operator learns the real reason.

    winget is shadowed; nothing hits the network.

    Run:  pwsh -File Tests\P1_BundleFailFast.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

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
    # ── 1 ────────────────────────────────────────────────────────────────────────────────────────────
    Write-Host '[1] Download-WingetApp: winget exits 0 having written ONLY a .msixbundle' -ForegroundColor Cyan

    $d1 = New-Dir
    $script:wingetExit  = 0
    $script:wingetDrops = @('Foo.msixbundle')
    $err = $null
    $r = Download-WingetApp -AppId 'Foo.Bar' -AppName 'Foo' -DownloadPath $d1 -Architecture 'x64' `
            -ErrorAction SilentlyContinue -ErrorVariable err 6>$null

    if ($r -eq $false) { Ok 'bundle-only download -> $false (was: silently $true, project scaffolded, dies later)' }
    else               { Bad "bundle-only download still reported as success (returned '$r')" }

    $msg = ($err | ForEach-Object { $_.ToString() }) -join ' '
    if ($msg -match 'Foo\.msixbundle')      { Ok 'the error NAMES the offending file' }         else { Bad "error does not name the file: [$msg]" }
    if ($msg -match '(?i)not\s+supported')  { Ok 'the error says bundles are NOT SUPPORTED' }   else { Bad "error does not say unsupported: [$msg]" }
    if ($msg -match '(?i)TODO|tracked')     { Ok 'the error says it is tracked' }               else { Bad "error does not mention tracking: [$msg]" }

    # ── 2 ────────────────────────────────────────────────────────────────────────────────────────────
    Write-Host '[2] …same for .appxbundle' -ForegroundColor Cyan
    $d2 = New-Dir
    $script:wingetDrops = @('Foo.appxbundle')
    $err2 = $null
    $r2 = Download-WingetApp -AppId 'Foo.Bar' -DownloadPath $d2 -ErrorAction SilentlyContinue -ErrorVariable err2 6>$null
    $msg2 = ($err2 | ForEach-Object { $_.ToString() }) -join ' '
    if ($r2 -eq $false -and $msg2 -match 'Foo\.appxbundle') { Ok '.appxbundle-only download -> $false, file named' }
    else { Bad "appxbundle: returned '$r2', error=[$msg2]" }

    # ── 3 ────────────────────────────────────────────────────────────────────────────────────────────
    Write-Host '[3] NO REGRESSION: a plain .msix (and .appx / .exe / .msi) is STILL accepted' -ForegroundColor Cyan
    foreach ($name in 'App.msix', 'App.appx', 'App.exe', 'App.msi') {
        $d = New-Dir
        $script:wingetExit  = 0
        $script:wingetDrops = @($name)
        $ok = Download-WingetApp -AppId 'Some.App' -DownloadPath $d -ErrorAction SilentlyContinue 6>$null
        if ($ok -eq $true) { Ok "'$name' is still a valid installer -> `$true" } else { Bad "'$name' regressed: returned '$ok'" }
    }

    # a bundle sitting NEXT TO a real installer must not break the supported installer
    $d3 = New-Dir
    $script:wingetDrops = @('App.msixbundle', 'App.msi')
    $ok3 = Download-WingetApp -AppId 'Some.App' -DownloadPath $d3 -ErrorAction SilentlyContinue 6>$null
    if ($ok3 -eq $true) { Ok 'a stray bundle alongside a real .msi does not block the supported installer' }
    else { Bad "bundle + msi wrongly failed (returned '$ok3')" }

    # ── 4 ────────────────────────────────────────────────────────────────────────────────────────────
    Write-Host '[4] Belt and braces: Get-InstallerFileInfo names the bundle for a bundle-only folder' -ForegroundColor Cyan
    $f1 = New-Dir
    Set-Content -LiteralPath (Join-Path $f1 'Foo.msixbundle') 'stub'
    $errG = $null
    $fi = Get-InstallerFileInfo -FilesPath $f1 -ErrorAction SilentlyContinue -ErrorVariable errG
    $msgG = ($errG | ForEach-Object { $_.ToString() }) -join ' '
    if (-not $fi.FileName) { Ok 'a bundle is still NOT treated as a usable installer' } else { Bad "bundle detected as installer: $($fi.FileName)" }
    if ($msgG -match 'Foo\.msixbundle' -and $msgG -match '(?i)not supported') {
        Ok 'the specific "bundle packages are not supported" message is emitted (not the generic "No installer detected")'
    } else { Bad "no specific bundle message: [$msgG]" }

    # an EMPTY folder must still be the plain generic case — no bundle noise
    $f2 = New-Dir
    $errE = $null
    $fiE = Get-InstallerFileInfo -FilesPath $f2 -ErrorAction SilentlyContinue -ErrorVariable errE
    if (-not $fiE.FileName -and -not $errE) { Ok 'an empty Files\ folder still returns quietly (no false bundle error)' }
    else { Bad "empty folder: file=$($fiE.FileName) err=[$(($errE | ForEach-Object { $_.ToString() }) -join ' ')]" }

    # a real .msix in the folder is still detected even if a bundle sits beside it
    $f3 = New-Dir
    Set-Content -LiteralPath (Join-Path $f3 'App.msixbundle') 'stub'
    Set-Content -LiteralPath (Join-Path $f3 'App.msix') 'stub'
    $fi3 = Get-InstallerFileInfo -FilesPath $f3 -ErrorAction SilentlyContinue
    if ($fi3.Type -eq 'msix' -and $fi3.FileName -eq 'App.msix') { Ok 'a real .msix beside a bundle is still detected as the installer' }
    else { Bad "msix beside bundle: type=$($fi3.Type) file=$($fi3.FileName)" }
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P1_BundleFailFast tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P1_BundleFailFast test(s) FAILED." -ForegroundColor Red; exit 1 }
