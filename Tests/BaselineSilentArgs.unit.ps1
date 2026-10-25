<#
    Installer-identity PR 3b (spec 2.14.3, 2.14.4; L21, L22, SV19, SV20): the switches an old or sibling installer is
    run with are composed the way winget composes them, and a sibling capture downloads exactly one registration type.

      [1] Resolve-Win32ToolkitBaselineSilentArgs: the manifest's Silent + its Custom (one space, not twice - "already
          there" means as whole switches, so neither '/ALLUSERSX' nor 'X/ALLUSERS' holds '/ALLUSERS'); no Silent ->
          winget's default for the type (Inno: '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART') + Custom; Source for every
          path (manifest-silent, manifest-silent+custom, catalog, catalog+custom, guessed); an MSIX never gets switches;
          portable/zip/pwa still throw.
      [2] Download-OldVersionInstaller -ExactType (winget shadowed): only that type (no Burn after NSIS), msi and wix both
          tried, no scope relaxation without -Scope, the scope relaxed (once) with it, W32T.InstallerVariantUnavailable when
          not offered and the destination untouched; -ExactType needs -InstallerType and excludes -FamilyPin; the Custom
          switches of the downloaded manifest reach SilentArgs, with SilentArgsSource and ManifestPath; a download whose
          manifest is another type (a zip wrapping the requested one, as winget's --installer-type allows), has installers
          of several types or has no manifest is not used (not offered; msi tried after a zip-wrapped wix); two installers
          of one type pass and the requested architecture's switches are used; quoted switches (a quoted Silent, a
          double-quoted Custom with escapes) are run unquoted and decoded; the pipeline cache stores only a download that
          passed the type check, discards and removes a cached entry of another type (never 'From cache'), heals once
          winget answers the right type, and reports a used entry 'From cache'.

    Run:  pwsh -File Tests\BaselineSilentArgs.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')
. (Join-Path $repo 'Private\Resolve-Win32ToolkitBaselineSilentArgs.ps1')

