<#
    Installer-identity PR 3b, commit F1 (spec 2.15.3-4; SV6, SV25, SV28, L27, L37, D17, D59a): Invoke-Win32ToolkitPriorProof
    and Invoke-Win32ToolkitPriorDemotion, with a shadowed Test-Win32ToolkitProject that writes Update records against the
    CURRENT binding (as the real proof run does) and the real Get-Win32ToolkitPriorProofState.

      [1] grouping: captured rules by floor record, the others by (UninstallerType, View); one Test-Win32ToolkitProject
          call per unproven group with -ProofEntryId and no other baseline parameter (Scenario Update, Backend HyperV,
          TestMode Unattended); -EntryId limits the groups; proven groups are not run again.
      [2] Hyper-V not ready -> no call; every rule 'not proven: Hyper-V is not ready'.
      [3] the loop: two captured Enforce rules in two groups, the second one's proof fails -> it is demoted (removed, its
          Approval Demoted, the warning names the failing assertion), the first is proven again on the remaining set in
          round 2 and ends Proven; the Export rows of the real finding are empty; the demoted rule is a proposal again.
      [4] operator rules are never demoted (one warning); without -Prove one round of demotion only, no run; a captured
          rule proven on the same set as a failed one is demoted with it (its proof covered the removed rule, and no
          proof runs here), so Export has no PRIOR-PROOF.
      [5] the bound: min(1 + captured Enforce rules, -MaxRounds) proof rounds; the survivor the last round's demotion
          un-proved is demoted too (spec Dv13; L37: Export does not refuse it as unproven); -MaxRounds above 4 is refused.
      [6] X3: -SiblingProof FloorAndNewest - the captured group (only) also runs from its newest capture; a newest pass
          keeps the floor proof, a newest failure revokes it.
      [7] a next version (spec 2.15.4): the failed carried rule and the one its removal un-proved are both demoted, Export
          has no PRIOR-PROOF but one ID-PRIOR-DROPPED per demoted carried rule; approved and proven again, or the drop
          acknowledged, clears its row.

    Run:  pwsh -File Tests\PriorDemotion.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test helpers')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Get-AuthenticodeSignature is shadowed: the signer checks never read a real file')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
. (Join-Path $repo 'Public\Set-Win32ToolkitPriorInstall.ps1')
. (Join-Path $repo 'Tests\Fixtures\sibling-proposal\SiblingFixture.ps1')
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32pd_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
$PC = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
$golden = [IO.File]::ReadAllText((Join-Path $repo 'Tests\Fixtures\psadt-4.1.8\Invoke-AppDeployToolkit.ps1'), [Text.Encoding]::UTF8)
$generated = $null

