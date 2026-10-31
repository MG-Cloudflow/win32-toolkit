<#
    Installer-identity PR 3b (spec 2.14.3, L21, SV19): ConvertFrom-Win32ToolkitWingetManifest reads every installer of
    a winget manifest - with its switches, codes, Apps and Features entries and default install location - from the
    public winget-pkgs manifests in Tests\Fixtures\winget-manifests (no network).

      [1] Notepad++ 8.8.9 - 8.9.8.1: the nullsoft installers (ProductCode 'Notepad++', DefaultInstallLocation), the WiX
          installer (a quoted GUID unquoted; the AFE UpgradeCode), the zip/portable ones (NestedInstallerType), the
          release date; installer-level and AFE codes kept apart.
      [2] KeePass 2.61.1: root Scope and ReleaseDate inherited; 'Custom: /ALLUSERS'; the MSI's AFE ProductCode and
          UpgradeCode. WinSCP 6.7: a double-quoted PackageVersion; two Inno installers with their own Custom; a root
          FileExtensions/Protocols list skipped.
      [3] Paint.NET 5.1.12: root InstallerType zip inherited, NestedInstallerType exe / wix, Silent '/auto', the AFE
          InstallerType. TeamViewer 15.82.6: a per-installer ReleaseDate.
      [4] a merged single-installer manifest (the shape 'winget download' writes): package facts, Silent and Custom, a
          block scalar skipped (a key inside it is never read); a separate locale file concatenated with '---'.
      [5] hostile or empty text: no Installers -> $null, never a throw; control characters neutralised; values capped
          at 256, the switches (a command line) at 2048 only; the source is ASCII-only; more than 32 nested levels ->
          $null (no deep recursion), 31 still read.
      [6] root keys inherited the way winget inherits them: OneDrive 26.153's root Silent kept for the machine installers
          that add only 'Custom: /allusers' (InstallerSwitches merged key by key); InstallationMetadata merged key by key;
          the root ProductCode and AppsAndFeaturesEntries not given to an msix installer; the root NestedInstallerType
          given to a zip installer only.
      [7] YAML scalars read as YAML reads them: a single-quoted value ends at its first lone quote (a quote inside a
          trailing comment is not part of it); double-quoted escapes decoded (\\, \", \x41, B; an unknown escape
          kept); an escape that decodes to a control character neutralised; an unterminated quote read as plain text.

    Run:  pwsh -File Tests\WingetManifestReader.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\ConvertFrom-Win32ToolkitWingetManifest.ps1')
$fx = Join-Path $repo 'Tests\Fixtures\winget-manifests'
function Read-Fixture([string]$Rel) { ConvertFrom-Win32ToolkitWingetManifest -Text ([IO.File]::ReadAllText((Join-Path $fx $Rel), [Text.Encoding]::UTF8)) }
function Pick($M, [string]$Arch, [string]$Type) { @($M.Installers | Where-Object { $_.Architecture -eq $Arch -and $_.InstallerType -eq $Type }) }