# == [1] the resolver ===================================================================================
Write-Host '[1] Resolve-Win32ToolkitBaselineSilentArgs' -ForegroundColor Cyan
$cases = @(
    @{ L = 'Silent + Custom'; A = @{ InstallerTypeName = 'inno'; YamlSilentArgs = '/VERYSILENT'; YamlCustomArgs = '/ALLUSERS' }; S = '/VERYSILENT /ALLUSERS'; Src = 'manifest-silent+custom'; G = $false }
    @{ L = 'Silent already holding Custom'; A = @{ InstallerTypeName = 'inno'; YamlSilentArgs = '/VERYSILENT /allusers'; YamlCustomArgs = '/ALLUSERS' }; S = '/VERYSILENT /allusers'; Src = 'manifest-silent'; G = $false }
    @{ L = 'Silent holding a longer switch only'; A = @{ InstallerTypeName = 'inno'; YamlSilentArgs = '/VERYSILENT /ALLUSERSX'; YamlCustomArgs = '/ALLUSERS' }; S = '/VERYSILENT /ALLUSERSX /ALLUSERS'; Src = 'manifest-silent+custom'; G = $false }
    @{ L = 'Silent holding Custom only as the tail of a longer token'; A = @{ InstallerTypeName = 'inno'; YamlSilentArgs = '/VERYSILENT X/ALLUSERS'; YamlCustomArgs = '/ALLUSERS' }; S = '/VERYSILENT X/ALLUSERS /ALLUSERS'; Src = 'manifest-silent+custom'; G = $false }
    @{ L = 'Silent holding a two-switch Custom'; A = @{ InstallerTypeName = 'burn'; YamlSilentArgs = '/quiet A=1 B=2 /norestart'; YamlCustomArgs = 'A=1 B=2' }; S = '/quiet A=1 B=2 /norestart'; Src = 'manifest-silent'; G = $false }
    @{ L = 'Silent only'; A = @{ InstallerTypeName = 'nullsoft'; YamlSilentArgs = '/S /D=x' }; S = '/S /D=x'; Src = 'manifest-silent'; G = $false }
    @{ L = 'no Silent, Inno + Custom (KeePass)'; A = @{ InstallerTypeName = 'inno'; YamlCustomArgs = '/ALLUSERS' }; S = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS'; Src = 'catalog+custom'; G = $false }
    @{ L = "no Silent, Inno (winget's default)"; A = @{ InstallerTypeName = 'inno' }; S = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; Src = 'catalog'; G = $false }
    @{ L = 'no Silent, nullsoft'; A = @{ InstallerTypeName = 'nullsoft' }; S = '/S'; Src = 'catalog'; G = $false }
    @{ L = 'no Silent, burn'; A = @{ InstallerTypeName = 'burn'; YamlCustomArgs = 'ACCEPTEULA=1' }; S = '/quiet /norestart ACCEPTEULA=1'; Src = 'catalog+custom'; G = $false }
    @{ L = 'msix + Custom'; A = @{ InstallerTypeName = 'msix'; YamlCustomArgs = '/x' }; S = ''; Src = 'catalog'; G = $false }
    @{ L = 'unknown type + Custom'; A = @{ InstallerTypeName = 'weird'; YamlCustomArgs = '/x' }; S = '/S'; Src = 'guessed'; G = $true }
    @{ L = 'typeless .exe'; A = @{ Extension = '.exe' }; S = '/S'; Src = 'guessed'; G = $true }
    @{ L = 'typeless .msi + Custom'; A = @{ Extension = '.msi'; YamlCustomArgs = 'ALLUSERS=1' }; S = '/qn /norestart ALLUSERS=1'; Src = 'catalog+custom'; G = $false }
    @{ L = 'typeless .msixbundle'; A = @{ Extension = '.msixbundle'; YamlCustomArgs = '/x' }; S = ''; Src = 'catalog'; G = $false }
)
foreach ($c in $cases) {
    $a = $c.A
    $r = Resolve-Win32ToolkitBaselineSilentArgs @a
    if ($r.SilentArgs -ceq $c.S -and $r.Source -ceq $c.Src -and $r.Guessed -eq $c.G) { Ok "$($c.L) -> '$($r.SilentArgs)' ($($r.Source))" } else { Bad "$($c.L): $($r | ConvertTo-Json -Compress)" }
}
foreach ($t in 'portable', 'zip', 'pwa') {
    $threw = $false
    try { $null = Resolve-Win32ToolkitBaselineSilentArgs -InstallerTypeName $t -YamlSilentArgs '/S' -YamlCustomArgs '/x' } catch { $threw = $true }
    if ($threw) { Ok "$t still throws (no silent installer)" } else { Bad "$t did not throw" }
}

# == [2] -ExactType =====================================================================================
Write-Host '[2] Download-OldVersionInstaller -ExactType' -ForegroundColor Cyan
. (Join-Path $repo 'Private\Get-WingetManifestFile.ps1')
. (Join-Path $repo 'Private\Get-YAMLInstallerInfo.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitCachedInstaller.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitWingetDownload.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerFamily.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitWingetNoApplicableInstaller.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')            # -ExactType reads the staged manifest (C-9)
. (Join-Path $repo 'Private\ConvertFrom-Win32ToolkitWingetManifest.ps1')
. (Join-Path $repo 'Private\Download-OldVersionInstaller.ps1')
# The pipeline cache: none unless a case sets a root.
$script:cacheRoot = $null
function Get-Win32ToolkitPipelineCacheRoot { $script:cacheRoot }
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('w32bsa_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:calls = [System.Collections.Generic.List[object]]::new()
$script:answer = { 0 }
# Every shadowed download writes the same installer bytes; the manifest records their SHA-256, so a cached copy validates.
$payload = [byte[]](5..60)
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try { $script:payloadSha = -join ($sha256.ComputeHash($payload) | ForEach-Object { $_.ToString('X2') }) } finally { $sha256.Dispose() }
# What the shadowed download's manifest says about the type ($null = no manifest written at all), and its switch lines.
$script:typeLines = { param([string]$Type) @("  InstallerType: $Type") }
$script:switchLines = { @('    Custom: /ALLUSERS') }
function winget {
    $a = [string[]]$args
    $script:calls.Add($a)
    $code = & $script:answer $a
    if ($code -eq 0) {
        $dir = $a[[array]::IndexOf($a, '--download-directory') + 1]
        $ti = [array]::IndexOf($a, '--installer-type')
        $type = if ($ti -ge 0) { $a[$ti + 1] } else { 'nullsoft' }
        $ext = if ($type -in @('msi', 'wix')) { 'msi' } else { 'exe' }
        [IO.File]::WriteAllBytes((Join-Path $dir "app.$ext"), $payload)
        $lines = & $script:typeLines $type
        if ($null -ne $lines) {
            Set-Content -LiteralPath (Join-Path $dir 'Acme.App.installer.yaml') -Encoding UTF8 -Value (@('PackageIdentifier: Acme.App', 'PackageVersion: 1.2.3', 'Installers:', '- Architecture: x64') +
                @($lines) + @("  InstallerSha256: $($script:payloadSha)", '  Scope: machine', "  ProductCode: 'Acme App'", '  InstallerSwitches:') + @(& $script:switchLines))
        }
    }
    $global:LASTEXITCODE = $code
}
# Runs the download with its host lines captured: @{ R = the result or the error; Host = the host text }.
function Invoke-Captured([hashtable]$Splat) {
    $out = $null; $err = $null
    try { $out = @(Download-OldVersionInstaller @Splat 6>&1 3>$null) } catch { $err = $_ }
    $r = if ($err) { $err } else { @($out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0] }
    @{ R = $r; Host = (@($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" }) -join "`n") }
}
$NA = -1978335216   # 0x8A150010 no applicable installer
function ValueOf($a, $flag) { $i = [array]::IndexOf([string[]]$a, $flag); if ($i -ge 0) { $a[$i + 1] } else { $null } }
function Has($a, $flag) { [array]::IndexOf([string[]]$a, $flag) -ge 0 }
$proj = Join-Path $tmpRoot 'p'
$dest = Join-Path $proj 'Sandbox\Siblings\inno-1.2.3'
$null = New-Item -ItemType Directory -Path $proj -Force
try {
    $script:calls.Clear(); $script:answer = { 0 }
    $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest -Architecture x64 -InstallerType inno -ExactType 6>$null 3>$null
    if ($script:calls.Count -eq 1 -and (ValueOf $script:calls[0] '--installer-type') -eq 'inno' -and -not (Has $script:calls[0] '--scope') -and $r.Family -eq 'exe' -and (@($r.TriedTypes) -join ',') -eq 'inno') { Ok 'inno: one call --installer-type inno, no --scope; Family exe, TriedTypes inno' } else { Bad "inno: $(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ')" }
    if ($r.SilentArgs -ceq '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS' -and $r.SilentArgsSource -eq 'catalog+custom' -and $r.CustomArgs -eq '/ALLUSERS' -and @($r.ManifestPath).Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $dest 'app.exe'))) { Ok "the manifest's Custom reaches SilentArgs (catalog+custom); ManifestPath; the installer lands in -DestinationDir" } else { Bad "inno result: $($r | ConvertTo-Json -Compress)" }

    $script:calls.Clear(); $script:answer = { $NA }
    $before = (Get-ChildItem -LiteralPath $dest | ForEach-Object Name) -join ','
    $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest -Architecture x64 -InstallerType nullsoft -ExactType 6>$null 3>$null } catch { $err = $_ }
    $types = @($script:calls | ForEach-Object { ValueOf $_ '--installer-type' })
    if ($err.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable' -and ($types -join ',') -eq 'nullsoft' -and "$($err.Exception.Message)" -match "no 'nullsoft' installer" -and ((Get-ChildItem -LiteralPath $dest | ForEach-Object Name) -join ',') -eq $before) { Ok 'nullsoft not offered -> W32T.InstallerVariantUnavailable after ONE try (no Burn/Inno fallback), the destination untouched' } else { Bad "not offered: $($err.FullyQualifiedErrorId) types=$($types -join ',')" }
    if (@($script:calls | Where-Object { -not (Has $_ '--installer-type') }).Count -eq 0) { Ok 'never an unpinned retry' } else { Bad 'unpinned call' }

    $script:calls.Clear(); $script:answer = { param([string[]]$A) if ((ValueOf $A '--installer-type') -eq 'wix') { $NA } else { 0 } }
    $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest -Architecture x64 -InstallerType wix -ExactType 6>$null 3>$null
    $types = @($script:calls | ForEach-Object { ValueOf $_ '--installer-type' })
    if (($types -join ',') -eq 'wix,msi' -and $r.ManifestInstallerType -eq 'msi' -and $r.Family -eq 'msi') { Ok 'msi and wix are one registration type: wix not offered -> msi tried' } else { Bad "msi/wix: $($types -join ',')" }

    $script:calls.Clear(); $script:answer = { param([string[]]$A) if (Has $A '--scope') { $NA } else { 0 } }
    $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest -Architecture x64 -InstallerType inno -Scope machine -ExactType 6>$null 3>$null -WarningVariable w
    if ($script:calls.Count -eq 2 -and (ValueOf $script:calls[0] '--scope') -eq 'machine' -and -not (Has $script:calls[1] '--scope') -and $r.ScopeRelaxed) { Ok 'with -Scope: the scoped attempt, then the same type without a scope (ScopeRelaxed)' } else { Bad "scope: $(@($script:calls | ForEach-Object { $_ -join ' ' }) -join ' || ')" }

    # winget's --installer-type also takes an archive that WRAPS the type (EffectiveInstallerType): a zip around the
    # nullsoft installer is not a nullsoft installer, so the capture must not use it.
    $script:calls.Clear(); $script:answer = { 0 }
    $script:typeLines = { param([string]$Type) @('  InstallerType: zip', "  NestedInstallerType: $Type") }
    $before = (Get-ChildItem -LiteralPath $dest | ForEach-Object Name) -join ','
    $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest -Architecture x64 -InstallerType nullsoft -ExactType 6>$null 3>$null } catch { $err = $_ }
    if ($err.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable' -and "$($err.Exception.Message)" -match "nullsoft gave 'zip'" -and $script:calls.Count -eq 1 -and
        ((Get-ChildItem -LiteralPath $dest | ForEach-Object Name) -join ',') -eq $before -and -not (Test-Path -LiteralPath "$dest.attempt")) { Ok "a zip wrapping the nullsoft installer -> W32T.InstallerVariantUnavailable ('nullsoft gave zip'), the destination untouched, no staging left" } else { Bad "zip-wrapped: $($err.FullyQualifiedErrorId) [$($err.Exception.Message)] calls=$($script:calls.Count)" }
    $script:calls.Clear(); $script:answer = { 0 }
    $script:typeLines = { param([string]$Type) if ($Type -eq 'wix') { @('  InstallerType: zip', '  NestedInstallerType: wix') } else { @("  InstallerType: $Type") } }
    $r = $null
    try { $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest -Architecture x64 -InstallerType wix -ExactType 6>$null 3>$null } catch { $r = "threw: $($_.Exception.Message)" }
    if ((@($script:calls | ForEach-Object { ValueOf $_ '--installer-type' }) -join ',') -eq 'wix,msi' -and $r.ManifestInstallerType -eq 'msi' -and (Test-Path -LiteralPath (Join-Path $dest 'app.msi'))) { Ok "wix answered with a zip -> not used; msi (the same registration type) tried next and used" } else { Bad "wix zip: $($r | ConvertTo-Json -Compress)" }
    $script:calls.Clear(); $script:typeLines = { $null }
    $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest -Architecture x64 -InstallerType inno -ExactType 6>$null 3>$null } catch { $err = $_ }
    if ($err.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable' -and "$($err.Exception.Message)" -match 'no readable manifest') { Ok 'a download without a manifest -> not offered (its type is unproven)' } else { Bad "no manifest: $($err.FullyQualifiedErrorId) [$($err.Exception.Message)]" }
    # A manifest whose installers are of several types is not that type either (winget download writes the one it chose).
    $script:calls.Clear()
    $script:typeLines = { param([string]$Type) @("  InstallerType: $Type", '- Architecture: x64', '  InstallerType: zip', '  NestedInstallerType: portable') }
    $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest -Architecture x64 -InstallerType nullsoft -ExactType 6>$null 3>$null } catch { $err = $_ }
    if ($err.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable' -and "$($err.Exception.Message)" -match "nullsoft gave 'nullsoft', 'zip'") { Ok "a manifest with a nullsoft and a zip installer -> not offered ('nullsoft gave nullsoft, zip')" } else { Bad "two types: $($err.FullyQualifiedErrorId) [$($err.Exception.Message)]" }
    # Two installers of the SAME type (x86 first): the type check passes and the switches are the downloaded architecture's.
    $script:typeLines = { param([string]$Type) @("  InstallerType: $Type", '  InstallerSwitches:', '    Silent: /S /TAG=x64', '- Architecture: x86', "  InstallerType: $Type") }
    $r = $null
    try { $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest -Architecture x64 -InstallerType nullsoft -ExactType 6>$null 3>$null } catch { $r = "threw: $($_.Exception.Message)" }
    if ($r.SilentArgs -ceq '/S /TAG=x64' -and $r.SilentArgsSource -eq 'manifest-silent') { Ok 'two nullsoft installers (x64, x86): accepted; the x64 installer''s own switches, not the x86 one''s' } else { Bad "same type twice: $($r | ConvertTo-Json -Compress)" }
    $script:typeLines = { param([string]$Type) @("  InstallerType: $Type") }

    # The switches that are run are read as YAML reads them: quotes removed, double-quoted escapes decoded (winget's own
    # writer double-quotes, with escapes, any value it cannot write plain). A quoted Silent never keeps its quotes.
    $quoted = @(
        @{ Custom = '"/ALLUSERS"'; S = '/VERYSILENT /ALLUSERS'; C = '/ALLUSERS' }
        @{ Custom = '"/D=C:\\x"'; S = '/VERYSILENT /D=C:\x'; C = '/D=C:\x' }
        @{ Custom = '"/DIR=\"C:\\X\""'; S = '/VERYSILENT /DIR="C:\X"'; C = '/DIR="C:\X"' }
    )
    $script:switchLines = { @("    Silent: '/VERYSILENT'", "    Custom: $($script:qcCustom)") }
    foreach ($qc in $quoted) {
        $script:qcCustom = $qc.Custom
        $r = $null
        try { $r = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest -Architecture x64 -InstallerType inno -ExactType 6>$null 3>$null } catch { $r = "threw: $($_.Exception.Message)" }
        if ($r.SilentArgs -ceq $qc.S -and $r.CustomArgs -ceq $qc.C -and $r.SilentArgsSource -eq 'manifest-silent+custom') { Ok "Silent '/VERYSILENT' (quoted) + Custom $($qc.Custom) -> [$($r.SilentArgs)]" } else { Bad "quoted $($qc.Custom): $($r | ConvertTo-Json -Compress)" }
    }
    $script:switchLines = { @('    Custom: /ALLUSERS') }

    # The pipeline cache: only a download of the requested type is stored under its key; a cached entry of another type
    # (an earlier build stored it) is discarded, removed and never reported 'From cache' (L22).
    $script:cacheRoot = Join-Path $tmpRoot 'cache'
    $keyOf = { param([string]$Type) Join-Path $script:cacheRoot "Acme.App\1.2.3\x64_any_$($Type)_any" }
    $zipWix = { param([string]$Type) if ($Type -eq 'wix') { @('  InstallerType: zip', '  NestedInstallerType: wix') } else { @("  InstallerType: $Type") } }
    $script:calls.Clear(); $script:answer = { 0 }; $script:typeLines = $zipWix
    $c1 = Invoke-Captured @{ AppId = 'Acme.App'; Version = '1.2.3'; ProjectPath = $proj; DestinationDir = $dest; Architecture = 'x64'; InstallerType = 'wix'; ExactType = $true }
    if (-not (Test-Path -LiteralPath (& $keyOf 'wix')) -and (Test-Path -LiteralPath (Join-Path (& $keyOf 'msi') 'app.msi')) -and $c1.R.ManifestInstallerType -eq 'msi') { Ok "a zip-wrapped 'wix' download is not cached under the wix key; the msi download is cached under its own" } else { Bad "store: wix key $(Test-Path -LiteralPath (& $keyOf 'wix')), msi key $(Test-Path -LiteralPath (& $keyOf 'msi')), $($c1.R | ConvertTo-Json -Compress)" }

    # Seed a poisoned wix entry (a valid cache entry whose manifest is a zip wrapping wix) and empty the msi key.
    Remove-Item -LiteralPath (& $keyOf 'msi') -Recurse -Force
    $poison = & $keyOf 'wix'
    $null = New-Item -ItemType Directory -Path $poison -Force
    [IO.File]::WriteAllBytes((Join-Path $poison 'app.msi'), $payload)
    Set-Content -LiteralPath (Join-Path $poison 'Acme.App.installer.yaml') -Encoding UTF8 -Value @('PackageIdentifier: Acme.App', 'PackageVersion: 1.2.3', 'Installers:', '- Architecture: x64', '  InstallerType: zip', '  NestedInstallerType: wix', "  InstallerSha256: $($script:payloadSha)")
    $script:calls.Clear()
    $c2 = Invoke-Captured @{ AppId = 'Acme.App'; Version = '1.2.3'; ProjectPath = $proj; DestinationDir = $dest; Architecture = 'x64'; InstallerType = 'wix'; ExactType = $true }
    $types = @($script:calls | ForEach-Object { ValueOf $_ '--installer-type' })
    if ($c2.R.ManifestInstallerType -eq 'msi' -and ($types -join ',') -eq 'wix,msi' -and -not (Test-Path -LiteralPath $poison) -and (Test-Path -LiteralPath (& $keyOf 'msi'))) { Ok 'a cached zip-wrapped wix entry: not used, removed from the cache, wix downloaded again (still a zip: not stored), then msi' } else { Bad "poisoned: types=$($types -join ',') poison left $(Test-Path -LiteralPath $poison) $($c2.R | ConvertTo-Json -Compress)" }
    if ($c2.Host -notmatch 'From cache' -and $c2.Host -notmatch 'Using the cached download' -and $c2.Host -match 'Downloaded\s*: app\.msi' -and $c2.Host -match "cached 'wix' download .* is 'zip'.*discarded") { Ok "the host says 'Downloaded', never 'From cache', and names the discarded entry" } else { Bad "labels: $($c2.Host)" }

    # The discarded entry heals: once winget answers wix with a wix installer, that is used and cached.
    $null = New-Item -ItemType Directory -Path $poison -Force
    [IO.File]::WriteAllBytes((Join-Path $poison 'app.msi'), $payload)
    Set-Content -LiteralPath (Join-Path $poison 'Acme.App.installer.yaml') -Encoding UTF8 -Value @('PackageIdentifier: Acme.App', 'PackageVersion: 1.2.3', 'Installers:', '- Architecture: x64', '  InstallerType: zip', '  NestedInstallerType: wix', "  InstallerSha256: $($script:payloadSha)")
    $script:calls.Clear(); $script:typeLines = { param([string]$Type) @("  InstallerType: $Type") }
    $c3 = Invoke-Captured @{ AppId = 'Acme.App'; Version = '1.2.3'; ProjectPath = $proj; DestinationDir = $dest; Architecture = 'x64'; InstallerType = 'wix'; ExactType = $true }
    $wixManifest = Get-ChildItem -LiteralPath $poison -Filter '*.yaml' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
    if ($c3.R.ManifestInstallerType -eq 'wix' -and $script:calls.Count -eq 1 -and "$wixManifest" -match 'InstallerType: wix' -and "$wixManifest" -notmatch 'zip' -and $c3.Host -match 'Downloaded\s*: app\.msi') { Ok 'a discarded entry heals: the fresh wix download is used and cached under the wix key' } else { Bad "heal: calls=$($script:calls.Count) $($c3.R | ConvertTo-Json -Compress) [$wixManifest]" }
    # ... and the next run takes it from the cache, without asking winget.
    $script:calls.Clear()
    $c4 = Invoke-Captured @{ AppId = 'Acme.App'; Version = '1.2.3'; ProjectPath = $proj; DestinationDir = $dest; Architecture = 'x64'; InstallerType = 'wix'; ExactType = $true }
    if ($script:calls.Count -eq 0 -and $c4.R.ManifestInstallerType -eq 'wix' -and $c4.Host -match 'From cache\s*: app\.msi') { Ok "a cached entry of the requested type is used and reported 'From cache'" } else { Bad "cache hit: calls=$($script:calls.Count) [$($c4.Host)]" }
    $script:cacheRoot = $null

    foreach ($bad in @(@{ L = 'without -InstallerType'; A = @{ ExactType = $true } }, @{ L = 'with -FamilyPin'; A = @{ ExactType = $true; FamilyPin = $true; InstallerType = 'inno' } })) {
        $a = $bad.A
        $threw = $null
        try { $null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -DestinationDir $dest @a 6>$null 3>$null } catch { $threw = "$($_.Exception.Message)" }
        if ($threw -match 'ExactType') { Ok "-ExactType $($bad.L) -> refused" } else { Bad "$($bad.L): $threw" }
    }
}
finally { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All BaselineSilentArgs tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail BaselineSilentArgs test(s) FAILED." -ForegroundColor Red; exit 1 }