# ---- shadows ----
function Get-AuthenticodeSignature { [CmdletBinding()] param([string]$LiteralPath) $null = $LiteralPath; [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $script:TestSiblingSigner } } }
$script:hvNotReady = @()
function Test-Win32ToolkitHyperVReady { @($script:hvNotReady) }
$script:calls = [System.Collections.Generic.List[object]]::new()
$script:failIds = @()
$script:failFirstGroup = $false
function Test-Win32ToolkitProject {
    [CmdletBinding()]
    param([string]$ProjectPath, [string]$Scenario, [string]$Backend, [string]$TestMode, [string[]]$ProofEntryId, [string]$SiblingProof,
        [Parameter(ValueFromRemainingArguments)]$Rest)
    $script:calls.Add([pscustomobject]@{ Keys = (@($PSBoundParameters.Keys | Sort-Object) -join ','); Scenario = $Scenario; Backend = $Backend; TestMode = $TestMode; Ids = (@($ProofEntryId) -join ',') })
    $b = Get-Win32ToolkitPriorProofBinding -ProjectPath $ProjectPath
    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $ids = @($ProofEntryId)
    $fails = @($ids | Where-Object { $script:failIds -ccontains $_ })
    # [5]: the first group of every round fails
    if ($script:failFirstGroup -and -not $script:failedThisRound) { $fails = $ids; $script:failedThisRound = $true }
    $names = @('Requirement-PreUpdate', 'NewAppIntact-PostUpdate', 'Tattoo-PostUpdate')
    $sha = ''
    foreach ($id in $ids) {
        $names += @("PriorPresent-PreUpdate.$id", "PriorAbsent-PostUpdate.$id", "SiblingIdentityStable-PreUpdate.$id", "PriorResidue-PostUpdate.$id")
        $e = @($cfg.PriorInstalls.Entries | Where-Object Id -ceq $id)[0]
        if ($e.CaptureId) { $rec = @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath -CaptureId $e.CaptureId)[0]; if ($rec) { $sha = [string]$rec.Sibling.InstallerSha256 } }
    }
    $failNames = @($fails | ForEach-Object { "PriorAbsent-PostUpdate.$_" })
    $obs = [ordered]@{}; foreach ($id in $ids) { $obs[$id] = '8.7.9' }
    $rec = [ordered]@{ Scenario = 'Update'; Backend = $Backend; Mode = $TestMode; TimestampUtc = (Get-Date).ToUniversalTime().AddSeconds($script:calls.Count).ToString('o')
        Verdict = $(if ($failNames.Count) { 'Failed' } else { 'Passed' }); Notes = ''
        Assertions = @($names | ForEach-Object { [ordered]@{ Name = $_; Result = $(if ($failNames -contains $_) { 'FAIL' } else { 'PASS' }) } })
        Proof = [ordered]@{ SchemaVersion = '1.0'; PriorInstallsHash = $b.PriorInstallsHash; ScriptSha256 = $b.ScriptSha256; FilesSha256 = $b.FilesSha256; SupportFilesSha256 = $b.SupportFilesSha256
            BaselineInstallerSha256 = $sha; CatalogVersion = $b.CatalogVersion; EntryIds = $ids; CaptureIds = @(); RequirementChecked = $true; ObservedVersions = $obs; DataLoss = @() } }
    $file = Join-Path $ProjectPath 'Documentation\TestResults.json'
    $all = @(if (Test-Path -LiteralPath $file) { @(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) }) + @([pscustomobject]$rec)
    # X3: -SiblingProof FloorAndNewest adds a run from the newest capture (another baseline hash: it cannot prove, a failure revokes).
    if ($SiblingProof -eq 'FloorAndNewest') {
        $n = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $rec -Depth 8)
        $n.Proof.BaselineInstallerSha256 = ('E' * 64)
        $n.TimestampUtc = (Get-Date).ToUniversalTime().AddSeconds($script:calls.Count + 30).ToString('o')
        if ($script:newestFails) { $n.Verdict = 'Failed'; foreach ($a in $n.Assertions) { if ($a.Name -like 'PriorAbsent-PostUpdate.*') { $a.Result = 'FAIL' } } }
        $all += @($n)
    }
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject @($all) -Depth 8), $utf8)
    $failNames.Count -eq 0
}
$script:newestFails = $false

