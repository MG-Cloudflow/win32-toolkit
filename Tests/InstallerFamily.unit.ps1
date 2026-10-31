<#
    Installer-identity PR 1 (spec 2.1, 2.2): the installer family table and the two small shared helpers.

      Get-Win32ToolkitInstallerFamily               the family table (Type / Family / PinOrder sets)
      Test-Win32ToolkitWingetNoApplicableInstaller  winget exit code 0x8A150010 (no applicable installer)
      ConvertTo-Win32ToolkitSafeText                untrusted text -> console/JSON safe text (C-6)

    Pure functions: no file system, no network, no winget.

    Run:  pwsh -File Tests\InstallerFamily.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerFamily.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitWingetNoApplicableInstaller.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')

# -- [1] The whole table ---------------------------------------------------------------------------
Write-Host '[1] Get-Win32ToolkitInstallerFamily -Type: every row of the table' -ForegroundColor Cyan
#            Type        Family      Prec  Reg     Dl      Pkg     Testable PinValue    Label
$rows = @(
    @('msstore',  'msix',     1,  $true,  $false, $false, $false, '',         'msstore (Microsoft Store)'),
    @('msix',     'msix',     2,  $true,  $true,  $true,  $true,  'msix',     'msix (MSIX package)'),
    @('appx',     'msix',     3,  $true,  $true,  $true,  $true,  'msix',     'appx (APPX package)'),
    @('msi',      'msi',      4,  $true,  $true,  $true,  $true,  'msi',      'msi (MSI)'),
    @('wix',      'msi',      5,  $true,  $true,  $true,  $true,  'wix',      'wix (MSI)'),
    @('burn',     'exe',      6,  $true,  $true,  $true,  $true,  'burn',     'burn (EXE bundle)'),
    @('nullsoft', 'exe',      7,  $true,  $true,  $true,  $true,  'nullsoft', 'nullsoft (vendor EXE, NSIS)'),
    @('inno',     'exe',      8,  $true,  $true,  $true,  $true,  'inno',     'inno (vendor EXE, Inno Setup)'),
    @('exe',      'exe',      9,  $true,  $true,  $true,  $true,  'exe',      'exe (vendor EXE)'),
    @('portable', 'portable', 10, $false, $true,  $false, $false, '',         'portable (no installer)')
)
foreach ($r in $rows) {
    $f = Get-Win32ToolkitInstallerFamily -Type $r[0]
    $got = @($f.Family, $f.Precedence, $f.Registers, $f.Downloadable, $f.Packageable, $f.Testable, $f.PinValue, $f.Label)
    $exp = @($r[1], $r[2], $r[3], $r[4], $r[5], $r[6], $r[7], $r[8])
    if ((($got | ForEach-Object { "$_" }) -join '|') -ceq (($exp | ForEach-Object { "$_" }) -join '|') -and
        $f.EffectiveType -eq $r[0] -and -not $f.ZipWrapped -and $f.Type -eq $r[0]) {
        Ok ("{0,-8} -> {1}" -f $r[0], ($got -join ' | '))
    } else { Bad ("{0}: got [{1}] expected [{2}]" -f $r[0], ($got -join ' | '), ($exp -join ' | ')) }
}
$up = Get-Win32ToolkitInstallerFamily -Type ' WIX '
if ($up.Type -eq 'wix' -and $up.Family -eq 'msi') { Ok 'input is trimmed and lower-cased (WIX -> wix, msi)' } else { Bad "WIX -> $($up.Type)/$($up.Family)" }

