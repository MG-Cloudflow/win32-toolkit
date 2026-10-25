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
      [7] capture lineage (PR 3b, A1): a carried captured rule brings its capture records (its CaptureId and every record
          of the same identity, byte for byte; a record of another identity stays behind) and its latest Approval (not the
          waivers); in the new project they are hash-verified and re-derive the rule (no PRIOR-CAPTURE-RECORD, no PRIOR-APPROVAL).
      A same-family rule (an EXE package; S3 cut its window below the old package version) carried to the next version
      keeps its VersionMax and passes while a record observed it; a VersionMax no record observed, or one only a record
      of another identity observed -> PRIOR-CAPTURE-RECORD (PriorInstallFinding.unit [9]: a cross-family rule stays exact).
      [8] per entry (C-7): a hand-edited rule without a VersionMax property, an invalid Id, a duplicate Id and the entries
          that are not objects (a string, [] and [null]) never cost the valid rules next to them; each bad one is dropped
          with a warning.
      [9] GUEST-TAMPER: the same-version rebuild of a project a test guest changed (here the first version: nothing to
          carry from) keeps no rule, decision or capture record, but records which rules there were
          (Documentation\PriorInstallDropped.json): Export lists one ID-PRIOR-DROPPED row per lost rule until it is
          declared again or acknowledged; a second rebuild keeps the record; the next version gets the open ones; an
          unreadable record refuses the Export. A carry source a test guest changed gives an empty list, and Export lists
          its rules as ID-PRIOR-DROPPED, also after the source is re-created.
      [10] after the install capture: a key of Uninstall.PrimaryKeys ({ Name; View }) is the package's own (ID-PRIOR-OWN);
          a rule with an invalid Id is dropped.

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

    # == [7] capture lineage: records and approvals ==========================================================
    Write-Host '[7] a carried captured rule brings its records and its approval (A1)' -ForegroundColor Cyan
    . (Join-Path $repo 'Tests\Fixtures\sibling-proposal\SiblingFixture.ps1')
    $src = New-CfProject -Template 'T8' -Version '8.9.8.1' -NoPrior
    $floorId = Write-TestSiblingRecord -ProjectPath $src -Record (New-TestSiblingRecord -Version '8.7.9' -Role Floor)
    $newId = Write-TestSiblingRecord -ProjectPath $src -Record (New-TestSiblingRecord -Version '8.9.8')
    $innoIds = @(foreach ($v in '8.7.9', '8.9.8') { Write-TestSiblingRecord -ProjectPath $src -Record (New-TestSiblingRecord -Type inno -Version $v -Key 'NppInno_is1' -InnoMarkers -ProductCodes @('NppInno_is1') -DisplayName 'Npp Inno' -Dir 'NppInno' -Main 'npp.exe' -Uninstaller 'unins000.exe') })
    $sib = ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $src -PackageSigner ([pscustomobject]@{ Status = 'Valid'; Subject = $script:TestSiblingSigner })
    $pp = @($sib.Proposals | Where-Object ProposalId -ceq 'nsis-x64')[0]
    $entry = New-Entry @{ Source = 'SiblingCapture'; CaptureId = $floorId; VersionMin = $pp.VersionMin; VersionMax = $pp.VersionMax; UninstallerSigner = $pp.UninstallerSigner }
    $cfg = Get-Cfg $src
    $cfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject]@{ SchemaVersion = '1.0'; Entries = @([pscustomobject]$entry) }) -Force
    [IO.File]::WriteAllText((Join-Path $src 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $tuple = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry (Get-Cfg $src).PriorInstalls.Entries[0]
    $null = Set-Win32ToolkitPriorInstallDecision -ProjectPath $src -Record @{ Kind = 'Approval'; Code = 'SIBLING-ENFORCE'; Target = 'nsis-x64'; ProposalId = 'nsis-x64'; ProposalHash = $tuple; CaptureIds = @($floorId, $newId); On = '2026-10-20'; Demoted = '' } -Confirm:$false
    $null = Set-Win32ToolkitPriorInstallDecision -ProjectPath $src -Record @{ Kind = 'Acknowledgement'; Code = 'DATA-LOSS'; Target = 'nsis-x64'; Reason = 'old package'; On = '2026-10-20' } -Confirm:$false
    $dst = New-CfProject -Template 'T8' -Version '8.9.9' -NoPrior
    $sum = Invoke-Copy $dst $null
    $copied = @(Get-ChildItem -LiteralPath (Join-Path $dst 'Documentation\SiblingCapture') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } | Sort-Object)
    $same = @($floorId, $newId | ForEach-Object { (Get-FileHash (Join-Path $src "Documentation\SiblingCapture\$_.json")).Hash -ceq (Get-FileHash (Join-Path $dst "Documentation\SiblingCapture\$_.json")).Hash }) -notcontains $false
    if ($sum.Records -eq 2 -and ($copied -join ',') -ceq ((@($floorId, $newId) | Sort-Object) -join ',') -and $same -and @($copied | Where-Object { $innoIds -ccontains $_ }).Count -eq 0) {
        Ok 'the records of the carried rule copied byte for byte (its floor and the same-identity newest); the other identity''s records stay behind'
    } else { Bad "records: $($sum.Records) $($copied -join ',')" }
    $verified = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $dst | ForEach-Object { $_.CaptureId } | Sort-Object)
    $dec = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $dst)
    if (($verified -join ',') -ceq ($copied -join ',') -and $sum.Approvals -eq 1 -and $dec.Count -eq 1 -and $dec[0].Kind -eq 'Approval' -and $dec[0].ProposalHash -ceq $tuple -and $dec[0].Latest -and -not $dec[0].Demoted) {
        Ok 'in the new project the records are hash-verified; the latest Approval copied (the DATA-LOSS acknowledgement was not)'
    } else { Bad "verified: $($verified -join ',') / $($dec | ConvertTo-Json -Compress)" }
    $rows = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $dst -Stage Export | Where-Object { $_.Code -in 'PRIOR-CAPTURE-RECORD', 'PRIOR-APPROVAL' })
    $e = @((Get-Cfg $dst).PriorInstalls.Entries)[0]
    if ($rows.Count -eq 0 -and $e.VersionMax -ceq $pp.VersionMax -and $e.CaptureId -ceq $floorId) { Ok 'the carried rule re-derives from the copied records (no PRIOR-CAPTURE-RECORD, no PRIOR-APPROVAL); VersionMax unchanged (D61)' } else { Bad "export rows: $($rows | ForEach-Object { "$($_.Code): $($_.Message)" })" }
    # A sibling of the package's own family (an EXE package, NSIS sibling): S3 cut the window below the package version
    # 8.9.8, so the 8.9.8 capture is outside it. The next version (8.9.9) carries the rule unchanged (D61) with both
    # records: the window waits for a new capture's raise, and Export accepts it while VersionMax is an observed version.
    $fSrc = New-CfProject -Template 'T8F' -Version '8.9.8' -Type 'exe' -NoPrior
    $fFloor = Write-TestSiblingRecord -ProjectPath $fSrc -Record (New-TestSiblingRecord -Version '8.7.9' -Role Floor)
    $null = Write-TestSiblingRecord -ProjectPath $fSrc -Record (New-TestSiblingRecord -Version '8.9.8')
    $fp = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $fSrc -PackageSigner ([pscustomobject]@{ Status = 'Valid'; Subject = $script:TestSiblingSigner })).Proposals)[0]
    $cfg = Get-Cfg $fSrc
    $cfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject]@{ SchemaVersion = '1.0'; Entries = @([pscustomobject](New-Entry @{ Mode = 'Block'; Source = 'SiblingCapture'; CaptureId = $fFloor; VersionMin = $fp.VersionMin; VersionMax = $fp.VersionMax; UninstallerSigner = $fp.UninstallerSigner })) }) -Force
    [IO.File]::WriteAllText((Join-Path $fSrc 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $srcRows = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $fSrc -Stage Export | Where-Object Code -eq 'PRIOR-CAPTURE-RECORD')
    $fDst = New-CfProject -Template 'T8F' -Version '8.9.9' -Type 'exe' -NoPrior
    $fSum = Invoke-Copy $fDst $null
    $fRows = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $fDst -Stage Export | Where-Object Code -eq 'PRIOR-CAPTURE-RECORD')
    $fe = @((Get-Cfg $fDst).PriorInstalls.Entries)[0]
    if ($fp.SameFamily -and $fp.VersionMax -eq '8.7.9.0' -and $srcRows.Count -eq 0 -and $fSum.Records -eq 2 -and $fe.VersionMax -eq '8.7.9.0' -and $fRows.Count -eq 0) {
        Ok 'a same-family captured rule (window cut below 8.9.8, S3) carried to 8.9.9 with both records: VersionMax unchanged (D61), no PRIOR-CAPTURE-RECORD'
    } else { Bad "same family: sf=$($fp.SameFamily) max=$($fp.VersionMax) src=$($srcRows.Count) records=$($fSum.Records) carried=$($fe.VersionMax) rows=$($fRows | ForEach-Object { $_.Message })" }
    $cfg = Get-Cfg $fDst
    $cfg.PriorInstalls.Entries[0].VersionMax = '8.8.0'
    [IO.File]::WriteAllText((Join-Path $fDst 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $fRows = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $fDst -Stage Export | Where-Object Code -eq 'PRIOR-CAPTURE-RECORD')
    if ($fRows.Count -eq 1 -and $fRows[0].Message -match 'covers 8\.7\.9\.0\.\.8\.8\.0') { Ok '...a VersionMax no record observed (8.8.0) -> PRIOR-CAPTURE-RECORD (the window is never typed)' } else { Bad "same family typed max: $($fRows | ForEach-Object { $_.Message })" }
    # ...nor a VersionMax only a record of ANOTHER identity observed: a third NSIS record at 8.8.0 with another main
    # program (npp.exe) is hash-verified but re-derives another Tuple, so 8.8.0.0 stays a typed window for this rule.
    $null = Write-TestSiblingRecord -ProjectPath $fDst -Record (New-TestSiblingRecord -Version '8.8.0' -Main 'npp.exe')
    $cfg = Get-Cfg $fDst
    $cfg.PriorInstalls.Entries[0].VersionMax = '8.8.0.0'
    [IO.File]::WriteAllText((Join-Path $fDst 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $fTuple = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry (Get-Cfg $fDst).PriorInstalls.Entries[0]
    $fCaps = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $fDst -PackageSigner ([pscustomobject]@{ Status = 'Valid'; Subject = $script:TestSiblingSigner })).Captures)
    $other = @($fCaps | Where-Object { (ConvertTo-Win32ToolkitPriorVersion -Text ([string]$_.ObservedVersion)) -eq [version]'8.8.0.0' -and $_.Tuple -and $_.Tuple -cne $fTuple })
    $mine = @($fCaps | Where-Object { $_.Tuple -ceq $fTuple }).Count
    $fRows = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $fDst -Stage Export | Where-Object Code -eq 'PRIOR-CAPTURE-RECORD')
    if ($other.Count -eq 1 -and $mine -eq 2 -and $fRows.Count -eq 1 -and $fRows[0].Message -match 'covers 8\.7\.9\.0\.\.8\.8\.0\.0, but its capture records give 8\.7\.9\.0\.\.8\.9\.8\.0') {
        Ok '...a lower VersionMax (8.8.0.0) only a record of another identity observed -> PRIOR-CAPTURE-RECORD (a same-identity record only)'
    } else { Bad "same family, other identity's version: other=$($other.Count) mine=$mine rows=$($fRows | ForEach-Object { $_.Message })" }

    # == [8] per entry (C-7) ===================================================================================
    Write-Host '[8] one bad rule never costs the others (C-7: fail-open per entry)' -ForegroundColor Cyan
    $noMax = New-Entry @{ Id = 'inno-x64'; Key = 'NppInno_is1'; UninstallerType = 'inno'; ProcessNames = @('npp-inno') }; $noMax.Remove('VersionMax')
    # 'junk' (a string), [] and [null]: entries that are not objects. A JSON round trip turns [] and [null] into $null.
    $pSrc = New-CfProject -Template 'T9' -Version '8.9.8.1' -Entries @((New-Entry), $noMax, (New-Entry @{ Id = 'BAD ID'; Key = 'Other' }), (New-Entry @{ Key = 'Dup' }), 'junk', @(), (, $null))
    $srcText = [IO.File]::ReadAllText((Join-Path $pSrc 'SupportFiles\AppConfig.json'))
    if (@((Get-Cfg $pSrc).PriorInstalls.Entries).Count -eq 7 -and $srcText -match '\[\s*\]' -and $srcText -match '\[\s*null\s*\]') { Ok 'the source holds 7 entries, among them [] and [null]' } else { Bad "fixture: $srcText" }
    $pe = New-CfProject -Template 'T9' -Version '8.9.9' -NoPrior
    $s = Invoke-Copy $pe $null
    $cfg = Get-Cfg $pe
    $ids = (@($cfg.PriorInstalls.Entries) | ForEach-Object { "$($_.Id)=$($_.VersionMax)" }) -join ','
    if ($ids -ceq 'inno-x64=8.9.9,nsis-x64=8.9.9') { Ok 'a hand-edited rule without a VersionMax property is carried with the new VersionMax; the valid rule next to it too (an empty-array entry beside them costs neither)' } else { Bad "per entry: $ids $($s | ConvertTo-Json -Compress -Depth 4) warn=$($script:warnLines -join ' | ')" }
    $why = @($s.Dropped | ForEach-Object { "$($_.Id): $($_.Reason)" })
    if ($s.Dropped.Count -eq 5 -and @($why | Where-Object { $_ -match 'Id must match' }).Count -eq 1 -and @($why | Where-Object { $_ -match 'Id is used by another entry' }).Count -eq 1 -and @($why | Where-Object { $_ -match 'not an object' }).Count -eq 3 -and @($why | Where-Object { $_ -match 'could not be checked' }).Count -eq 0 -and $script:warnLines.Count -eq 5) {
        Ok 'an invalid Id, a duplicate Id and the three entries that are not objects ("junk", [], [null]) are dropped alone, each with a warning naming the problem'
    } else { Bad "dropped: $($why -join ' | ') warn=$($script:warnLines -join ' | ')" }

    # == [9] a project a test guest changed (GUEST-TAMPER) ===================================================
    Write-Host '[9] nothing is kept or carried from a project a test guest changed' -ForegroundColor Cyan
    # The first WiX version of the app (no version before it in T10) whose Update proof run tripped the tripwire.
    $tp = New-CfProject -Template 'T10' -Version '8.9.9' -Entries @((New-Entry @{ VersionMax = '8.9.9' }), (New-Entry @{ Id = 'inno-x64'; Key = 'NppInno_is1'; UninstallerType = 'inno'; VersionMax = '8.9.9'; ProcessNames = @('npp-inno') }), (New-Entry @{ Id = 'BAD ID'; Key = 'Other' }), 'junk')
    [IO.File]::WriteAllText((Join-Path $tp 'Documentation\PriorInstallDecisions.json'), '{"SchemaVersion":"1.0","Records":[{"Kind":"Waiver","Code":"PROOF","Target":"nsis-x64","Reason":"forged","On":"2026-10-25"}]}', $utf8)
    $null = New-Item -ItemType Directory -Path (Join-Path $tp 'Documentation\SiblingCapture') -Force
    [IO.File]::WriteAllText((Join-Path $tp 'Documentation\SiblingCapture\3f9c0a7d51e2b846.json'), '{"SchemaVersion":"1.0"}', $utf8)
    [IO.File]::WriteAllText((Join-Path $tp 'Documentation\GuestTamper.json'), '{"Scenario":"Update","Files":["SupportFiles\\AppConfig.json"]}', $utf8)
    $snap = Get-Win32ToolkitPriorInstallSnapshot -ProjectPath $tp -WarningVariable tw 3>$null
    $snapProps = (@($snap.PSObject.Properties | ForEach-Object Name) | Sort-Object) -join ','
    if ($snap -and $snap.Tampered -and $snapProps -ceq 'Lost,ProjectPath,Tampered' -and (@($snap.Lost | ForEach-Object { "$($_.Id)|$($_.Kind)|$($_.Key)|$($_.View)" }) -join ',') -ceq 'nsis-x64|ArpKey|Notepad++|Native,inno-x64|ArpKey|NppInno_is1|Native,BAD ID|ArpKey|Other|Native' -and
        @($tw | Where-Object { "$_" -like '*GuestTamper.json*NOT kept*ID-PRIOR-DROPPED*' }).Count -eq 1) {
        Ok 'the snapshot of a tampered project is only a marker: the Id, Kind, Key and View of its rules (no bytes, decisions or capture files), one warning'
    } else { Bad "tamper snapshot: $($snap | ConvertTo-Json -Compress -Depth 3) warn=$($tw -join ' | ')" }
    Remove-Item -LiteralPath $tp -Recurse -Force
    $tp = New-CfProject -Template 'T10' -Version '8.9.9' -NoPrior
    $s = Invoke-Copy $tp $snap
    $cfg = Get-Cfg $tp
    $lostFile = Join-Path $tp 'Documentation\PriorInstallDropped.json'
    $lostDoc = if (Test-Path -LiteralPath $lostFile) { Get-Content -LiteralPath $lostFile -Raw | ConvertFrom-Json } else { $null }
    if ($s.Action -eq 'None' -and (@($s.Lost) -join ',') -ceq 'nsis-x64,inno-x64' -and @($cfg.PriorInstalls.Entries).Count -eq 0 -and $null -ne $cfg.PSObject.Properties['PriorInstalls'] -and
        -not (Test-Path -LiteralPath (Join-Path $tp 'Documentation\PriorInstallDecisions.json')) -and -not (Test-Path -LiteralPath (Join-Path $tp 'Documentation\SiblingCapture')) -and
        (@($lostDoc.Entries | ForEach-Object { "$($_.Id)|$($_.Key)|$($_.From)" }) -join ',') -ceq 'inno-x64|NppInno_is1|Notepad++_x64_8.9.9,nsis-x64|Notepad++|Notepad++_x64_8.9.9' -and -not [IO.File]::ReadAllBytes($lostFile)[0].Equals([byte]0xEF)) {
        Ok 'the tampered rebuild with no version before it: no rule, decision or capture record restored; the two valid identities recorded in Documentation\PriorInstallDropped.json (BOM-less); an empty rule set written'
    } else { Bad "tamper rebuild: $($s | ConvertTo-Json -Compress -Depth 3) lost=$($lostDoc | ConvertTo-Json -Compress -Depth 4)" }
    $lostRows = { @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $args[0] -Stage Export | Where-Object Code -eq 'ID-PRIOR-DROPPED') }
    $r = & $lostRows $tp
    if ((@($r | ForEach-Object Target) -join ',') -ceq 'inno-x64,nsis-x64' -and @($r | Where-Object { $_.Message -match 'not kept because a test guest changed' -and $_.Message -match "-Acknowledge ID-PRIOR-DROPPED -Target $($_.Target) " }).Count -eq 2) {
        Ok 'Export lists one ID-PRIOR-DROPPED row per lost rule, each with the acknowledgement command (fail-closed, as a carry source a guest changed)'
    } else { Bad "lost rows: $($r | ForEach-Object { "$($_.Target): $($_.Message)" })" }
    # A second rebuild of the same version (not tampered) keeps the record.
    $snap2 = Get-Win32ToolkitPriorInstallSnapshot -ProjectPath $tp
    Remove-Item -LiteralPath $tp -Recurse -Force
    $tp = New-CfProject -Template 'T10' -Version '8.9.9' -NoPrior
    $null = Invoke-Copy $tp $snap2
    $r = & $lostRows $tp
    if ((@($r | ForEach-Object Target) -join ',') -ceq 'inno-x64,nsis-x64') { Ok 'rebuilding it again (not tampered) keeps the lost rules: the rows stay' } else { Bad "second rebuild: $(@($r | ForEach-Object Target) -join ',')" }
    $null = Set-Win32ToolkitPriorInstallDecision -ProjectPath $tp -Record @{ Kind = 'Acknowledgement'; Code = 'ID-PRIOR-DROPPED'; Target = 'inno-x64'; Reason = 'the Inno build is gone from the fleet'; On = '2026-10-26' } -Confirm:$false
    $r = & $lostRows $tp
    if ((@($r | ForEach-Object Target) -join ',') -ceq 'nsis-x64') { Ok 'an ID-PRIOR-DROPPED acknowledgement removes its row' } else { Bad "ack: $(@($r | ForEach-Object Target) -join ',')" }
    # The next version carries the lost rule that is still open (not the acknowledged one).
    $tNext = New-CfProject -Template 'T10' -Version '9.0' -NoPrior
    $s = Invoke-Copy $tNext $null
    $r = & $lostRows $tNext
    if ($s.Action -eq 'Carried' -and (@($s.Lost) -join ',') -ceq 'nsis-x64' -and (@($r | ForEach-Object Target) -join ',') -ceq 'nsis-x64' -and $r[0].Message -match 'of Notepad\+\+_x64_8\.9\.9 was not kept') {
        Ok 'the next version gets the lost rule that is still open (the acknowledged one stays behind) and lists it at Export'
    } else { Bad "next: $($s | ConvertTo-Json -Compress -Depth 3) rows=$(@($r | ForEach-Object Target) -join ',')" }
    # Declaring the rule again (same Kind, Key and View) ends it.
    $c = Get-Cfg $tp
    $c.PriorInstalls.Entries = @([pscustomobject](New-Entry @{ VersionMax = '8.9.9' }))
    [IO.File]::WriteAllText((Join-Path $tp 'SupportFiles\AppConfig.json'), ($c | ConvertTo-Json -Depth 8), $utf8)
    if ((& $lostRows $tp).Count -eq 0) { Ok 'the rule declared again (same Kind, Key and View) -> no row' } else { Bad 'declared again' }
    [IO.File]::WriteAllText((Join-Path $tNext 'Documentation\PriorInstallDropped.json'), 'not json', $utf8)
    $r = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $tNext -Stage Export)
    if (@($r | Where-Object { $_.Code -eq 'PRIOR-INVALID' -and $_.Message -match 'PriorInstallDropped\.json cannot be read' }).Count -eq 1) { Ok 'a lost-rules file that cannot be read refuses the Export (fail-closed)' } else { Bad "unreadable: $($r | ForEach-Object { "$($_.Code): $($_.Message)" })" }

    $tOld = New-CfProject -Template 'T11' -Version '8.9.8.1' -Entries @((New-Entry))
    $null = New-Item -ItemType Directory -Path (Join-Path $tOld 'Documentation\SiblingCapture') -Force
    [IO.File]::WriteAllText((Join-Path $tOld 'Documentation\SiblingCapture\3f9c0a7d51e2b846.json'), '{"SchemaVersion":"1.0"}', $utf8)
    [IO.File]::WriteAllText((Join-Path $tOld 'Documentation\GuestTamper.json'), '{"Scenario":"Update"}', $utf8)
    $tNew = New-CfProject -Template 'T11' -Version '8.9.9' -NoPrior
    $s = Invoke-Copy $tNew $null
    $cfg = Get-Cfg $tNew
    $dropRows = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $tNew -Stage Export | Where-Object Code -eq 'ID-PRIOR-DROPPED')
    if ($s.Action -eq 'Refused' -and $null -ne $cfg.PSObject.Properties['PriorInstalls'] -and @($cfg.PriorInstalls.Entries).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $tNew 'Documentation\SiblingCapture')) -and
        @($script:warnLines | Where-Object { $_ -like '*changed by a test guest*NOT carried*' }).Count -eq 1 -and $dropRows.Count -eq 1 -and $dropRows[0].Target -eq 'nsis-x64') {
        Ok 'a carry source a test guest changed gives nothing (an empty list, no records), and Export lists its rule as ID-PRIOR-DROPPED (fail-closed)'
    } else { Bad "tamper carry: $($s | ConvertTo-Json -Compress -Depth 3) rows=$($dropRows.Count)" }
    # The source is re-created later (marker gone, its rules not kept): the new version still lists the rule it never got.
    Remove-Item -LiteralPath (Join-Path $tOld 'Documentation\GuestTamper.json')
    $c = Get-Cfg $tOld; $c.PriorInstalls.Entries = @()
    [IO.File]::WriteAllText((Join-Path $tOld 'SupportFiles\AppConfig.json'), ($c | ConvertTo-Json -Depth 8), $utf8)
    $dropRows = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $tNew -Stage Export | Where-Object Code -eq 'ID-PRIOR-DROPPED')
    if ((@($s.Lost) -join ',') -ceq 'nsis-x64' -and $dropRows.Count -eq 1 -and $dropRows[0].Target -eq 'nsis-x64') { Ok '...recorded in the new project, so the row stays after the source itself is re-created' } else { Bad "after source re-created: lost=$(@($s.Lost) -join ',') rows=$($dropRows.Count)" }

    # == [10] after the install capture: Uninstall.PrimaryKeys, invalid ids =================================
    Write-Host '[10] the own keys from Uninstall.PrimaryKeys; invalid ids after the install capture' -ForegroundColor Cyan
    $pk = New-CfProject -Template 'T12' -Version '8.9.9' -Type 'exe' -Entries @((New-Entry @{ VersionMax = '8.9.7' }), (New-Entry @{ Id = 'inno-x64'; Key = 'NppInno_is1'; UninstallerType = 'inno'; VersionMax = '8.9.7'; ProcessNames = @('npp-inno') }), (New-Entry @{ Id = 'BAD ID'; Key = 'Other'; VersionMax = '8.9.7' }))
    $cfg = Get-Cfg $pk
    $cfg | Add-Member -NotePropertyName OwnIdentity -NotePropertyValue ([pscustomobject]@{ SchemaVersion = '1.0'; ProductCode = ''; UpgradeCode = ''; ArpKeys = @([pscustomobject]@{ Key = 'NppHelper'; View = 'Native' }); CapturedOn = '2026-10-25' }) -Force
    $cfg | Add-Member -NotePropertyName Uninstall -NotePropertyValue ([pscustomobject]@{ AppName = 'Notepad++'; ProductCodes = @(); Uninstallers = @(); CleanupPaths = @(); InstallRoots = @(); PrimaryKeys = @([pscustomobject]@{ Name = 'Notepad++'; View = 'Registry64' }) }) -Force
    [IO.File]::WriteAllText((Join-Path $pk 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $sync = Sync-Win32ToolkitPriorInstallOwnIdentity -ProjectPath $pk -WarningVariable pw 3>$null
    $left = (@((Get-Cfg $pk).PriorInstalls.Entries) | ForEach-Object Id) -join ','
    if ($left -ceq 'inno-x64' -and @($sync.Own) -contains 'nsis-x64' -and @($sync.Dropped | Where-Object { $_.Reason -match "own uninstall key" }).Count -eq 0 -and @($pw | Where-Object { "$_" -like 'ID-PRIOR-OWN:*nsis-x64*' }).Count -eq 1) {
        Ok "a key the capture recorded in Uninstall.PrimaryKeys ({ Name; View }) is the package's own -> ID-PRIOR-OWN, not 'invalid'"
    } else { Bad "primary keys: left=$left own=$(@($sync.Own) -join ',') dropped=$(@($sync.Dropped | ForEach-Object { "$($_.Id): $($_.Reason)" }) -join ' | ')" }
    if (@($sync.Dropped | Where-Object { $_.Reason -match 'Id must match' }).Count -eq 1) { Ok 'a rule with an invalid Id is dropped after the install capture too' } else { Bad "sync invalid id: $(@($sync.Dropped | ForEach-Object { "$($_.Id): $($_.Reason)" }) -join ' | ')" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PriorCarryForward tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PriorCarryForward test(s) FAILED." -ForegroundColor Red; exit 1 }
