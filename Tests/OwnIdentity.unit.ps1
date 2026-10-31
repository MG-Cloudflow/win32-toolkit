<#
    Installer-identity PR 3 (spec 2.2, L1, Dv1): Write-Win32ToolkitOwnIdentity records the package's own uninstall
    identity in AppConfig.OwnIdentity, for every installer type.

      [1] Notepad++ WiX capture: ProductCode / UpgradeCode from the packaged MSI's Property table (the MSI property
          reader is shadowed with the real Notepad++ 8.9.8.1 codes), ArpKeys = the {5C6F...} key, View Native;
          the tattoo key (HKLM\SOFTWARE\<Author>\...) is never an own uninstall key; NO Uninstall section is
          written into an MSI project (the L1 regression: the device Uninstall block would throw on it).
      [2] Git-style EXE capture with a co-installed key -> both keys (sorted); no product code.
      [3] WOW6432Node key -> View Wow6432; a key name with a control character or a separator -> not recorded;
          a key below an uninstall key (a sub key) -> not recorded; > 64 keys -> 64.
      [4] re-run with the same capture -> byte-identical AppConfig.json; every other section kept.
      [5] an unreadable capture ($null) -> $false, one warning, AppConfig.json untouched.
      [6] the source file is ASCII-only and writes its check mark as [char]0x2713.

    Projects are built under %TEMP% and removed at the end; nothing is installed or run.

    Run:  pwsh -File Tests\OwnIdentity.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }

