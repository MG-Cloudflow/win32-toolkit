<#
    Installer-identity PR 3 (spec 2.11, 2.19; D12, D17, D20, D25, D29, L3, L13, L28, L38, L39, SV2, SV5, SV14):
    Get-Win32ToolkitPriorInstallFinding - the Export errors and the advisory rows of the prior-install rules - on real
    projects (generated from the PSADT 4.1.8 golden), with the real proof state, decisions and capture-record readers.

      [1] no rules -> no row; GUEST-TAMPER with or without rules.
      [2] the script: no remove-prior blocks or PriorCheckFirst false -> PRIOR-NO-SLOTS; a revision-1 script against a
          revision-2 catalog -> PRIOR-REVISION.
      [3] the rules: a Block rule without own identity -> PRIOR-NO-OWNIDENTITY; an invalid rule -> PRIOR-INVALID naming it.
      [4] the proof: an unproven Enforce rule -> PRIOR-PROOF, a PROOF waiver removes it; a Sandbox or Interactive pass never
          proves; a later failure with the same binding revokes; a changed PreInstall.ps1 hook or entry un-proves.
      [5] the window and data loss: VersionMin 8.8 with a proven 8.8.9 -> PRIOR-VERSIONMIN (exact), 8.8.9 passes, a
          VERSIONMIN waiver passes; a proving record with DataLoss -> PRIOR-DATA-LOSS, a DATA-LOSS acknowledgement passes.
      [6] capture lineage: no verified record -> PRIOR-CAPTURE-RECORD; no, a demoted or another identity's Approval ->
          PRIOR-APPROVAL, the latest current one passes; a PROOF waiver is ignored for it; PRIOR-UNCOVERED (Info).
      [7] the version before: a rule missing here -> ID-PRIOR-DROPPED, an acknowledgement removes it; a rule that is now the
          package's own key -> ID-PRIOR-OWN (a warning, not an error).
      [8] advisory rows and stages: PRIOR-BLOCK-FLEET, PRIOR-ENFORCE-PILOT (the kill switch), PRIOR-NO-WELCOME,
          PRIOR-CLASS-E (a warning only), PRIOR-PREDECESSOR-PUBLISHED; Export returns only errors, Advisory only the rest;
          Get-Win32ToolkitPackageAdvisory shows them (Source PriorInstalls) in their order.
      [10] a rule of the version before naming a key of Uninstall.PrimaryKeys ({ Name; View }) -> ID-PRIOR-OWN, not
          ID-PRIOR-DROPPED; an Enforce rule the proof state does not name -> PRIOR-PROOF (fail-closed).

    Run:  pwsh -File Tests\PriorInstallFinding.unit.ps1
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32pf_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
$PC = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
$golden = [IO.File]::ReadAllText((Join-Path $repo 'Tests\Fixtures\psadt-4.1.8\Invoke-AppDeployToolkit.ps1'), [Text.Encoding]::UTF8)
# The script is generated once and copied: the generator is the same for every project.
$scriptCache = @{}
function Get-GeneratedScript([switch]$NoOrgUi, [switch]$NoBlocks) {
    $k = "$([bool]$NoOrgUi)$([bool]$NoBlocks)"
    if (-not $scriptCache.ContainsKey($k)) {
        $tmp = Join-Path $root ('gen_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
        $null = New-Item -ItemType Directory -Path $root -Force
        [IO.File]::WriteAllText($tmp, $golden, [Text.UTF8Encoding]::new($true))
        $null = Set-PSADTDataDrivenScript -ScriptPath $tmp -WarningAction SilentlyContinue
        $t = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        if (-not $NoOrgUi) {
            $t = Remove-Win32ToolkitPhaseDefaultUi -Content $t -Phase 'Pre-Install'
            $t = Set-Win32ToolkitPhaseBlock -Content $t -Phase 'Pre-Install' -Slot 'org-ui' -Code (Get-Win32ToolkitDeployScriptBlock -Name OrgUiPreInstall)
        }
        if ($NoBlocks) { $t = Remove-Win32ToolkitPhaseBlock -Content (Remove-Win32ToolkitPhaseBlock -Content $t -Phase 'Pre-Install' -Slot 'prior-check') -Phase 'Pre-Install' -Slot 'remove-prior' }
        $scriptCache[$k] = $t
        Remove-Item -LiteralPath $tmp
    }
    $scriptCache[$k]
}
function Entry([string]$Id = 'nsis-x64', [string]$Mode = 'Enforce', [hashtable]$O = @{}) {
    $e = [ordered]@{ Id = $Id; Kind = 'ArpKey'; Mode = $Mode; Key = 'Notepad++'; View = 'Native'; Publisher = 'Notepad++ Team'; DisplayName = 'Notepad++ (64-bit x64)'; DisplayNameTemplate = ''
        VersionMin = '8.8.9'; VersionMax = '8.9.9'; UninstallerType = 'nullsoft'; UninstallerFileName = 'uninstall.exe'; UninstallerSigner = ''; InstallDir = '%ProgramFiles%\Notepad++'
        MainExe = 'notepad++.exe'; ProcessNames = @('notepad++'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-25' }
    foreach ($k in $O.Keys) { $e[$k] = $O[$k] }
    $e
}
function New-FProject {
    param([string]$Name, [object[]]$Entries, [switch]$NoOwn, [switch]$NoOrgUi, [switch]$NoBlocks, [string]$Template = 'T', [string]$Version = '8.9.9', [string]$WingetId = 'Notepad++.Notepad++', [hashtable]$Extra = @{}, [switch]$NoPrior)
    $p = Join-Path $root "Projects\$Template\$Name"
    foreach ($d in 'SupportFiles\OrgHooks', 'Documentation', 'Files') { $null = New-Item -ItemType Directory -Path (Join-Path $p $d) -Force }
    [IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), (Get-GeneratedScript -NoOrgUi:$NoOrgUi -NoBlocks:$NoBlocks), [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $p 'Files\npp.msi'), 'msi bytes', $utf8)
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\OrgHooks\PreInstall.ps1'), "Write-ADTLogEntry -Message 'hook'", $utf8)
    $cfg = [ordered]@{ SchemaVersion = '1.0'
        App = [ordered]@{ Vendor = 'Notepad++ Team'; Name = ''; DisplayName = 'Notepad++'; Version = $Version; Arch = 'x64'; ScriptAuthor = 'Contoso IT'; ScriptDate = '2026-10-25' }
        Installer = [ordered]@{ Type = 'msi'; FileName = 'npp.msi'; SilentArgs = '' }; ProcessesToClose = @('notepad++')
        Source = [ordered]@{ SchemaVersion = '1.0'; WingetId = $WingetId; Version = $Version; InstallerType = 'wix'; Family = 'msi'; Architecture = 'x64'; PinnedBy = 'winget-default'; ProductCode = $PC }
        OrgUi = [ordered]@{ Welcome = [ordered]@{ Enabled = $true } } }
    if (-not $NoOwn) { $cfg['OwnIdentity'] = [ordered]@{ SchemaVersion = '1.0'; ProductCode = $PC; UpgradeCode = ''; ArpKeys = @([ordered]@{ Key = $PC; View = 'Native' }); CapturedOn = '2026-10-25' } }
    if (-not $NoPrior) { $cfg['PriorInstalls'] = [ordered]@{ SchemaVersion = '1.0'; Entries = @($Entries) } }
    foreach ($k in $Extra.Keys) { $cfg[$k] = $Extra[$k] }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $p
}
# An Update record that checked $Ids against the CURRENT binding (as PriorProof.unit).
function Rec([string]$P, [string[]]$Ids, [hashtable]$O = @{}) {
    $b = Get-Win32ToolkitPriorProofBinding -ProjectPath $P
    $names = @('Requirement-PreUpdate', 'NewAppIntact-PostUpdate', 'Tattoo-PostUpdate', 'OldArpGone-PostUpdate')
    foreach ($id in $Ids) { $names += @("PriorPresent-PreUpdate.$id", "PriorAbsent-PostUpdate.$id") }
    $fails = @($O['Fail'] | Where-Object { $_ })
    $obs = [ordered]@{}; foreach ($id in $Ids) { $obs[$id] = if ($O.ContainsKey('Observed')) { $O.Observed } else { '8.8.9' } }
    $proof = [ordered]@{ SchemaVersion = '1.0'; PriorInstallsHash = $b.PriorInstallsHash; ScriptSha256 = $b.ScriptSha256; FilesSha256 = $b.FilesSha256; SupportFilesSha256 = $b.SupportFilesSha256
        BaselineInstallerSha256 = ''; CatalogVersion = $b.CatalogVersion; EntryIds = @($Ids); CaptureIds = @(); RequirementChecked = $true; ObservedVersions = $obs; DataLoss = @($O['DataLoss'] | Where-Object { $_ }) }
    [ordered]@{ Scenario = 'Update'; Backend = $(if ($O.Backend) { $O.Backend } else { 'HyperV' }); Mode = $(if ($O.Mode) { $O.Mode } else { 'Unattended' })
        TimestampUtc = $(if ($O.Ts) { $O.Ts } else { '2026-10-25T10:00:00.0000000Z' }); Verdict = $(if ($fails.Count) { 'Failed' } else { 'Passed' })
        Assertions = @($names | ForEach-Object { [ordered]@{ Name = $_; Result = $(if ($fails -contains $_) { 'FAIL' } else { 'PASS' }) } }); Notes = ''; Proof = $proof }
}
function Set-ResultFile([string]$P, [object[]]$Records) { [IO.File]::WriteAllText((Join-Path $P 'Documentation\TestResults.json'), (ConvertTo-Json -InputObject @($Records) -Depth 8), $utf8) }
function Decide([string]$P, [hashtable]$R) { if (-not $R.On) { $R.On = '2026-10-25' }; $null = Set-Win32ToolkitPriorInstallDecision -ProjectPath $P -Record $R -Confirm:$false }
function Rows([string]$P, [string]$Stage = 'Export') { @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $P -Stage $Stage) }
function Codes([string]$P, [string]$Stage = 'Export') { (@(Rows $P $Stage | ForEach-Object Code) | Sort-Object -Unique) -join ',' }

try {
    # == [1] ===================================================================================================
    Write-Host '[1] no rules; GUEST-TAMPER' -ForegroundColor Cyan
    $p = New-FProject 'none' -NoPrior
    if ((Codes $p) -eq '' -and (Codes $p 'Advisory') -eq '') { Ok 'a project without rules -> no row at Export or in the advisory' } else { Bad "none: $(Codes $p) / $(Codes $p 'Advisory')" }
    [IO.File]::WriteAllText((Join-Path $p 'Documentation\GuestTamper.json'), '{}', $utf8)
    if ((Codes $p) -eq 'GUEST-TAMPER') { Ok 'Documentation\GuestTamper.json -> GUEST-TAMPER (no override), with or without rules' } else { Bad "tamper: $(Codes $p)" }

    # == [2] ===================================================================================================
    Write-Host '[2] the deploy script' -ForegroundColor Cyan
    $p = New-FProject 'noblocks' @((Entry 'exe-x64' 'Block')) -NoBlocks
    $r = @(Rows $p)
    if ((Codes $p) -eq 'PRIOR-NO-SLOTS' -and $r[0].Message -match 'no remove-prior blocks' -and $r[0].Message -match 'Re-create the project') { Ok 'rules + a script without remove-prior blocks (RemovePriorRevision 0) -> PRIOR-NO-SLOTS (re-create)' } else { Bad "noblocks: $($r | ConvertTo-Json -Compress)" }
    $p = New-FProject 'noorgui' @((Entry 'exe-x64' 'Block')) -NoOrgUi
    if ((Codes $p) -eq 'PRIOR-NO-SLOTS' -and (Rows $p)[0].Message -match 'dialog') { Ok 'rules + PriorCheckFirst false -> PRIOR-NO-SLOTS' } else { Bad "noorgui: $(Codes $p)" }
    $p = New-FProject 'rev' @((Entry 'exe-x64' 'Block'))
    $realBlock = ${function:Get-Win32ToolkitDeployScriptBlock}
    $curRev = [int](& $realBlock -Name RemovePriorRevision)
    function Get-Win32ToolkitDeployScriptBlock { param([string]$Name, $Phase, $HookFile, $FailureAction) if ($Name -eq 'RemovePriorRevision') { return ($curRev + 1) }; & $realBlock @PSBoundParameters }
    $c = Codes $p
    ${function:Get-Win32ToolkitDeployScriptBlock} = $realBlock
    if ($c -eq 'PRIOR-REVISION') { Ok "a revision-$curRev project against a revision-$($curRev + 1) catalog -> PRIOR-REVISION" } else { Bad "revision: $c" }
    if ((Codes $p) -eq '') { Ok "the same project with this catalog (revision $curRev) and a Block rule -> no error" } else { Bad "rev ok: $(Codes $p)" }

    # == [3] ===================================================================================================
    Write-Host '[3] own identity and invalid rules' -ForegroundColor Cyan
    $p = New-FProject 'noown' @((Entry 'exe-x64' 'Block')) -NoOwn
    if ((Codes $p) -eq 'PRIOR-NO-OWNIDENTITY') { Ok 'a Block rule without a known own identity -> PRIOR-NO-OWNIDENTITY (and no PRIOR-INVALID for the same reason)' } else { Bad "noown: $(Codes $p)" }
    $p = New-FProject 'invalid' @((Entry 'exe-x64' 'Block' @{ Publisher = '' }))
    $r = @(Rows $p)
    if ((Codes $p) -eq 'PRIOR-INVALID' -and $r[0].Target -eq 'exe-x64' -and $r[0].Message -match 'Publisher') { Ok 'an invalid rule -> PRIOR-INVALID naming the rule and the problem' } else { Bad "invalid: $($r | ConvertTo-Json -Compress)" }

    # == [4] ===================================================================================================
    Write-Host '[4] the proof (D17)' -ForegroundColor Cyan
    $p = New-FProject 'proof' @((Entry))
    $r = @(Rows $p)
    if ((Codes $p) -eq 'PRIOR-PROOF' -and $r[0].Message -match "Test-Win32ToolkitProject -ProjectPath '.*' -Scenario Update -Backend HyperV -TestMode Unattended" -and $r[0].Message -match '-Waive PROOF -Target nsis-x64') { Ok 'an unproven Enforce rule -> PRIOR-PROOF with the proof command and the waiver' } else { Bad "proof: $($r | ConvertTo-Json -Compress)" }
    Set-ResultFile $p @((Rec $p @('nsis-x64')))
    if ((Codes $p) -eq '') { Ok 'a Passed Hyper-V Unattended record of the current binding -> no error' } else { Bad "proven: $(Codes $p)" }
    foreach ($c in @(@{ L = 'a Sandbox pass'; O = @{ Backend = 'Sandbox' } }, @{ L = 'an Interactive pass'; O = @{ Mode = 'Interactive' } })) {
        Set-ResultFile $p @((Rec $p @('nsis-x64') $c.O))
        if ((Codes $p) -eq 'PRIOR-PROOF') { Ok "$($c.L) never proves -> PRIOR-PROOF" } else { Bad "$($c.L): $(Codes $p)" }
    }
    Set-ResultFile $p @((Rec $p @('nsis-x64')), (Rec $p @('nsis-x64') @{ Ts = '2026-10-26T10:00:00Z'; Fail = @('PriorAbsent-PostUpdate.nsis-x64') }))
    if ((Codes $p) -eq 'PRIOR-PROOF') { Ok 'a later failure with the same binding revokes the pass' } else { Bad "revoke: $(Codes $p)" }
    # Live row OP-NEWER: after a 69102 the reason was cut before the exit code and the only remedy was the same failing run.
    $newer = Rec $p @('nsis-x64') @{ Ts = '2026-10-26T10:00:00Z'; Fail = @('Requirement-PreUpdate', 'PriorPresent-PreUpdate.nsis-x64', 'PriorAbsent-PostUpdate.nsis-x64', 'NewAppIntact-PostUpdate', 'Tattoo-PostUpdate', 'OldArpGone-PostUpdate') }
    $newer.Notes = "Intune-parity phase 'Update (Intune parity)' exited with code 69102. The update exited with code 69102: a newer version of the prior install is present than its rule covers (VersionMax)."
    Set-ResultFile $p @($newer)
    $m = [string](@(Rows $p | Where-Object Code -eq 'PRIOR-PROOF')[0].Message)
    if ($m -match '\(the newest proof run failed \(the update exited with code 69102; ' -and $m -match "newer than the rule's VersionMax \(69102\)" -and $m -match '-SpecificVersion') { Ok '69102: the reason leads with the exit code; the remedy widens the window or picks a baseline inside it' } else { Bad "69102: $m" }
    # Live row OP-NEWER (round 2): the widen step was "$set -Id nsis-x64 ... -VersionMax <version>" (no command); it keeps the
    # rule's mode and floor and names the version the test observed.
    [IO.File]::WriteAllText((Join-Path $p 'Documentation\PriorInstallCandidates.json'), (ConvertTo-Json -InputObject ([ordered]@{ SchemaVersion = '1.0'; Baseline = [ordered]@{ Version = '8.9.9'; InstallerType = 'nullsoft'; Family = 'exe' }
                Candidates = @([ordered]@{ ProposedId = 'nsis-x64'; Confidence = 'High'; Key = 'Notepad++'; View = 'Native'; ObservedVersion = '8.9.9'; WindowsInstaller = $false }) }) -Depth 5), $utf8)
    $m = [string](@(Rows $p | Where-Object Code -eq 'PRIOR-PROOF')[0].Message)
    $eMin = [string](@((Get-Content -LiteralPath (Join-Path $p 'SupportFiles\AppConfig.json') -Raw | ConvertFrom-Json).PriorInstalls.Entries)[0].VersionMin)
    if ($m.Contains("The prior install on the test VM (8.9.9) was newer than the rule's VersionMax (69102), so that run fails again: widen its window, keeping its mode and floor (Set-Win32ToolkitPriorInstall -ProjectPath '$p' -FromUpdateTest -Id nsis-x64 -Mode Enforce -VersionMin '$eMin' -VersionMax '8.9.9')")) { Ok '69102: the widen command keeps the mode and floor and names the observed version' } else { Bad "69102 widen: $m" }
    Remove-Item -LiteralPath (Join-Path $p 'Documentation\PriorInstallCandidates.json')
    $busy = Rec $p @('nsis-x64') @{ Ts = '2026-10-26T10:00:00Z'; Fail = @('PriorAbsent-PostUpdate.nsis-x64') }
    $busy.Notes = 'The update exited with code 69107: a restart is pending.'
    Set-ResultFile $p @($busy)
    $m = [string](@(Rows $p | Where-Object Code -eq 'PRIOR-PROOF')[0].Message)
    if ($m -match 'retry code 69107 \(on the test VM: a restart was pending' -and $m -match 'Run it again: Test-Win32ToolkitProject') { Ok '69107: a retry code that says nothing about the rule -> its cause, run it again' } else { Bad "69107: $m" }
    # Live rows APP-RUNNING, MSIBUSY (round 2): 1618 was explained with "a restart pending" (69107's cause), and a failing watched
    # run was called "the newest proof run".
    $busy = Rec $p @('nsis-x64') @{ Ts = '2026-10-26T10:00:00Z'; Fail = @('PriorAbsent-PostUpdate.nsis-x64'); Mode = 'Interactive' }
    $busy.Notes = 'The update exited with code 1618: Intune retries it later.'
    Set-ResultFile $p @($busy)
    $m = [string](@(Rows $p | Where-Object Code -eq 'PRIOR-PROOF')[0].Message)
    if ($m -match 'The newest run that checked it ended with the retry code 1618 \(on the test VM: the prior app was still running after the close-apps dialog, Windows Installer was busy, or the prior install changed while the dialog was open\)' -and
        $m -notmatch 'restart|newest proof run ended') { Ok '1618 from a watched run: the causes of 1618 only, and "the newest run that checked it" (a watched run is no proof run)' } else { Bad "1618: $m" }
    # Live row KILL-NATIVE (round 2): after 69111 the step was the same proof run, which refuses again.
    $kill = Rec $p @('nsis-x64') @{ Ts = '2026-10-26T10:00:00Z'; Fail = @('PriorAbsent-PostUpdate.nsis-x64') }
    $kill.Notes = 'The update exited with code 69111: removal of prior installs is switched off on this device (RemovePriorDisabled).'
    Set-ResultFile $p @($kill)
    $m = [string](@(Rows $p | Where-Object Code -eq 'PRIOR-PROOF')[0].Message)
    if ($m -match 'ended with 69111: removal of prior installs was switched off on the test VM \(RemovePriorDisabled = 1 under HKLM\\SOFTWARE\\.+\\win32-toolkit, set by the package itself - an org hook - or by the test VM''s checkpoint\), so that run refuses again\. Remove what sets it, then prove it: Test-Win32ToolkitProject') { Ok '69111: the kill switch on the test VM is named; remove what sets it before the proof' } else { Bad "69111: $m" }
    # Live row OP-UNPROVEN (round 2): a run that did not match the rule's identity (PriorPresent FAIL) got "Prove it" and a PROOF
    # waiver - the same failing run, or a rule that matches nothing on such devices.
    $um = Rec $p @('nsis-x64') @{ Ts = '2026-10-26T10:00:00Z'; Fail = @('PriorPresent-PreUpdate.nsis-x64', 'PriorAbsent-PostUpdate.nsis-x64', 'OldArpGone-PostUpdate') }
    Set-ResultFile $p @($um)
    $m = [string](@(Rows $p | Where-Object Code -eq 'PRIOR-PROOF')[0].Message)
    if ($m -match "the rule's identity did not match it \(PriorPresent-PreUpdate\.nsis-x64 FAIL: its publisher, name or version window differ\), so proving it again fails the same way: replace it from that run's candidate, keeping its mode \(Set-Win32ToolkitPriorInstall -ProjectPath '.*' -FromUpdateTest -Id nsis-x64 -Mode Enforce -VersionMin '.*' -VersionMax '.*'\), then prove it: Test-Win32ToolkitProject" -and
        $m -notmatch '-Waive PROOF') { Ok 'an unmatched identity: replace the rule from the candidate (mode kept), no PROOF waiver offered' } else { Bad "unmatched: $m" }
    Set-ResultFile $p @((Rec $p @('nsis-x64')))
    [IO.File]::AppendAllText((Join-Path $p 'SupportFiles\OrgHooks\PreInstall.ps1'), "`n# changed")
    if ((Codes $p) -eq 'PRIOR-PROOF') { Ok 'a changed PreInstall.ps1 org hook un-proves (SupportFilesSha256)' } else { Bad "hook: $(Codes $p)" }
    Decide $p @{ Kind = 'Waiver'; Code = 'PROOF'; Target = 'nsis-x64'; Reason = 'pilot ring only' }
    if ((Codes $p) -eq '') { Ok 'a PROOF waiver removes PRIOR-PROOF for an operator rule' } else { Bad "waiver: $(Codes $p)" }

    # == [5] ===================================================================================================
    Write-Host '[5] the window (L13) and data loss' -ForegroundColor Cyan
    $p = New-FProject 'vmin' @((Entry 'nsis-x64' 'Enforce' @{ VersionMin = '8.8' }))
    Set-ResultFile $p @((Rec $p @('nsis-x64') @{ Observed = '8.8.9' }))
    $r = @(Rows $p)
    if ((Codes $p) -eq 'PRIOR-VERSIONMIN' -and $r[0].Message -match '8\.8\.9\.0|8\.8\.9') { Ok 'VersionMin 8.8 with a proven 8.8.9 -> PRIOR-VERSIONMIN (exact)' } else { Bad "vmin: $($r | ConvertTo-Json -Compress)" }
    Decide $p @{ Kind = 'Waiver'; Code = 'VERSIONMIN'; Target = 'nsis-x64'; Reason = 'older builds behave the same' }
    if ((Codes $p) -eq '') { Ok 'a VERSIONMIN waiver passes' } else { Bad "vmin waiver: $(Codes $p)" }
    $p = New-FProject 'vminok' @((Entry))
    Set-ResultFile $p @((Rec $p @('nsis-x64') @{ Observed = '8.8.9' }))
    if ((Codes $p) -eq '') { Ok 'VersionMin 8.8.9 with a proven 8.8.9 passes' } else { Bad "vmin ok: $(Codes $p)" }
    Set-ResultFile $p @((Rec $p @('nsis-x64') @{ DataLoss = @('nsis-x64') }))
    if ((Codes $p) -eq 'PRIOR-DATA-LOSS') { Ok 'a proving record with DataLoss -> PRIOR-DATA-LOSS' } else { Bad "data loss: $(Codes $p)" }
    Decide $p @{ Kind = 'Acknowledgement'; Code = 'DATA-LOSS'; Target = 'nsis-x64'; Reason = 'settings live in APPDATA' }
    if ((Codes $p) -eq '') { Ok 'a DATA-LOSS acknowledgement -> Export passes' } else { Bad "data loss ack: $(Codes $p)" }

    # == [6] ===================================================================================================
    Write-Host '[6] capture lineage (SV2, SV5, SV14)' -ForegroundColor Cyan
    $capE = Entry 'nsis-x64' 'Enforce' @{ Source = 'SiblingCapture'; CaptureId = '3f9c0a7d51e2b846' }
    $p = New-FProject 'capture' @($capE)
    $c = Codes $p
    if ($c -match 'PRIOR-CAPTURE-RECORD' -and $c -match 'PRIOR-APPROVAL' -and $c -match 'PRIOR-PROOF') { Ok 'a captured Enforce rule without its record or approval -> PRIOR-CAPTURE-RECORD, PRIOR-APPROVAL, PRIOR-PROOF' } else { Bad "capture: $c" }
    if (@(Rows $p | Where-Object Code -eq 'PRIOR-PROOF')[0].Message -notmatch '-Waive PROOF') { Ok 'PRIOR-PROOF of a captured rule offers no waiver' } else { Bad 'capture proof waiver offered' }
    Decide $p @{ Kind = 'Waiver'; Code = 'PROOF'; Target = 'nsis-x64'; Reason = 'x' }
    if ((Codes $p) -match 'PRIOR-PROOF') { Ok 'a PROOF waiver is ignored for a captured rule' } else { Bad 'capture waiver honoured' }
    $tuple = Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry ([pscustomobject]$capE)
    Decide $p @{ Kind = 'Approval'; Code = 'SIBLING-ENFORCE'; Target = 'nsis-x64'; ProposalId = 'nsis-x64'; ProposalHash = $tuple; CaptureIds = @('3f9c0a7d51e2b846'); Demoted = '' }
    if ((Codes $p) -notmatch 'PRIOR-APPROVAL') { Ok 'the latest, current Approval of exactly its identity -> no PRIOR-APPROVAL' } else { Bad "approval: $(Codes $p)" }
    $null = Set-Win32ToolkitPriorInstallDecision -ProjectPath $p -Record @{ Target = 'nsis-x64'; On = '2026-10-26' } -DemoteTarget -Confirm:$false
    if ((Codes $p) -match 'PRIOR-APPROVAL') { Ok 'an Approval marked Demoted -> PRIOR-APPROVAL' } else { Bad "demoted: $(Codes $p)" }
    Decide $p @{ Kind = 'Approval'; Code = 'SIBLING-ENFORCE'; Target = 'nsis-x64'; ProposalId = 'nsis-x64'; ProposalHash = ('A' * 64); CaptureIds = @(); Demoted = '' }
    if ((Codes $p) -match 'PRIOR-APPROVAL') { Ok "an Approval of another identity (ProposalHash) -> PRIOR-APPROVAL" } else { Bad "other hash: $(Codes $p)" }
    if (@(Rows $p 'Advisory' | Where-Object { $_.Code -eq 'PRIOR-UNCOVERED' -and $_.Severity -eq 'Info' }).Count -eq 1) { Ok 'a captured rule -> PRIOR-UNCOVERED (Info)' } else { Bad "uncovered: $(Codes $p 'Advisory')" }

    # == [7] ===================================================================================================
    Write-Host '[7] the version before (ID-PRIOR-DROPPED, ID-PRIOR-OWN)' -ForegroundColor Cyan
    $null = New-FProject 'Notepad++_x64_8.9.8.1' @((Entry 'nsis-x64' 'Block'), (Entry 'inno-x64' 'Block' @{ Key = 'NppInno_is1'; UninstallerType = 'inno' }), (Entry 'own-x64' 'Block' @{ Key = $PC })) -Template 'D' -Version '8.9.8.1'
    $p = New-FProject 'Notepad++_x64_8.9.9' @((Entry 'nsis-x64' 'Block')) -Template 'D'
    $r = @(Rows $p)
    if ((Codes $p) -eq 'ID-PRIOR-DROPPED' -and $r.Count -eq 1 -and $r[0].Target -eq 'inno-x64' -and $r[0].Message -match '-Acknowledge ID-PRIOR-DROPPED -Target inno-x64') { Ok 'a rule of the version before missing here -> ID-PRIOR-DROPPED (Target = its id) with the acknowledgement command' } else { Bad "dropped: $($r | ConvertTo-Json -Compress)" }
    if (@(Rows $p 'Advisory' | Where-Object { $_.Code -eq 'ID-PRIOR-OWN' -and $_.Target -eq 'own-x64' -and $_.Severity -eq 'Warning' }).Count -eq 1) { Ok "a rule that is now this package's own key -> ID-PRIOR-OWN (a warning, not ID-PRIOR-DROPPED)" } else { Bad "own: $(Codes $p 'Advisory')" }
    Decide $p @{ Kind = 'Acknowledgement'; Code = 'ID-PRIOR-DROPPED'; Target = 'inno-x64'; Reason = 'the Inno build is gone from the fleet' }
    if ((Codes $p) -eq '') { Ok 'an ID-PRIOR-DROPPED acknowledgement removes it' } else { Bad "dropped ack: $(Codes $p)" }

    # == [8] ===================================================================================================
    Write-Host '[8] advisory rows and stages' -ForegroundColor Cyan
    $null = New-FProject 'Npp_x64_8.9.8' -NoPrior -Template 'A' -Version '8.9.8'
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'Projects\A\Npp_x64_8.9.8\Intune') -Force
    [IO.File]::WriteAllText((Join-Path $root 'Projects\A\Npp_x64_8.9.8\Intune\Publications.json'), '[{"TenantId":"t","AppId":"11111111-2222-3333-4444-555555555555","WingetId":"Notepad++.Notepad++"}]', $utf8)
    $p = New-FProject 'Npp_x64_8.9.9' @((Entry 'exe-x64' 'Block' @{ Key = 'Other'; UninstallerType = '' }), (Entry)) -Template 'A' -WingetId 'Python.Python.3.12' -Extra @{ OrgUi = [ordered]@{ Welcome = [ordered]@{ Enabled = $false } } }
    Set-ResultFile $p @((Rec $p @('nsis-x64')))
    $adv = @(Rows $p 'Advisory')
    $codes = @($adv | ForEach-Object Code)
    if ((Codes $p) -eq '' -and @($adv | Where-Object Severity -eq 'Error').Count -eq 0) { Ok 'Export returns only errors (none here), the advisory none of them' } else { Bad "stages: export=$(Codes $p)" }
    $fleet = @($adv | Where-Object Code -eq 'PRIOR-BLOCK-FLEET')
    if ($fleet.Count -eq 1 -and $fleet[0].Message -match 'FAIL this install \(69101\)' -and $fleet[0].Message -match 'pilot') { Ok 'PRIOR-BLOCK-FLEET for the Block rule (69101, pilot first)' } else { Bad "fleet: $($fleet | ConvertTo-Json -Compress)" }
    $pilot = @($adv | Where-Object Code -eq 'PRIOR-ENFORCE-PILOT')
    if ($pilot.Count -eq 1 -and $pilot[0].Message -match 'RemovePriorDisabled' -and $pilot[0].Message -match 'HKLM\\SOFTWARE\\Contoso IT\\win32-toolkit' -and $pilot[0].Message -match '64-bit') { Ok 'PRIOR-ENFORCE-PILOT names the kill switch under the ScriptAuthor key (64-bit remediation)' } else { Bad "pilot: $($pilot | ConvertTo-Json -Compress)" }
    if ($codes -contains 'PRIOR-NO-WELCOME' -and @($adv | Where-Object Code -eq 'PRIOR-NO-WELCOME')[0].Message -match 'notepad\+\+.*1618') { Ok 'OrgUi.Welcome.Enabled false + Enforce -> PRIOR-NO-WELCOME (1618 retries)' } else { Bad "no welcome: $($codes -join ',')" }
    if (@($adv | Where-Object { $_.Code -eq 'PRIOR-CLASS-E' -and $_.Severity -eq 'Warning' }).Count -eq 1 -and -not ((Codes $p) -match 'CLASS')) { Ok 'a versioned-family winget id (Python.Python.*) -> PRIOR-CLASS-E, a warning only (never refuses)' } else { Bad "class e: $($codes -join ',')" }
    if (@($adv | Where-Object { $_.Code -eq 'PRIOR-PREDECESSOR-PUBLISHED' -and $_.Message -match 'Npp_x64_8\.9\.8' }).Count -eq 1) { Ok 'a published lower version in the template -> PRIOR-PREDECESSOR-PUBLISHED' } else { Bad "predecessor: $($codes -join ',')" }
    $pa = Get-Win32ToolkitPackageAdvisory -ProjectPath $p -Context Export 3>$null
    $prior = @($pa.Findings | Where-Object Source -eq 'PriorInstalls')
    $order = @($prior | Where-Object Severity -eq 'Warning' | ForEach-Object Code) -join ','
    if ($order -eq 'PRIOR-BLOCK-FLEET,PRIOR-NO-WELCOME,PRIOR-PREDECESSOR-PUBLISHED,PRIOR-ENFORCE-PILOT,PRIOR-CLASS-E' -and @($prior | Where-Object { $_.Message -notlike 'Prior install: *' }).Count -eq 0) { Ok "Get-Win32ToolkitPackageAdvisory shows them (Source PriorInstalls, 'Prior install: ') in their order" } else { Bad "advisory order: $order" }

    # == [10] ==================================================================================================
    Write-Host '[10] the own keys of Uninstall.PrimaryKeys; a proof state that names no rule' -ForegroundColor Cyan
    $null = New-FProject 'Notepad++_x64_8.9.8.1' @((Entry 'nsis-x64' 'Block'), (Entry 'own-x64' 'Block' @{ Key = 'NppPrimary' })) -Template 'PK' -Version '8.9.8.1'
    $p = New-FProject 'Notepad++_x64_8.9.9' @((Entry 'nsis-x64' 'Block')) -Template 'PK' -Extra @{ Uninstall = [ordered]@{ AppName = 'Notepad++'; ProductCodes = @(); Uninstallers = @(); CleanupPaths = @(); InstallRoots = @(); PrimaryKeys = @([ordered]@{ Name = 'NppPrimary'; View = 'Registry64' }) } }
    if ((Codes $p) -eq '' -and @(Rows $p 'Advisory' | Where-Object { $_.Code -eq 'ID-PRIOR-OWN' -and $_.Target -eq 'own-x64' }).Count -eq 1) { Ok "a rule of the version before naming a key of Uninstall.PrimaryKeys ({ Name; View }) -> ID-PRIOR-OWN (a warning), not ID-PRIOR-DROPPED" } else { Bad "primary keys: export=$(Codes $p) advisory=$(Codes $p 'Advisory')" }
    $p = New-FProject 'nostate' @((Entry))
    $realState = ${function:Get-Win32ToolkitPriorProofState}
    function Get-Win32ToolkitPriorProofState { param([string]$ProjectPath) $null = $ProjectPath; @() }
    $r = @(Rows $p | Where-Object Code -eq 'PRIOR-PROOF')
    ${function:Get-Win32ToolkitPriorProofState} = $realState
    if ($r.Count -eq 1 -and $r[0].Message -match 'proof state could not be read') { Ok 'an Enforce rule the proof state does not name -> PRIOR-PROOF (fail-closed)' } else { Bad "no state: $(Codes $p)" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PriorInstallFinding tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PriorInstallFinding test(s) FAILED." -ForegroundColor Red; exit 1 }
