<#
    Installer-identity PR 3 (spec 2.1, 2.3, L28, L34, D21, SV5, SV15): Test-Win32ToolkitPriorInstallEntry (the host
    validator), Get-Win32ToolkitPriorInstallHash (binding and tuple hashes) and ConvertTo-Win32ToolkitPriorVersion (the
    device's own version parser, run on the host).

      [1] a valid Notepad++-style Enforce entry; the MSI package whose tattoo leaf equals the NSIS key name (App.Name '',
          App.DisplayName 'Notepad++') is VALID - the tattoo is never an own uninstall key (Appendix B #1).
      [2] the field matrix: every rule with a valid and invalid value (CR/LF/NUL, a comment-end token, U+2019, U+202E, wildcard keys,
          '..' folders, the own keys from OwnIdentity and Uninstall, own-family VersionMax = App.Version, missing Enforce
          fields, empty Publisher, templates with 0 / 2 {v}, lower-case modes, Source / CaptureId / Track / AddedOn).
      [3] set rules: > 32 entries, duplicate Id and (Key, View), invalid ScriptAuthor, unreadable App.Version, no known
          own identity (also for Block), Enforce without OwnIdentity; -PreCapture skips them and uses Source.ProductCode.
      [4] rules needing decisions / records apply only when bound: DisplayName / VersionMin required unless waived (never
          for capture lineage); a capture-lineage entry needs its verified record and VersionMin = the floor's observed
          version; lineage per entry.
      [5] hashes: AddedOn / Source / CaptureId / Track keep the binding; any device field, Mode, OwnIdentity, App.Version,
          ScriptAuthor or Installer change moves it; the tuple ignores Id, Mode and the window; 64 upper-case hex; a
          dictionary entry hashes like the same object (its keys are its fields).
      [6] the version parser = the device parser (padded parts, 9-digit parts, fifth part).
      [7] never more lenient than the device: the device's own evaluation (catalog texts A and B, run here with the
          registry shadowed) refuses as invalid data (69105) nothing the host accepts - a trailing line break in Id,
          UninstallerFileName, MainExe, a process name, InstallDir or Key (the host anchors with \z, as the device), every
          row of the field matrix, and an Enforce entry whose OwnIdentity holds only an UpgradeCode (no own key or code);
          JSON-typed falsy values read with the device's truthiness (configs round-tripped through ConvertTo-Json /
          ConvertFrom-Json): an OwnIdentity of '', 0 or false next to Uninstall keys is no OwnIdentity (Enforce refused,
          Block valid on both), and ProcessNames [0] / [false] / [''] are no process names (refused on both).

    Pure (no file I/O). Run:  pwsh -File Tests\PriorInstallEntry.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Test-Path and Get-ItemProperty are shadowed inside Get-DeviceVerdict: the device evaluation never reads the registry')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'Test-Win32ToolkitPriorInstallEntry', 'Get-Win32ToolkitPriorInstallHash', 'ConvertTo-Win32ToolkitPriorVersion', 'Get-Win32ToolkitDeployScriptBlock', 'ConvertTo-Win32ToolkitSafeText') {
    . (Join-Path $repo "Private\$f.ps1")
}