# -- [2] zip-wrapped and unknown types -------------------------------------------------------------
Write-Host '[2] zip + nested type, portable, unknown types (never throws)' -ForegroundColor Cyan
$z = Get-Win32ToolkitInstallerFamily -Type zip -NestedType wix
if ($z.Family -eq 'msi' -and $z.EffectiveType -eq 'wix' -and $z.ZipWrapped -and -not $z.Packageable -and -not $z.Testable -and
    $z.Registers -and $z.PinValue -eq '' -and $z.Precedence -eq 5 -and $z.Label -eq 'wix (MSI), zip-wrapped' -and $z.NestedType -eq 'wix') {
    Ok "zip + wix -> Family msi, EffectiveType wix, ZipWrapped, not Packageable, not Testable, PinValue '', label '$($z.Label)'"
} else { Bad "zip + wix -> $($z | ConvertTo-Json -Compress)" }
$ze = Get-Win32ToolkitInstallerFamily -Type ZIP -NestedType EXE
if ($ze.Family -eq 'exe' -and $ze.ZipWrapped -and -not $ze.Testable -and $ze.PinValue -eq '' -and $ze.Label -eq 'exe (vendor EXE), zip-wrapped') { Ok 'zip + exe -> exe family, zip-wrapped, untestable' } else { Bad "zip + exe -> $($ze | ConvertTo-Json -Compress)" }
$zp = Get-Win32ToolkitInstallerFamily -Type zip -NestedType portable
if ($zp.Family -eq 'portable' -and -not $zp.Registers -and -not $zp.Testable) { Ok 'zip + portable -> portable, registers nothing' } else { Bad "zip + portable -> $($zp | ConvertTo-Json -Compress)" }
$z0 = Get-Win32ToolkitInstallerFamily -Type zip
if ($z0.Family -eq 'other' -and $z0.ZipWrapped -and -not $z0.Registers -and $z0.PinValue -eq '') { Ok 'zip without a nested type -> other' } else { Bad "zip -> $($z0 | ConvertTo-Json -Compress)" }
$n = Get-Win32ToolkitInstallerFamily -Type nullsoft -NestedType wix
if ($n.EffectiveType -eq 'nullsoft' -and $n.Family -eq 'exe' -and -not $n.ZipWrapped) { Ok 'a nested type is ignored when the type is not zip' } else { Bad "nullsoft + nested wix -> $($n | ConvertTo-Json -Compress)" }

foreach ($t in @('pwa', 'font', 'bogus', '', $null)) {
    $threw = $false
    try { $o = Get-Win32ToolkitInstallerFamily -Type $t } catch { $threw = $true }
    if (-not $threw -and $o.Family -eq 'other' -and $o.Precedence -eq 99 -and -not $o.Registers -and -not $o.Downloadable -and
        -not $o.Packageable -and -not $o.Testable -and $o.PinValue -eq '') {
        Ok "'$t' -> Family other, precedence 99, no pin value, no throw"
    } else { Bad "'$t' -> threw=$threw $($o | ConvertTo-Json -Compress)" }
}

