<#
    P1 — winget YAML: the WRONG manifest file was being read, and the encoding was unspecified.

    A winget package ships a manifest SET and the keys are NOT interchangeable:

        <Id>.installer.yaml      InstallerType, Architecture, ProductCode, Scope, InstallerLocale,
                                 InstallerSwitches/Silent      <- installer data lives ONLY here
        <Id>.locale.<loc>.yaml   PackageName, Publisher, ShortDescription, PackageUrl, PublisherUrl
        <Id>.yaml                PackageIdentifier, PackageVersion

    Get-YAMLInstallerInfo / Get-WingetIdFromProject / Download-OldVersionInstaller all did

        Get-ChildItem -Filter '*.yaml' | Select-Object -First 1     (i.e. $yamlFiles[0])

    and parsed THAT ONE FILE for every key — so whichever file happened to sort first decided the
    answer. Both directions are broken:

      * installer manifest sorts first  -> PackageName / Publisher / Description / InformationUrl all
        come back $null (Publish then ships the app to Intune as publisher 'Unknown').
      * a locale manifest sorts first   -> InstallerType / Architecture / ProductCode / SilentArgs all
        come back $null (or, worse, whatever locale junk matched the regex).

    Enumeration order is not a contract, so the fix is to select by manifest KIND
    (Private\Get-WingetManifestFile.ps1) and read every manifest as UTF-8 so non-ASCII
    publisher/app names survive.

    Nothing here hits the network: winget is shadowed.

    Run:  pwsh -File Tests\P1_YamlManifest.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-WingetManifestFile.ps1')
. (Join-Path $repo 'Private\Get-YAMLInstallerInfo.ps1')
. (Join-Path $repo 'Private\Get-WingetIdFromProject.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')  # installer-extension source of truth (bundle support)
. (Join-Path $repo 'Private\Resolve-Win32ToolkitBaselineSilentArgs.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitWingetDownload.ps1')  # every winget download runs through it (C-9)
. (Join-Path $repo 'Private\Download-OldVersionInstaller.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\ConvertFrom-Win32ToolkitWingetManifest.ps1')   # C-9: Download-OldVersionInstaller reads the downloaded switches with it

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────────
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32yaml_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

# winget manifests are UTF-8 (with BOM). Write them as real bytes, not via Set-Content's default.
function Write-Manifest($Path, $Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true)))
}

# The real installer data. NOTE the non-ASCII publisher/app name — it must survive the read.
$installerYaml = @'
PackageIdentifier: Contoso.Editor
PackageVersion: 2.1.0
InstallerLocale: en-US
MinimumOSVersion: 10.0.0.0
Installers:
- Architecture: x64
  InstallerType: inno
  Scope: machine
  InstallerUrl: https://example.invalid/CoentosoEditorSetup.exe
  InstallerSha256: 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
  ProductCode: '{11111111-2222-3333-4444-555555555555}'
  InstallerSwitches:
    Custom: /LOG
    Silent: /VERYSILENT /NORESTART /SP-
ManifestType: installer
ManifestVersion: 1.6.0
'@

# The locale manifest owns the display strings. It carries DECOY installer keys: deliberately wrong
# values that only a parser reading the wrong file could ever return.
$localeYaml = @'
PackageIdentifier: Contoso.Editor
PackageVersion: 2.1.0
PackageLocale: en-US
Publisher: Nagüi Softwäre
PublisherUrl: https://publisher.invalid/
PackageName: Cöntoso Editör
PackageUrl: https://package.invalid/editor
ShortDescription: A tiny editor for büsy people.
Architecture: DECOY-arch
InstallerType: DECOY-type
ProductCode: '{DECOYDEC-OYDE-COYD-ECOY-DECOYDECOYDE}'
Scope: DECOY-scope
InstallerSwitches:
  Silent: /DECOY-SILENT
ManifestType: defaultLocale
ManifestVersion: 1.6.0
'@

$versionYaml = @'
PackageIdentifier: Contoso.Editor
PackageVersion: 2.1.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.6.0
'@