# == [1] Notepad++ ======================================================================================
Write-Host '[1] Notepad++ 8.8.9 - 8.9.8.1' -ForegroundColor Cyan
$versions = @('8.8.9', '8.9', '8.9.1', '8.9.5', '8.9.6.4', '8.9.7', '8.9.8', '8.9.8.1')
$bad = @()
foreach ($v in $versions) {
    $m = Read-Fixture "Notepad++.Notepad++\$v.installer.yaml"
    $n = @(Pick $m 'x64' 'nullsoft')
    if (-not $m -or $m.PackageIdentifier -ne 'Notepad++.Notepad++' -or $m.PackageVersion -ne $v -or $m.ReleaseDate -notmatch '^\d{4}-\d{2}-\d{2}$' -or $n.Count -ne 1 -or
        $n[0].ProductCode -ne 'Notepad++' -or $n[0].Scope -ne 'machine' -or $n[0].DefaultInstallLocation -notlike '%ProgramFiles*\Notepad++') { $bad += $v }
}
if ($bad.Count -eq 0) { Ok "every version: package id and version, the release date, one x64 nullsoft installer (ProductCode Notepad++, machine, DefaultInstallLocation)" } else { Bad "versions: $($bad -join ', ')" }
$m = Read-Fixture 'Notepad++.Notepad++\8.9.8.1.installer.yaml'
$w = @(Pick $m 'x64' 'wix')
if ($m.Installers.Count -eq 7 -and $w.Count -eq 1 -and $w[0].ProductCode -ceq '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}' -and @($w[0].AppsAndFeaturesEntries).Count -eq 1 -and
    $w[0].AppsAndFeaturesEntries[0].UpgradeCode -ceq '{CDB13460-04DF-4708-A7FD-4CB4A0684605}' -and $w[0].AppsAndFeaturesEntries[0].ProductCode -eq '' -and $w[0].UpgradeCode -eq '') {
    Ok '8.9.8.1: 7 installers; the WiX ProductCode unquoted; the AFE UpgradeCode kept apart from the installer-level codes'
} else { Bad "8.9.8.1 wix: $($w | ConvertTo-Json -Depth 4 -Compress)" }
$z = @($m.Installers | Where-Object InstallerType -eq 'zip')
if ($z.Count -eq 3 -and @($z | Where-Object NestedInstallerType -ne 'portable').Count -eq 0 -and $m.ReleaseDate -eq '2026-09-24') { Ok 'the zip installers carry NestedInstallerType portable; ReleaseDate 2026-09-24' } else { Bad "zip: $($z | ConvertTo-Json -Depth 3 -Compress)" }
if ((@(Pick $m 'x86' 'nullsoft')[0]).DefaultInstallLocation -ceq '%ProgramFiles(x86)%\Notepad++') { Ok "the x86 installer's own DefaultInstallLocation (InstallationMetadata)" } else { Bad 'x86 location' }
if (@($m.Installers | Where-Object { $_.InstallerSwitches.Silent -or $_.InstallerSwitches.Custom }).Count -eq 0) { Ok 'no Silent/Custom where the manifest has none (InstallLocation is not read as either)' } else { Bad 'switches leaked' }

# == [2] KeePass, WinSCP ================================================================================
Write-Host '[2] KeePass 2.61.1, WinSCP 6.7' -ForegroundColor Cyan
$k = Read-Fixture 'DominikReichl.KeePass\2.61.1.installer.yaml'
$ki = @(Pick $k 'x64' 'inno')[0]; $km = @(Pick $k 'x64' 'msi')[0]
if ($k.Installers.Count -eq 6 -and @($k.Installers | Where-Object Scope -ne 'machine').Count -eq 0 -and @($k.Installers | Where-Object ReleaseDate -ne '2026-05-01').Count -eq 0) { Ok 'root Scope machine and ReleaseDate inherited by all 6 installers' } else { Bad "keepass inherit: $($k.Installers | Select-Object Architecture, InstallerType, Scope, ReleaseDate | ConvertTo-Json -Compress)" }
if ($ki.InstallerSwitches.Custom -ceq '/ALLUSERS' -and $ki.InstallerSwitches.Silent -eq '' -and $ki.ProductCode -ceq 'KeePassPasswordSafe2_is1') { Ok "Inno: 'Custom: /ALLUSERS', no Silent, ProductCode KeePassPasswordSafe2_is1" } else { Bad "keepass inno: $($ki | ConvertTo-Json -Depth 3 -Compress)" }
if ($km.ProductCode -ceq '{33F0E718-1110-4F95-A59B-230A62C02DE5}' -and $km.AppsAndFeaturesEntries[0].ProductCode -ceq '{33F0E718-1110-4F95-A59B-230A62C02DE5}' -and $km.AppsAndFeaturesEntries[0].UpgradeCode -ceq '{F2F19898-4F86-4940-9BFA-426574CE03E1}' -and $km.InstallerSwitches.Custom -eq '') { Ok 'MSI: installer-level and AFE ProductCode, the AFE UpgradeCode; no Custom' } else { Bad "keepass msi: $($km | ConvertTo-Json -Depth 3 -Compress)" }
$s = Read-Fixture 'WinSCP.WinSCP\6.7.installer.yaml'
$su = @($s.Installers | Where-Object { $_.InstallerType -eq 'inno' -and $_.Scope -eq 'user' })[0]; $sm = @($s.Installers | Where-Object { $_.InstallerType -eq 'inno' -and $_.Scope -eq 'machine' })[0]
if ($s.PackageVersion -ceq '6.7' -and $su.InstallerSwitches.Custom -ceq '/CURRENTUSER' -and $sm.InstallerSwitches.Custom -ceq '/ALLUSERS' -and $s.Installers.Count -eq 3) { Ok 'WinSCP: "6.7" unquoted; each Inno installer its own Custom (/CURRENTUSER, /ALLUSERS); the Protocols list skipped' } else { Bad "winscp: $($s | ConvertTo-Json -Depth 4 -Compress)" }
if ((@(Pick $s 'x86' 'wix')[0]).DefaultInstallLocation -ceq '%ProgramFiles(x86)%/WinSCP') { Ok 'a DefaultInstallLocation is returned as written (no normalisation here)' } else { Bad 'winscp location' }