# The MSI Property table of the packaged installer (the real Notepad++ 8.9.8.1 WiX MSI codes).
$script:msiProps = @{ ProductCode = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'; UpgradeCode = '{CDB13460-04DF-4708-A7FD-4CB4A0684605}' }
function Get-Win32ToolkitMsiProperty { param([string]$Path, [string]$Property) [string]$script:msiProps[$Property] }

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32own_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $root -Force
$utf8 = [Text.UTF8Encoding]::new($false)

function New-Project([string]$Name, [string]$InstallerFile, [hashtable]$App) {
    $p = Join-Path $root $Name
    $null = New-Item -ItemType Directory -Path (Join-Path $p 'Files'), (Join-Path $p 'SupportFiles') -Force
    [IO.File]::WriteAllText((Join-Path $p "Files\$InstallerFile"), 'x', $utf8)
    $type = if ($InstallerFile -like '*.msi') { 'msi' } else { 'exe' }
    $cfg = [ordered]@{ SchemaVersion = '1.0'; App = $App; Installer = [ordered]@{ Type = $type; FileName = $InstallerFile; SilentArgs = '' }; ProcessesToClose = @('keep-me') }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 6), $utf8)
    $p
}
function Get-Cfg([string]$P) { Get-Content -LiteralPath (Join-Path $P 'SupportFiles\AppConfig.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Key([string]$Path, [hashtable]$Values = @{}) { [pscustomobject]@{ Path = $Path; KeyName = $Path.Substring($Path.LastIndexOf('\') + 1); Values = [pscustomobject]$Values } }
$u = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$uw = 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'

try {
    # == [1] Notepad++ WiX ===============================================================================
    Write-Host '[1] Notepad++ WiX MSI: codes from the Property table, the product key, no tattoo, no Uninstall section' -ForegroundColor Cyan
    $npp = New-Project 'npp' 'npp.8.9.8.1.Installer.x64.msi' ([ordered]@{ Vendor = 'Notepad++ Team'; Name = ''; DisplayName = 'Notepad++'; Version = '8.9.8.1'; ScriptAuthor = 'Contoso IT' })
    $cap = [pscustomobject]@{
        InstallationInfo = [pscustomobject]@{ ProjectName = 'npp'; Timestamp = '20261025_101112'; PsadtExitCode = 0 }
        NewFiles         = @([pscustomobject]@{ Path = 'C:\Program Files\Notepad++\notepad++.exe'; Type = 'File' })
        NewRegistryKeys  = @(
            (Key "$u\{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}" @{ DisplayName = 'Notepad++ (64-bit x64)'; WindowsInstaller = 1 })
            (Key 'HKEY_LOCAL_MACHINE\SOFTWARE\Contoso IT\Notepad++ Team\Notepad++' @{ Version = '8.9.8.1' })
            (Key 'HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Products\3458F6C58AE79B047BF8404C3708ED7F')
        )
    }
    $lines = @(Write-Win32ToolkitOwnIdentity -ProjectPath $npp -Capture $cap 6>&1)
    $r = $lines | Where-Object { $_ -is [bool] }
    $host1 = @($lines | Where-Object { $_ -isnot [bool] } | ForEach-Object { "$_" })
    $cfg = Get-Cfg $npp
    $o = $cfg.OwnIdentity
    if ($r -eq $true -and $o.SchemaVersion -eq '1.0' -and $o.ProductCode -ceq '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}' -and $o.UpgradeCode -ceq '{CDB13460-04DF-4708-A7FD-4CB4A0684605}') { Ok 'ProductCode and UpgradeCode come from the MSI Property table' } else { Bad "codes: r=$r $($o | ConvertTo-Json -Compress)" }
    if (@($o.ArpKeys).Count -eq 1 -and $o.ArpKeys[0].Key -ceq '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}' -and $o.ArpKeys[0].View -ceq 'Native') { Ok 'ArpKeys = the product key, View Native (the tattoo and the Classes key are not uninstall keys)' } else { Bad "ArpKeys: $($o.ArpKeys | ConvertTo-Json -Compress)" }
    if (-not $cfg.PSObject.Properties['Uninstall']) { Ok 'an MSI project gets NO Uninstall section (its device uninstall stays the Zero-Config one, L1)' } else { Bad 'Uninstall section written into an MSI project' }
    if ($o.CapturedOn -ceq '2026-10-25') { Ok "CapturedOn = the capture's own date" } else { Bad "CapturedOn: $($o.CapturedOn)" }
    if (($host1 -join '|') -ceq "$([char]0x2713) Own identity recorded: 1 uninstall key(s), product code {5C6F8543-7EA8-40B9-B78F-04C78300DE7F}") { Ok 'one host line with the check mark, the key count and the product code' } else { Bad "host line: $($host1 -join ' | ')" }
    if (@($cfg.ProcessesToClose) -join ',' -ceq 'keep-me' -and $cfg.App.DisplayName -ceq 'Notepad++' -and $cfg.Installer.Type -ceq 'msi') { Ok 'every other section is kept' } else { Bad 'other sections changed' }

    # == [2] EXE with a co-installed key =================================================================
    Write-Host '[2] EXE capture with a co-installed key -> both keys, sorted; no product code' -ForegroundColor Cyan
    $git = New-Project 'git' 'Git-2.55.0-64-bit.exe' ([ordered]@{ Vendor = 'The Git Development Community'; Name = 'Git'; DisplayName = 'Git'; Version = '2.55.0'; ScriptAuthor = 'Contoso IT' })
    $cap2 = [pscustomobject]@{
        DocumentationInfo = [pscustomobject]@{ Timestamp = '20260101_120000' }
        NewRegistryKeys   = @((Key "$u\Git_is1" @{ DisplayName = 'Git' }), (Key "$u\Git LFS" @{ DisplayName = 'Git LFS' }), (Key "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git LFS"))
    }
    $r = Write-Win32ToolkitOwnIdentity -ProjectPath $git -Capture $cap2 6>$null
    $o = (Get-Cfg $git).OwnIdentity
    $got = @($o.ArpKeys | ForEach-Object { "$($_.View)|$($_.Key)" }) -join ','
    if ($r -eq $true -and $got -ceq 'Native|Git LFS,Native|Git_is1' -and $o.ProductCode -eq '' -and $o.UpgradeCode -eq '') { Ok 'Git_is1 + the co-installed Git LFS key (HKLM and HKEY_LOCAL_MACHINE spellings collapse), no codes' } else { Bad "git: r=$r keys=$got pc=$($o.ProductCode)" }
    if ($o.CapturedOn -ceq '2026-01-01') { Ok 'CapturedOn from DocumentationInfo.Timestamp' } else { Bad "CapturedOn: $($o.CapturedOn)" }

    # == [3] views, odd names, cap =======================================================================
    Write-Host '[3] WOW6432Node -> Wow6432; control characters, sub keys -> not recorded; at most 64 keys' -ForegroundColor Cyan
    $odd = New-Project 'odd' 'setup.exe' ([ordered]@{ Vendor = 'V'; Name = 'A'; Version = '1.0'; ScriptAuthor = 'Contoso IT' })
    $keys = @(
        (Key "$uw\App32")
        (Key "$u\Bad$([char]7)Key")
        (Key "$u\Bad$([char]0x202E)Bidi")
        (Key "$u\App\SubKey")
        (Key "$u\..")
        (Key "HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PerUser")
    )
    $r = Write-Win32ToolkitOwnIdentity -ProjectPath $odd -Capture ([pscustomobject]@{ NewRegistryKeys = $keys }) 6>$null
    $got = @((Get-Cfg $odd).OwnIdentity.ArpKeys | ForEach-Object { "$($_.View)|$($_.Key)" }) -join ','
    if ($r -eq $true -and $got -ceq 'Wow6432|App32') { Ok 'only the WOW6432Node key is recorded (View Wow6432); control/format characters, a sub key, .. and HKCU are not' } else { Bad "odd: $got" }
    $many = @(for ($i = 99; $i -ge 0; $i--) { Key ('{0}\Key{1:D3}' -f $u, $i) })
    $r = Write-Win32ToolkitOwnIdentity -ProjectPath $odd -Capture ([pscustomobject]@{ NewRegistryKeys = $many }) 6>$null
    $o = (Get-Cfg $odd).OwnIdentity
    if (@($o.ArpKeys).Count -eq 64 -and $o.ArpKeys[0].Key -ceq 'Key000' -and $o.ArpKeys[63].Key -ceq 'Key063') { Ok '100 keys -> the first 64 in ordinal order' } else { Bad "cap: $(@($o.ArpKeys).Count) first=$($o.ArpKeys[0].Key)" }

    # == [4] idempotent ==================================================================================
    Write-Host '[4] a re-run with the same capture writes the same bytes' -ForegroundColor Cyan
    $f = Join-Path $npp 'SupportFiles\AppConfig.json'
    $before = [IO.File]::ReadAllBytes($f)
    $null = Write-Win32ToolkitOwnIdentity -ProjectPath $npp -Capture $cap 6>$null
    $after = [IO.File]::ReadAllBytes($f)
    if ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String($after)) { Ok 'byte-identical AppConfig.json' } else { Bad 'AppConfig.json changed on a re-run' }

    # == [5] fail-open ===================================================================================
    Write-Host '[5] an unreadable capture -> $false, one warning, AppConfig untouched' -ForegroundColor Cyan
    $before = [IO.File]::ReadAllBytes($f)
    $w = $null
    $r = Write-Win32ToolkitOwnIdentity -ProjectPath $npp -Capture $null -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $after = [IO.File]::ReadAllBytes($f)
    if ($r -eq $false -and @($w).Count -eq 1 -and "$($w[0])" -match 'own uninstall identity was not recorded' -and [Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String($after)) { Ok '$false + one warning; AppConfig.json byte-identical' } else { Bad "fail-open: r=$r warnings=$(@($w).Count) $($w -join '|')" }
    $script:msiProps = @{}
    function Get-Win32ToolkitProjectSource { param($ProjectPath, [switch]$Rebuild) throw 'boom' }
    $r = Write-Win32ToolkitOwnIdentity -ProjectPath $npp -Capture $cap -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $after = [IO.File]::ReadAllBytes($f)
    if ($r -eq $false -and @($w).Count -eq 1 -and [Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String($after)) { Ok 'a throwing helper -> $false + one warning, nothing written' } else { Bad "helper throws: r=$r" }
    function Get-Win32ToolkitProjectSource { param($ProjectPath, [switch]$Rebuild) throw ([System.Management.Automation.ErrorRecord]::new([Exception]::new('w32t'), 'W32T.Test', 'InvalidData', $null)) }
    $thrown = try { $null = Write-Win32ToolkitOwnIdentity -ProjectPath $npp -Capture $cap 6>$null; '' } catch { $_.FullyQualifiedErrorId }
    if ($thrown -eq 'W32T.Test') { Ok 'a W32T.* error from a helper is re-thrown (C-2)' } else { Bad "W32T: '$thrown'" }

    # == [6] source text ==================================================================================
    Write-Host '[6] the source file is ASCII-only' -ForegroundColor Cyan
    $bytes = [IO.File]::ReadAllBytes((Join-Path $repo 'Private\Write-Win32ToolkitOwnIdentity.ps1'))
    if (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok 'ASCII-only (the check mark is [char]0x2713)' } else { Bad 'non-ASCII bytes in Write-Win32ToolkitOwnIdentity.ps1' }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All OwnIdentity tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail OwnIdentity test(s) FAILED." -ForegroundColor Red; exit 1 }