# Fixture A — the canonical winget download layout (installer manifest sorts FIRST).
# Old code read it and returned $null for Publisher / PackageName / Description / InformationUrl.
$dirA = Join-Path $tmpRoot 'A_canonical'
New-Item -ItemType Directory -Path $dirA -Force | Out-Null
Write-Manifest (Join-Path $dirA 'Contoso.Editor.installer.yaml')     $installerYaml
Write-Manifest (Join-Path $dirA 'Contoso.Editor.locale.en-US.yaml')  $localeYaml
Write-Manifest (Join-Path $dirA 'Contoso.Editor.yaml')               $versionYaml

# Fixture B — same manifest set, but the LOCALE manifest is the alphabetically-first file, so the old
# `$yamlFiles[0]` read the locale manifest and the installer fields came back as the DECOY values /
# $null. (Enumeration order is not something a caller may lean on — selection must be by KIND.)
$dirB = Join-Path $tmpRoot 'B_locale_first'
New-Item -ItemType Directory -Path $dirB -Force | Out-Null
Write-Manifest (Join-Path $dirB 'Contoso.Editor.default.locale.en-US.yaml') $localeYaml
Write-Manifest (Join-Path $dirB 'Contoso.Editor.installer.yaml')            $installerYaml
Write-Manifest (Join-Path $dirB 'Contoso.Editor.yaml')                      $versionYaml

$firstB = (Get-ChildItem -LiteralPath $dirB -Filter '*.yaml' -File | Select-Object -First 1).Name
Write-Host "[fixture] the old code's `$yamlFiles[0] in B is: $firstB" -ForegroundColor DarkGray
if ($firstB -like '*.locale*') { Ok 'fixture B really does put the LOCALE manifest first (the old bug is reachable)' }
else { Bad "fixture B is not locale-first ($firstB) — the test would not prove anything" }

# ══ 1. Get-WingetManifestFile picks by KIND, not by sort order ════════════════════════════════════
Write-Host '[1] Get-WingetManifestFile: the right manifest for the right job' -ForegroundColor Cyan

foreach ($d in @($dirA, $dirB)) {
    $label = Split-Path $d -Leaf
    $i = Get-WingetManifestFile -Path $d -Kind Installer
    $l = Get-WingetManifestFile -Path $d -Kind Locale
    $v = Get-WingetManifestFile -Path $d -Kind Version
    if ($i.Name -like '*.installer.yaml')                                   { Ok "$label : Kind Installer -> $($i.Name)" } else { Bad "$label : Kind Installer -> $($i.Name)" }
    if ($l.Name -like '*.locale*.yaml')                                     { Ok "$label : Kind Locale    -> $($l.Name)" } else { Bad "$label : Kind Locale -> $($l.Name)" }
    if ($v.Name -notlike '*.installer.yaml' -and $v.Name -notlike '*.locale*.yaml') { Ok "$label : Kind Version   -> $($v.Name)" } else { Bad "$label : Kind Version -> $($v.Name)" }
}

# A single-manifest folder (hand-made project / older capture) must still resolve for every Kind.
$dirSingle = Join-Path $tmpRoot 'C_single'
New-Item -ItemType Directory -Path $dirSingle -Force | Out-Null
Write-Manifest (Join-Path $dirSingle 'Contoso.Editor.yaml') ($versionYaml + "`n" + $installerYaml)
$s = @(
    (Get-WingetManifestFile -Path $dirSingle -Kind Installer),
    (Get-WingetManifestFile -Path $dirSingle -Kind Locale),
    (Get-WingetManifestFile -Path $dirSingle -Kind Version)
)
if (@($s | Where-Object { $_ }).Count -eq 3) { Ok 'a single-manifest folder still resolves for every Kind (falls back, never returns nothing)' }
else { Bad 'single-manifest folder returned $null for some Kind' }

# An empty / missing folder must be $null, not an error.
$dirEmpty = Join-Path $tmpRoot 'D_empty'
New-Item -ItemType Directory -Path $dirEmpty -Force | Out-Null
if ($null -eq (Get-WingetManifestFile -Path $dirEmpty)) { Ok 'no manifests -> $null' } else { Bad 'empty folder did not return $null' }
if ($null -eq (Get-WingetManifestFile -Path (Join-Path $tmpRoot 'does-not-exist'))) { Ok 'missing folder -> $null (no throw)' } else { Bad 'missing folder did not return $null' }

