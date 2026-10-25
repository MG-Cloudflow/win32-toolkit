<#
    Installer-identity PR 3 (spec 2.3, 2.10, 2.11, D17, SV6, L12, L14): Get-Win32ToolkitPriorProofBinding and
    Get-Win32ToolkitPriorProofState - when does an Enforce rule count as proven?

      [1] the binding: 64-hex hashes; a file added under Files\, an edited SupportFiles\OrgHooks\PreInstall.ps1, an
          edited deploy script, a changed entry or a changed catalog version each move exactly their own value.
      [2] the state: Block / Report -> NotNeeded; a Passed Hyper-V Unattended record with the current binding and the
          required PASS assertions -> Proven (ProvenOn, ProvenVersions); Sandbox, Interactive, a skipped requirement, a
          missing required assertion -> never; a newer Failed record revokes an older pass (any backend); a newer pass
          after a failure proves again; NotRun and Baseline.Unavailable records are ignored; a changed FilesSha256,
          ScriptSha256, SupportFilesSha256 (a changed org hook) or CatalogVersion un-proves; two entries proven by two
          runs; Proof.DataLoss -> still Proven with DataLoss (user data never decides, L14).
      [3] capture lineage: also SiblingIdentityStable / PriorResidue and BaselineInstallerSha256 = the floor capture
          record's installer hash (record written in the frozen shape, read through the hash-verified reader).

    Fixture projects and TestResults.json files under %TEMP%; no test run. Run:  pwsh -File Tests\PriorProof.unit.ps1
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

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32proof_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
$PC = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'