# == [3] Paint.NET, TeamViewer ==========================================================================
Write-Host '[3] Paint.NET 5.1.12, TeamViewer 15.82.6' -ForegroundColor Cyan
$p = Read-Fixture 'dotPDN.PaintDotNet\5.1.12.installer.yaml'
$pe = @($p.Installers | Where-Object { $_.Architecture -eq 'x64' -and $_.NestedInstallerType -eq 'exe' })[0]
if (@($p.Installers | Where-Object InstallerType -ne 'zip').Count -eq 0 -and $pe.InstallerSwitches.Silent -ceq '/auto' -and $pe.AppsAndFeaturesEntries[0].InstallerType -eq 'wix' -and $pe.Scope -eq 'machine') { Ok 'root InstallerType zip inherited; the zipped EXE: Silent /auto, AFE InstallerType wix' } else { Bad "paint.net: $($pe | ConvertTo-Json -Depth 4 -Compress)" }
$t = Read-Fixture 'TeamViewer.TeamViewer\15.82.6.installer.yaml'
if ((@(Pick $t 'x64' 'nullsoft')[0]).ReleaseDate -eq '2026-09-29' -and (@($t.Installers | Where-Object { $_.Architecture -eq 'x64' -and $_.InstallerType -eq 'zip' })[0]).ReleaseDate -eq '2026-09-22' -and $t.ReleaseDate -eq '') { Ok 'a per-installer ReleaseDate (no root one: the package ReleaseDate stays empty)' } else { Bad "teamviewer dates: $($t.Installers | Select-Object InstallerType, ReleaseDate | ConvertTo-Json -Compress)" }

# == [4] merged and multi-document ======================================================================
Write-Host '[4] the merged manifest winget download writes; a separate locale file' -ForegroundColor Cyan
$g = Read-Fixture 'Notepad++.Notepad++\merged-8.9.8.1.yaml'
if ($g.PackageName -eq 'Notepad++' -and $g.Publisher -eq 'Notepad++ Team' -and $g.Installers.Count -eq 1 -and $g.Installers[0].InstallerSwitches.Silent -ceq '/S' -and $g.Installers[0].InstallerSwitches.Custom -ceq '/noUpdater' -and $g.Installers[0].InstallerSwitches.SilentWithProgress -ceq '/S') { Ok 'merged: package facts, one installer, Silent / SilentWithProgress / Custom' } else { Bad "merged: $($g | ConvertTo-Json -Depth 4 -Compress)" }
if ($g.Installers[0].InstallerType -eq 'nullsoft' -and -not ($g | ConvertTo-Json -Depth 5).Contains('decoy')) { Ok 'a key inside a block scalar (Description: |-) is never read' } else { Bad 'block scalar read' }
$both = [IO.File]::ReadAllText((Join-Path $fx 'Notepad++.Notepad++\8.9.8.1.locale.en-US.yaml')) + "`n---`n" + [IO.File]::ReadAllText((Join-Path $fx 'Notepad++.Notepad++\8.9.8.1.installer.yaml'))
$b = ConvertFrom-Win32ToolkitWingetManifest -Text $both
if ($b.PackageName -eq 'Notepad++' -and $b.Publisher -eq 'Notepad++ Team' -and $b.Installers.Count -eq 7 -and $b.ReleaseDate -eq '2026-09-24') { Ok "locale + installer joined with '---': names from the locale document, installers from the installer document" } else { Bad "two docs: $($b | Select-Object PackageName, Publisher, ReleaseDate | ConvertTo-Json -Compress) / $(@($b.Installers).Count)" }