# ══ 2. Installer fields come from the INSTALLER manifest ══════════════════════════════════════════
Write-Host '[2] Get-YAMLInstallerInfo: installer data is read from *.installer.yaml' -ForegroundColor Cyan

foreach ($d in @($dirA, $dirB)) {
    $label = Split-Path $d -Leaf
    $info  = Get-YAMLInstallerInfo -FilesPath $d
    if (-not $info) { Bad "$label : returned null"; continue }

    if ($info.InstallerType -eq 'inno')                    { Ok "$label : InstallerType = inno"        } else { Bad "$label : InstallerType = '$($info.InstallerType)' (decoy/null?)" }
    if ($info.Architecture  -eq 'x64')                     { Ok "$label : Architecture  = x64"         } else { Bad "$label : Architecture = '$($info.Architecture)'" }
    if ($info.Scope         -eq 'machine')                 { Ok "$label : Scope         = machine"     } else { Bad "$label : Scope = '$($info.Scope)'" }
    if ($info.InstallerLocale -eq 'en-US')                 { Ok "$label : InstallerLocale = en-US"     } else { Bad "$label : InstallerLocale = '$($info.InstallerLocale)'" }
    if ($info.SilentArgs    -eq '/VERYSILENT /NORESTART /SP-') { Ok "$label : SilentArgs = the installer manifest's" } else { Bad "$label : SilentArgs = '$($info.SilentArgs)'" }
    # Installer-identity PR 3b (L21): the switches that are RUN have one reader (ConvertFrom-Win32ToolkitWingetManifest,
    # through Download-OldVersionInstaller, [5]); this reader has no second, different reading of Custom.
    if (-not $info.ContainsKey('CustomArgs')) { Ok "$label : no CustomArgs here (the Custom switches that are run are read in [5])" } else { Bad "$label : CustomArgs = '$($info.CustomArgs)'" }
    if ($info.ProductCode -match '11111111-2222-3333-4444-555555555555') { Ok "$label : ProductCode from the installer manifest" } else { Bad "$label : ProductCode = '$($info.ProductCode)'" }

    # …and NONE of the decoys planted in the locale manifest leaked in.
    $leaked = @($info.Values | Where-Object { $_ -and ($_ -match 'DECOY') })
    if ($leaked.Count -eq 0) { Ok "$label : no DECOY value from the locale manifest leaked into the installer fields" }
    else { Bad "$label : leaked decoys -> $($leaked -join ', ')" }
}

# ══ 3. Display strings come from the LOCALE manifest, UTF-8 intact ════════════════════════════════
Write-Host '[3] Get-YAMLInstallerInfo: PackageName/Publisher/Description come from the locale manifest (UTF-8)' -ForegroundColor Cyan

foreach ($d in @($dirA, $dirB)) {
    $label = Split-Path $d -Leaf
    $info  = Get-YAMLInstallerInfo -FilesPath $d

    # The old code, reading only the installer manifest (fixture A's first file), returned $null here —
    # Publish-Win32ToolkitIntuneApp then shipped the app to Intune as publisher 'Unknown'.
    if ($info.Publisher   -eq 'Nagüi Softwäre')  { Ok "$label : Publisher   = 'Nagüi Softwäre' (non-ASCII round-trips)" } else { Bad "$label : Publisher = '$($info.Publisher)'" }
    if ($info.PackageName -eq 'Cöntoso Editör')  { Ok "$label : PackageName = 'Cöntoso Editör' (non-ASCII round-trips)" } else { Bad "$label : PackageName = '$($info.PackageName)'" }
    if ($info.Description -eq 'A tiny editor for büsy people.') { Ok "$label : ShortDescription read, non-ASCII intact" } else { Bad "$label : Description = '$($info.Description)'" }
    if ($info.InformationUrl -eq 'https://package.invalid/editor') { Ok "$label : InformationUrl = PackageUrl" } else { Bad "$label : InformationUrl = '$($info.InformationUrl)'" }
    if ($info.PackageVersion -eq '2.1.0') { Ok "$label : PackageVersion = 2.1.0" } else { Bad "$label : PackageVersion = '$($info.PackageVersion)'" }

    # Guard the actual mojibake shape: a UTF-8 'ü' decoded as Windows-1252 becomes 'Ã¼'.
    if ($info.Publisher -notmatch 'Ã') { Ok "$label : no mojibake (the manifest is decoded as UTF-8)" } else { Bad "$label : mojibake -> '$($info.Publisher)'" }
}

