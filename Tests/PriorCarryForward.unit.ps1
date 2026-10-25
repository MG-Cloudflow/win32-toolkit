<#
    Installer-identity PR 3 (spec 2.13; D18, L4, L5, L33, L34, D61, D20): the prior-install rules of a new version come
    from the version it rebuilds (snapshot + restore) or from the version before it (carry-forward), and are re-checked
    once the install capture recorded the package's own identity.

      [1] carry: a predecessor 8.9.8.1 (not published: L5 needs no anchor) with an Enforce operator rule -> 8.9.9 gets it
          with VersionMax 8.9.9 and the host line; the process names merged (D20); waivers are not carried; a
          SiblingCapture rule keeps its VersionMax (D61); no predecessor -> nothing, AppConfig untouched.
      [2] the source (L5): a v2 with an emptied list above a v1 with rules -> v2 is the source, nothing is carried; an
          x86 project of the same app is never the source of an x64 one; a project without the property is skipped.
      [3] own family (L33): an EXE package's operator rule -> VersionMax = the predecessor's App.Version.
      [4] re-validation (-PreCapture): a rule naming the MSI's own ProductCode -> ID-PRIOR-OWN, not carried; a rule failing
          another check -> dropped with a warning naming it.
      [5] same-version rebuild (L4): the snapshot holds the rules, the decisions and the capture files; restored as they
          were (no bump, Enforce kept before OwnIdentity exists), TestResults.json not restored, process names merged.
      [6] after the install capture (L34): an EXE package whose capture shows the carried key as its own -> ID-PRIOR-OWN,
          the rule removed and the rest valid with the full rules; a carry followed by a re-capture
          (Update-PSADTProcessesToClose) keeps notepad++ in ProcessesToClose.

    Run:  pwsh -File Tests\PriorCarryForward.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32cf_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
$PC = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'

