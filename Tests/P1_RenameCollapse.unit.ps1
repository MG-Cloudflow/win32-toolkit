<#
    P1 — Rename-InstallerFile DESTROYED an installer when two files shared an extension.

    The old code enumerated ALL files of a given extension and, inside the loop, computed the SAME
    target name for every one of them:

        if (Test-Path $newPath) { Remove-Item $newPath -Force }
        Rename-Item -Path $file.FullName -NewName $newName -Force

    So with setup.exe + helper.exe in Files\, setup.exe was renamed to App_x64_1.0.exe and then DELETED
    by helper.exe's iteration. One file went in, one file came out — silent data loss, and the file that
    survived was whichever one the enumeration happened to hit last.

    The same hole applied to an already correctly-named file: the candidate list filtered it out
    (BaseName -ne $baseName) but it still sat at $newPath, so Remove-Item ate it.

    Fixed behaviour: >1 candidate for an extension => rename SKIPPED for that extension, both files kept,
    a warning names them. Get-InstallerFileInfo still finds the installer. The single-file case renames
    exactly as before.

    Nothing here touches the network. Only temp folders are written.

    Run:  pwsh -File Tests\P1_RenameCollapse.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Rename-InstallerFile.ps1')
. (Join-Path $repo 'Private\Get-InstallerFileInfo.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32rn_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-Files {
    # Creates a fresh Files\ folder pre-populated with @{ name = content }
    param([hashtable]$Content)
    $p = Join-Path $tempRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    foreach ($k in $Content.Keys) { Set-Content -LiteralPath (Join-Path $p $k) -Value $Content[$k] -NoNewline }
    $p
}
function Names($p) { @(Get-ChildItem -LiteralPath $p -File | ForEach-Object { $_.Name } | Sort-Object) }
function Body($p, $n) {
    $f = Join-Path $p $n
    if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw } else { $null }
}