# -- [3] Family set --------------------------------------------------------------------------------
Write-Host '[3] Get-Win32ToolkitInstallerFamily -Family' -ForegroundColor Cyan
$fam = @(
    @{ Args = @{ Family = 'exe' };                              Exp = 'burn,nullsoft,inno,exe' },
    @{ Args = @{ Family = 'msi' };                              Exp = 'msi,wix' },
    @{ Args = @{ Family = 'msix' };                             Exp = 'msstore,msix,appx' },
    @{ Args = @{ Family = 'msix'; DownloadableOnly = $true };   Exp = 'msix,appx' },
    @{ Args = @{ Family = 'MSI' };                              Exp = 'msi,wix' },
    @{ Args = @{ Family = 'portable' };                         Exp = 'portable' },
    @{ Args = @{ Family = 'other' };                            Exp = '' },
    @{ Args = @{ Family = 'bogus' };                            Exp = '' }
)
foreach ($c in $fam) {
    $a = $c.Args
    $got = @(Get-Win32ToolkitInstallerFamily @a) -join ','
    $label = ($a.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '
    if ($got -ceq $c.Exp) { Ok "$label -> '$got'" } else { Bad "$label -> '$got' (expected '$($c.Exp)')" }
}

# -- [4] PinOrder set ------------------------------------------------------------------------------
Write-Host '[4] Get-Win32ToolkitInstallerFamily -PinOrder (pin the family, not the type)' -ForegroundColor Cyan
$pins = [ordered]@{
    'wix' = 'wix,msi'; 'msi' = 'msi,wix'; 'nullsoft' = 'nullsoft,burn,inno,exe'; 'inno' = 'inno,burn,nullsoft,exe'
    'exe' = 'exe,burn,nullsoft,inno'; 'burn' = 'burn,nullsoft,inno,exe'; 'msix' = 'msix,appx'; 'appx' = 'appx,msix'
    'portable' = ''; 'zip' = ''; 'msstore' = ''; 'pwa' = ''; 'bogus' = ''; '' = ''
}
foreach ($k in $pins.Keys) {
    $threw = $false
    try { $got = @(Get-Win32ToolkitInstallerFamily -PinOrder $k) -join ',' } catch { $threw = $true; $got = '<threw>' }
    if (-not $threw -and $got -ceq $pins[$k]) { Ok "-PinOrder '$k' -> '$got'" } else { Bad "-PinOrder '$k' -> '$got' (expected '$($pins[$k])')" }
}

# -- [5] winget no-applicable-installer code -------------------------------------------------------
Write-Host '[5] Test-Win32ToolkitWingetNoApplicableInstaller' -ForegroundColor Cyan
if (Test-Win32ToolkitWingetNoApplicableInstaller -ExitCode -1978335216) { Ok '-1978335216 -> $true' } else { Bad '-1978335216 -> $false' }
if (Test-Win32ToolkitWingetNoApplicableInstaller 0x8A150010) { Ok '0x8A150010 (positional) -> $true' } else { Bad '0x8A150010 -> $false' }
foreach ($code in @(0x8A150008, 0x8A150014, 0, 1, -1)) {
    if (-not (Test-Win32ToolkitWingetNoApplicableInstaller -ExitCode $code)) { Ok ("{0} (0x{0:X8}) -> `$false" -f $code) } else { Bad "$code -> `$true" }
}
$t = (Test-Win32ToolkitWingetNoApplicableInstaller -ExitCode 0)
if ($t -is [bool]) { Ok 'returns a [bool]' } else { Bad "returns $($t.GetType().Name)" }

# -- [6] Safe text ---------------------------------------------------------------------------------
Write-Host '[6] ConvertTo-Win32ToolkitSafeText' -ForegroundColor Cyan
$esc = [char]0x1B; $nul = [char]0; $rlo = [char]0x202E; $ls = [char]0x2028; $ps = [char]0x2029; $zw = [char]0x200B
$cases = @(
    @{ In = "a${esc}[31mred";      Exp = 'a?[31mred';   Label = 'ESC -> ?' },
    @{ In = "a${nul}b";            Exp = 'a?b';         Label = 'NUL -> ?' },
    @{ In = "evil${rlo}txt.exe";   Exp = 'evil?txt.exe'; Label = 'U+202E (bidi override, Cf) -> ?' },
    @{ In = "one${ls}two${ps}three"; Exp = 'one?two?three'; Label = 'U+2028 / U+2029 -> ?' },
    @{ In = "a${zw}b";             Exp = 'a?b';         Label = 'U+200B (zero width, Cf) -> ?' },
    @{ In = "a`tb`r`nc";           Exp = 'a?b??c';      Label = 'TAB / CR / LF -> ?' },
    @{ In = '  padded  ';          Exp = 'padded';      Label = 'trimmed' },
    @{ In = "Caf$([char]0xE9) $([char]0x4E2D)"; Exp = "Caf$([char]0xE9) $([char]0x4E2D)"; Label = 'letters outside ASCII are kept' },
    @{ In = '';                    Exp = '';            Label = "'' -> ''" },
    @{ In = $null;                 Exp = '';            Label = '$null -> ''''' }
)
foreach ($c in $cases) {
    $got = ConvertTo-Win32ToolkitSafeText -Text $c.In
    if ($got -ceq $c.Exp) { Ok $c.Label } else { Bad "$($c.Label): got [$got]" }
}
$long = ConvertTo-Win32ToolkitSafeText -Text ('a' * 300)
if ($long.Length -eq 256 -and $long.EndsWith('...') -and $long.StartsWith('a' * 253)) { Ok 'longer than 256 -> 253 chars + ... (256)' } else { Bad "cap: length $($long.Length)" }
$cap = ConvertTo-Win32ToolkitSafeText 'abcdefghijklmnop' -MaxLength 10
if ($cap -ceq 'abcdefg...') { Ok "-MaxLength 10 -> '$cap'" } else { Bad "-MaxLength 10 -> '$cap'" }
$exact = ConvertTo-Win32ToolkitSafeText -Text ('b' * 256)
if ($exact.Length -eq 256 -and -not $exact.EndsWith('...')) { Ok 'exactly 256 chars -> unchanged' } else { Bad 'exactly 256 chars was cut' }
$threw = $false
try { ConvertTo-Win32ToolkitSafeText -Text 'x' -MaxLength 2 | Out-Null } catch { $threw = $true }
if ($threw) { Ok '-MaxLength below 4 is rejected by parameter validation' } else { Bad '-MaxLength 2 accepted' }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All InstallerFamily tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail InstallerFamily test(s) FAILED." -ForegroundColor Red; exit 1 }