$PC = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'; $UC = '{CDB13460-04DF-4708-A7FD-4CB4A0684605}'
function Entry([hashtable]$Over = @{}) {
    $e = [ordered]@{ Id = 'nsis-x64'; Kind = 'ArpKey'; Mode = 'Enforce'; Key = 'Notepad++'; View = 'Native'; Publisher = 'Notepad++ Team'
        DisplayName = 'Notepad++ (64-bit x64)'; DisplayNameTemplate = ''; VersionMin = '8.7.9'; VersionMax = '8.9.8.1'; UninstallerType = 'nullsoft'
        UninstallerFileName = 'uninstall.exe'; UninstallerSigner = ''; InstallDir = '%ProgramFiles%\Notepad++'; MainExe = 'notepad++.exe'
        ProcessNames = @('notepad++'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-25' }
    foreach ($k in $Over.Keys) { $e[$k] = $Over[$k] }
    [pscustomobject]$e
}
function Cfg([object[]]$Entries, [hashtable]$Over = @{}) {
    $c = [ordered]@{
        App           = [pscustomobject]@{ Vendor = 'Notepad++ Team'; Name = ''; DisplayName = 'Notepad++'; Version = '8.9.8.1'; ScriptAuthor = 'Contoso IT' }
        Installer     = [pscustomobject]@{ Type = 'msi'; FileName = 'npp.8.9.8.1.Installer.x64.msi' }
        Source        = [pscustomobject]@{ SchemaVersion = '1.0'; ProductCode = $PC; UpgradeCode = $UC }
        OwnIdentity   = [pscustomobject]@{ SchemaVersion = '1.0'; ProductCode = $PC; UpgradeCode = $UC; ArpKeys = @([pscustomobject]@{ Key = $PC; View = 'Native' }); CapturedOn = '2026-10-25' }
        PriorInstalls = [pscustomobject]@{ SchemaVersion = '1.0'; Entries = @($Entries) }
    }
    foreach ($k in $Over.Keys) { if ($null -eq $Over[$k]) { $c.Remove($k) } else { $c[$k] = $Over[$k] } }
    [pscustomobject]$c
}
function V($Config, [hashtable]$Opt = @{}) { Test-Win32ToolkitPriorInstallEntry -Config $Config @Opt }
function Has($r, [string]$Rx) { @($r.Problems | Where-Object { $_ -match $Rx }).Count -gt 0 }

# == [1] valid =========================================================================================
Write-Host '[1] valid entries; the tattoo leaf is never an own key' -ForegroundColor Cyan
$r = V (Cfg @((Entry)))
if ($r.Valid -and @($r.Problems).Count -eq 0 -and $r.PerEntry[0].Valid -and $r.Lineage['nsis-x64'] -eq 'Operator') { Ok 'a Notepad++-style Enforce entry of the WiX MSI package is valid (lineage Operator)' } else { Bad "valid: $($r.Problems -join ' | ')" }
foreach ($m in 'Block', 'Report') { $r = V (Cfg @((Entry @{ Mode = $m; UninstallerType = ''; UninstallerFileName = ''; InstallDir = ''; MainExe = ''; ProcessNames = @() })))
    if ($r.Valid) { Ok "$m entry without removal data is valid" } else { Bad "${m}: $($r.Problems -join ' | ')" } }
$r = V (Cfg @((Entry @{ DisplayName = ''; DisplayNameTemplate = 'Notepad++ {v} (64-bit x64)' })))
if ($r.Valid) { Ok 'a DisplayNameTemplate with exactly one {v} (DisplayName empty) is valid' } else { Bad "template: $($r.Problems -join ' | ')" }

# == [2] field matrix ==================================================================================
Write-Host '[2] the field matrix' -ForegroundColor Cyan
$bad = @(
    @{ L = 'Id with upper case'; O = @{ Id = 'NSIS-x64' }; Rx = '^NSIS-x64|entry 1: Id' }
    @{ L = 'Id too long'; O = @{ Id = ('a' * 41) }; Rx = 'Id must match' }
    @{ L = 'Kind arpkey'; O = @{ Kind = 'arpkey' }; Rx = "Kind must be 'ArpKey'" }
    @{ L = 'Kind MsiUpgradeCode (PR 3c)'; O = @{ Kind = 'MsiUpgradeCode' }; Rx = "Kind must be 'ArpKey'" }
    @{ L = 'Mode enforce (lower case)'; O = @{ Mode = 'enforce' }; Rx = 'Mode must be' }
    @{ L = 'Mode missing'; O = @{ Mode = '' }; Rx = 'Mode must be' }
    @{ L = 'wildcard Key'; O = @{ Key = 'Notepad*' }; Rx = 'Key must be' }
    @{ L = 'Key with a backslash'; O = @{ Key = 'A\B' }; Rx = 'Key must be' }
    @{ L = 'Key with LF'; O = @{ Key = "Notepad++`n" }; Rx = 'Key must be' }
    @{ L = 'Key with NUL'; O = @{ Key = "Note$([char]0)pad" }; Rx = 'Key must be' }
    @{ L = "Key '..'"; O = @{ Key = '..' }; Rx = 'Key must be' }
    @{ L = 'Key = OwnIdentity.ProductCode (other case)'; O = @{ Key = $PC.ToLowerInvariant() }; Rx = "own uninstall key" }
    @{ L = 'View native'; O = @{ View = 'native' }; Rx = 'View must be' }
    @{ L = 'empty Publisher'; O = @{ Publisher = '' }; Rx = 'Publisher' }
    @{ L = 'Publisher with CR'; O = @{ Publisher = "Notepad++`rTeam" }; Rx = 'Publisher' }
    @{ L = 'Publisher with U+202E'; O = @{ Publisher = "Notepad++ $([char]0x202E)maeT" }; Rx = 'Publisher' }
    @{ L = 'DisplayName with U+202E'; O = @{ DisplayName = "Notepad++$([char]0x202E)" }; Rx = 'DisplayName must be' }
    @{ L = 'template without {v}'; O = @{ DisplayName = ''; DisplayNameTemplate = 'Notepad++' }; Rx = 'exactly one \{v\}' }
    @{ L = 'template with two {v}'; O = @{ DisplayName = ''; DisplayNameTemplate = '{v} {v}' }; Rx = 'exactly one \{v\}' }
    @{ L = 'template and a DisplayName'; O = @{ DisplayNameTemplate = 'Notepad++ {v}' }; Rx = 'DisplayName must be empty' }
    @{ L = 'VersionMin unreadable'; O = @{ VersionMin = 'latest' }; Rx = 'VersionMin cannot be read' }
    @{ L = 'VersionMax 10-digit part'; O = @{ VersionMax = '8.9.1234567890' }; Rx = 'VersionMax is required' }
    @{ L = 'VersionMax fifth part'; O = @{ VersionMax = '8.9.8.1.5' }; Rx = 'VersionMax is required' }
    @{ L = 'VersionMax missing'; O = @{ VersionMax = '' }; Rx = 'VersionMax is required' }
    @{ L = 'VersionMin above VersionMax'; O = @{ VersionMin = '9.0' }; Rx = 'VersionMin is higher' }
    @{ L = 'UninstallerType msi'; O = @{ UninstallerType = 'msi' }; Rx = 'UninstallerType must be' }
    @{ L = 'UninstallerFileName with a path'; O = @{ UninstallerFileName = '..\uninstall.exe' }; Rx = 'UninstallerFileName must be' }
    @{ L = "UninstallerFileName '#>.exe'"; O = @{ UninstallerFileName = '#>.exe' }; Rx = 'UninstallerFileName must be' }
    @{ L = 'UninstallerSigner with LF'; O = @{ UninstallerSigner = "CN=X`nCN=Y" }; Rx = 'UninstallerSigner' }
    @{ L = "InstallDir '..'"; O = @{ InstallDir = '%ProgramFiles%\..\Windows' }; Rx = 'InstallDir must be' }
    @{ L = 'InstallDir trailing dot'; O = @{ InstallDir = '%ProgramFiles%\Notepad++.' }; Rx = 'InstallDir must be' }
    @{ L = 'InstallDir leading space'; O = @{ InstallDir = '%ProgramFiles%\ Notepad++' }; Rx = 'InstallDir must be' }
    @{ L = 'InstallDir outside Program Files'; O = @{ InstallDir = 'C:\Tools\Notepad++' }; Rx = 'InstallDir must be' }
    @{ L = 'InstallDir with U+2019'; O = @{ InstallDir = "%ProgramFiles%\Notepad$([char]0x2019)s" }; Rx = 'InstallDir must be' }
    @{ L = 'MainExe = UninstallerFileName'; O = @{ MainExe = 'Uninstall.exe' }; Rx = 'MainExe must differ' }
    @{ L = "ProcessName 'notepad++.exe'"; O = @{ ProcessNames = @('notepad++.exe') }; Rx = 'ProcessNames must be' }
    @{ L = '9 ProcessNames'; O = @{ ProcessNames = @(1..9 | ForEach-Object { "p$_" }) }; Rx = 'at most 8' }
    @{ L = 'Enforce without UninstallerType'; O = @{ UninstallerType = '' }; Rx = 'needs UninstallerType' }
    @{ L = 'Enforce without InstallDir'; O = @{ InstallDir = '' }; Rx = 'needs InstallDir' }
    @{ L = 'Enforce without MainExe'; O = @{ MainExe = '' }; Rx = 'needs MainExe' }
    @{ L = 'Enforce without ProcessNames'; O = @{ ProcessNames = @() }; Rx = 'needs at least one ProcessName' }
    @{ L = 'Source unknown'; O = @{ Source = 'Guess' }; Rx = 'Source must be' }
    @{ L = 'SiblingCapture without CaptureId'; O = @{ Source = 'SiblingCapture' }; Rx = 'CaptureId must be' }
    @{ L = 'CaptureId upper case'; O = @{ CaptureId = '3F9C0A7D51E2B846' }; Rx = 'CaptureId must be' }
    @{ L = 'Track unknown'; O = @{ Track = 'Old' }; Rx = 'Track must be' }
    @{ L = 'AddedOn missing'; O = @{ AddedOn = '' }; Rx = 'AddedOn' }
)
foreach ($c in $bad) {
    $r = V (Cfg @((Entry $c.O)))
    if (-not $r.Valid -and (Has $r $c.Rx)) { Ok "$($c.L) -> invalid" } else { Bad "$($c.L): valid=$($r.Valid) $($r.Problems -join ' | ')" }
}
$exe = Cfg @((Entry @{ VersionMax = '8.9.8.1' })) @{ Installer = [pscustomobject]@{ Type = 'exe'; FileName = 'npp.exe' } }
$r = V $exe
if (-not $r.Valid -and (Has $r "lower than this package's version")) { Ok "EXE package (own family): VersionMax = App.Version -> invalid (S3)" } else { Bad "own family: $($r.Problems -join ' | ')" }
$exe.PriorInstalls.Entries[0].VersionMax = '8.9.8'
if ((V $exe).Valid) { Ok 'EXE package: VersionMax below App.Version -> valid' } else { Bad 'own family below' }
$r = V (Cfg @((Entry @{ VersionMax = '10.0' })))
if ($r.Valid) { Ok 'cross family (MSI package): VersionMax above App.Version -> valid' } else { Bad "cross: $($r.Problems -join ' | ')" }
$withUninstall = Cfg @((Entry @{ Key = 'Git_is1' })) @{ Uninstall = [pscustomobject]@{ ProductCodes = @(); PrimaryKeys = @([pscustomobject]@{ Name = 'Git_is1'; View = 'Registry64' }) } }
$r = V $withUninstall
if (-not $r.Valid -and (Has $r 'own uninstall key')) { Ok 'Key = an Uninstall.PrimaryKeys name -> invalid' } else { Bad "primary key: $($r.Problems -join ' | ')" }
$withPc = Cfg @((Entry @{ Key = '{11111111-2222-3333-4444-555555555555}' })) @{ Uninstall = [pscustomobject]@{ ProductCodes = @('{11111111-2222-3333-4444-555555555555}') } }
if (Has (V $withPc) 'own uninstall key') { Ok 'Key = an Uninstall.ProductCodes entry -> invalid' } else { Bad 'uninstall product code accepted' }
$r = V (Cfg @((Entry @{ Source = 'SiblingCapture'; CaptureId = '3f9c0a7d51e2b846'; Key = 'Notepad++ [x64]' })))
if (Has $r 'Key must be|captured Enforce entry') { Ok "a captured Enforce key outside ^[A-Za-z0-9 ._+(){}-]+$ -> invalid" } else { Bad "captured key: $($r.Problems -join ' | ')" }
$r = V (Cfg @((Entry @{ Source = 'SiblingCapture'; CaptureId = '3f9c0a7d51e2b846'; Key = 'Notepad++ #1' })))
if (Has $r 'captured Enforce entry must match') { Ok "a captured Enforce key with '#' -> invalid (SV11)" } else { Bad "captured key #: $($r.Problems -join ' | ')" }
$r = V (Cfg @((Entry @{ Key = 'Notepad++ #1' })))
if ($r.Valid) { Ok "the same key in an operator entry -> valid (the conservative set is for captured Enforce entries)" } else { Bad "operator key #: $($r.Problems -join ' | ')" }

# == [3] set rules =====================================================================================
Write-Host '[3] set rules' -ForegroundColor Cyan
$many = @(1..33 | ForEach-Object { Entry @{ Id = "e$_"; Key = "K$_"; Mode = 'Report' } })
if (Has (V (Cfg $many)) 'at most 32') { Ok '33 entries -> invalid' } else { Bad '33 entries accepted' }
$r = V (Cfg @((Entry), (Entry @{ Mode = 'Block' })))
if (Has $r 'Id is used by another entry') { Ok 'duplicate Id -> invalid' } else { Bad "dup id: $($r.Problems -join ' | ')" }
$r = V (Cfg @((Entry), (Entry @{ Id = 'other'; Key = 'NOTEPAD++'; Mode = 'Block' })))
if (Has $r 'same uninstall key') { Ok 'duplicate (Key, View), case-insensitive -> invalid' } else { Bad "dup key: $($r.Problems -join ' | ')" }
$r = V (Cfg @((Entry), (Entry @{ Id = 'other'; View = 'Wow6432' })))
if ($r.Valid) { Ok 'the same key in the other view -> valid' } else { Bad "other view: $($r.Problems -join ' | ')" }
foreach ($a in @('', 'Contoso\IT', 'Contoso*', "Contoso`tIT")) {
    $r = V (Cfg @((Entry)) @{ App = [pscustomobject]@{ Version = '8.9.8.1'; ScriptAuthor = $a } })
    if (Has $r 'ScriptAuthor') { Ok "ScriptAuthor '$($a -replace "`t", '<TAB>')' -> invalid (the marker root)" } else { Bad "author $a accepted" }
}
if (Has (V (Cfg @((Entry)) @{ App = [pscustomobject]@{ Version = 'latest'; ScriptAuthor = 'Contoso IT' } })) 'App.Version') { Ok 'unreadable App.Version -> invalid' } else { Bad 'App.Version unreadable accepted' }
$noOwn = Cfg @((Entry @{ Mode = 'Block' })) @{ OwnIdentity = $null }
$r = V $noOwn
if (Has $r 'own uninstall identity is unknown') { Ok 'a Block entry without any known own identity -> invalid (L28)' } else { Bad "no own (Block): $($r.Problems -join ' | ')" }
$r = V (Cfg @((Entry @{ Mode = 'Block'; Key = 'Git_is1' })) @{ OwnIdentity = $null; Uninstall = [pscustomobject]@{ ProductCodes = @(); PrimaryKeys = @([pscustomobject]@{ Name = 'Git'; View = 'Registry64' }) } })
if ($r.Valid) { Ok 'Uninstall.PrimaryKeys is a known own identity for a Block entry' } else { Bad "primary keys own: $($r.Problems -join ' | ')" }
$r = V (Cfg @((Entry @{ Key = 'Git_is1' })) @{ OwnIdentity = $null; Uninstall = [pscustomobject]@{ ProductCodes = @(); PrimaryKeys = @([pscustomobject]@{ Name = 'Git'; View = 'Registry64' }) } })
if (Has $r 'needs this package''s OwnIdentity') { Ok 'an Enforce entry needs OwnIdentity itself (L28)' } else { Bad "enforce own: $($r.Problems -join ' | ')" }
$r = V $noOwn @{ PreCapture = $true }
if ($r.Valid) { Ok '-PreCapture: no own-identity precondition (carry-forward before the capture)' } else { Bad "precapture: $($r.Problems -join ' | ')" }
$pre = Cfg @((Entry @{ Key = $PC })) @{ OwnIdentity = $null }
if (Has (V $pre @{ PreCapture = $true }) 'own uninstall key') { Ok "-PreCapture: the MSI Source.ProductCode is the own key" } else { Bad 'precapture own key' }
$pre2 = Cfg @((Entry @{ Key = 'Git_is1' })) @{ Uninstall = [pscustomobject]@{ PrimaryKeys = @([pscustomobject]@{ Name = 'Git_is1'; View = 'Registry64' }) } }
if ((V $pre2 @{ PreCapture = $true }).Valid) { Ok '-PreCapture compares with the Source codes only (an old Uninstall key is not used)' } else { Bad 'precapture uses Uninstall' }
if ((V (Cfg @())).Valid -and (V ([pscustomobject]@{ SchemaVersion = '1.0' })).Valid) { Ok 'no entries / no PriorInstalls section -> valid' } else { Bad 'empty set invalid' }

# == [4] decisions and records =========================================================================
Write-Host '[4] rules that need decisions or capture records apply only when bound' -ForegroundColor Cyan
$noName = Cfg @((Entry @{ DisplayName = '' }))
if ((V $noName).Valid) { Ok 'empty DisplayName without -Decisions: not checked (the requirement generator binds neither)' } else { Bad 'DisplayName checked without -Decisions' }
if (Has (V $noName @{ Decisions = @() }) 'DisplayName is required') { Ok 'empty DisplayName with -Decisions and no waiver -> invalid (D21)' } else { Bad 'DisplayName not required with -Decisions' }
$waiver = [pscustomobject]@{ Kind = 'Waiver'; Code = 'DISPLAYNAME'; Target = 'nsis-x64'; Reason = 'r'; On = '2026-10-25' }
if ((V $noName @{ Decisions = @($waiver) }).Valid) { Ok 'a DISPLAYNAME waiver (declared before the entry) allows an empty name' } else { Bad 'DISPLAYNAME waiver ignored' }
$capNoName = Cfg @((Entry @{ DisplayName = ''; Source = 'SiblingCapture'; CaptureId = '3f9c0a7d51e2b846' }))
if (Has (V $capNoName @{ Decisions = @($waiver) }) 'DisplayName is required') { Ok 'the waiver never applies to capture lineage (D59b, SV8)' } else { Bad 'waiver applied to capture lineage' }
$noMin = Cfg @((Entry @{ VersionMin = '' }))
if ((V $noMin).Valid -and (Has (V $noMin @{ Decisions = @() }) 'VersionMin is required') -and (V $noMin @{ Decisions = @([pscustomobject]@{ Kind = 'Waiver'; Code = 'VERSIONMIN'; Target = 'nsis-x64'; Reason = 'r'; On = '2026-10-25' }) }).Valid) {
    Ok 'empty VersionMin: unchecked without -Decisions, invalid with them, valid with a VERSIONMIN waiver'
} else { Bad 'VersionMin waiver rules' }
$approval = [pscustomobject]@{ Kind = 'Approval'; Code = 'SIBLING-ENFORCE'; Target = 'nsis-x64'; ProposalId = 'nsis-x64'; ProposalHash = ('A' * 64); CaptureIds = @('3f9c0a7d51e2b846'); On = '2026-10-25'; Demoted = '' }
$r = V (Cfg @((Entry))) @{ Decisions = @($approval) }
if ($r.Lineage['nsis-x64'] -eq 'Capture') { Ok 'an Approval record for the Id gives capture lineage (whatever Source says, SV5)' } else { Bad "lineage approval: $($r.Lineage['nsis-x64'])" }
if ((V (Cfg @((Entry @{ CaptureId = '3f9c0a7d51e2b846' })))).Lineage['nsis-x64'] -eq 'Capture' -and (V (Cfg @((Entry @{ Source = 'UpdateTest' })))).Lineage['nsis-x64'] -eq 'UpdateTest') { Ok 'a CaptureId gives capture lineage; Source UpdateTest gives UpdateTest' } else { Bad 'lineage rules' }
$cap = Cfg @((Entry @{ Source = 'SiblingCapture'; CaptureId = '3f9c0a7d51e2b846'; VersionMin = '8.7.9' }))
$rec = [ordered]@{ CaptureId = '3f9c0a7d51e2b846'; Observation = [ordered]@{ Candidates = @([ordered]@{ Key = 'Notepad++'; View = 'Native'; DisplayVersion = '8.7.9' }) } }
if ((V $cap).Valid) { Ok 'capture lineage without -Records: the record rules are not applied' } else { Bad "cap no records: $((V $cap).Problems -join ' | ')" }
if ((V $cap @{ Records = @($rec) }).Valid) { Ok 'capture lineage: its verified record observed exactly VersionMin -> valid' } else { Bad "cap record: $((V $cap @{ Records = @($rec) }).Problems -join ' | ')" }
$r = V $cap @{ Records = @() }
if (Has $r '^nsis-x64: capture record: no hash-verified capture record') { Ok "no verified record -> 'capture record:' problem" } else { Bad "no record: $($r.Problems -join ' | ')" }
$cap.PriorInstalls.Entries[0].VersionMin = '8.7'
if (Has (V $cap @{ Records = @($rec) }) 'capture record: VersionMin must be exactly') { Ok 'VersionMin 8.7 against an observed 8.7.9 -> invalid (exact, never rounded, SV14)' } else { Bad 'rounded floor accepted' }

# == [5] hashes ========================================================================================
Write-Host '[5] binding and tuple hashes' -ForegroundColor Cyan
$base = Cfg @((Entry), (Entry @{ Id = 'inno-x86'; Key = 'App_is1'; View = 'Wow6432'; Mode = 'Block' }))
$h0 = Get-Win32ToolkitPriorInstallHash -Config $base
if ($h0 -cmatch '^[0-9A-F]{64}$') { Ok 'binding = 64 upper-case hex' } else { Bad "hash: $h0" }
$swap = Cfg @((Entry @{ Id = 'inno-x86'; Key = 'App_is1'; View = 'Wow6432'; Mode = 'Block' }), (Entry))
if ((Get-Win32ToolkitPriorInstallHash -Config $swap) -ceq $h0) { Ok 'entries are sorted by Id: the file order does not matter' } else { Bad 'order changes the binding' }
foreach ($c in @(@{ AddedOn = '2020-01-01' }, @{ Source = 'UpdateTest' }, @{ CaptureId = '3f9c0a7d51e2b846' }, @{ Track = 'Frozen' }, @{ ProcessNames = @('NOTEPAD++') })) {
    $x = Cfg @((Entry $c), (Entry @{ Id = 'inno-x86'; Key = 'App_is1'; View = 'Wow6432'; Mode = 'Block' }))
    $same = (Get-Win32ToolkitPriorInstallHash -Config $x) -ceq $h0
    $isNameCase = $c.ContainsKey('ProcessNames')
    if ($isNameCase) { if (-not $same) { Ok 'a process-name case change moves the binding (the names are data the device uses)' } else { Bad 'process name case ignored' } }
    elseif ($same) { Ok "$(@($c.Keys)[0]) change keeps the binding" } else { Bad "$(@($c.Keys)[0]) moved the binding" }
}
foreach ($c in @(@{ Mode = 'Block' }, @{ Key = 'Notepad++2' }, @{ View = 'Wow6432' }, @{ Publisher = 'X' }, @{ DisplayName = 'X' }, @{ VersionMin = '8.7.8' }, @{ VersionMax = '8.9.9' },
        @{ UninstallerType = 'inno' }, @{ UninstallerFileName = 'u.exe' }, @{ UninstallerSigner = 'CN=X' }, @{ InstallDir = '%ProgramFiles%\X' }, @{ MainExe = 'x.exe' }, @{ ProcessNames = @('notepad++', 'x') })) {
    $x = Cfg @((Entry $c), (Entry @{ Id = 'inno-x86'; Key = 'App_is1'; View = 'Wow6432'; Mode = 'Block' }))
    if ((Get-Win32ToolkitPriorInstallHash -Config $x) -cne $h0) { Ok "$(@($c.Keys)[0]) change moves the binding" } else { Bad "$(@($c.Keys)[0]) did not move the binding" }
}
$x = Cfg @((Entry), (Entry @{ Id = 'inno-x86'; Key = 'App_is1'; View = 'Wow6432'; Mode = 'Block' }))
$x.OwnIdentity.ArpKeys = @([pscustomobject]@{ Key = $PC; View = 'Native' }, [pscustomobject]@{ Key = 'Extra'; View = 'Native' })
if ((Get-Win32ToolkitPriorInstallHash -Config $x) -cne $h0) { Ok 'an OwnIdentity change moves the binding' } else { Bad 'OwnIdentity ignored' }
foreach ($o in @(@{ App = [pscustomobject]@{ Version = '8.9.9'; ScriptAuthor = 'Contoso IT' } }, @{ App = [pscustomobject]@{ Version = '8.9.8.1'; ScriptAuthor = 'Other' } }, @{ Installer = [pscustomobject]@{ Type = 'msi'; FileName = 'other.msi' } })) {
    $x = Cfg @((Entry), (Entry @{ Id = 'inno-x86'; Key = 'App_is1'; View = 'Wow6432'; Mode = 'Block' })) $o
    if ((Get-Win32ToolkitPriorInstallHash -Config $x) -cne $h0) { Ok "$(@($o.Keys)[0]) change moves the binding" } else { Bad "$(@($o.Keys)[0]) ignored" }
}
$t0 = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry (Entry)
$same = @(@{ Id = 'other' }, @{ Mode = 'Block' }, @{ VersionMin = '1.0' }, @{ VersionMax = '99' }, @{ AddedOn = '2000-01-01' }, @{ Source = 'SiblingCapture' }) | Where-Object { (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry (Entry $_)) -cne $t0 }
$diff = @(@{ Key = 'K' }, @{ View = 'Wow6432' }, @{ Publisher = 'P' }, @{ DisplayName = 'D' }, @{ UninstallerType = 'inno' }, @{ InstallDir = '%ProgramFiles%\Y' }, @{ MainExe = 'm.exe' }, @{ UninstallerSigner = 'CN=S' }) | Where-Object { (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry (Entry $_)) -ceq $t0 }
if ($t0 -cmatch '^[0-9A-F]{64}$' -and @($same).Count -eq 0 -and @($diff).Count -eq 0) { Ok 'tuple: identity + removal method only (Id, Mode, window, metadata ignored)' } else { Bad "tuple: same-changed $(@($same).Count), diff-unchanged $(@($diff).Count)" }
$hx = (Get-Win32ToolkitPriorInstallHash -Config ([pscustomobject]@{})) -cmatch '^[0-9A-F]{64}$'
if ($hx) { Ok 'an empty config still hashes (no throw)' } else { Bad 'empty config hash' }
# A dictionary (an entry or a proposal built in memory) hashes like the same fields of a parsed object - its keys are its
# fields - so two different dictionaries never share one empty-field tuple (the validator reads dictionaries too).
$dict = [ordered]@{}; foreach ($pp in (Entry).PSObject.Properties) { $dict[$pp.Name] = $pp.Value }
$dict2 = [ordered]@{}; foreach ($pp in (Entry @{ Key = 'Other'; ProcessNames = @('other', 'x') }).PSObject.Properties) { $dict2[$pp.Name] = $pp.Value }
$td = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $dict
if ($td -ceq $t0 -and (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $dict2) -ceq (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry (Entry @{ Key = 'Other'; ProcessNames = @('other', 'x') })) -and (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $dict2) -cne $td) {
    Ok 'tuple of a dictionary = tuple of the same object (a different dictionary hashes differently)'
} else { Bad "dictionary tuple: $td vs $t0" }
$bd = Cfg @($dict, (Entry @{ Id = 'inno-x86'; Key = 'App_is1'; View = 'Wow6432'; Mode = 'Block' }))
if ((Get-Win32ToolkitPriorInstallHash -Config $bd) -ceq $h0) { Ok 'binding with a dictionary entry = binding with the same object entry' } else { Bad 'dictionary entry changes the binding' }

# == [6] the version parser ============================================================================
Write-Host '[6] ConvertTo-Win32ToolkitPriorVersion = the device parser' -ForegroundColor Cyan
foreach ($c in @(@('8.9', '8.9.0.0'), @('26.02', '26.2.0.0'), @('v3.0.17.4', '3.0.17.4'), @('8.9-beta', '8.9.0.0'), @('8.9.', '8.9.0.0'), @('3.12.10150.0', '3.12.10150.0'), @('8.8.9 (x64)', '8.8.9.0'),
        @('8.9.1234567890', ''), @('8.9.8.1.5', ''), @('1234567890', ''), @('', ''), @('x.y', ''))) {
    $v = ConvertTo-Win32ToolkitPriorVersion -Text $c[0]
    $got = if ($v) { $v.ToString() } else { '' }
    if ($got -ceq $c[1]) { Ok "'$($c[0])' -> '$($c[1])'" } else { Bad "'$($c[0])' -> '$got', want '$($c[1])'" }
}
foreach ($f in 'Test-Win32ToolkitPriorInstallEntry', 'Get-Win32ToolkitPriorInstallHash', 'ConvertTo-Win32ToolkitPriorVersion') {
    if (@([IO.File]::ReadAllBytes((Join-Path $repo "Private\$f.ps1")) | Where-Object { $_ -gt 127 }).Count -eq 0) { Ok "$f.ps1 is ASCII-only" } else { Bad "$f.ps1 has non-ASCII bytes" }
}

# == [7] never more lenient than the device ============================================================
# The device re-checks the host rules (text B, 'the host rules again') and refuses a Block/Enforce entry with invalid
# data on EVERY device (69105). The host must refuse at least what the device refuses: a value the host accepted and the
# device refuses would ship past Export and fail the whole fleet. The device text runs here in-process with the registry
# shadowed (every uninstall key absent), so a valid entry gives 'Absent' and invalid data 'Refuse' 69105.
Write-Host '[7] the host refuses every entry the device refuses as invalid data (trailing line breaks, own identity)' -ForegroundColor Cyan
function Get-DeviceVerdict($Config) {
    function Test-Path { param([string]$LiteralPath, [string]$PathType) if ($LiteralPath -like 'HKLM:*') { return $false }; throw "unexpected path $LiteralPath $PathType" }
    function Get-ItemProperty { throw 'no registry value is read for an absent key' }
    . ([scriptblock]::Create((Get-Win32ToolkitDeployScriptBlock -Name PriorPredicate)))
    . ([scriptblock]::Create((Get-Win32ToolkitDeployScriptBlock -Name PriorEvaluate)))
    foreach ($e in @($Config.PriorInstalls.Entries)) {
        $d = & $w32tPrEvaluate $e $Config
        if ($d.Outcome -eq 'Refuse' -and $d.Code -eq 69105) { 'invalid' } else { [string]$d.Outcome }
    }
}
if ((Get-DeviceVerdict (Cfg @((Entry)))) -eq 'Absent') { Ok 'the device text runs here: a valid entry whose key is absent -> Absent' } else { Bad "device harness: $(Get-DeviceVerdict (Cfg @((Entry))))" }
$lf = "`n"
foreach ($c in @(
        @{ L = 'Id'; O = @{ Id = "nsis-x64$lf" } }
        @{ L = 'UninstallerFileName'; O = @{ UninstallerFileName = "uninstall.exe$lf" } }
        @{ L = 'MainExe'; O = @{ MainExe = "notepad++.exe$lf" } }
        @{ L = 'a process name'; O = @{ ProcessNames = @("notepad++$lf") } }
        @{ L = 'InstallDir'; O = @{ InstallDir = "%ProgramFiles%\Notepad++$lf" } }
        @{ L = 'Key'; O = @{ Key = "Notepad++$lf" } }
    )) {
    $cfg = Cfg @((Entry $c.O))
    $dev = Get-DeviceVerdict $cfg
    $r = V $cfg
    if ($dev -eq 'invalid' -and -not $r.Valid) { Ok "$($c.L) with a trailing line break: the device refuses it (69105), and so does the host" } else { Bad "$($c.L) + LF: device '$dev', host valid=$($r.Valid)" }
}
foreach ($c in @(@{ L = 'CaptureId'; O = @{ Source = 'SiblingCapture'; CaptureId = "3f9c0a7d51e2b846$lf" } }, @{ L = 'AddedOn'; O = @{ AddedOn = "2026-10-25$lf" } }, @{ L = 'AddedOn with non-ASCII digits'; O = @{ AddedOn = "2026-10-2$([char]0x0665)" } })) {
    if (-not (V (Cfg @((Entry $c.O)))).Valid) { Ok "$($c.L) (host-only metadata) with a trailing line break or a non-ASCII digit -> invalid" } else { Bad "$($c.L) accepted" }
}
# Every row of the field matrix: whatever the device refuses as invalid data, the host refuses too.
$lenient = @(foreach ($c in $bad) { $cfg = Cfg @((Entry $c.O)); if ((Get-DeviceVerdict $cfg) -eq 'invalid' -and (V $cfg).Valid) { $c.L } })
if ($lenient.Count -eq 0) { Ok "field matrix: no row the device refuses is accepted by the host ($($bad.Count) rows)" } else { Bad "host more lenient than the device: $($lenient -join ', ')" }
# Own identity: the device refuses an Enforce entry unless OwnIdentity holds an own uninstall key or product code.
$ucOnly = [pscustomobject]@{ SchemaVersion = '1.0'; ProductCode = ''; UpgradeCode = $UC; ArpKeys = @(); CapturedOn = '2026-10-25' }
$cfg = Cfg @((Entry)) @{ OwnIdentity = $ucOnly }
$r = V $cfg
if ((Get-DeviceVerdict $cfg) -eq 'invalid' -and -not $r.Valid -and (Has $r 'at least one own uninstall key or product code') -and -not (Has $r "own uninstall identity is unknown|needs this package's OwnIdentity")) {
    Ok 'Enforce with an OwnIdentity that holds only an UpgradeCode: the device refuses it (69105) and the host reports it as invalid data (not as a missing OwnIdentity)'
} else { Bad "UpgradeCode-only Enforce: device '$(Get-DeviceVerdict $cfg)', host $($r.Problems -join ' | ')" }
$cfg = Cfg @((Entry @{ Mode = 'Block' })) @{ OwnIdentity = $ucOnly }
if ((Get-DeviceVerdict $cfg) -eq 'Absent' -and (V $cfg).Valid) { Ok 'the same OwnIdentity with a Block entry: valid on both (an UpgradeCode is a known own identity, L28)' } else { Bad "UpgradeCode-only Block: device '$(Get-DeviceVerdict $cfg)', host $((V $cfg).Problems -join ' | ')" }
$cfg = Cfg @((Entry @{ Key = 'Git_is1' })) @{ OwnIdentity = $ucOnly; Uninstall = [pscustomobject]@{ ProductCodes = @(); PrimaryKeys = @([pscustomobject]@{ Name = 'Git'; View = 'Registry64' }) } }
if ((Get-DeviceVerdict $cfg) -eq 'Absent' -and (V $cfg).Valid) { Ok 'an Uninstall.PrimaryKeys name is an own key for both (Enforce valid)' } else { Bad "primary key own: device '$(Get-DeviceVerdict $cfg)', host $((V $cfg).Problems -join ' | ')" }
# JSON-typed falsy values (a hand-edited AppConfig.json; the toolkit's writers always emit an OwnIdentity object and string
# process names). The device reads the file with ConvertFrom-Json and tests truthiness: '', 0 and false are no OwnIdentity
# (-not $w32tOwnId) and no process name (Where-Object { $_ }). The configs go through ConvertTo-Json | ConvertFrom-Json so
# both sides see exactly the JSON types the device sees.
function Json($Config) { $Config | ConvertTo-Json -Depth 10 | ConvertFrom-Json }
$ownUninstall = @(
    @{ L = 'Uninstall.ProductCodes'; U = [pscustomobject]@{ ProductCodes = @('{11111111-2222-3333-4444-555555555555}') } }
    @{ L = 'Uninstall.PrimaryKeys'; U = [pscustomobject]@{ ProductCodes = @(); PrimaryKeys = @([pscustomobject]@{ Name = 'Git'; View = 'Registry64' }) } }
)
foreach ($o in @('', 0, $false)) {
    $show = ConvertTo-Json $o -Compress
    foreach ($u in $ownUninstall) {
        $cfg = Json (Cfg @((Entry)) @{ OwnIdentity = $o; Uninstall = $u.U })
        $dev = Get-DeviceVerdict $cfg
        $r = V $cfg
        if ($dev -eq 'invalid' -and -not $r.Valid -and (Has $r "needs this package's OwnIdentity")) { Ok "Enforce with OwnIdentity $show next to $($u.L): the device refuses it (69105), and so does the host" } else { Bad "OwnIdentity $show + $($u.L) (Enforce): device '$dev', host valid=$($r.Valid) $($r.Problems -join ' | ')" }
        $cfg = Json (Cfg @((Entry @{ Mode = 'Block' })) @{ OwnIdentity = $o; Uninstall = $u.U })
        $dev = Get-DeviceVerdict $cfg
        $r = V $cfg
        if ($dev -eq 'Absent' -and $r.Valid) { Ok "Block with OwnIdentity $show next to $($u.L): valid on both (the Uninstall key is a known own identity)" } else { Bad "OwnIdentity $show + $($u.L) (Block): device '$dev', host $($r.Problems -join ' | ')" }
    }
}
foreach ($c in @(@{ L = '[0]'; P = @(0) }, @{ L = '[false]'; P = @($false) }, @{ L = "['']"; P = @('') })) {
    $cfg = Json (Cfg @((Entry @{ ProcessNames = $c.P })))
    $dev = Get-DeviceVerdict $cfg
    $r = V $cfg
    if ($dev -eq 'invalid' -and -not $r.Valid -and (Has $r 'needs at least one ProcessName') -and (Has $r 'ProcessNames must be plain process names')) {
        Ok "Enforce with ProcessNames $($c.L): no process name on the device (69105), and none on the host"
    } else { Bad "ProcessNames $($c.L): device '$dev', host valid=$($r.Valid) $($r.Problems -join ' | ')" }
}
# The host stays stricter where the device drops a falsy name silently: 0 next to a real name, or in a Block entry.
foreach ($c in @(@{ L = "Enforce [0, 'notepad++']"; O = @{ ProcessNames = @(0, 'notepad++') } }, @{ L = 'Block [false]'; O = @{ Mode = 'Block'; ProcessNames = @($false) } })) {
    $r = V (Json (Cfg @((Entry $c.O))))
    if (-not $r.Valid -and (Has $r 'ProcessNames must be plain process names')) { Ok "$($c.L): the host refuses the falsy name (never a '0' / 'False' process name)" } else { Bad "$($c.L): host valid=$($r.Valid) $($r.Problems -join ' | ')" }
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PriorInstallEntry tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PriorInstallEntry test(s) FAILED." -ForegroundColor Red; exit 1 }