try {
    # ══ 1 ══ THE BUG: two .exe files must both survive ════════════════════════════════════════════
    Write-Host '[1] Two .exe files in Files\ — neither may be deleted' -ForegroundColor Cyan

    $d1 = New-Files @{ 'setup.exe' = 'REAL-INSTALLER-PAYLOAD'; 'helper.exe' = 'HELPER-PAYLOAD' }
    Rename-InstallerFile -FilesPath $d1 -AppName 'Acme App' -Version '1.0.0' -Architecture 'x64' `
        -WarningVariable w1 -WarningAction SilentlyContinue 6>$null

    $n1 = Names $d1
    if ($n1.Count -eq 2) { Ok "both files still present ($($n1 -join ', '))" }
    else { Bad "file(s) LOST — expected 2 files, found $($n1.Count): $($n1 -join ', ')" }

    # No content may vanish: both payloads must still be on disk somewhere in the folder.
    $bodies = @(Get-ChildItem -LiteralPath $d1 -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
    if ($bodies -contains 'REAL-INSTALLER-PAYLOAD') { Ok 'installer content survived' }
    else { Bad 'installer content was DESTROYED' }
    if ($bodies -contains 'HELPER-PAYLOAD') { Ok 'helper content survived' }
    else { Bad 'helper content was DESTROYED' }

    # The collision must be reported, and the warning must NAME the colliding files.
    $wText = ($w1 | ForEach-Object { $_.Message }) -join ' | '
    if ($wText -match 'setup\.exe' -and $wText -match 'helper\.exe') { Ok 'warning names both colliding files' }
    else { Bad "warning did not name the colliding files. Got: '$wText'" }

    # And the pipeline must still be able to find an installer in that folder.
    $fi1 = Get-InstallerFileInfo -FilesPath $d1 -WarningAction SilentlyContinue
    if ($fi1.FileName -and $fi1.Type -eq 'exe') { Ok "Get-InstallerFileInfo still resolves an installer ($($fi1.FileName))" }
    else { Bad 'Get-InstallerFileInfo could not resolve an installer after the skip' }

    # ══ 2 ══ Collision with an ALREADY-CLEAN file (the other half of the same bug) ═════════════════
    Write-Host '[2] A correctly-named file beside a second .exe must not be deleted' -ForegroundColor Cyan

    $d2 = New-Files @{ 'Acme_App_x64_1.0.0.exe' = 'ALREADY-CLEAN'; 'uninstall.exe' = 'UNINSTALLER' }
    Rename-InstallerFile -FilesPath $d2 -AppName 'Acme App' -Version '1.0.0' -Architecture 'x64' `
        -WarningAction SilentlyContinue 6>$null

    if ((Names $d2).Count -eq 2) { Ok 'both files still present' }
    else { Bad "file(s) LOST — found: $((Names $d2) -join ', ')" }
    if ((Body $d2 'Acme_App_x64_1.0.0.exe') -eq 'ALREADY-CLEAN') { Ok 'the already-clean file was not overwritten by the other .exe' }
    else { Bad 'the already-clean file was overwritten/deleted' }

    # ══ 3 ══ No regression: the single-file cases still rename exactly as before ═══════════════════
    Write-Host '[3] Single-file rename still works (.exe and .msi)' -ForegroundColor Cyan

    $d3 = New-Files @{ 'AcmeSetup-1.0.0-installer.exe' = 'ONLY-INSTALLER' }
    Rename-InstallerFile -FilesPath $d3 -AppName 'Acme App' -Version '1.0.0' -Architecture 'x64' 6>$null
    if ((Names $d3) -eq @('Acme_App_x64_1.0.0.exe')) { Ok '.exe renamed to Acme_App_x64_1.0.0.exe' }
    else { Bad ".exe not renamed as expected. Got: $((Names $d3) -join ', ')" }
    if ((Body $d3 'Acme_App_x64_1.0.0.exe') -eq 'ONLY-INSTALLER') { Ok '.exe content preserved through the rename' }
    else { Bad '.exe content changed/lost through the rename' }

    $d4 = New-Files @{ 'somepackage.msi' = 'ONLY-MSI' }
    Rename-InstallerFile -FilesPath $d4 -AppName 'Acme App' -Version '2.1' -Architecture 'x86' 6>$null
    if ((Names $d4) -eq @('Acme_App_x86_2.1.msi')) { Ok '.msi renamed to Acme_App_x86_2.1.msi' }
    else { Bad ".msi not renamed as expected. Got: $((Names $d4) -join ', ')" }
    if ((Body $d4 'Acme_App_x86_2.1.msi') -eq 'ONLY-MSI') { Ok '.msi content preserved through the rename' }
    else { Bad '.msi content changed/lost through the rename' }

    # ══ 4 ══ One .msi + one .exe is NOT a collision — different extensions, both renamed ═══════════
    Write-Host '[4] Different extensions are independent (one .msi + one .exe both get renamed)' -ForegroundColor Cyan

    $d5 = New-Files @{ 'pkg.msi' = 'MSI-BODY'; 'boot.exe' = 'EXE-BODY' }
    Rename-InstallerFile -FilesPath $d5 -AppName 'Acme App' -Version '1.0.0' -Architecture 'x64' `
        -WarningAction SilentlyContinue 6>$null
    $n5 = Names $d5
    if ($n5.Count -eq 2 -and ($n5 -contains 'Acme_App_x64_1.0.0.msi') -and ($n5 -contains 'Acme_App_x64_1.0.0.exe')) {
        Ok 'both extensions renamed, nothing lost'
    }
    else { Bad "expected both renamed, got: $($n5 -join ', ')" }
    if ((Body $d5 'Acme_App_x64_1.0.0.msi') -eq 'MSI-BODY' -and (Body $d5 'Acme_App_x64_1.0.0.exe') -eq 'EXE-BODY') {
        Ok 'contents did not cross over'
    }
    else { Bad 'file contents crossed over between extensions' }

    # ══ 5 ══ PSADT's own binaries are not installer candidates (matches Get-InstallerFileInfo) ═════
    Write-Host "[5] A stray ServiceUI.exe does not block the real installer's rename" -ForegroundColor Cyan

    $d6 = New-Files @{ 'setup.exe' = 'REAL'; 'ServiceUI.exe' = 'PSADT-BINARY' }
    Rename-InstallerFile -FilesPath $d6 -AppName 'Acme App' -Version '1.0.0' -Architecture 'x64' `
        -WarningAction SilentlyContinue 6>$null
    $n6 = Names $d6
    if ($n6.Count -eq 2 -and ($n6 -contains 'Acme_App_x64_1.0.0.exe') -and ($n6 -contains 'ServiceUI.exe')) {
        Ok 'installer renamed, ServiceUI.exe untouched'
    }
    else { Bad "expected Acme_App_x64_1.0.0.exe + ServiceUI.exe, got: $($n6 -join ', ')" }
    if ((Body $d6 'ServiceUI.exe') -eq 'PSADT-BINARY') { Ok 'ServiceUI.exe content intact' }
    else { Bad 'ServiceUI.exe was clobbered' }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
Write-Host "$fail FAILED" -ForegroundColor Red; exit 1