function Entry([string]$Id, [string]$Mode = 'Enforce', [hashtable]$Over = @{}) {
    $e = [ordered]@{ Id = $Id; Kind = 'ArpKey'; Mode = $Mode; Key = "Key-$Id"; View = 'Native'; Publisher = 'Vendor'; DisplayName = "App $Id"; DisplayNameTemplate = ''
        VersionMin = '8.7.9'; VersionMax = '8.9.8.1'; UninstallerType = 'nullsoft'; UninstallerFileName = 'uninstall.exe'; UninstallerSigner = ''; InstallDir = "%ProgramFiles%\$Id"
        MainExe = 'app.exe'; ProcessNames = @('app'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-25' }
    foreach ($k in $Over.Keys) { $e[$k] = $Over[$k] }
    $e
}
function New-ProofProject([string]$Name, [object[]]$Entries) {
    $p = Join-Path $root $Name
    $null = New-Item -ItemType Directory -Path (Join-Path $p 'Files'), (Join-Path $p 'SupportFiles\OrgHooks'), (Join-Path $p 'Documentation') -Force
    [IO.File]::WriteAllText((Join-Path $p 'Files\npp.msi'), 'msi bytes', $utf8)
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\OrgHooks\PreInstall.ps1'), "Write-ADTLogEntry -Message 'hook'", $utf8)
    [IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), '# deploy script', $utf8)
    $cfg = [ordered]@{ App = [ordered]@{ Version = '8.9.9'; ScriptAuthor = 'Contoso IT' }; Installer = [ordered]@{ Type = 'msi'; FileName = 'npp.msi' }
        OwnIdentity = [ordered]@{ ProductCode = $PC; ArpKeys = @([ordered]@{ Key = $PC; View = 'Native' }) }; PriorInstalls = [ordered]@{ SchemaVersion = '1.0'; Entries = @($Entries) } }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $p
}
# A TestResults.json record of an Update run that checked $Ids against the CURRENT binding (unless overridden).
function Rec([string]$P, [string[]]$Ids, [hashtable]$O = @{}) {
    $b = Get-Win32ToolkitPriorProofBinding -ProjectPath $P
    $names = @('Requirement-PreUpdate', 'NewAppIntact-PostUpdate', 'Tattoo-PostUpdate', 'OldArpGone-PostUpdate')
    foreach ($id in $Ids) { $names += @("PriorPresent-PreUpdate.$id", "PriorAbsent-PostUpdate.$id", "SiblingIdentityStable-PreUpdate.$id", "PriorResidue-PostUpdate.$id") }
    $fails = @($O['Fail'] | Where-Object { $_ })
    $obs = [ordered]@{}; foreach ($id in $Ids) { $obs[$id] = if ($O.ContainsKey('Observed')) { $O.Observed } else { '8.9.5' } }
    $proof = [ordered]@{ SchemaVersion = '1.0'; PriorInstallsHash = $b.PriorInstallsHash; ScriptSha256 = $b.ScriptSha256; FilesSha256 = $b.FilesSha256; SupportFilesSha256 = $b.SupportFilesSha256
        BaselineInstallerSha256 = $(if ($O.ContainsKey('BaselineSha')) { $O.BaselineSha } else { '' }); CatalogVersion = $b.CatalogVersion; EntryIds = @($Ids); CaptureIds = @()
        RequirementChecked = $(if ($O.ContainsKey('Req')) { $O.Req } else { $true }); ObservedVersions = $obs; DataLoss = @($O['DataLoss'] | Where-Object { $_ }) }
    foreach ($k in @($O.Keys | Where-Object { $_ -like 'Proof.*' })) { $proof[$k.Substring(6)] = $O[$k] }
    $r = [ordered]@{ Scenario = 'Update'; Backend = $(if ($O.Backend) { $O.Backend } else { 'HyperV' }); Mode = $(if ($O.Mode) { $O.Mode } else { 'Unattended' })
        TimestampUtc = $(if ($O.Ts) { $O.Ts } else { '2026-10-25T10:00:00.0000000Z' }); Verdict = $(if ($O.Verdict) { $O.Verdict } elseif ($fails.Count) { 'Failed' } else { 'Passed' })
        Assertions = @($names | Where-Object { $O['Omit'] -notcontains $_ } | ForEach-Object { [ordered]@{ Name = $_; Result = $(if ($fails -contains $_) { 'FAIL' } else { 'PASS' }) } }); Notes = ''; Proof = $proof }
    if ($O.NotRun) { $r['NotRun'] = [ordered]@{ Code = 'PARITY-DIALOG-WAIT' } }
    if ($O.Unavailable) { $r['Baseline'] = [ordered]@{ Version = '8.9'; Unavailable = $true } }
    $r
}
function Set-ResultFile([string]$P, [object[]]$Records) { [IO.File]::WriteAllText((Join-Path $P 'Documentation\TestResults.json'), (ConvertTo-Json -InputObject @($Records) -Depth 8), $utf8) }
function State([string]$P, [string]$Id) { @(Get-Win32ToolkitPriorProofState -ProjectPath $P) | Where-Object { $_.Id -ceq $Id } | Select-Object -First 1 }

try {
    # == [1] binding =====================================================================================
    Write-Host '[1] Get-Win32ToolkitPriorProofBinding' -ForegroundColor Cyan
    $p = New-ProofProject 'binding' @((Entry 'nsis-x64'))
    $b0 = Get-Win32ToolkitPriorProofBinding -ProjectPath $p
    if (@($b0.PriorInstallsHash, $b0.ScriptSha256, $b0.FilesSha256, $b0.SupportFilesSha256 | Where-Object { $_ -cnotmatch '^[0-9A-F]{64}$' }).Count -eq 0 -and $b0.CatalogVersion -cmatch '^[0-9a-f]{16}$') { Ok 'four 64-hex hashes and the 16-hex catalog version' } else { Bad "binding: $($b0 | ConvertTo-Json -Compress)" }
    $moves = @(
        @{ L = 'a file added under Files\'; F = 'FilesSha256'; A = { [IO.File]::WriteAllText((Join-Path $p 'Files\extra.mst'), 'x', $utf8) }; U = { Remove-Item (Join-Path $p 'Files\extra.mst') } }
        @{ L = 'the edited org hook SupportFiles\OrgHooks\PreInstall.ps1'; F = 'SupportFilesSha256'; A = { [IO.File]::AppendAllText((Join-Path $p 'SupportFiles\OrgHooks\PreInstall.ps1'), ' # x') }; U = { [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\OrgHooks\PreInstall.ps1'), "Write-ADTLogEntry -Message 'hook'", $utf8) } }
        @{ L = 'the edited deploy script'; F = 'ScriptSha256'; A = { [IO.File]::AppendAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), "`n# edit") }; U = { [IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), '# deploy script', $utf8) } }
    )
    foreach ($m in $moves) {
        & $m.A
        $b1 = Get-Win32ToolkitPriorProofBinding -ProjectPath $p
        $changed = @('PriorInstallsHash', 'ScriptSha256', 'FilesSha256', 'SupportFilesSha256') | Where-Object { $b1.$_ -cne $b0.$_ }
        if (@($changed) -join ',' -ceq $m.F) { Ok "$($m.L) moves $($m.F) only" } else { Bad "$($m.L): changed $(@($changed) -join ',')" }
        & $m.U
    }
    $b2 = Get-Win32ToolkitPriorProofBinding -ProjectPath $p
    if (($b2 | ConvertTo-Json -Compress) -ceq ($b0 | ConvertTo-Json -Compress)) { Ok 'restored files give the same binding (content, not timestamps)' } else { Bad 'binding not reproducible' }

    # == [2] state ======================================================================================
    Write-Host '[2] Get-Win32ToolkitPriorProofState' -ForegroundColor Cyan
    $p = New-ProofProject 'state' @((Entry 'nsis-x64'), (Entry 'block-x64' 'Block'), (Entry 'rep-x64' 'Report'))
    Set-ResultFile $p @()
    $s = @(Get-Win32ToolkitPriorProofState -ProjectPath $p)
    if (($s | Where-Object Id -eq 'block-x64').State -eq 'NotNeeded' -and ($s | Where-Object Id -eq 'rep-x64').State -eq 'NotNeeded') { Ok 'Block and Report -> NotNeeded' } else { Bad 'NotNeeded' }
    $x = $s | Where-Object Id -eq 'nsis-x64'
    if ($x.State -eq 'NotProven' -and $x.Reason -match 'no proof run' -and $x.Lineage -eq 'Operator') { Ok 'Enforce without a run -> NotProven (no proof run)' } else { Bad "no run: $($x | ConvertTo-Json -Compress)" }
    Set-ResultFile $p @((Rec $p @('nsis-x64') @{ Observed = '8.8.9' }))
    $x = State $p 'nsis-x64'
    if ($x.State -eq 'Proven' -and $x.ProvenOn -eq '2026-10-25' -and @($x.ProvenVersions) -join ',' -eq '8.8.9' -and -not $x.DataLoss) { Ok 'a Passed Hyper-V Unattended record with the current binding -> Proven (date, observed version)' } else { Bad "proven: $($x | ConvertTo-Json -Compress)" }
    foreach ($c in @(
            @{ L = 'a Sandbox pass'; O = @{ Backend = 'Sandbox' }; Rx = 'Sandbox or watched' }
            @{ L = 'an Interactive pass'; O = @{ Mode = 'Interactive' }; Rx = 'Sandbox or watched' }
            @{ L = 'a pass with the requirement check skipped'; O = @{ Req = $false }; Rx = 'Sandbox or watched' }
            @{ L = 'a pass without PriorAbsent'; O = @{ Omit = @('PriorAbsent-PostUpdate.nsis-x64') }; Rx = 'required assertion' }
            @{ L = 'a pass without the Requirement assertion'; O = @{ Omit = @('Requirement-PreUpdate') }; Rx = 'required assertion' }
            @{ L = 'a NotRun record'; O = @{ NotRun = $true }; Rx = 'no proof run' }
            @{ L = 'a Baseline.Unavailable record'; O = @{ Unavailable = $true }; Rx = 'no proof run' }
        )) {
        Set-ResultFile $p @((Rec $p @('nsis-x64') $c.O))
        $x = State $p 'nsis-x64'
        if ($x.State -eq 'NotProven' -and $x.Reason -match $c.Rx) { Ok "$($c.L) never proves ($($x.Reason))" } else { Bad "$($c.L): $($x.State) $($x.Reason)" }
    }
    Set-ResultFile $p @((Rec $p @('nsis-x64')), (Rec $p @('nsis-x64') @{ Backend = 'Sandbox'; Fail = @('PriorAbsent-PostUpdate.nsis-x64') }))
    $x = State $p 'nsis-x64'
    # Live row MSIBUSY: a failing watched or Sandbox run revokes the proof too; the reason says which run it was.
    if ($x.State -eq 'NotProven' -and $x.Reason -match '^the newest run that checked it, a Windows Sandbox run, failed \(PriorAbsent-PostUpdate\.nsis-x64\); a failed run revokes the proof whatever its backend or mode$') { Ok 'a newer Failed record (even Sandbox) revokes the older pass; the reason names the failing assertion and that it was a Sandbox run' } else { Bad "revoke: $($x | ConvertTo-Json -Compress)" }
    Set-ResultFile $p @((Rec $p @('nsis-x64')), (Rec $p @('nsis-x64') @{ Mode = 'Interactive'; Fail = @('PriorAbsent-PostUpdate.nsis-x64') }))
    $x = State $p 'nsis-x64'
    if ($x.State -eq 'NotProven' -and $x.Reason -match '^the newest run that checked it, a watched Hyper-V run, failed') { Ok 'a failing watched Hyper-V run revokes and is named as one' } else { Bad "watched revoke: $($x.Reason)" }
    # Live rows DEMOTE, RC2-PROOF, MSIBUSY: 69105, 69107 and 1618 read as the same failing assertions; the update's own exit code
    # (the record's Notes) is named too, FIRST (live row OP-NEWER: a shortened text lost it at the end).
    $rf = Rec $p @('nsis-x64') @{ Fail = @('PriorAbsent-PostUpdate.nsis-x64') }
    $rf.Notes = "Intune-parity phase 'Update (Intune parity)' exited with code 69107. The update exited with code 69107: a restart is pending."
    Set-ResultFile $p @((Rec $p @('nsis-x64')), $rf)
    $x = State $p 'nsis-x64'
    if ($x.LastFailure -ceq 'the update exited with code 69107; PriorAbsent-PostUpdate.nsis-x64' -and $x.LastExitCode -eq 69107 -and $x.Reason -ceq 'the newest proof run failed (the update exited with code 69107; PriorAbsent-PostUpdate.nsis-x64)') { Ok 'the failing run''s update exit code (its Notes) leads LastFailure and the reason; LastExitCode 69107' } else { Bad "exit code: $($x.LastFailure) / $($x.LastExitCode) / $($x.Reason)" }
    $rf.Notes = ''
    Set-ResultFile $p @((Rec $p @('nsis-x64')), $rf)
    if ($null -eq (State $p 'nsis-x64').LastExitCode) { Ok 'no exit code in the Notes -> LastExitCode $null' } else { Bad 'LastExitCode without a note' }
    Set-ResultFile $p @((Rec $p @('nsis-x64') @{ Fail = @('Tattoo-PostUpdate') }), (Rec $p @('nsis-x64') @{ Ts = '2026-10-26T10:00:00Z' }))
    $x = State $p 'nsis-x64'
    if ($x.State -eq 'Proven' -and $x.ProvenOn -eq '2026-10-26') { Ok 'a newer pass after a failure proves again' } else { Bad "pass after fail: $($x.State)" }
    Set-ResultFile $p @((Rec $p @('nsis-x64') @{ DataLoss = @('nsis-x64') }))
    $x = State $p 'nsis-x64'
    if ($x.State -eq 'Proven' -and $x.DataLoss) { Ok 'Proof.DataLoss names the entry: Proven with DataLoss (user data never decides, L14)' } else { Bad "data loss: $($x | ConvertTo-Json -Compress)" }
    Set-ResultFile $p @((Rec $p @('nsis-x64') @{ Observed = '8.8.9' }), (Rec $p @('nsis-x64') @{ Observed = '8.9.5' }))
    if ((@((State $p 'nsis-x64').ProvenVersions) -join ',') -eq '8.8.9,8.9.5') { Ok 'ProvenVersions = the observed version of every proving record' } else { Bad 'ProvenVersions' }
    Set-ResultFile $p @((Rec $p @('nsis-x64')))
    foreach ($m in @(
            @{ L = 'a file added under Files\ (FilesSha256)'; A = { [IO.File]::WriteAllText((Join-Path $p 'Files\new.mst'), 'x', $utf8) }; U = { Remove-Item (Join-Path $p 'Files\new.mst') } }
            @{ L = 'a changed org hook (SupportFilesSha256)'; A = { [IO.File]::AppendAllText((Join-Path $p 'SupportFiles\OrgHooks\PreInstall.ps1'), ' # x') }; U = { [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\OrgHooks\PreInstall.ps1'), "Write-ADTLogEntry -Message 'hook'", $utf8) } }
            @{ L = 'an edited deploy script (ScriptSha256)'; A = { [IO.File]::AppendAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), ' ') }; U = { [IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), '# deploy script', $utf8) } }
        )) {
        & $m.A
        $x = State $p 'nsis-x64'
        # Live row OP-OWN: the reason names the part that changed (a declared dependency changes SupportFiles).
        $part = if ($m.L -like '*(SupportFilesSha256)') { 'a file in SupportFiles' } elseif ($m.L -like '*(FilesSha256)') { 'the Files folder' } else { 'the deploy script' }
        if ($x.State -eq 'NotProven' -and $x.Reason -match 'changed after the last proof run' -and $x.Reason -match ('\(' + [regex]::Escape($part))) { Ok "$($m.L) un-proves, naming $part" } else { Bad "$($m.L): $($x.State) $($x.Reason)" }
        & $m.U
    }
    # Live rows KILL-NATIVE, KILL-WOW, APP-RUNNING, OP-EXPORT: a file ADDED to SupportFiles (AppConfig.json unchanged) was
    # explained as an AppConfig.json change.
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\pr3-flag.flag'), 'x', $utf8)
    $x = State $p 'nsis-x64'
    Remove-Item -LiteralPath (Join-Path $p 'SupportFiles\pr3-flag.flag')
    # Live rows KILL-WOW, APP-RUNNING (round 2): the part's own brackets nested inside the reason's ("(SupportFiles (a file ...))").
    if ($x.State -eq 'NotProven' -and $x.Reason -ceq 'the package or its prior-install rules changed after the last proof run (a file in SupportFiles was added, removed or changed - AppConfig.json, an org hook, UpdateRequirement.ps1 or another file): run it again' -and $x.Reason -notmatch 'dependencies, processes, rules') { Ok 'a file added under SupportFiles un-proves; the reason says a file there was added, removed or changed (not "AppConfig.json"), with no nested brackets' } else { Bad "added file: $($x.Reason)" }
    if ((State $p 'nsis-x64').State -eq 'Proven') { Ok 'restored -> Proven again' } else { Bad 'restore' }
    $realBlock = ${function:Get-Win32ToolkitDeployScriptBlock}
    function Get-Win32ToolkitDeployScriptBlock { param([string]$Name) if ($Name -eq 'RemovePriorCatalogVersion') { return '0123456789abcdef' }; & $realBlock -Name $Name }
    $x = State $p 'nsis-x64'
    ${function:Get-Win32ToolkitDeployScriptBlock} = $realBlock
    if ($x.State -eq 'NotProven') { Ok 'another catalog version (a later device text) un-proves' } else { Bad 'catalog version ignored' }
    $cfgFile = Join-Path $p 'SupportFiles\AppConfig.json'
    $orig = [IO.File]::ReadAllText($cfgFile)
    [IO.File]::WriteAllText($cfgFile, $orig.Replace('"VersionMax": "8.9.8.1"', '"VersionMax": "8.9.8.2"'), $utf8)
    $x = State $p 'nsis-x64'
    if ($x.State -eq 'NotProven') { Ok 'a changed entry (binding) un-proves' } else { Bad 'entry change ignored' }
    [IO.File]::WriteAllText($cfgFile, $orig, $utf8)

    $p2 = New-ProofProject 'two' @((Entry 'nsis-x64'), (Entry 'inno-x86' 'Enforce' @{ View = 'Wow6432'; UninstallerType = 'inno'; UninstallerFileName = 'unins000.exe' }))
    Set-ResultFile $p2 @((Rec $p2 @('nsis-x64')))
    if ((State $p2 'nsis-x64').State -eq 'Proven' -and (State $p2 'inno-x86').State -eq 'NotProven') { Ok 'a run proves only the entries it checked (EntryIds)' } else { Bad 'EntryIds' }
    Set-ResultFile $p2 @((Rec $p2 @('nsis-x64')), (Rec $p2 @('inno-x86')))
    if ((State $p2 'nsis-x64').State -eq 'Proven' -and (State $p2 'inno-x86').State -eq 'Proven') { Ok 'two entries proven by two runs (one proof group each)' } else { Bad 'two runs' }

    # == [3] capture lineage ============================================================================
    Write-Host '[3] capture lineage: the floor capture record decides the baseline' -ForegroundColor Cyan
    $p3 = New-ProofProject 'capture' @()
    $rec = [ordered]@{ SchemaVersion = '1.0'; CaptureKey = 'nullsoft-8.7.9'
        Package = [ordered]@{ WingetId = 'Vendor.App'; Version = '8.9.9'; Architecture = 'x64'; InstallerType = 'wix'; Family = 'msi' }
        Sibling = [ordered]@{ InstallerType = 'nullsoft'; EffectiveType = 'nullsoft'; Version = '8.7.9'; Role = 'Floor'; ReleaseDate = ''; Scope = ''; Locale = ''; Architecture = 'x64'; InstallerFile = 'setup.exe'; InstallerSha256 = ('AB' * 32); SilentArgs = '/S'; SilentArgsSource = 'catalog'; Manifest = [ordered]@{} }
        Run = [ordered]@{ Backend = 'HyperV'; Mode = 'Unattended'; GuestScriptSha256 = ('EF' * 32) }; Install = [ordered]@{}; Observation = [ordered]@{ NoiseControl = 'Verified' }; Probe = [ordered]@{ Result = 'Clean'; ProbedView = 'Native' }; HostChecks = [ordered]@{} }
    $json = ConvertTo-Json -InputObject $rec -Depth 12 -Compress -EscapeHandling EscapeNonAscii
    $bytes = $utf8.GetBytes($json)
    $cid = (-join ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
    $null = New-Item -ItemType Directory -Path (Join-Path $p3 'Documentation\SiblingCapture') -Force
    [IO.File]::WriteAllBytes((Join-Path $p3 "Documentation\SiblingCapture\$cid.json"), $bytes)
    $cfg3 = Get-Content (Join-Path $p3 'SupportFiles\AppConfig.json') -Raw | ConvertFrom-Json
    $cfg3.PriorInstalls.Entries = @([pscustomobject](Entry 'nsis-x64' 'Enforce' @{ Source = 'SiblingCapture'; CaptureId = $cid }))
    [IO.File]::WriteAllText((Join-Path $p3 'SupportFiles\AppConfig.json'), ($cfg3 | ConvertTo-Json -Depth 8), $utf8)
    Set-ResultFile $p3 @((Rec $p3 @('nsis-x64') @{ BaselineSha = ('AB' * 32) }))
    $x = State $p3 'nsis-x64'
    if ($x.State -eq 'Proven' -and $x.Lineage -eq 'Capture') { Ok 'capture lineage: the floor installer hash and SiblingIdentityStable / PriorResidue PASS -> Proven' } else { Bad "capture: $($x | ConvertTo-Json -Compress)" }
    Set-ResultFile $p3 @((Rec $p3 @('nsis-x64') @{ BaselineSha = ('CD' * 32) }))
    if ((State $p3 'nsis-x64').State -eq 'NotProven') { Ok 'another baseline installer than the floor capture -> not a proof (SV5)' } else { Bad 'baseline hash ignored' }
    Set-ResultFile $p3 @((Rec $p3 @('nsis-x64') @{ BaselineSha = ('AB' * 32); Omit = @('PriorResidue-PostUpdate.nsis-x64') }))
    if ((State $p3 'nsis-x64').State -eq 'NotProven') { Ok 'capture lineage without PriorResidue -> not a proof' } else { Bad 'PriorResidue not required' }
    Remove-Item (Join-Path $p3 "Documentation\SiblingCapture\$cid.json")
    Set-ResultFile $p3 @((Rec $p3 @('nsis-x64') @{ BaselineSha = ('AB' * 32) }))
    $x = State $p3 'nsis-x64'
    if ($x.State -eq 'NotProven' -and $x.Reason -match 'floor capture record') { Ok 'the floor capture record is missing -> NotProven (re-capture)' } else { Bad "missing record: $($x.Reason)" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PriorProof tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PriorProof test(s) FAILED." -ForegroundColor Red; exit 1 }