function New-Entry([hashtable]$O = @{}) {
    $e = [ordered]@{ Id = 'nsis-x64'; Kind = 'ArpKey'; Mode = 'Enforce'; Key = 'Notepad++'; View = 'Native'; Publisher = 'Notepad++ Team'; DisplayName = 'Notepad++ (64-bit x64)'
        DisplayNameTemplate = ''; VersionMin = '8.7.9'; VersionMax = '8.9.8.1'; UninstallerType = 'nullsoft'; UninstallerFileName = 'uninstall.exe'; UninstallerSigner = ''
        InstallDir = '%ProgramFiles%\Notepad++'; MainExe = 'notepad++.exe'; ProcessNames = @('notepad++'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-20' }
    foreach ($k in $O.Keys) { $e[$k] = $O[$k] }
    $e
}
# A project folder as the toolkit leaves it after configure (no Files: the winget id is persisted in Source).
function New-CfProject {
    param([string]$Template = 'Contoso', [string]$Version, [string]$Arch = 'x64', [string]$Type = 'msi', [object[]]$Entries, [switch]$NoPrior, [string]$ProductCode = '', [string[]]$Processes = @('zeta'), [string]$Name)
    if (-not $Name) { $Name = "Notepad++_${Arch}_$Version" }
    $p = Join-Path $root "Projects\$Template\$Name"
    foreach ($d in 'SupportFiles', 'Documentation', 'Files') { $null = New-Item -ItemType Directory -Path (Join-Path $p $d) -Force }
    [IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), '# deploy script', $utf8)
    $cfg = [ordered]@{ SchemaVersion = '1.0'
        App = [ordered]@{ Vendor = 'Notepad++ Team'; Name = ''; DisplayName = 'Notepad++'; Version = $Version; Arch = $Arch; ScriptAuthor = 'Contoso IT'; ScriptDate = '2026-10-20' }
        Installer = [ordered]@{ Type = $Type; FileName = "npp.$Type"; SilentArgs = '' }
        ProcessesToClose = @($Processes)
        Source = [ordered]@{ SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Version = $Version; InstallerType = $(if ($Type -eq 'msi') { 'wix' } else { 'nullsoft' }); Family = $Type; Architecture = $Arch; PinnedBy = 'winget-default'; ProductCode = $ProductCode } }
    if (-not $NoPrior) { $cfg['PriorInstalls'] = [ordered]@{ SchemaVersion = '1.0'; Entries = @($Entries) } }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $p
}
function Get-Cfg([string]$P) { Get-Content -LiteralPath (Join-Path $P 'SupportFiles\AppConfig.json') -Raw | ConvertFrom-Json }
function Invoke-Copy([string]$P, $Snapshot) {
    $script:hostLines = @(); $script:warnLines = @()
    $out = @(Copy-Win32ToolkitPriorInstallState -ProjectPath $P -Snapshot $Snapshot -WarningVariable w 3>$null 6>&1)
    $script:hostLines = @($out | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
    $script:warnLines = @($w | ForEach-Object { "$_" })
    @($out | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })[0]
}

try {
    # == [1] carry ============================================================================================
    Write-Host '[1] carry-forward from the version before' -ForegroundColor Cyan
    $old = New-CfProject -Template 'T1' -Version '8.9.8.1' -Entries @((New-Entry), (New-Entry @{ Id = 'inno-x86'; Key = 'NppInno_is1'; View = 'Wow6432'; UninstallerType = 'inno'; Source = 'SiblingCapture'; CaptureId = '3f9c0a7d51e2b846'; VersionMax = '8.9.8.1'; InstallDir = '%ProgramFiles(x86)%\NppInno'; ProcessNames = @('npp-inno') }))
    [IO.File]::WriteAllText((Join-Path $old 'Documentation\PriorInstallDecisions.json'), '{"SchemaVersion":"1.0","Records":[{"Kind":"Waiver","Code":"PROOF","Target":"nsis-x64","Reason":"pilot","On":"2026-10-20"}]}', $utf8)
    $new = New-CfProject -Template 'T1' -Version '8.9.9'
    $s = Invoke-Copy $new $null
    $cfg = Get-Cfg $new
    $n = @($cfg.PriorInstalls.Entries | Where-Object Id -eq 'nsis-x64')[0]
    $c = @($cfg.PriorInstalls.Entries | Where-Object Id -eq 'inno-x86')[0]
    if ($s.Action -eq 'Carried' -and $s.Source -eq $old -and $n.VersionMax -eq '8.9.9' -and $n.Mode -eq 'Enforce' -and $n.VersionMin -eq '8.7.9') { Ok 'an unpublished 8.9.8.1 with an Enforce operator rule -> 8.9.9 carries it with VersionMax 8.9.9 (D18, L5)' } else { Bad "carry: $($s | ConvertTo-Json -Compress) $($n | ConvertTo-Json -Compress)" }
    if ($c -and $c.VersionMax -eq '8.9.8.1') { Ok 'a SiblingCapture rule keeps its VersionMax (D61)' } else { Bad "capture rule: $($c | ConvertTo-Json -Compress)" }
    if (($script:hostLines -join "`n") -match [regex]::Escape('Carried 2 prior-install rules from Notepad++_x64_8.9.8.1 (Enforce: ARP NppInno_is1, Enforce: ARP Notepad++); they need a new proof run.')) { Ok 'the host line names the source, the modes and keys, and the new proof run' } else { Bad "host: $($script:hostLines -join ' | ')" }
    if ((@($cfg.ProcessesToClose) -join ',') -ceq 'notepad++,npp-inno,zeta') { Ok 'D20: the carried process names are merged into ProcessesToClose' } else { Bad "ptc: $(@($cfg.ProcessesToClose) -join ',')" }
    if (-not (Test-Path -LiteralPath (Join-Path $new 'Documentation\PriorInstallDecisions.json'))) { Ok 'waivers are not carried (they were decisions about the previous package)' } else { Bad 'decisions copied' }
    $none = New-CfProject -Template 'T1b' -Version '1.0' -Name 'Other_x64_1.0' -NoPrior
    $h0 = (Get-FileHash (Join-Path $none 'SupportFiles\AppConfig.json')).Hash
    $s = Invoke-Copy $none $null
    if ($s.Action -eq 'None' -and (Get-FileHash (Join-Path $none 'SupportFiles\AppConfig.json')).Hash -eq $h0 -and $script:hostLines.Count -eq 0) { Ok 'no predecessor -> nothing carried, AppConfig.json untouched' } else { Bad "none: $($s | ConvertTo-Json -Compress)" }

    # == [2] the source =======================================================================================
    Write-Host '[2] the carry-forward source (L5)' -ForegroundColor Cyan
    $v1 = New-CfProject -Template 'T2' -Version '8.9.7' -Entries @((New-Entry))
    $v2 = New-CfProject -Template 'T2' -Version '8.9.8' -Entries @()
    $v3 = New-CfProject -Template 'T2' -Version '8.9.9' -NoPrior
    $src = Get-Win32ToolkitPriorCarrySource -ProjectPath $v3
    $s = Invoke-Copy $v3 $null
    $cfg = Get-Cfg $v3
    if ($src.Path -eq $v2 -and $s.Action -eq 'Carried' -and @($cfg.PriorInstalls.Entries).Count -eq 0 -and $null -ne $cfg.PSObject.Properties['PriorInstalls']) { Ok 'a v2 with an emptied list above a v1 with rules is the source: nothing is carried (removed rules stay removed)' } else { Bad "emptied (v1 $(Split-Path -Leaf $v1)): src=$($src.Path) $($cfg.PriorInstalls | ConvertTo-Json -Compress)" }
    $null = New-CfProject -Template 'T3' -Version '8.9.8.5' -Arch 'x86' -Entries @((New-Entry @{ Id = 'nsis-x86'; View = 'Wow6432'; InstallDir = '%ProgramFiles(x86)%\Notepad++' }))
    $x64 = New-CfProject -Template 'T3' -Version '8.9.9' -NoPrior
    if ($null -eq (Get-Win32ToolkitPriorCarrySource -ProjectPath $x64)) { Ok 'an x86 project of the same app is never the source of an x64 project' } else { Bad 'x86 source' }
    $x64old = New-CfProject -Template 'T3' -Version '8.9.8.1' -Entries @((New-Entry))
    if ((Get-Win32ToolkitPriorCarrySource -ProjectPath $x64).Path -eq $x64old) { Ok '...the highest x64 one below is (the higher x86 one skipped)' } else { Bad 'x64 source' }
    $noProp = New-CfProject -Template 'T3' -Version '8.9.8.4' -NoPrior
    if ((Get-Win32ToolkitPriorCarrySource -ProjectPath $x64).Path -eq $x64old) { Ok 'a higher project without a PriorInstalls property is skipped' } else { Bad "noprop: $noProp" }

    # == [3] own family =======================================================================================
    Write-Host '[3] own family (an EXE package, L33)' -ForegroundColor Cyan
    $eOld = New-CfProject -Template 'T4' -Version '8.9.8' -Type 'exe' -Entries @((New-Entry @{ Id = 'inno-x64'; Key = 'NppInno_is1'; UninstallerType = 'inno'; VersionMax = '8.9.7' }))
    $eNew = New-CfProject -Template 'T4' -Version '8.9.9' -Type 'exe' -NoPrior
    $null = Invoke-Copy $eNew $null
    $e = @((Get-Cfg $eNew).PriorInstalls.Entries)[0]
    if ($e.VersionMax -eq '8.9.8') { Ok "an EXE package's operator rule -> VersionMax = the predecessor's App.Version (8.9.8, below the new 8.9.9)" } else { Bad "own family: $($e.VersionMax) (source $eOld)" }

    # == [4] re-validation ====================================================================================
    Write-Host '[4] re-validated against the new package (-PreCapture)' -ForegroundColor Cyan
    $null = New-CfProject -Template 'T5' -Version '2.0' -Entries @((New-Entry), (New-Entry @{ Id = 'msi-own'; Key = $PC; Mode = 'Block' }), (New-Entry @{ Id = 'bad-x64'; Key = 'Bad'; Publisher = '' }))
    $mNew = New-CfProject -Template 'T5' -Version '2.1' -ProductCode $PC -NoPrior
    $s = Invoke-Copy $mNew $null
    $ids = @((Get-Cfg $mNew).PriorInstalls.Entries | ForEach-Object Id) -join ','
    if ($ids -eq 'nsis-x64' -and @($s.Own) -contains 'msi-own' -and @($script:warnLines | Where-Object { $_ -like 'ID-PRIOR-OWN:*msi-own*' }).Count -eq 1) { Ok "a rule naming the MSI's own ProductCode -> ID-PRIOR-OWN, not carried" } else { Bad "own: ids=$ids $($s | ConvertTo-Json -Compress) warn=$($script:warnLines -join ' | ')" }
    if (@($s.Dropped | Where-Object Id -eq 'bad-x64').Count -eq 1 -and @($script:warnLines | Where-Object { $_ -like "*'bad-x64'*Publisher*" }).Count -eq 1) { Ok 'a rule failing another check -> dropped, the warning names the problem' } else { Bad "dropped: $($s.Dropped | ConvertTo-Json -Compress) warn=$($script:warnLines -join ' | ')" }

    # == [5] same-version rebuild =============================================================================
    Write-Host '[5] same-version rebuild (L4)' -ForegroundColor Cyan
    $rb = New-CfProject -Template 'T6' -Version '8.9.9' -Entries @((New-Entry @{ VersionMax = '8.9.9' }))
    $decText = '{"SchemaVersion":"1.0","Records":[{"Kind":"Acknowledgement","Code":"DATA-LOSS","Target":"nsis-x64","Reason":"settings in APPDATA","On":"2026-10-21"}]}'
    [IO.File]::WriteAllText((Join-Path $rb 'Documentation\PriorInstallDecisions.json'), $decText, $utf8)
    $null = New-Item -ItemType Directory -Path (Join-Path $rb 'Documentation\SiblingCapture') -Force
    [IO.File]::WriteAllText((Join-Path $rb 'Documentation\SiblingCapture\3f9c0a7d51e2b846.json'), '{"SchemaVersion":"1.0"}', $utf8)
    [IO.File]::WriteAllText((Join-Path $rb 'Documentation\SiblingCapture.json'), '{"Plan":[]}', $utf8)
    [IO.File]::WriteAllText((Join-Path $rb 'Documentation\TestResults.json'), '[]', $utf8)
    $snap = Get-Win32ToolkitPriorInstallSnapshot -ProjectPath $rb
    if ($snap -and $snap.HasPriorInstalls -and $null -ne $snap.Decisions -and @($snap.CaptureFiles).Count -eq 2) { Ok 'the snapshot holds the rules, the decisions and the two capture files' } else { Bad "snapshot: $($snap | ConvertTo-Json -Compress -Depth 3)" }
    Remove-Item -LiteralPath $rb -Recurse -Force
    $rb = New-CfProject -Template 'T6' -Version '8.9.9' -NoPrior
    $s = Invoke-Copy $rb $snap
    $cfg = Get-Cfg $rb
    $e = @($cfg.PriorInstalls.Entries)[0]
    if ($s.Action -eq 'Restored' -and $e.Mode -eq 'Enforce' -and $e.VersionMax -eq '8.9.9' -and $null -eq $cfg.PSObject.Properties['OwnIdentity']) { Ok 'the rules restored as they were: the Enforce rule kept before the capture wrote OwnIdentity (-PreCapture), no bump' } else { Bad "restore: $($s | ConvertTo-Json -Compress) $($e | ConvertTo-Json -Compress)" }
    $decNow = [IO.File]::ReadAllText((Join-Path $rb 'Documentation\PriorInstallDecisions.json'))
    $capNow = Test-Path -LiteralPath (Join-Path $rb 'Documentation\SiblingCapture\3f9c0a7d51e2b846.json')
    if ($decNow -ceq $decText -and $capNow -and (Test-Path -LiteralPath (Join-Path $rb 'Documentation\SiblingCapture.json')) -and -not (Test-Path -LiteralPath (Join-Path $rb 'Documentation\TestResults.json'))) { Ok 'the decisions and capture files restored byte for byte; TestResults.json not (a new proof run is needed)' } else { Bad 'restored files' }
    if ((@($cfg.ProcessesToClose) -join ',') -ceq 'notepad++,zeta' -and ($script:hostLines -join "`n") -match 'Kept 1 prior-install rule of the rebuilt version \(Enforce: ARP Notepad\+\+\); it needs a new proof run\.') { Ok 'process names merged; the host line says the rule was kept' } else { Bad "restore ptc/host: $(@($cfg.ProcessesToClose) -join ',') | $($script:hostLines -join ' | ')" }
    $empty = Join-Path $root 'Projects\T6\Empty_x64_1.0'
    $null = New-Item -ItemType Directory -Path $empty -Force
    if ($null -eq (Get-Win32ToolkitPriorInstallSnapshot -ProjectPath $empty) -and $null -eq (Get-Win32ToolkitPriorInstallSnapshot -ProjectPath (Join-Path $root 'missing'))) { Ok 'nothing to keep (or no folder) -> no snapshot' } else { Bad 'empty snapshot' }

    # == [6] after the install capture ========================================================================
    Write-Host '[6] after the install capture (L34)' -ForegroundColor Cyan
    $null = New-CfProject -Template 'T7' -Version '8.9.8' -Type 'exe' -Entries @((New-Entry @{ VersionMax = '8.9.7' }), (New-Entry @{ Id = 'inno-x64'; Key = 'NppInno_is1'; UninstallerType = 'inno'; VersionMax = '8.9.7'; ProcessNames = @('npp-inno') }))
    $ex = New-CfProject -Template 'T7' -Version '8.9.9' -Type 'exe' -NoPrior
    $null = Invoke-Copy $ex $null
    $cfg = Get-Cfg $ex
    $cfg | Add-Member -NotePropertyName OwnIdentity -NotePropertyValue ([pscustomobject]@{ SchemaVersion = '1.0'; ProductCode = ''; UpgradeCode = ''; ArpKeys = @([pscustomobject]@{ Key = 'Notepad++'; View = 'Native' }); CapturedOn = '2026-10-25' }) -Force
    [IO.File]::WriteAllText((Join-Path $ex 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $sync = Sync-Win32ToolkitPriorInstallOwnIdentity -ProjectPath $ex -WarningVariable sw 3>$null
    $cfg = Get-Cfg $ex
    $full = Test-Win32ToolkitPriorInstallEntry -Config $cfg -Decisions @() -Records @()
    if ((@($cfg.PriorInstalls.Entries | ForEach-Object Id) -join ',') -eq 'inno-x64' -and @($sync.Own) -contains 'nsis-x64' -and @($sw | Where-Object { "$_" -like 'ID-PRIOR-OWN:*nsis-x64*' }).Count -eq 1 -and $full.Valid) {
        Ok 'an EXE package whose capture shows the carried key as its own -> ID-PRIOR-OWN, the rule removed, the rest valid with the full rules'
    } else { Bad "sync: $(@($cfg.PriorInstalls.Entries | ForEach-Object Id) -join ',') own=$(@($sync.Own) -join ',') valid=$($full.Valid) $($full.Problems -join '; ')" }
    $h1 = (Get-FileHash (Join-Path $ex 'SupportFiles\AppConfig.json')).Hash
    $null = Sync-Win32ToolkitPriorInstallOwnIdentity -ProjectPath $ex 3>$null
    if ((Get-FileHash (Join-Path $ex 'SupportFiles\AppConfig.json')).Hash -eq $h1) { Ok 'nothing to drop -> AppConfig.json not written' } else { Bad 'rewritten without a change' }
    $capJson = Join-Path $ex 'Documentation\InstallationChanges_20261025_101010.json'
    $capture = @{ InstallationInfo = @{ PsadtExitCode = 0 }; NewFiles = @(); NewRegistryKeys = @(@{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\otherapp.exe'; KeyName = 'otherapp.exe'; Values = @{} }) }
    [IO.File]::WriteAllText($capJson, ($capture | ConvertTo-Json -Depth 6), $utf8)
    $null = Update-PSADTProcessesToClose -ProjectPath $ex -JsonFilePath $capJson 3>$null 6>$null
    $ptc = @((Get-Cfg $ex).ProcessesToClose)
    if ($ptc -contains 'notepad++' -and $ptc -contains 'npp-inno' -and $ptc -contains 'otherapp') { Ok 'carry + a re-capture (Update-PSADTProcessesToClose): ProcessesToClose keeps notepad++ next to the captured app' } else { Bad "ptc after capture: $($ptc -join ',')" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PriorCarryForward tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PriorCarryForward test(s) FAILED." -ForegroundColor Red; exit 1 }