# ══ 4. Get-WingetIdFromProject still finds the PackageIdentifier ══════════════════════════════════
Write-Host '[4] Get-WingetIdFromProject: deterministic pick, id still found' -ForegroundColor Cyan

foreach ($d in @($dirA, $dirB, $dirSingle)) {
    $label = Split-Path $d -Leaf
    $id    = Get-WingetIdFromProject -FilesPath $d
    if ($id -eq 'Contoso.Editor') { Ok "$label : PackageIdentifier = Contoso.Editor" } else { Bad "$label : PackageIdentifier = '$id'" }
}

# No version manifest at all (installer + locale only) — the id must still be found via the fallback.
$dirNoVer = Join-Path $tmpRoot 'E_no_version_manifest'
New-Item -ItemType Directory -Path $dirNoVer -Force | Out-Null
Write-Manifest (Join-Path $dirNoVer 'Contoso.Editor.installer.yaml')    $installerYaml
Write-Manifest (Join-Path $dirNoVer 'Contoso.Editor.locale.en-US.yaml') $localeYaml
if ((Get-WingetIdFromProject -FilesPath $dirNoVer) -eq 'Contoso.Editor') { Ok 'no version manifest: falls through to the other manifests and still finds the id' }
else { Bad 'id not found when there is no version manifest' }
if ($null -eq (Get-WingetIdFromProject -FilesPath $dirEmpty)) { Ok 'no manifests -> $null' } else { Bad 'empty folder did not return $null' }

# ══ 5. Download-OldVersionInstaller reads the installer manifest too ══════════════════════════════
Write-Host '[5] Download-OldVersionInstaller: baseline silent args come from *.installer.yaml' -ForegroundColor Cyan

# Shadow winget: write the same 3-manifest set (locale first) + a fake installer into the download dir.
function winget {
    $a   = @($args)
    $idx = [array]::IndexOf($a, '--download-directory')
    $dir = $a[$idx + 1]
    Write-Manifest (Join-Path $dir 'Contoso.Editor.default.locale.en-US.yaml') $localeYaml
    Write-Manifest (Join-Path $dir 'Contoso.Editor.installer.yaml')            $script:p1Installer
    Write-Manifest (Join-Path $dir 'Contoso.Editor.yaml')                      $versionYaml
    Set-Content -LiteralPath (Join-Path $dir 'CoentosoEditorSetup.exe') -Value 'MZ'
    $global:LASTEXITCODE = 0
}

$script:p1Installer = $installerYaml
$proj = Join-Path $tmpRoot 'proj'
$dest = Join-Path $proj 'Sandbox\Dependencies\Contoso.Editor'
New-Item -ItemType Directory -Path $dest -Force | Out-Null

$baseline = Download-OldVersionInstaller -AppId 'Contoso.Editor' -Version '2.1.0' -ProjectPath $proj -DestinationDir $dest 6>$null 3>$null

if ($baseline.InstallerName -eq 'CoentosoEditorSetup.exe') { Ok 'the downloaded installer is located' } else { Bad "InstallerName = '$($baseline.InstallerName)'" }
# The manifest InstallerType ('inno') and the manifest Silent switches both live in *.installer.yaml.
# Old code took the locale manifest -> no InstallerType, no Silent -> it GUESSED '/S' for the baseline
# install, which silently makes the whole Update test inconclusive (an Inno setup ignores /S).
# Installer-identity PR 3b (L21): winget appends the manifest's Custom switches after the silent ones.
if ($baseline.SilentArgs -eq '/VERYSILENT /NORESTART /SP- /LOG' -and $baseline.SilentArgsSource -eq 'manifest-silent+custom' -and $baseline.CustomArgs -eq '/LOG') { Ok "SilentArgs = '/VERYSILENT /NORESTART /SP- /LOG' (the installer manifest's Silent plus its Custom, as winget composes them; not a '/S' guess)" }
else { Bad "SilentArgs = '$($baseline.SilentArgs)' source '$($baseline.SilentArgsSource)'" }
if (@($baseline.ManifestPath).Count -eq 3 -and @($baseline.ManifestPath | Where-Object { $_ -like '*.installer.yaml' }).Count -eq 1) { Ok 'ManifestPath lists the downloaded manifests' } else { Bad "ManifestPath: $(@($baseline.ManifestPath) -join ', ')" }