function New-DProject([string]$Name, [string]$Version = '8.9.9', [string]$Template = 'T') {
    if (-not $script:generated) {
        $tmp = Join-Path $root 'gen.ps1'
        $null = New-Item -ItemType Directory -Path $root -Force
        [IO.File]::WriteAllText($tmp, $golden, [Text.UTF8Encoding]::new($true))
        $null = Set-PSADTDataDrivenScript -ScriptPath $tmp -WarningAction SilentlyContinue
        $t = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        $t = Remove-Win32ToolkitPhaseDefaultUi -Content $t -Phase 'Pre-Install'
        $script:generated = Set-Win32ToolkitPhaseBlock -Content $t -Phase 'Pre-Install' -Slot 'org-ui' -Code (Get-Win32ToolkitDeployScriptBlock -Name OrgUiPreInstall)
    }
    $p = Join-Path $root "Projects\$Template\$Name"
    foreach ($d in 'SupportFiles', 'Documentation', 'Files') { $null = New-Item -ItemType Directory -Path (Join-Path $p $d) -Force }
    [IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), $script:generated, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllBytes((Join-Path $p 'Files\npp.msi'), [byte[]](1, 2, 3))
    $cfg = [ordered]@{ SchemaVersion = '1.0'; App = [ordered]@{ Vendor = 'Notepad++ Team'; Name = 'Notepad++'; DisplayName = 'Notepad++'; Version = $Version; Arch = 'x64'; ScriptAuthor = 'Contoso IT' }
        Installer = [ordered]@{ Type = 'msi'; FileName = 'npp.msi'; SilentArgs = '' }; ProcessesToClose = @('zeta')
        Source = [ordered]@{ SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Architecture = 'x64'; ProductCode = $PC }
        OrgUi = [ordered]@{ Welcome = [ordered]@{ Enabled = $true } }
        OwnIdentity = [ordered]@{ SchemaVersion = '1.0'; ProductCode = $PC; UpgradeCode = ''; ArpKeys = @([ordered]@{ Key = $PC; View = 'Native' }); CapturedOn = '2026-10-25' } }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $p
}
$sets = @{
    nsis = @{}
    inno = @{ Type = 'inno'; Key = 'NppInno_is1'; InnoMarkers = $true; ProductCodes = @('NppInno_is1'); DisplayName = 'Npp Inno'; Dir = 'NppInno'; Main = 'nppi.exe'; Uninstaller = 'unins000.exe'; DefaultInstallLocation = '' }
    third = @{ Key = 'NppThird'; ProductCodes = @('NppThird'); DisplayName = 'Npp Third'; Dir = 'NppThird'; Main = 'nppt.exe'; DefaultInstallLocation = ''; View = 'Wow6432' }
}
function Add-Captured([string]$P, [string[]]$Which, [switch]$Apply) {
    foreach ($w in $Which) {
        foreach ($v in @(@{ Version = '8.7.9'; Role = 'Floor' }, @{ Version = '8.9.8'; Role = 'Newest' })) {
            $a = $sets[$w].Clone(); foreach ($k in $v.Keys) { $a[$k] = $v[$k] }
            $null = Write-TestSiblingRecord -ProjectPath $P -Record (New-TestSiblingRecord @a)
        }
    }
    if ($Apply) {
        $ids = @((ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $P).Proposals | ForEach-Object ProposalId)
        $null = Set-Win32ToolkitPriorInstall -ProjectPath $P -FromSiblingCapture -Mode Enforce -ProposalId $ids -Confirm:$false 6>$null
    }
}
function Get-Cfg([string]$P) { Get-Content -LiteralPath (Join-Path $P 'SupportFiles\AppConfig.json') -Raw | ConvertFrom-Json }
function Reset-Calls { $script:calls.Clear(); $script:failIds = @(); $script:failFirstGroup = $false; $script:failedThisRound = $false; $script:hvNotReady = @() }

