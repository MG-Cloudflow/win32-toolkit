<#
    Installer-identity PR 3b, commit A1 (spec 2.14.8, 2.15.1-2, 2.15.5; SV1, SV3, SV5, SV8-SV12, SV14, S26, S30, D25, D61,
    L36): ConvertTo-Win32ToolkitSiblingProposal, Test-Win32ToolkitSiblingSigner, Get-/Update-Win32ToolkitPriorInstallWindow.
    The capture records are fixtures written in the frozen shape (Tests\Fixtures\sibling-proposal\SiblingFixture.ps1),
    hash-named exactly as the capture writes them.

      [1] the goal: the nullsoft Notepad++ sibling of a WiX Notepad++ package -> one High, Enforce-eligible, flag-free
          proposal 'nsis-x64' (window floor..newest, padded); it survives the own-identity gate although the WiX
          package's tattoo leaf is 'Notepad++'; the sibling writing the package's OWN key -> no proposal, SameKey.
      [2] kind mapping: NSIS magic present / absent, Inno markers, a manifest 'exe' with the NSIS magic
          (ManifestTypeGeneric), a contradiction (TypeMismatch).
      [3] stability: drift -> one proposal per identity, the older Frozen, a gap; one capture -> Unattributed;
          interleaved identities -> Unstable.
      [4] version scheme: Python / .NET-shaped rows -> VersionScheme; a proven monotone mapping -> allowed; a constant
          DisplayVersion -> ConstantVersion.
      [5] the name: 'Wireshark 4.6.9 x64' -> 'Wireshark {v} x64'; locale, another version form, an empty name.
      [6] removal data: a VLC-shaped install (...\VideoLAN\VLC); no new root, a shell-folder root, no main program.
      [7] signer matrix (Test-Win32ToolkitSiblingSigner) and the SignerMismatch flag (not an eligibility reason).
      [8] the ACL allow-list on recorded rules, identical to the device text B's verdict on the same rules.
      [9] EnforceEligible for every S30 class; a class E winget id -> eligible with the ClassE flag; Medium only when
          named; per-user and tampered records.
     [10] the window rule (Get-Win32ToolkitPriorInstallWindow).
     [11] the raise (Update-Win32ToolkitPriorInstallWindow): a newer same-identity record raises VersionMax only (the
          Approval still matches, the binding changes); a changed identity -> a new proposal and the old rule Frozen;
          nothing else written.

    Run:  pwsh -File Tests\SiblingProposal.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test helpers')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Get-Acl is shadowed: the ACL checks read recorded rules, never a real folder')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