# Installer-identity PR 3b (L21): the switches that are RUN are read as YAML reads them (ConvertFrom-Win32ToolkitWingetManifest):
# one pair of quotes removed, double-quoted escapes decoded, a trailing comment dropped. winget's own writer double-quotes
# (with escapes) any value it cannot write plain, and the downloaded manifest is the one these switches come from.
$switchManifest = {
    param([string]$Silent, [string]$Custom)
    "PackageIdentifier: Contoso.Editor`nPackageVersion: 2.1.0`nInstallers:`n- Architecture: x64`n  InstallerType: inno`n  Scope: machine`n" +
    "  InstallerSha256: 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF`n  InstallerSwitches:`n    Silent: $Silent`n    Custom: $Custom`nManifestType: installer`nManifestVersion: 1.6.0`n"
}
$switchCases = @(
    @{ L = 'a quoted Silent and a double-quoted Custom'; Silent = "'/VERYSILENT /NORESTART'"; Custom = '"/ALLUSERS"'; S = '/VERYSILENT /NORESTART /ALLUSERS'; C = '/ALLUSERS' }
    @{ L = 'a double-quoted Custom with an escaped backslash'; Silent = '/VERYSILENT'; Custom = '"/D=C:\\x"'; S = '/VERYSILENT /D=C:\x'; C = '/D=C:\x' }
    @{ L = 'a double-quoted Custom with escaped quotes'; Silent = '/VERYSILENT'; Custom = '"/DIR=\"C:\\X\""'; S = '/VERYSILENT /DIR="C:\X"'; C = '/DIR="C:\X"' }
    @{ L = 'a double-quoted Custom with escaped quotes and a second switch'; Silent = '"/VERYSILENT"'; Custom = '"/DIR=\"C:\\Program Files\\X\" /LOG" # a comment'; S = '/VERYSILENT /DIR="C:\Program Files\X" /LOG'; C = '/DIR="C:\Program Files\X" /LOG' }
    @{ L = "a single-quoted Custom ('' inside, a quote in its trailing comment)"; Silent = '/VERYSILENT'; Custom = "'INSTALLDIR=""C:\Program Files\X"" TAG=''a #b''' # the comment's quote ' is not part of it"; S = '/VERYSILENT INSTALLDIR="C:\Program Files\X" TAG=''a #b'''; C = 'INSTALLDIR="C:\Program Files\X" TAG=''a #b''' }
    @{ L = 'a plain Custom with a trailing comment (a # inside a word stays)'; Silent = '/VERYSILENT'; Custom = '/ALLUSERS /TAG=a#b   # machine-wide'; S = '/VERYSILENT /ALLUSERS /TAG=a#b'; C = '/ALLUSERS /TAG=a#b' }
)
foreach ($sc in $switchCases) {
    $script:p1Installer = & $switchManifest $sc.Silent $sc.Custom
    $b = Download-OldVersionInstaller -AppId 'Contoso.Editor' -Version '2.1.0' -ProjectPath $proj -DestinationDir $dest 6>$null 3>$null
    if ($b.SilentArgs -ceq $sc.S -and $b.CustomArgs -ceq $sc.C -and $b.SilentArgsSource -eq 'manifest-silent+custom') { Ok "$($sc.L) -> SilentArgs [$($b.SilentArgs)]" }
    else { Bad "$($sc.L): SilentArgs [$($b.SilentArgs)] CustomArgs [$($b.CustomArgs)] source '$($b.SilentArgsSource)'" }
}
# The AppConfig contract (PR 1, L8) is unchanged: Get-YAMLInstallerInfo still returns the quoted Silent as written.
$script:p1Installer = & $switchManifest "'/VERYSILENT /NORESTART'" '/LOG'
$b = Download-OldVersionInstaller -AppId 'Contoso.Editor' -Version '2.1.0' -ProjectPath $proj -DestinationDir $dest 6>$null 3>$null
$asWritten = (Get-YAMLInstallerInfo -FilesPath $dest).SilentArgs
if ($asWritten -ceq "'/VERYSILENT /NORESTART'" -and $b.SilentArgs -ceq '/VERYSILENT /NORESTART /LOG') { Ok "Get-YAMLInstallerInfo.SilentArgs stays as written ('/VERYSILENT /NORESTART' in quotes, for AppConfig); the baseline runs it unquoted" } else { Bad "as written [$asWritten], run [$($b.SilentArgs)]" }