try {
    # == [1] grouping =========================================================================================
    Write-Host '[1] grouping and the call' -ForegroundColor Cyan
    $p = New-DProject 'group'
    Add-Captured $p 'nsis', 'inno' -Apply
    $cfg = Get-Cfg $p
    $op = { param([string]$Id, [string]$Key, [string]$Type, [string]$View) [pscustomobject][ordered]@{ Id = $Id; Kind = 'ArpKey'; Mode = 'Enforce'; Key = $Key; View = $View; Publisher = 'Op'; DisplayName = $Key; DisplayNameTemplate = ''
            VersionMin = '1.0'; VersionMax = '2.0'; UninstallerType = $Type; UninstallerFileName = 'u.exe'; UninstallerSigner = ''; InstallDir = '%ProgramFiles%\Op'; MainExe = 'op.exe'; ProcessNames = @('op'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-25' } }
    $cfg.PriorInstalls.Entries = @($cfg.PriorInstalls.Entries) + @((& $op 'op-a' 'OpA' 'nullsoft' 'Native'), (& $op 'op-b' 'OpB' 'nullsoft' 'Native'), (& $op 'op-c' 'OpC' 'inno' 'Wow6432'))
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    Reset-Calls
    $null = Invoke-Win32ToolkitPriorProof -ProjectPath $p 6>$null
    $groups = @($script:calls | ForEach-Object Ids | Sort-Object)
    if (($groups -join ' | ') -ceq 'inno-x64 | nsis-x64 | op-a,op-b | op-c') { Ok 'four groups: each captured rule by its floor record; op-a + op-b (nullsoft, Native); op-c (inno, Wow6432)' } else { Bad "groups: $($groups -join ' | ')" }
    if (@($script:calls | Where-Object { $_.Keys -cne 'Backend,ProjectPath,ProofEntryId,Scenario,TestMode' -or $_.Scenario -ne 'Update' -or $_.Backend -ne 'HyperV' -or $_.TestMode -ne 'Unattended' }).Count -eq 0) { Ok 'every call: -Scenario Update -Backend HyperV -TestMode Unattended -ProofEntryId <group>, no other (baseline) parameter' } else { Bad "keys: $(@($script:calls.Keys) -join ' | ')" }
    Reset-Calls
    $null = Invoke-Win32ToolkitPriorProof -ProjectPath $p 6>$null
    if ($script:calls.Count -eq 0) { Ok 'every group proven (the binding unchanged) -> no run again' } else { Bad "rerun: $($script:calls.Count)" }
    $cfg = Get-Cfg $p; $cfg.PriorInstalls.Entries[-1].VersionMax = '2.1'
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    Reset-Calls
    $null = Invoke-Win32ToolkitPriorProof -ProjectPath $p -EntryId 'op-c' 6>$null
    if ((@($script:calls | ForEach-Object Ids) -join ' | ') -ceq 'op-c') { Ok 'a changed rule un-proves the whole set (SV6); -EntryId op-c runs only its group' } else { Bad "entryid: $(@($script:calls | ForEach-Object Ids) -join ' | ')" }

    # == [2] Hyper-V not ready =================================================================================
    Write-Host '[2] Hyper-V not ready' -ForegroundColor Cyan
    Reset-Calls
    $script:hvNotReady = @('the test VM win32tk-golden does not exist')
    $w = $null
    $st = @(Invoke-Win32ToolkitPriorProof -ProjectPath $p -WarningVariable w -WarningAction SilentlyContinue 6>$null)
    $np = @($st | Where-Object { $_.State -eq 'NotProven' })
    if ($script:calls.Count -eq 0 -and $np.Count -ge 1 -and @($np | Where-Object { $_.Reason -notlike 'not proven: Hyper-V is not ready (the test VM win32tk-golden does not exist)' }).Count -eq 0 -and @($w).Count -eq 1) { Ok "no call; every unproven rule 'not proven: Hyper-V is not ready (...)', one warning" } else { Bad "notready: calls $($script:calls.Count) $(@($np | ForEach-Object Reason) -join ' | ')" }

    # == [3] the loop ==========================================================================================
    Write-Host '[3] the proof-demotion loop' -ForegroundColor Cyan
    $p = New-DProject 'loop'
    Add-Captured $p 'nsis', 'inno' -Apply
    Reset-Calls
    $script:failIds = @('inno-x64')
    $w = $null
    $r = Invoke-Win32ToolkitPriorDemotion -ProjectPath $p -Prove -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $cfg = Get-Cfg $p
    $callIds = @($script:calls | ForEach-Object Ids)
    if ($r.Rounds -eq 2 -and ($callIds -join ' | ') -ceq 'inno-x64 | nsis-x64 | nsis-x64' -and (@($cfg.PriorInstalls.Entries | ForEach-Object Id) -join ',') -ceq 'nsis-x64' -and (@($r.Proven) -join ',') -ceq 'nsis-x64' -and (@($r.Demoted | ForEach-Object Id) -join ',') -ceq 'inno-x64') {
        Ok 'round 1: inno-x64 fails and is demoted; round 2: nsis-x64 proven again on the remaining set; it ends Proven'
    } else { Bad "loop: rounds $($r.Rounds) calls $($callIds -join ' | ') entries $(@($cfg.PriorInstalls.Entries | ForEach-Object Id) -join ',')" }
    $ap = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $p | Where-Object { $_.Kind -eq 'Approval' -and $_.Target -eq 'inno-x64' -and $_.Latest })
    $dw = @($w | Where-Object { "$_" -match "rule 'inno-x64' was not proven \(failing assertions: PriorAbsent-PostUpdate\.inno-x64\) and was demoted" })
    if ($ap.Count -eq 1 -and $ap[0].Demoted -match '^\d{4}-\d{2}-\d{2}$' -and $dw.Count -eq 1) { Ok 'its Approval marked Demoted; the warning names the failing assertion' } else { Bad "approval/warning: $($ap | ConvertTo-Json -Compress) $($w -join ' | ')" }
    # Live row RAISE: the warning printed '-ProposalId <id>'; it names the identity's proposal (still Enforce-eligible here).
    if ($dw.Count -eq 1 -and "$($dw[0])" -match "Fix the cause and approve it again \(Set-Win32ToolkitPriorInstall -ProjectPath '.*' -FromSiblingCapture -Mode Enforce -ProposalId inno-x64\)\.$") { Ok 'an eligible identity: the warning names its proposal id in the Enforce command (no <id> placeholder)' } else { Bad "proposal id: $($dw -join ' | ')" }
    # Live row RAISE: a noise-unverified capture of the same identity made it Block-only, yet the warning said "approve it
    # again ... -Mode Enforce" (refused: not eligible). It now names the reasons and the Block command.
    $pn = New-DProject 'noise'
    Add-Captured $pn 'nsis' -Apply
    $null = Write-TestSiblingRecord -ProjectPath $pn -Record (New-TestSiblingRecord -Version '8.9.8.1' -Role 'Newest' -Noise 'Unverified')
    Reset-Calls
    $w = $null
    $null = Invoke-Win32ToolkitPriorDemotion -ProjectPath $pn -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $nw = @($w | Where-Object { "$_" -match "rule 'nsis-x64' was not proven" })
    if ($nw.Count -eq 1 -and "$($nw[0])" -match 'no longer eligible for Enforce \(.*NoiseUnverified' -and "$($nw[0])" -match '-FromSiblingCapture -Mode Block -ProposalId nsis-x64\)\.$' -and "$($nw[0])" -notmatch '-Mode Enforce') { Ok 'a Block-only identity: the warning names why it is no longer eligible and the Block command (never -Mode Enforce)' } else { Bad "ineligible: $($w -join ' | ')" }
    $rows = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $p -Stage Export)
    $adv = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $p -Stage Advisory | Where-Object { $_.Code -eq 'ID-SIBLING-UNAPPLIED' -and $_.Target -eq 'inno-x64' })
    if ($rows.Count -eq 0 -and $adv.Count -eq 1 -and (@($cfg.ProcessesToClose) -join ',') -match 'nppi') { Ok 'Export (the real prior-install gate) passes; the demoted identity is a proposal again (ID-SIBLING-UNAPPLIED); its process name stays' } else { Bad "export: $(@($rows | ForEach-Object { "$($_.Code): $($_.Message)" }) -join ' | ')" }

    # == [4] operator rules; no -Prove ==========================================================================
    Write-Host '[4] operator rules are never demoted; without -Prove' -ForegroundColor Cyan
    $p = New-DProject 'oper'
    Add-Captured $p 'nsis' -Apply
    $cfg = Get-Cfg $p
    $cfg.PriorInstalls.Entries = @($cfg.PriorInstalls.Entries) + @([pscustomobject][ordered]@{ Id = 'op-a'; Kind = 'ArpKey'; Mode = 'Enforce'; Key = 'OpA'; View = 'Native'; Publisher = 'Op'; DisplayName = 'OpA'; DisplayNameTemplate = ''
            VersionMin = '1.0'; VersionMax = '2.0'; UninstallerType = 'inno'; UninstallerFileName = 'u.exe'; UninstallerSigner = ''; InstallDir = '%ProgramFiles%\Op'; MainExe = 'op.exe'; ProcessNames = @('op'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-25' })
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    Reset-Calls
    $script:failIds = @('op-a')
    $w = $null
    $r = Invoke-Win32ToolkitPriorDemotion -ProjectPath $p -Prove -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $ids = @((Get-Cfg $p).PriorInstalls.Entries | ForEach-Object Id) -join ','
    if ($ids -ceq 'nsis-x64,op-a' -and (@($r.Unproven) -join ',') -ceq 'op-a' -and @($r.Demoted).Count -eq 0 -and @($w | Where-Object { "$_" -match "'op-a' \(Operator\) is not proven.*never demoted" }).Count -eq 1) { Ok 'an unproven operator Enforce rule is never demoted: one warning' } else { Bad "operator: $ids / $($w -join ' | ')" }
    $p = New-DProject 'noprove'
    Add-Captured $p 'nsis', 'inno' -Apply
    Reset-Calls
    $r = Invoke-Win32ToolkitPriorDemotion -ProjectPath $p -WarningAction SilentlyContinue 6>$null
    if ($script:calls.Count -eq 0 -and $r.Rounds -eq 1 -and @($r.Demoted).Count -eq 2 -and @((Get-Cfg $p).PriorInstalls.Entries).Count -eq 0) { Ok 'without -Prove: one round, no run, every unproven captured Enforce rule demoted ("no proof run")' } else { Bad "noprove: calls $($script:calls.Count) rounds $($r.Rounds) demoted $(@($r.Demoted).Count)" }
    if (@($r.Demoted | Where-Object { $_.Reason -match 'no proof run' }).Count -eq 2) { Ok 'the reason of a rule never run: no proof run' } else { Bad "reason: $(@($r.Demoted | ForEach-Object Reason) -join ' | ')" }
    # One group proven, the other failed, on the same rule set; then no proof (Hyper-V not ready / no Update test): the
    # failed rule is demoted, and its removal un-proves the proven one, which nothing here can prove again.
    $p = New-DProject 'partial'
    Add-Captured $p 'nsis', 'inno' -Apply
    Reset-Calls
    $script:failIds = @('inno-x64')
    $null = Invoke-Win32ToolkitPriorProof -ProjectPath $p 6>$null
    $before = (@(Get-Win32ToolkitPriorProofState -ProjectPath $p | ForEach-Object { "$($_.Id)=$($_.State)" } | Sort-Object -Descending) -join ',')
    Reset-Calls
    $w = $null
    $r = Invoke-Win32ToolkitPriorDemotion -ProjectPath $p -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $dm = @($r.Demoted | ForEach-Object { "$($_.Id): $($_.Reason)" })
    if ($before -ceq 'nsis-x64=Proven,inno-x64=NotProven' -and $script:calls.Count -eq 0 -and $r.Rounds -eq 1 -and @((Get-Cfg $p).PriorInstalls.Entries).Count -eq 0 -and $dm.Count -eq 2 -and
        $dm[0] -match '^inno-x64: failing assertions: PriorAbsent-PostUpdate\.inno-x64$' -and $dm[1] -match '^nsis-x64: its proof also covered inno-x64, demoted just before it, and no proof runs here') {
        Ok 'without -Prove: the failed rule is demoted, then the proven one its removal un-proved (the reason names inno-x64), no run'
    } else { Bad "partial: before $before calls $($script:calls.Count) demoted $($dm -join ' | ')" }
    $ap = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $p | Where-Object { $_.Kind -eq 'Approval' -and $_.Target -eq 'nsis-x64' -and $_.Latest })
    if ($ap.Count -eq 1 -and $ap[0].Demoted -and @($w | Where-Object { "$_" -match "rule 'nsis-x64' was not proven \(its proof also covered inno-x64" }).Count -eq 1 -and
        @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $p -Stage Export | Where-Object Code -eq 'PRIOR-PROOF').Count -eq 0) {
        Ok 'its Approval marked Demoted, one warning; Export has no PRIOR-PROOF (D59a: demote and continue)'
    } else { Bad "partial approval/export: $($ap | ConvertTo-Json -Compress) / $($w -join ' | ')" }

    # == [5] the bound ==========================================================================================
    Write-Host '[5] the loop ends at its bound' -ForegroundColor Cyan
    $p = New-DProject 'bound'
    Add-Captured $p 'nsis', 'inno', 'third' -Apply
    Reset-Calls
    $script:failFirstGroup = $true
    $orig = ${function:Invoke-Win32ToolkitPriorProof}
    function Invoke-Win32ToolkitPriorProof { param([string]$ProjectPath, [string[]]$EntryId) $script:failedThisRound = $false; & $orig -ProjectPath $ProjectPath }
    $r = Invoke-Win32ToolkitPriorDemotion -ProjectPath $p -Prove -MaxRounds 2 -WarningAction SilentlyContinue 6>$null
    ${function:Invoke-Win32ToolkitPriorProof} = $orig
    $left = @((Get-Cfg $p).PriorInstalls.Entries)
    $last = @($r.Demoted)[-1]
    if ($r.Rounds -eq 2 -and @($r.Demoted).Count -eq 3 -and $left.Count -eq 0 -and $script:calls.Count -eq 5) { Ok 'one rule fails per round: -MaxRounds 2 (below 1 + 3) stops proving after two rounds (5 runs), two demoted for their failure' } else { Bad "bound: rounds $($r.Rounds) demoted $(@($r.Demoted).Count) left $($left.Count) calls $($script:calls.Count)" }
    if ($last.Reason -match "its proof also covered [a-z0-9-]+, demoted just before it, and the last proof round \(2\) has run" -and @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $p -Stage Export | Where-Object Code -eq 'PRIOR-PROOF').Count -eq 0) {
        Ok 'the survivor the last demotion un-proved is demoted too (no round left; the reason names the rule before it): Export has no PRIOR-PROOF (L37)'
    } else { Bad "bound survivor: $($last | ConvertTo-Json -Compress) / $(@(Get-Win32ToolkitPriorInstallFinding -ProjectPath $p -Stage Export | ForEach-Object Code) -join ',')" }
    $threw = $null
    try { $null = Invoke-Win32ToolkitPriorDemotion -ProjectPath $p -MaxRounds 5 -WarningAction SilentlyContinue 6>$null } catch { $threw = $_.FullyQualifiedErrorId }
    if ($threw -like 'ParameterArgumentValidationError*') { Ok '-MaxRounds 5 is refused: never more than four rounds (L37)' } else { Bad "maxrounds 5: $threw" }

    # == [6] X3: -SiblingProof FloorAndNewest ===================================================================
    Write-Host '[6] X3: a run from the newest capture too; a failure there revokes' -ForegroundColor Cyan
    $p = New-DProject 'newest'
    Add-Captured $p 'nsis' -Apply
    $cfg = Get-Cfg $p
    $cfg.PriorInstalls.Entries = @($cfg.PriorInstalls.Entries) + @([pscustomobject][ordered]@{ Id = 'op-a'; Kind = 'ArpKey'; Mode = 'Enforce'; Key = 'OpA'; View = 'Native'; Publisher = 'Op'; DisplayName = 'OpA'; DisplayNameTemplate = ''
            VersionMin = '1.0'; VersionMax = '2.0'; UninstallerType = 'inno'; UninstallerFileName = 'u.exe'; UninstallerSigner = ''; InstallDir = '%ProgramFiles%\Op'; MainExe = 'op.exe'; ProcessNames = @('op'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-25' })
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    Reset-Calls
    $st = @(Invoke-Win32ToolkitPriorProof -ProjectPath $p -SiblingProof FloorAndNewest 6>$null)
    $nsisCall = @($script:calls | Where-Object Ids -eq 'nsis-x64')[0]; $opCall = @($script:calls | Where-Object Ids -eq 'op-a')[0]
    if ($nsisCall.Keys -match 'SiblingProof' -and $opCall.Keys -notmatch 'SiblingProof' -and @($st | Where-Object { $_.Id -eq 'nsis-x64' -and $_.State -eq 'Proven' }).Count -eq 1) { Ok 'the captured group runs with -SiblingProof FloorAndNewest (the operator group does not); a passing newest run keeps the floor proof' } else { Bad "x3 calls: $($script:calls | ConvertTo-Json -Compress)" }
    $p2 = New-DProject 'newestfail'
    Add-Captured $p2 'nsis' -Apply
    Reset-Calls
    $script:newestFails = $true
    $st = @(Invoke-Win32ToolkitPriorProof -ProjectPath $p2 -SiblingProof FloorAndNewest 6>$null)
    $script:newestFails = $false
    $ns = @($st | Where-Object Id -eq 'nsis-x64')[0]
    if ($ns.State -eq 'NotProven' -and $ns.Reason -match 'the newest proof run failed \(PriorAbsent-PostUpdate\.nsis-x64\)') { Ok 'the floor run passed, the newest one failed -> not proven (the failure revokes)' } else { Bad "revoke: $($ns | ConvertTo-Json -Compress)" }

    # == [7] a next version: a demoted carried rule ==============================================================
    Write-Host '[7] a next version: a demoted carried rule meets ID-PRIOR-DROPPED at Export' -ForegroundColor Cyan
    # 8.9.9 carries nsis-x64 and inno-x64 from 8.9.8 (its carry source: same app, template folder and architecture); its
    # own template folder, so no other case gets a carry source.
    $p = New-DProject 'next' -Template 'N'
    Add-Captured $p 'nsis', 'inno' -Apply
    $prev = New-DProject 'prev' -Version '8.9.8' -Template 'N'
    $pc = Get-Cfg $prev
    $pc | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue (Get-Cfg $p).PriorInstalls -Force
    [IO.File]::WriteAllText((Join-Path $prev 'SupportFiles\AppConfig.json'), ($pc | ConvertTo-Json -Depth 8), $utf8)
    Reset-Calls
    $script:failIds = @('inno-x64')
    $null = Invoke-Win32ToolkitPriorProof -ProjectPath $p 6>$null
    Reset-Calls
    $r = Invoke-Win32ToolkitPriorDemotion -ProjectPath $p -WarningAction SilentlyContinue 6>$null
    $rows = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $p -Stage Export)
    $codes = (@($rows | ForEach-Object { "$($_.Code)[$($_.Target)]" } | Sort-Object) -join ',')
    if ((Get-Win32ToolkitPriorCarrySource -ProjectPath $p).Name -ceq 'prev' -and (@($r.Demoted | ForEach-Object Id) -join ',') -ceq 'inno-x64,nsis-x64' -and
        $codes -ceq 'ID-PRIOR-DROPPED[inno-x64],ID-PRIOR-DROPPED[nsis-x64]') {
        Ok 'the failed carried rule and the one its removal un-proved are both demoted: no PRIOR-PROOF, but one ID-PRIOR-DROPPED each (the version before carried them)'
    } else { Bad "carried: demoted $(@($r.Demoted | ForEach-Object Id) -join ',') rows $codes" }
    $null = Set-Win32ToolkitPriorInstall -ProjectPath $p -FromSiblingCapture -Mode Enforce -ProposalId 'nsis-x64' -Confirm:$false 6>$null
    $null = Invoke-Win32ToolkitPriorProof -ProjectPath $p 6>$null
    $codes = (@(Get-Win32ToolkitPriorInstallFinding -ProjectPath $p -Stage Export | ForEach-Object { "$($_.Code)[$($_.Target)]" } | Sort-Object) -join ',')
    $null = Set-Win32ToolkitPriorInstall -ProjectPath $p -Acknowledge ID-PRIOR-DROPPED -Target 'inno-x64' -Reason 'the Inno build is gone from the fleet' -Confirm:$false 6>$null
    $after = @(Get-Win32ToolkitPriorInstallFinding -ProjectPath $p -Stage Export)
    if ($codes -ceq 'ID-PRIOR-DROPPED[inno-x64]' -and $after.Count -eq 0) {
        Ok 'nsis-x64 approved and proven again: its row is gone; the inno-x64 drop acknowledged: Export passes'
    } else { Bad "carried again: $codes / $(@($after | ForEach-Object { "$($_.Code)[$($_.Target)]" }) -join ',')" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PriorDemotion tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PriorDemotion test(s) FAILED." -ForegroundColor Red; exit 1 }