. (Join-Path $repo 'Tests\Fixtures\sibling-proposal\SiblingFixture.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32sp_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$sig = [pscustomobject]@{ Status = 'Valid'; Subject = $script:TestSiblingSigner }
$n = 0
function New-P([hashtable]$P = @{}) { $script:n++; New-TestSiblingProject -Path (Join-Path $root "p$script:n") @P }
function Add-Rec([string]$P, [hashtable]$A = @{}) { $rec = New-TestSiblingRecord @A; Write-TestSiblingRecord -ProjectPath $P -Record $rec }
function Get-Props([string]$P, [string[]]$Named = @(), $Signer = $sig) { ConvertTo-Win32ToolkitSiblingProposal -ProjectPath $P -PackageSigner $Signer -ProposalId $Named }
function Two([hashtable]$A = @{}, [hashtable]$PArgs = @{}) {
    $p = New-P $PArgs
    $a1 = $A.Clone(); $a2 = $A.Clone()
    foreach ($x in $a1, $a2) { $x.Remove('Version2'); $x.Remove('Observed2') }
    $a1['Version'] = $(if ($A['Version']) { $A['Version'] } else { '8.7.9' }); $a1['Role'] = 'Floor'
    $a2['Version'] = $(if ($A['Version2']) { $A['Version2'] } else { '8.9.8' }); $a2['Role'] = 'Newest'
    if ($A.ContainsKey('Observed2')) { $a2['Observed'] = $A['Observed2'] }
    $null = Add-Rec $p $a1; $null = Add-Rec $p $a2
    $p
}

try {
    # == [1] the goal ======================================================================================
    Write-Host '[1] the goal: the nullsoft Notepad++ sibling of a WiX package' -ForegroundColor Cyan
    $p = New-P @{ InstallerType = 'msi' }
    $floor = Add-Rec $p @{ Version = '8.7.9'; Role = 'Floor' }
    $newest = Add-Rec $p @{ Version = '8.9.8'; Role = 'Newest' }
    $r = Get-Props $p
    $x = @($r.Proposals)
    $px = $x[0]
    if ($x.Count -eq 1 -and $px.ProposalId -ceq 'nsis-x64' -and $px.Confidence -eq 'High' -and $px.EnforceEligible -and $px.FlagFree -and $px.Track -eq 'Current' -and $px.Stability -eq 'Stable') { Ok "one High, Enforce-eligible, flag-free proposal 'nsis-x64' (Current, Stable)" } else { Bad "goal: $($x | ConvertTo-Json -Depth 3 -Compress)" }
    if ($px.VersionMin -ceq '8.7.9.0' -and $px.VersionMax -ceq '8.9.8.0' -and $px.FloorCaptureId -ceq $floor -and (@($px.CaptureIds) -join ',') -ceq "$floor,$newest") { Ok 'window: VersionMin = the floor capture (8.7.9.0), VersionMax = the newest same-identity capture (8.9.8.0), padded; CaptureIds floor first' } else { Bad "window: $($px.VersionMin)..$($px.VersionMax) $($px.CaptureIds -join ',')" }
    if ($px.Key -ceq 'Notepad++' -and $px.UninstallerType -eq 'nullsoft' -and $px.UninstallerFileName -eq 'uninstall.exe' -and $px.InstallDir -eq '%ProgramFiles%\Notepad++' -and $px.MainExe -eq 'notepad++.exe' -and (@($px.ProcessNames) -join ',') -eq 'notepad++' -and $px.UninstallerSigner -ceq $script:TestSiblingSigner -and $px.DisplayName -eq 'Notepad++ (64-bit x64)') {
        Ok 'the tuple: key, kind nullsoft, uninstall.exe, %ProgramFiles%\Notepad++, notepad++.exe / notepad++, the host-verified uninstaller signer'
    } else { Bad "tuple: $($px | ConvertTo-Json -Compress)" }
    if ($px.ProposalHash -ceq (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $px)) { Ok 'ProposalHash is the Tuple hash of the proposal (spec 2.3)' } else { Bad 'proposal hash' }
    $cfg = Get-Content -LiteralPath (Join-Path $p 'SupportFiles\AppConfig.json') -Raw | ConvertFrom-Json
    if ($cfg.App.Name -eq 'Notepad++' -and $cfg.Installer.Type -eq 'msi') { Ok 'the nullsoft key Notepad++ survives the own-identity gate of a WiX package whose tattoo leaf is Notepad++ (S26: the tattoo is never an own key)' } else { Bad 'tattoo fixture' }
    $q = New-P @{ OwnArpKeys = @('Notepad++') }
    $null = Add-Rec $q @{ Version = '8.7.9'; Role = 'Floor' }; $null = Add-Rec $q @{ Version = '8.9.8' }
    $r = Get-Props $q
    if (@($r.Proposals).Count -eq 0 -and @($r.SameKey).Count -eq 2 -and @($r.SameKey)[0].Key -eq 'Notepad++') { Ok "the sibling writes the package's own key -> no proposal, SameKey (ID-SIBLING-SAME-KEY)" } else { Bad "samekey: $(@($r.Proposals).Count) / $(@($r.SameKey).Count)" }

    # == [2] kind mapping ===================================================================================
    Write-Host '[2] kind mapping (SV12)' -ForegroundColor Cyan
    $r = Get-Props (Two @{ NoNsis = $true })
    $px = @($r.Proposals)[0]
    if ($px.UninstallerType -eq '' -and $px.Flags -contains 'GenericExe' -and -not $px.EnforceEligible -and $px.ProposalId -eq 'exe-x64') { Ok 'nullsoft without the NSIS magic on the copied uninstaller -> a generic exe (GenericExe, Block only, exe-x64)' } else { Bad "no magic: $($px.UninstallerType) $($px.Flags -join ',')" }
    $r = Get-Props (Two @{ Type = 'inno'; Key = 'App_is1'; InnoMarkers = $true; ProductCodes = @('App_is1'); DisplayName = 'App'; Dir = 'App'; Main = 'app.exe'; Uninstaller = 'unins000.exe' })
    $px = @($r.Proposals)[0]
    if ($px.UninstallerType -eq 'inno' -and @($px.Flags).Count -eq 0 -and $px.EnforceEligible -and $px.ProposalId -eq 'inno-x64') { Ok 'Inno Setup: an _is1 key, the App Path value and unins*.dat -> inno, no flag (inno-x64)' } else { Bad "inno: $($px.UninstallerType) $($px.Flags -join ',')" }
    $r = Get-Props (Two @{ Type = 'exe' })
    $px = @($r.Proposals)[0]
    if ($px.UninstallerType -eq 'nullsoft' -and (@($px.Flags) -join ',') -eq 'ManifestTypeGeneric' -and $px.EnforceEligible -and $px.FlagFree) { Ok "a manifest 'exe' with the NSIS magic -> nullsoft + ManifestTypeGeneric (informational: still eligible and flag-free)" } else { Bad "exe: $($px.UninstallerType) $($px.Flags -join ',')" }
    $r = Get-Props (Two @{ Type = 'inno'; ForceNsis = $true })
    $px = @($r.Proposals)[0]
    if ($px.Flags -contains 'TypeMismatch' -and $px.UninstallerType -eq '' -and -not $px.EnforceEligible) { Ok 'winget says inno, the uninstaller carries the NSIS magic -> TypeMismatch (Block only)' } else { Bad "mismatch: $($px.Flags -join ',')" }

    # == [3] stability, drift, gap ===========================================================================
    Write-Host '[3] stability, drift, Frozen, gap' -ForegroundColor Cyan
    $p = New-P
    $null = Add-Rec $p @{ Version = '8.5.0'; Role = 'Floor'; Publisher = 'Don Ho' }
    $null = Add-Rec $p @{ Version = '8.6.0'; Role = 'Extra'; Publisher = 'Don Ho' }
    $null = Add-Rec $p @{ Version = '8.8.0'; Role = 'Extra' }
    $null = Add-Rec $p @{ Version = '8.9.8'; Role = 'Newest' }
    $r = Get-Props $p
    $cur = @($r.Proposals | Where-Object ProposalId -ceq 'nsis-x64')[0]; $old = @($r.Proposals | Where-Object ProposalId -ceq 'nsis-x64-2')[0]
    if ($cur.Publisher -eq 'Notepad++ Team' -and $cur.Track -eq 'Current' -and $cur.VersionMin -eq '8.8.0.0' -and $old.Publisher -eq 'Don Ho' -and $old.Track -eq 'Frozen' -and $old.VersionMax -eq '8.6.0.0') { Ok 'drift: one proposal per identity (nsis-x64 Current 8.8.0.0.., nsis-x64-2 Frozen ..8.6.0.0)' } else { Bad "drift: $(@($r.Proposals) | ForEach-Object { "$($_.ProposalId) $($_.Publisher) $($_.Track)" })" }
    if (@($r.Gaps).Count -eq 1 -and $r.Gaps[0].From -eq '8.6.0' -and $r.Gaps[0].To -eq '8.8.0') { Ok 'the versions between the identities are a gap (8.6.0 -> 8.8.0; ID-SIBLING-DRIFT-GAP)' } else { Bad "gaps: $($r.Gaps | ConvertTo-Json -Compress)" }
    $p = New-P
    $null = Add-Rec $p @{ Version = '8.9.8' }
    $r = Get-Props $p
    if (@($r.Proposals).Count -eq 0 -and @($r.Unattributed | Where-Object { $_.Reason -match 'one capture' }).Count -eq 1) { Ok 'an identity seen in one capture only -> Unattributed, no proposal' } else { Bad "one: $(@($r.Proposals).Count)" }
    $p = New-P
    $null = Add-Rec $p @{ Version = '8.5.0'; Role = 'Floor'; Publisher = 'Don Ho' }
    $null = Add-Rec $p @{ Version = '8.6.0'; Role = 'Extra' }
    $null = Add-Rec $p @{ Version = '8.7.0'; Role = 'Extra'; Publisher = 'Don Ho' }
    $null = Add-Rec $p @{ Version = '8.8.0'; Role = 'Newest' }
    $r = Get-Props $p
    if (@($r.Proposals).Count -eq 2 -and @($r.Proposals | Where-Object { $_.Stability -eq 'Unstable' -and $_.Flags -contains 'Unstable' -and -not $_.EnforceEligible }).Count -eq 2) { Ok 'interleaved identities -> both Unstable, not Enforce-eligible' } else { Bad "interleaved: $(@($r.Proposals) | ForEach-Object { "$($_.ProposalId) $($_.Stability)" })" }

    # == [4] version scheme ===================================================================================
    Write-Host '[4] version scheme (SV3, SV14)' -ForegroundColor Cyan
    foreach ($c in @(
            @{ L = 'Python-shaped (3.12.4 / 3.12.4150.0, one winget version)'; A = @{ Version = '3.12.4'; Version2 = '3.12.4'; Observed = '3.12.4150.0'; Observed2 = '3.12.4150.0' }; Want = 'VersionScheme' }
            @{ L = '.NET-shaped (8.0.11 / 8.0.11.34221)'; A = @{ Version = '8.0.11'; Version2 = '8.0.11'; Observed = '8.0.11.34221'; Observed2 = '8.0.11.34221' }; Want = 'VersionScheme' }
            @{ L = 'not monotone (2.0 -> 5.1, 2.1 -> 5.0)'; A = @{ Version = '2.0'; Version2 = '2.1'; Observed = '5.1'; Observed2 = '5.0' }; Want = 'VersionScheme' }
            @{ L = 'constant (1.0 and 1.1 both 1.0.0)'; A = @{ Version = '1.0'; Version2 = '1.1'; Observed = '1.0.0'; Observed2 = '1.0.0' }; Want = 'ConstantVersion' }
            @{ L = 'a proven monotone mapping (3.12.4 -> 3.12.4150.0, 3.12.5 -> 3.12.5150.0)'; A = @{ Version = '3.12.4'; Version2 = '3.12.5'; Observed = '3.12.4150.0'; Observed2 = '3.12.5150.0' }; Want = '' }
        )) {
        $r = Get-Props (Two $c.A)
        $px = @($r.Proposals)[0]
        $has = @($px.Flags | Where-Object { $_ -in 'VersionScheme', 'ConstantVersion' })
        if (($c.Want -and $has -contains $c.Want -and -not $px.EnforceEligible) -or (-not $c.Want -and $has.Count -eq 0 -and $px.EnforceEligible)) { Ok "$($c.L) -> $(if ($c.Want) { "$($c.Want) (Block only)" } else { 'allowed' })" } else { Bad "$($c.L): $($px.Flags -join ',')" }
    }

    # == [5] the name ===========================================================================================
    Write-Host '[5] the name (SV8, SV24)' -ForegroundColor Cyan
    $p = New-P
    $null = Add-Rec $p @{ Key = 'Wireshark'; DisplayName = 'Wireshark 4.6.8 x64'; Version = '4.6.8'; Role = 'Floor'; Dir = 'Wireshark'; Main = 'Wireshark.exe'; ProductCodes = @('Wireshark') }
    $null = Add-Rec $p @{ Key = 'Wireshark'; DisplayName = 'Wireshark 4.6.9 x64'; Version = '4.6.9'; Dir = 'Wireshark'; Main = 'Wireshark.exe'; ProductCodes = @('Wireshark') }
    $r = Get-Props $p
    $px = @($r.Proposals)[0]
    if (@($r.Proposals).Count -eq 1 -and $px.DisplayNameTemplate -ceq 'Wireshark {v} x64' -and $px.DisplayName -eq '' -and $px.EnforceEligible) { Ok "'Wireshark 4.6.9 x64' -> DisplayNameTemplate 'Wireshark {v} x64' (one identity across versions)" } else { Bad "template: $($px.DisplayNameTemplate) / $(@($r.Proposals).Count)" }
    foreach ($c in @(
            @{ L = 'the installer language in the name'; A = @{ DisplayName = 'Mozilla Firefox (x64 en-US)' }; Want = 'LocaleInName' }
            # Live row COPRODUCT: the Mozilla locale packages set no InstallerLocale; their names hold a bare code.
            @{ L = 'a bare language code in the name (no InstallerLocale)'; A = @{ DisplayName = 'Mozilla Firefox (x64 nl)' }; Want = 'LocaleInName' }
            @{ L = 'a bare language code alone in parentheses'; A = @{ DisplayName = 'Mozilla Thunderbird (de)' }; Want = 'LocaleInName' }
            @{ L = 'another version form in the name'; A = @{ DisplayName = 'Notepad++ 2.0 edition' }; Want = 'NameEmbedsVersion' }
            @{ L = 'an empty name'; A = @{ DisplayName = '' }; Want = 'EmptyName' }
        )) {
        $px = @((Get-Props (Two $c.A)).Proposals)[0]
        if ($px.Flags -contains $c.Want -and -not $px.EnforceEligible) { Ok "$($c.L) -> $($c.Want) (Block only)" } else { Bad "$($c.L): $($px.Flags -join ',')" }
    }

    # == [6] removal data ========================================================================================
    Write-Host '[6] removal data (SV8-SV10)' -ForegroundColor Cyan
    $vlc = @{ Key = 'VLC media player'; DisplayName = 'VLC media player'; Publisher = 'VideoLAN'; Dir = 'VideoLAN\VLC'; Main = 'vlc.exe'; ProductCodes = @('VLC media player'); Version = '3.0.20'; Version2 = '3.0.21'; PackageName = 'VLC media player'; ManifestPublisher = 'VideoLAN'; DefaultInstallLocation = '' }
    $px = @((Get-Props (Two $vlc)).Proposals)[0]
    if ($px.InstallDir -eq '%ProgramFiles%\VideoLAN\VLC' -and $px.MainExe -eq 'vlc.exe' -and (@($px.ProcessNames) -join ',') -eq 'vlc' -and $px.EnforceEligible) { Ok 'VLC-shaped: root C:\Program Files\VideoLAN, InstallDir %ProgramFiles%\VideoLAN\VLC, MainExe vlc.exe, process vlc' } else { Bad "vlc: $($px.InstallDir) $($px.MainExe) $($px.Flags -join ',')" }
    foreach ($c in @(
            @{ L = 'no folder the install created holds the uninstaller'; A = @{ Root = '' }; Want = 'UninstallerOutsideRoot' }
            @{ L = 'the install root is a shell folder (C:\Program Files)'; A = @{ Root = 'C:\Program Files' }; Want = 'UninstallerOutsideRoot' }
            @{ L = 'the uninstaller path is not canonical'; A = @{ Canonical = $false }; Want = 'UninstallerOutsideRoot' }
            @{ L = 'no main program in its folder'; A = @{ Main = '' }; Want = 'NoMainExe' }
            @{ L = 'a folder outside Program Files'; A = @{ InstallDirToken = '' }; Want = 'InstallDirNotProgramFiles' }
        )) {
        $px = @((Get-Props (Two $c.A)).Proposals)[0]
        if ($px.Flags -contains $c.Want -and -not $px.EnforceEligible) { Ok "$($c.L) -> $($c.Want) (not Enforce-eligible)" } else { Bad "$($c.L): $($px.Flags -join ',')" }
    }
    # No false language: an architecture and a word in parentheses stay allowed.
    $px = @((Get-Props (Two @{ DisplayName = 'Notepad++ (64-bit x64)' })).Proposals)[0]
    $px2 = @((Get-Props (Two @{ DisplayName = 'Contoso Tool (Machine-wide installer)' })).Proposals)[0]
    if ($px.Flags -notcontains 'LocaleInName' -and $px2.Flags -notcontains 'LocaleInName') { Ok "'(64-bit x64)' and '(Machine-wide installer)' -> no LocaleInName" } else { Bad "locale false positive: $($px.Flags -join ',') / $($px2.Flags -join ',')" }
    $px = @((Get-Props (Two @{ Quiet = '/S /allusers' })).Proposals)[0]
    if ($px.Flags -contains 'ArgsDiffer' -and $px.EnforceEligible -and $px.FlagFree) { Ok "a captured quiet uninstall with '/allusers' -> ArgsDiffer (informational; the constant switches are used)" } else { Bad "argsdiffer: $($px.Flags -join ',')" }

    # == [7] signer ===============================================================================================
    Write-Host '[7] signer cross-check' -ForegroundColor Cyan
    $v = @{ Status = 'Valid'; Subject = 'CN=Vendor' }
    $matrix = @(
        @{ L = 'all Valid, one signer'; A = @{ SiblingInstaller = $v; SiblingMain = $v; PackageInstaller = $v }; Want = $false }
        @{ L = 'the main program not copied out'; A = @{ SiblingInstaller = $v; SiblingMain = @{ Status = ''; Subject = '' }; PackageInstaller = $v }; Want = $false }
        @{ L = 'the sibling installer unsigned'; A = @{ SiblingInstaller = @{ Status = 'NotSigned'; Subject = '' }; SiblingMain = $v; PackageInstaller = $v }; Want = $true }
        @{ L = 'the package installer unsigned'; A = @{ SiblingInstaller = $v; SiblingMain = $v; PackageInstaller = @{ Status = 'NotSigned'; Subject = '' } }; Want = $true }
        @{ L = 'two signers'; A = @{ SiblingInstaller = @{ Status = 'Valid'; Subject = 'CN=Other' }; SiblingMain = $v; PackageInstaller = $v }; Want = $true }
        @{ L = 'the main program with a broken signature'; A = @{ SiblingInstaller = $v; SiblingMain = @{ Status = 'HashMismatch'; Subject = 'CN=Vendor' }; PackageInstaller = $v }; Want = $true }
        @{ L = "the main program signed by another than the package's main program"; A = @{ SiblingInstaller = $v; SiblingMain = $v; PackageInstaller = $v; PackageMain = @{ Status = 'Valid'; Subject = 'CN=Main' } }; Want = $true }
    )
    foreach ($m in $matrix) {
        $a = $m.A
        $res = Test-Win32ToolkitSiblingSigner @a
        if ($res.Mismatch -eq $m.Want -and ($m.Want -eq (@($res.Reasons).Count -gt 0))) { Ok "$($m.L) -> $(if ($m.Want) { 'SignerMismatch' } else { 'match' })" } else { Bad "$($m.L): $($res.Mismatch) $($res.Reasons -join ';')" }
    }
    $px = @((Get-Props (Two) -Signer ([pscustomobject]@{ Status = 'Valid'; Subject = 'CN=Somebody else' })).Proposals)[0]
    if ($px.Flags -contains 'SignerMismatch' -and $px.EnforceEligible -and -not $px.FlagFree) { Ok 'a package installer of another signer -> SignerMismatch: still Enforce-eligible (Export needs SIGNER-MISMATCH), never in a bulk Block' } else { Bad "signer flag: $($px.Flags -join ',') $($px.EnforceEligible)" }

    # == [8] ACL allow-list = text B ===============================================================================
    Write-Host '[8] the ACL allow-list on recorded rules = the device text B' -ForegroundColor Cyan
    $folder = 'C:\Program Files\Notepad++'; $exe = "$folder\uninstall.exe"
    $du = 'S-1-5-21-1111111111-2222222222-3333333333-513'
    $cases = @(
        @{ L = 'SYSTEM, Administrators, TrustedInstaller, Users read, CREATOR OWNER inherit-only'; Owner = 'S-1-5-32-544'; Extra = @(); Want = $false }
        @{ L = 'owner SYSTEM'; Owner = 'S-1-5-18'; Extra = @(); Want = $false }
        @{ L = 'owner TrustedInstaller'; Owner = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'; Extra = @(); Want = $false }
        @{ L = 'Domain Users Modify'; Owner = 'S-1-5-32-544'; Extra = @([ordered]@{ Sid = $du; Rights = 197055; Inheritance = 3; Propagation = 0; Type = 'Allow' }); Want = $true }
        @{ L = 'a per-user owner'; Owner = 'S-1-5-21-1111111111-2222222222-3333333333-1001'; Extra = @(); Want = $true }
        @{ L = 'Users write data'; Owner = 'S-1-5-32-544'; Extra = @([ordered]@{ Sid = 'S-1-5-32-545'; Rights = 2; Inheritance = 0; Propagation = 0; Type = 'Allow' }); Want = $true }
        @{ L = 'Everyone write, but a Deny rule'; Owner = 'S-1-5-32-544'; Extra = @([ordered]@{ Sid = 'S-1-1-0'; Rights = 278; Inheritance = 0; Propagation = 0; Type = 'Deny' }); Want = $false }
        @{ L = 'Domain Users Modify, inherit-only on the folder'; Owner = 'S-1-5-32-544'; Extra = @([ordered]@{ Sid = $du; Rights = 197055; Inheritance = 3; Propagation = 2; Type = 'Allow' }); Want = $false }
    )
    # Text B, the device's own scriptblock, run against the same rules through a Get-Acl shadow.
    $tmpDir = Join-Path $root 'acl'; $null = New-Item -ItemType Directory -Path $tmpDir -Force
    $w32tPrAclProblem = $null
    . ([scriptblock]::Create((Get-Win32ToolkitDeployScriptBlock -Name PriorPredicate) + "`n" + (Get-Win32ToolkitDeployScriptBlock -Name PriorEvaluate)))
    $script:fakeAcl = $null
    function Get-Acl {
        param([string]$LiteralPath)
        $null = $LiteralPath
        $o = [pscustomobject]@{ Owner = $script:fakeAcl.Owner; Rules = $script:fakeAcl.Rules }
        $o | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($t) $null = $t; [pscustomobject]@{ Value = $this.Owner } }
        $o | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value {
            param($a, $b, $t) $null = $a, $b, $t
            @($this.Rules | ForEach-Object { [pscustomobject]@{ AccessControlType = [Security.AccessControl.AccessControlType]$_.Type; PropagationFlags = [Security.AccessControl.PropagationFlags]$_.Propagation
                        IdentityReference = [pscustomobject]@{ Value = $_.Sid }; FileSystemRights = [Enum]::ToObject([Security.AccessControl.FileSystemRights], [int]$_.Rights) } })
        }
        $o
    }
    foreach ($c in $cases) {
        $acl = New-TestSiblingAcl -Folder $folder -Exe $exe -Owner $c.Owner -ExtraFolderRules $c.Extra
        $px = @((Get-Props (Two @{ Acl = $acl })).Proposals)[0]
        $host_ = $px.Flags -contains 'WeakAcl'
        $script:fakeAcl = [pscustomobject]@{ Owner = $c.Owner; Rules = @($acl[0].Rules) }
        $textB = [bool](& $w32tPrAclProblem $tmpDir $true)
        if ($host_ -eq $c.Want -and $textB -eq $c.Want -and ($host_ -eq (-not $px.EnforceEligible) -or -not $c.Want)) { Ok "$($c.L) -> $(if ($c.Want) { 'WeakAcl (Block only)' } else { 'none' }); text B agrees" } else { Bad "$($c.L): host $host_ textB $textB want $($c.Want)" }
    }
    Remove-Item Function:\Get-Acl

    # == [9] EnforceEligible for every S30 class ===================================================================
    Write-Host '[9] EnforceEligible (S30)' -ForegroundColor Cyan
    foreach ($c in @(
            @{ L = 'the probe did not run (NotProbed)'; A = @{ ProbeResult = 'NotProbed' }; Want = 'ProbeNotClean' }
            @{ L = 'the probe left the install (Survived)'; A = @{ ProbeResult = 'Survived' }; Want = 'ProbeNotClean' }
            @{ L = 'noise control not verified'; A = @{ Noise = 'Unverified' }; Want = 'NoiseUnverified' }
            @{ L = 'a Windows Sandbox capture'; A = @{ Backend = 'Sandbox' }; Want = 'Sandbox' }
            @{ L = 'an assisted capture (D62)'; A = @{ Mode = 'Assisted' }; Want = 'Assisted' }
            @{ L = 'an unsafe captured text'; A = @{ Unsafe = $true }; Want = 'UnsafeText' }
            @{ L = 'a key outside the conservative set'; A = @{ Key = 'Notepad++#1'; ProductCodes = @('Notepad++#1') }; Want = 'KeyCharset' }
        )) {
        $px = @((Get-Props (Two $c.A)).Proposals)[0]
        if ($px.Flags -contains $c.Want -and -not $px.EnforceEligible -and @($px.IneligibleReasons | Where-Object { $_ -like "$($c.Want):*" }).Count -eq 1) { Ok "$($c.L) -> $($c.Want), not eligible (reason listed)" } else { Bad "$($c.L): $($px.Flags -join ',') $($px.EnforceEligible)" }
    }
    $px = @((Get-Props (Two @{} @{ WingetId = 'Python.Python.3.12' })).Proposals)[0]
    if ($px.Flags -contains 'ClassE' -and $px.EnforceEligible -and -not $px.FlagFree) { Ok 'a class E winget id (Python.Python.3.12) -> eligible, flag ClassE (D25: a warning, never a reason)' } else { Bad "classE: $($px.Flags -join ',') $($px.EnforceEligible)" }
    # The flag text is operator text (the List and the review card show it): no internal decision id.
    if ([string]$px.FlagText['ClassE'] -ceq 'a versioned family (its versions install side by side)') { Ok 'the ClassE flag text names no internal decision id' } else { Bad "classE text: $($px.FlagText['ClassE'])" }
    $medium = @{ Key = 'Contoso Tool'; DisplayName = 'Contoso Tool'; Publisher = 'Contoso'; Dir = 'Contoso Tool'; Main = 'tool.exe'; ProductCodes = @(); PackageName = 'Contoso Tool'; ManifestPublisher = 'Contoso'; DefaultInstallLocation = '%ProgramFiles%\Contoso Tool' }
    $pm = Two $medium
    $px = @((Get-Props $pm).Proposals)[0]
    $px2 = @((Get-Props $pm -Named 'nsis-x64').Proposals)[0]
    if ($px.Confidence -eq 'Medium' -and -not $px.EnforceEligible -and @($px.IneligibleReasons | Where-Object { $_ -like 'MediumNotNamed*' }).Count -eq 1 -and $px2.EnforceEligible) { Ok 'Medium (PackageName, folder and a host-verified signer) -> eligible only when named with -ProposalId' } else { Bad "medium: $($px.Confidence) $($px.EnforceEligible) / $($px2.EnforceEligible)" }
    $pu = New-P
    foreach ($v in '8.7.9', '8.9.8') { $null = Add-Rec $pu @{ Version = $v; NoPrimaryCandidate = $true; Hkcu = @([ordered]@{ Key = 'Notepad++'; DisplayName = 'Notepad++' }); ProvisionalPrimary = '' } }
    $r = Get-Props $pu
    if (@($r.Proposals).Count -eq 0 -and @($r.PerUser).Count -eq 2) { Ok 'an HKCU-only registration -> PerUser, no proposal (ID-SIBLING-PERUSER)' } else { Bad "peruser: $(@($r.PerUser).Count)" }
    $pu = Two @{ InstallLocation = 'C:\Users\pat\AppData\Local\Notepad++' }
    $r = Get-Props $pu
    if (@($r.Proposals).Count -eq 0 -and @($r.PerUser).Count -eq 2) { Ok 'an install under a user profile -> PerUser, no proposal' } else { Bad "profile: $(@($r.Proposals).Count) $(@($r.PerUser).Count)" }
    $pt = Two
    $f1 = @(Get-ChildItem -LiteralPath (Join-Path $pt 'Documentation\SiblingCapture') -File)[0]
    $bytes = [IO.File]::ReadAllBytes($f1.FullName); $bytes[20] = [byte][char]'x'; [IO.File]::WriteAllBytes($f1.FullName, $bytes)
    $r = Get-Props $pt
    if (@($r.Proposals).Count -eq 0 -and @($r.Captures).Count -eq 1) { Ok 'a record changed after it was written is ignored (hash prefix) -> one capture left, no proposal' } else { Bad "tamper: $(@($r.Proposals).Count) $(@($r.Captures).Count)" }

    # == [10] the window rule =======================================================================================
    Write-Host '[10] the window rule (L36)' -ForegroundColor Cyan
    $p = New-P
    $f0 = Add-Rec $p @{ Version = '8.7.9'; Role = 'Floor' }
    $f1 = Add-Rec $p @{ Version = '8.8.9'; Role = 'Extra' }
    $null = Add-Rec $p @{ Version = '8.9.8' }
    $r = Get-Props $p
    $t = @($r.Proposals)[0].ProposalHash
    $w0 = Get-Win32ToolkitPriorInstallWindow -Captures $r.Captures -Tuple $t
    $w1 = Get-Win32ToolkitPriorInstallWindow -Captures $r.Captures -Tuple $t -FloorCaptureId $f1
    $wx = Get-Win32ToolkitPriorInstallWindow -Captures $r.Captures -Tuple $t -FloorCaptureId 'aaaaaaaaaaaaaaaa'
    $wb = Get-Win32ToolkitPriorInstallWindow -Captures $r.Captures -Tuple $t -Below '8.9.0'
    if ($w0.VersionMin -eq '8.7.9.0' -and $w0.VersionMax -eq '8.9.8.0' -and $w0.FloorCaptureId -ceq $f0 -and $w1.VersionMin -eq '8.8.9.0' -and $w1.VersionMax -eq '8.9.8.0' -and -not $wx.Found -and $wb.VersionMax -eq '8.8.9.0') {
        Ok 'VersionMin = the CaptureId record (8.7.9.0, or 8.8.9.0 when named), VersionMax = the highest same identity (8.9.8.0); an unknown floor -> not found; -Below keeps lower versions only'
    } else { Bad "window: $($w0 | ConvertTo-Json -Compress) $($w1.VersionMin) $($wx.Found) $($wb.VersionMax)" }

    # == [11] the raise ==============================================================================================
    Write-Host '[11] the raise after a new capture (D61)' -ForegroundColor Cyan
    $p = New-P
    $fl = Add-Rec $p @{ Version = '8.7.9'; Role = 'Floor' }
    $null = Add-Rec $p @{ Version = '8.9.8' }
    $px = @((Get-Props $p).Proposals)[0]
    $entry = [ordered]@{ Id = 'nsis-x64'; Kind = 'ArpKey'; Mode = 'Enforce'; Key = $px.Key; View = $px.View; Publisher = $px.Publisher; DisplayName = $px.DisplayName; DisplayNameTemplate = ''
        VersionMin = $px.VersionMin; VersionMax = $px.VersionMax; UninstallerType = $px.UninstallerType; UninstallerFileName = $px.UninstallerFileName; UninstallerSigner = $px.UninstallerSigner
        InstallDir = $px.InstallDir; MainExe = $px.MainExe; ProcessNames = @($px.ProcessNames); Source = 'SiblingCapture'; CaptureId = $fl; Track = 'Current'; AddedOn = '2026-10-25' }
    $cfgFile = Join-Path $p 'SupportFiles\AppConfig.json'
    $cfg = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject]@{ SchemaVersion = '1.0'; Entries = @([pscustomobject]$entry) })
    [IO.File]::WriteAllText($cfgFile, ($cfg | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $null = Set-Win32ToolkitPriorInstallDecision -ProjectPath $p -Record @{ Kind = 'Approval'; Code = 'SIBLING-ENFORCE'; Target = 'nsis-x64'; ProposalId = 'nsis-x64'; ProposalHash = $px.ProposalHash; CaptureIds = @($px.CaptureIds); On = '2026-10-25'; Demoted = '' } -Confirm:$false
    $decFile = Join-Path $p 'Documentation\PriorInstallDecisions.json'
    $dec0 = Get-FileHash -LiteralPath $decFile
    $bind0 = Get-Win32ToolkitPriorInstallHash -Config (Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json)
    $s0 = Update-Win32ToolkitPriorInstallWindow -ProjectPath $p 6>$null
    if (@($s0.Raised).Count -eq 0 -and @($s0.Frozen).Count -eq 0 -and (Get-Win32ToolkitPriorInstallHash -Config (Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json)) -ceq $bind0) { Ok 'no newer capture -> nothing raised, nothing written' } else { Bad 'noop raise' }
    $null = Add-Rec $p @{ Version = '8.9.9' }
    $other0 = (Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json | Select-Object -ExcludeProperty PriorInstalls | ConvertTo-Json -Depth 10)
    $s1 = Update-Win32ToolkitPriorInstallWindow -ProjectPath $p 6>$null
    $cfg1 = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json
    $e1 = $cfg1.PriorInstalls.Entries[0]
    $approvalOk = @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $p | Where-Object { $_.Kind -eq 'Approval' -and $_.Latest -and $_.ProposalHash -ceq (Get-Win32ToolkitPriorInstallHash -Kind Tuple -Entry $e1) }).Count -eq 1
    if ($e1.VersionMax -eq '8.9.9.0' -and $e1.VersionMin -eq '8.7.9.0' -and $e1.Mode -eq 'Enforce' -and $e1.Track -eq 'Current' -and @($s1.Raised).Count -eq 1 -and $approvalOk -and (Get-Win32ToolkitPriorInstallHash -Config $cfg1) -cne $bind0) {
        Ok 'a newer same-identity record -> VersionMax raised to 8.9.9.0, VersionMin unchanged; the Approval still matches; the binding (so the proof) changes'
    } else { Bad "raise: $($e1 | ConvertTo-Json -Compress) approval $approvalOk" }
    $other1 = ($cfg1 | Select-Object -ExcludeProperty PriorInstalls | ConvertTo-Json -Depth 10)
    if ($other1 -ceq $other0 -and (Get-FileHash -LiteralPath $decFile).Hash -ceq $dec0.Hash -and @($cfg1.PriorInstalls.Entries).Count -eq 1) { Ok 'nothing else written (no other AppConfig section, no decision, no new rule)' } else { Bad 'raise wrote more' }
    $null = Add-Rec $p @{ Version = '9.1.0'; Publisher = 'Notepad++ Team Inc.' }
    $null = Add-Rec $p @{ Version = '9.1.0'; Role = 'Repeat'; Publisher = 'Notepad++ Team Inc.' }
    $s2 = Update-Win32ToolkitPriorInstallWindow -ProjectPath $p 6>$null
    $e2 = (Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json).PriorInstalls.Entries[0]
    $r = Get-Props $p
    $newP = @($r.Proposals | Where-Object { $_.Publisher -eq 'Notepad++ Team Inc.' })
    if ($e2.Track -eq 'Frozen' -and $e2.VersionMax -eq '8.9.9.0' -and $e2.Mode -eq 'Enforce' -and @($s2.Frozen) -contains 'nsis-x64' -and $newP.Count -eq 1 -and $newP[0].Track -eq 'Current' -and (Get-FileHash -LiteralPath $decFile).Hash -ceq $dec0.Hash) {
        Ok 'a changed identity -> a new proposal (Current) and the old rule Frozen (window and mode kept, no decision written)'
    } else { Bad "frozen: $($e2 | ConvertTo-Json -Compress) / $($newP.Count)" }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All SiblingProposal tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail SiblingProposal test(s) FAILED." -ForegroundColor Red; exit 1 }