# Several installers (a hand-made manifest; winget download writes only the one it chose): the downloaded architecture's.
$script:p1Installer = "PackageIdentifier: Contoso.Editor`nPackageVersion: 2.1.0`nInstallers:`n- Architecture: x86`n  InstallerType: inno`n  InstallerSwitches:`n    Silent: /VERYSILENT /TAG=x86`n" +
    "- Architecture: x64`n  InstallerType: inno`n  InstallerSwitches:`n    Silent: /VERYSILENT /TAG=x64`nManifestType: installer`n"
$b = Download-OldVersionInstaller -AppId 'Contoso.Editor' -Version '2.1.0' -ProjectPath $proj -DestinationDir $dest -Architecture x64 6>$null 3>$null
if ($b.SilentArgs -ceq '/VERYSILENT /TAG=x64') { Ok 'a manifest with several installers: the switches of the downloaded architecture' } else { Bad "several installers: [$($b.SilentArgs)]" }

# Fallback: a manifest the reader cannot read (no 'Installers:' list) keeps the PR 1 behaviour - Silent as written, no Custom.
$script:p1Installer = "PackageIdentifier: Contoso.Editor`nPackageVersion: 2.1.0`nInstallerType: inno`nInstallerSwitches:`n  Silent: /VERYSILENT /SP-`n  Custom: /LOG`n"
$b = Download-OldVersionInstaller -AppId 'Contoso.Editor' -Version '2.1.0' -ProjectPath $proj -DestinationDir $dest 6>$null 3>$null
if ($b.SilentArgs -ceq '/VERYSILENT /SP-' -and $b.SilentArgsSource -eq 'manifest-silent' -and $b.CustomArgs -eq '') { Ok "no 'Installers:' list: Get-YAMLInstallerInfo's Silent, no Custom (as before PR 3b)" } else { Bad "fallback: [$($b.SilentArgs)] '$($b.SilentArgsSource)' [$($b.CustomArgs)]" }
$script:p1Installer = $installerYaml

# ══ 6. Every manifest read pins the encoding ══════════════════════════════════════════════════════
Write-Host '[6] Every Get-Content of a manifest specifies -Encoding UTF8 (AST-verified)' -ForegroundColor Cyan

$sources = @(
    'Private\Get-WingetManifestFile.ps1',
    'Private\Get-YAMLInstallerInfo.ps1',
    'Private\Get-WingetIdFromProject.ps1',
    'Private\Download-OldVersionInstaller.ps1'
)
foreach ($rel in $sources) {
    $p    = Join-Path $repo $rel
    $ast  = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null)
    $gets = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -in @('Get-Content', 'gc')
    }, $true)

    $bare = @($gets | Where-Object {
        $names = $_.CommandElements |
            Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
            ForEach-Object { $_.ParameterName }
        $names -notcontains 'Encoding'
    })
    if ($bare.Count -eq 0) { Ok "$rel : $($gets.Count) Get-Content call(s), all with -Encoding" }
    else { Bad "$rel : $($bare.Count) Get-Content call(s) with no -Encoding (line $($bare[0].Extent.StartLineNumber))" }
}

# The three callers must go through the ONE helper — no lingering hand-rolled '*.yaml' picks.
# AST, not a text match: the doc comments legitimately QUOTE the old `Get-ChildItem '*.yaml'` line to
# explain the fix, and Download-OldVersionInstaller still uses Get-ChildItem for the installer file.
foreach ($rel in @('Private\Get-YAMLInstallerInfo.ps1', 'Private\Get-WingetIdFromProject.ps1', 'Private\Download-OldVersionInstaller.ps1')) {
    $p   = Join-Path $repo $rel
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null)
    $gci = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -in @('Get-ChildItem', 'gci', 'dir', 'ls') -and
        $n.Extent.Text -match '\.yaml'
    }, $true))
    $usesHelper = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Get-WingetManifestFile'
    }, $true)).Count -gt 0

    if ($usesHelper -and $gci.Count -eq 0) {
        Ok "$rel : selects the manifest via Get-WingetManifestFile (no local '*.yaml' pick)"
    } else { Bad "$rel : usesHelper=$usesHelper, own '*.yaml' Get-ChildItem call(s)=$($gci.Count)" }
}