# == [5] hostile ========================================================================================
Write-Host '[5] hostile or empty text' -ForegroundColor Cyan
$nulls = @('', '   ', 'PackageIdentifier: X', "Installers:`n", ":::`n- - -`n[[[", ('A: ' + ('x' * 100000)))
$r = @(foreach ($n in $nulls) { try { , (ConvertFrom-Win32ToolkitWingetManifest -Text $n) } catch { 'THREW' } })
if (@($r | Where-Object { $null -ne $_ }).Count -eq 0) { Ok 'no Installers list (empty, junk, a huge line) -> $null, never a throw' } else { Bad "hostile: $($r | ConvertTo-Json -Compress -Depth 2)" }
$e = [char]0x1B; $bidi = [char]0x202E
$h = ConvertFrom-Win32ToolkitWingetManifest -Text "PackageIdentifier: A.B`nPublisher: Evil${e}[2J${bidi}Corp`nInstallers:`n- Architecture: x64`n  InstallerType: nullsoft`n  ProductCode: '$('k' * 600)'`n  InstallerSwitches:`n    Custom: /S`$(calc)`n"
if ($h -and -not $h.Publisher.Contains([string]$e) -and -not $h.Publisher.Contains([string]$bidi) -and $h.Installers[0].ProductCode.Length -le 256 -and $h.Installers[0].InstallerSwitches.Custom -ceq '/S$(calc)') { Ok 'control and bidi characters neutralised, values capped at 256, nothing evaluated (a $(...) stays text)' } else { Bad "neutralise: $($h | ConvertTo-Json -Depth 4 -Compress)" }
# The switches are a command line (Download-OldVersionInstaller runs them): kept whole up to winget-pkgs' longest (Custom
# 2048), never cut at 256; longer is capped at 2048.
$long = '/D=' + ('x' * 597)
$huge = '/D=' + ('y' * 2997)
$lw = ConvertFrom-Win32ToolkitWingetManifest -Text "Installers:`n- Architecture: x64`n  InstallerType: inno`n  InstallerSwitches:`n    Silent: $long`n    Custom: $long`n    SilentWithProgress: $long`n- Architecture: x86`n  InstallerType: inno`n  InstallerSwitches:`n    Custom: $huge`n"
if ($lw.Installers[0].InstallerSwitches.Custom -ceq $long -and $lw.Installers[0].InstallerSwitches.Silent -ceq $long -and $lw.Installers[0].InstallerSwitches.SilentWithProgress -ceq $long -and $lw.Installers[1].InstallerSwitches.Custom.Length -eq 2048) { Ok 'switch values: 600 characters kept whole (Silent, SilentWithProgress, Custom); 3000 capped at 2048' } else { Bad "switch cap: $($lw.Installers[0].InstallerSwitches.Custom.Length) / $($lw.Installers[1].InstallerSwitches.Custom.Length)" }
if (@([IO.File]::ReadAllBytes((Join-Path $repo 'Private\ConvertFrom-Win32ToolkitWingetManifest.ps1')) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'the reader is ASCII-only' } else { Bad 'non-ASCII bytes' }
$deep = @('Installers:', '- Architecture: x64', '  InstallerType: nullsoft', '  Deep:') + @(1..300 | ForEach-Object { (' ' * (2 + 2 * $_)) + "k${_}:" })
$sw = [Diagnostics.Stopwatch]::StartNew()
$d = $null; $threw = $false
try { $d = ConvertFrom-Win32ToolkitWingetManifest -Text ($deep -join "`n") } catch { $threw = $true }
$ok31 = ConvertFrom-Win32ToolkitWingetManifest -Text ((@('Installers:', '- Architecture: x64', '  InstallerType: nullsoft', '  Deep:') + @(1..30 | ForEach-Object { (' ' * (2 + 2 * $_)) + "k${_}:" })) -join "`n")
if (-not $threw -and $null -eq $d -and $sw.Elapsed.TotalSeconds -lt 10 -and $ok31.Installers[0].InstallerType -eq 'nullsoft') { Ok "300 nested levels -> `$null in $([int]$sw.Elapsed.TotalMilliseconds) ms (no deep recursion); 31 levels still read" } else { Bad "deep: threw=$threw null=$($null -eq $d) seconds=$($sw.Elapsed.TotalSeconds) ok31=$($null -ne $ok31)" }

# == [6] inheritance as winget does it ==================================================================
Write-Host '[6] root keys inherited the way winget inherits them' -ForegroundColor Cyan
$o = Read-Fixture 'Microsoft.OneDrive\26.153.0809.0004.installer.yaml'
$om = @($o.Installers | Where-Object { $_.Architecture -eq 'x64' -and $_.Scope -eq 'machine' })[0]
$ou = @($o.Installers | Where-Object { $_.Architecture -eq 'x64' -and $_.Scope -eq 'user' })[0]
if ($om.InstallerSwitches.Silent -ceq '/silent' -and $om.InstallerSwitches.SilentWithProgress -ceq '/silent' -and $om.InstallerSwitches.Custom -ceq '/allusers') { Ok "OneDrive machine installer: the root Silent kept next to its own 'Custom: /allusers' (merged key by key, as winget runs '/silent /allusers')" } else { Bad "onedrive machine: $($om.InstallerSwitches | ConvertTo-Json -Compress)" }
if ($ou.InstallerSwitches.Silent -ceq '/silent' -and $ou.InstallerSwitches.Custom -eq '' -and $ou.ProductCode -ceq 'OneDriveSetup.exe' -and $ou.ReleaseDate -eq '2026-08-25' -and $o.Installers.Count -eq 6) { Ok 'OneDrive user installer: the root switches, ProductCode (exe) and ReleaseDate' } else { Bad "onedrive user: $($ou | ConvertTo-Json -Depth 3 -Compress)" }
$inh = ConvertFrom-Win32ToolkitWingetManifest -Text (@(
        'PackageIdentifier: Contoso.Inherit', 'PackageVersion: 1.0', 'ProductCode: Contoso Inherit', 'NestedInstallerType: exe',
        'InstallerSwitches:', '  Silent: /quiet', 'InstallationMetadata:', '  DefaultInstallLocation: ''%ProgramFiles%\Contoso''',
        'AppsAndFeaturesEntries:', '- DisplayName: Contoso Inherit', '  Publisher: Contoso',
        'Installers:',
        '- Architecture: x64', '  InstallerType: msix', '  InstallerSwitches:', '    Custom: /x',
        '- Architecture: x64', '  InstallerType: zip', '  InstallationMetadata:', '    Files:', '    - RelativeFilePath: app.exe',
        '- Architecture: x86', '  InstallerType: nullsoft', '  ProductCode: Contoso Inherit x86', '  InstallerSwitches:', '    Silent: /S'
    ) -join "`n")
$ix = @($inh.Installers | Where-Object InstallerType -eq 'msix')[0]; $iz = @($inh.Installers | Where-Object InstallerType -eq 'zip')[0]; $in = @($inh.Installers | Where-Object InstallerType -eq 'nullsoft')[0]
if ($ix.ProductCode -eq '' -and @($ix.AppsAndFeaturesEntries).Count -eq 0 -and $ix.NestedInstallerType -eq '' -and $ix.InstallerSwitches.Silent -ceq '/quiet' -and $ix.InstallerSwitches.Custom -ceq '/x') { Ok 'msix: no root ProductCode / Apps and Features entries, no NestedInstallerType; root Silent + its own Custom' } else { Bad "msix: $($ix | ConvertTo-Json -Depth 4 -Compress)" }
if ($iz.NestedInstallerType -eq 'exe' -and $iz.ProductCode -ceq 'Contoso Inherit' -and @($iz.AppsAndFeaturesEntries).Count -eq 1 -and $iz.DefaultInstallLocation -ceq '%ProgramFiles%\Contoso') { Ok 'zip: the root NestedInstallerType (exe), so the root ProductCode and Apps and Features entry; InstallationMetadata merged (its own Files, the root DefaultInstallLocation)' } else { Bad "zip: $($iz | ConvertTo-Json -Depth 4 -Compress)" }
if ($in.ProductCode -ceq 'Contoso Inherit x86' -and $in.InstallerSwitches.Silent -ceq '/S' -and $in.NestedInstallerType -eq '' -and @($in.AppsAndFeaturesEntries).Count -eq 1) { Ok "nullsoft: its own ProductCode and Silent win; no NestedInstallerType (not an archive); the root Apps and Features entry" } else { Bad "nullsoft: $($in | ConvertTo-Json -Depth 4 -Compress)" }

# == [7] YAML scalars ===================================================================================
Write-Host '[7] YAML scalars read as YAML reads them' -ForegroundColor Cyan
$q = ConvertFrom-Win32ToolkitWingetManifest -Text (@(
        'PackageIdentifier: Contoso.Quotes', "Publisher: 'It''s Contoso' # don't read this", 'Installers:',
        '- Architecture: x64', '  InstallerType: inno', '  ProductCode: "Contoso\x41\u0042_is1"   # a comment',
        '  InstallerSwitches:', '    Custom: "/DIR=\"C:\\Program Files\\Contoso\" /LOG"', '    Silent: "/VERYSILENT \q"',
        '    SilentWithProgress: ''unterminated', '  InstallationMetadata:', '    DefaultInstallLocation: "%ProgramFiles%\\Contoso"',
        '- Architecture: x86', '  InstallerType: inno', '  ProductCode: "Evil\u001B[2J\u202ECorp"'
    ) -join "`n")
$q1 = $q.Installers[0]
if ($q.Publisher -ceq "It's Contoso") { Ok "single-quoted: '' is one quote; a quote inside the trailing comment is not part of the value" } else { Bad "single: [$($q.Publisher)]" }
if ($q1.InstallerSwitches.Custom -ceq '/DIR="C:\Program Files\Contoso" /LOG' -and $q1.DefaultInstallLocation -ceq '%ProgramFiles%\Contoso' -and $q1.ProductCode -ceq 'ContosoAB_is1') { Ok 'double-quoted: \\ \" \x41 \u0042 decoded; the trailing comment dropped' } else { Bad "double: [$($q1.InstallerSwitches.Custom)] [$($q1.DefaultInstallLocation)] [$($q1.ProductCode)]" }
if ($q1.InstallerSwitches.Silent -ceq '/VERYSILENT \q' -and $q1.InstallerSwitches.SilentWithProgress -ceq "'unterminated") { Ok 'an unknown escape is kept as written; an unterminated quote is read as plain text' } else { Bad "kept: [$($q1.InstallerSwitches.Silent)] [$($q1.InstallerSwitches.SilentWithProgress)]" }
$q2 = $q.Installers[1].ProductCode
if ($q2 -like 'Evil*Corp' -and -not $q2.Contains([string][char]0x1B) -and -not $q2.Contains([string][char]0x202E)) { Ok 'an escape that decodes to a control or bidi character is neutralised (ConvertTo-Win32ToolkitSafeText)' } else { Bad "escaped control: [$q2]" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All WingetManifestReader tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail WingetManifestReader test(s) FAILED." -ForegroundColor Red; exit 1 }