# ══ 7. YAML quotes are stripped from installer facts and ids only (installer-identity PR 1, L8) ═══
Write-Host '[7] Get-YAMLInstallerInfo: one pair of YAML quotes is stripped from installer facts and ids, not from display strings' -ForegroundColor Cyan

# The assertion oracle only (the strict-GUID check the requirement fallback applies); the stripper itself
# is a scriptblock inside Get-YAMLInstallerInfo, so no production call edge is added (C-9).
. (Join-Path $repo 'Private\Test-Win32ToolkitProductCode.ps1')

$quotedInstaller = @'
PackageIdentifier: 'Contoso.Quoted'
PackageVersion: "5.1"
InstallerLocale: 'en-US'
Installers:
- Architecture: "x64"
  InstallerType: "wix"
  Scope: 'machine'
  UpgradeBehavior: install
  ProductCode: '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
  InstallerSwitches:
    Silent: '/quiet'
ManifestType: installer
ManifestVersion: 1.6.0
'@
$quotedLocale = @'
PackageIdentifier: 'Contoso.Quoted'
PackageVersion: "5.1"
PackageLocale: en-US
Publisher: 'O''Reilly'
PackageName: "X"
ShortDescription: 'Quoted ''description'''
PackageUrl: 'https://package.invalid/quoted'
ManifestType: defaultLocale
ManifestVersion: 1.6.0
'@
$dirQ = Join-Path $tmpRoot 'F_quoted'
New-Item -ItemType Directory -Path $dirQ -Force | Out-Null
Write-Manifest (Join-Path $dirQ 'Contoso.Quoted.installer.yaml')    $quotedInstaller
Write-Manifest (Join-Path $dirQ 'Contoso.Quoted.locale.en-US.yaml') $quotedLocale
$q = Get-YAMLInstallerInfo -FilesPath $dirQ

if ($q.ProductCode -ceq '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}') { Ok "ProductCode: '{GUID}' -> bare GUID" } else { Bad "ProductCode = [$($q.ProductCode)]" }
if (Test-Win32ToolkitProductCode -Value $q.ProductCode) { Ok 'the stripped ProductCode passes Test-Win32ToolkitProductCode (no longer dropped by the requirement fallback)' } else { Bad 'stripped ProductCode fails Test-Win32ToolkitProductCode' }
if ($q.Scope -ceq 'machine')        { Ok "Scope: 'machine' -> machine" }            else { Bad "Scope = [$($q.Scope)]" }
if ($q.InstallerType -ceq 'wix')    { Ok 'InstallerType: "wix" -> wix' }            else { Bad "InstallerType = [$($q.InstallerType)]" }
if ($q.Architecture -ceq 'x64')     { Ok 'Architecture: "x64" -> x64' }             else { Bad "Architecture = [$($q.Architecture)]" }
if ($q.PackageVersion -ceq '5.1')   { Ok 'PackageVersion: "5.1" -> 5.1' }           else { Bad "PackageVersion = [$($q.PackageVersion)]" }
if ($q.PackageIdentifier -ceq 'Contoso.Quoted') { Ok "PackageIdentifier: 'Contoso.Quoted' -> Contoso.Quoted" } else { Bad "PackageIdentifier = [$($q.PackageIdentifier)]" }
if ($q.InstallerLocale -ceq 'en-US') { Ok "InstallerLocale: 'en-US' -> en-US" }     else { Bad "InstallerLocale = [$($q.InstallerLocale)]" }
if ($q.UpgradeBehavior -ceq 'install') { Ok 'UpgradeBehavior: install is read (new field)' } else { Bad "UpgradeBehavior = [$($q.UpgradeBehavior)]" }
if ($q.ContainsKey('UpgradeBehavior')) { Ok 'the hashtable carries an UpgradeBehavior key' } else { Bad 'no UpgradeBehavior key' }

# Regression (L8): the display strings that feed App.Vendor / App.DisplayName (the tattoo key) are unchanged.
if ($q.Publisher -ceq "'O''Reilly'")   { Ok "Publisher: 'O''Reilly' comes back exactly as before (quotes kept)" } else { Bad "Publisher changed: [$($q.Publisher)]" }
if ($q.PackageName -ceq '"X"')         { Ok 'PackageName: "X" comes back exactly as before (quotes kept)' }     else { Bad "PackageName changed: [$($q.PackageName)]" }
if ($q.Description -ceq "'Quoted ''description'''") { Ok 'ShortDescription comes back exactly as before (quotes kept)' } else { Bad "Description changed: [$($q.Description)]" }
if ($q.InformationUrl -ceq "'https://package.invalid/quoted'") { Ok 'PackageUrl comes back exactly as before (quotes kept)' } else { Bad "InformationUrl changed: [$($q.InformationUrl)]" }
if ($q.SilentArgs -ceq "'/quiet'")     { Ok 'SilentArgs comes back exactly as before (quotes kept)' }           else { Bad "SilentArgs changed: [$($q.SilentArgs)]" }

# Single quotes: one pair only, a doubled '' inside becomes '; an unmatched quote is left alone.
$edge = @'
PackageIdentifier: Contoso.Edge
PackageVersion: '1.0''beta'
Installers:
- Architecture: x86
  InstallerType: 'nullsoft'
  Scope: "user"
  UpgradeBehavior: 'uninstallPrevious'
  ProductCode: "Contoso Edge"
  InstallerLocale: 'de-DE
'@
$dirE = Join-Path $tmpRoot 'G_quote_edges'
New-Item -ItemType Directory -Path $dirE -Force | Out-Null
Write-Manifest (Join-Path $dirE 'Contoso.Edge.installer.yaml') $edge
$e = Get-YAMLInstallerInfo -FilesPath $dirE
if ($e.PackageVersion -ceq "1.0'beta")         { Ok "PackageVersion: '1.0''beta' -> 1.0'beta ('' unescaped)" } else { Bad "PackageVersion = [$($e.PackageVersion)]" }
if ($e.InstallerType -ceq 'nullsoft')          { Ok "InstallerType: 'nullsoft' -> nullsoft" }   else { Bad "InstallerType = [$($e.InstallerType)]" }
if ($e.Scope -ceq 'user')                      { Ok 'Scope: "user" -> user' }                    else { Bad "Scope = [$($e.Scope)]" }
if ($e.UpgradeBehavior -ceq 'uninstallPrevious') { Ok "UpgradeBehavior: 'uninstallPrevious' -> uninstallPrevious" } else { Bad "UpgradeBehavior = [$($e.UpgradeBehavior)]" }
if ($e.ProductCode -ceq 'Contoso Edge')        { Ok 'ProductCode: "Contoso Edge" (non-GUID) -> Contoso Edge' } else { Bad "ProductCode = [$($e.ProductCode)]" }
if (-not (Test-Win32ToolkitProductCode -Value $e.ProductCode)) { Ok 'a non-GUID ProductCode still fails the strict GUID check' } else { Bad 'non-GUID ProductCode passed the GUID check' }
if ($e.InstallerLocale -ceq "'de-DE")          { Ok 'an unmatched quote is left alone' }        else { Bad "InstallerLocale = [$($e.InstallerLocale)]" }

# Unquoted values are unchanged (the existing fixture A).
$plain = Get-YAMLInstallerInfo -FilesPath $dirA
if ($plain.PackageVersion -ceq '2.1.0' -and $plain.InstallerType -ceq 'inno' -and $plain.Scope -ceq 'machine' -and $null -eq $plain.UpgradeBehavior) {
    Ok 'unquoted manifests read exactly as before (UpgradeBehavior $null when absent)'
} else { Bad "unquoted fixture changed: version=[$($plain.PackageVersion)] type=[$($plain.InstallerType)] scope=[$($plain.Scope)] upgrade=[$($plain.UpgradeBehavior)]" }

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P1_YamlManifest tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P1_YamlManifest test(s) FAILED." -ForegroundColor Red; exit 1 }
