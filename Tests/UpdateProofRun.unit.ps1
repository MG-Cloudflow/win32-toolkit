<#
    Installer-identity PR 3 (spec 2.10, L12, L14, L15, L18, L27, L38): the Update test as the proof run of prior-install
    rules, and the guest-run tripwire of projects with prior-install state.

      [1] New-UpdateAssertionScript: the data file Sandbox\UpdateAssertionData.json is BOM-less and holds the proof and
          other entry ids, the new program files (Program Files only, shared folders excluded), the own MSI product code;
          the script holds none of those values, parses under Windows PowerShell 5.1, embeds the catalog PriorPredicate
          and PriorEvaluate texts verbatim, and writes 'RESULT COMPLETE' only after every prior ASSERT / DATA line.
      [2] the prior-install assertion text run in a Windows PowerShell 5.1 child (registry, ACL, signature, services, Appx
          and the Windows Installer COM object shadowed; $env:ProgramFiles is a temp folder): PriorPresent PASS / FAIL,
          OtherPriorAbsent before and after, SiblingIdentityStable, PriorAbsent, PriorResidue (a service left), the
          user-data line (DATA ... = LOST / KEPT, never an ASSERT), NewAppIntact (files + own MSI; MSIX provisioned or not;
          SKIP without files), PriorObservations.json.
      [3] Test-Win32ToolkitProject -Scenario Update (Hyper-V and Sandbox runs shadowed): the first proof group in Id order
          (a Wow6432 inno entry -> an inno baseline pinned, architecture x86); -ProofEntryId selects another group (nullsoft,
          the package's architecture); -ProofEntryId across two groups, or on a project without rules -> an error before
          anything is checked, staged or run; an explicit -BaselineInstallerType (or Packaged) picks the group of that
          technology whose registry view its old version writes (an x86 package: Wow6432); -SpecificVersion / -VersionsBack
          (also with -BaselineInstallerType Auto) keep the group's technology and architecture; an x86 package's Native group
          -> an x64 baseline; the record's Proof (the current binding, the baseline
          installer hash, EntryIds, RequirementChecked, ObservedVersions, DataLoss); a project whose blocks are another
          catalog revision -> no Proof, one warning; a project without rules -> no Proof (the old record shape).
      [4] the tripwire and the watched-Sandbox rule: a watched Sandbox Update or InstallUninstall run of a project with
          rules -> W32T.PriorInstallRefused, nothing launched; a Hyper-V guest run that changes a project file ->
          W32T.GuestTamper and no record; a Sandbox guest that forges Documentation\TestResults.json AFTER the waiter
          returned but before its sandbox closed -> W32T.GuestTamper, no record; a sandbox that cannot be confirmed closed
          -> W32T.GuestTamper with that reason; an untouched unattended Sandbox run -> recorded (Backend Sandbox).

    Nothing is installed or started; projects under %TEMP%. Run:  pwsh -File Tests\UpdateProofRun.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders and shadows')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'the 5.1 harness shadows registry and process cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'test shadows keep the real command names')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
. (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1')
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }

$root = Join-Path ([IO.Path]::GetTempPath()) ('w32upr_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
$PC = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
$ps51 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Entry([string]$Id, [string]$Mode = 'Enforce', [hashtable]$Over = @{}) {
    $e = [ordered]@{ Id = $Id; Kind = 'ArpKey'; Mode = $Mode; Key = 'App'; View = 'Native'; Publisher = 'Vendor Team'; DisplayName = 'App (64-bit)'; DisplayNameTemplate = ''
        VersionMin = '8.0'; VersionMax = '8.9.8.1'; UninstallerType = 'nullsoft'; UninstallerFileName = 'uninstall.exe'; UninstallerSigner = ''; InstallDir = '%ProgramFiles%\App'
        MainExe = 'app.exe'; ProcessNames = @('app'); Source = 'Operator'; Track = 'Current'; AddedOn = '2026-10-25' }
    foreach ($k in $Over.Keys) { $e[$k] = $Over[$k] }
    $e
}
# A project generated with this catalog: a deploy script that holds the remove-prior pair (revision as given).
function New-ProofProject([string]$Name, [object[]]$Entries, [int]$Revision = (Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision)) {
    $p = Join-Path $root $Name
    foreach ($d in 'Files', 'SupportFiles', 'Documentation', 'Sandbox\Logs') { $null = New-Item -ItemType Directory -Path (Join-Path $p $d) -Force }
    Copy-Item -LiteralPath (Join-Path $repo 'Tests\Fixtures\winget-manifests\Notepad++.Notepad++\8.9.8.1.installer.yaml') -Destination (Join-Path $p 'Files\Notepad++.Notepad++.installer.yaml')
    [IO.File]::WriteAllText((Join-Path $p 'Files\npp.8.9.8.1.Installer.x64.msi'), 'msi', $utf8)
    $blocks = "## win32-toolkit:Pre-Install:prior-check (begin) - x`r`n## remove-prior catalog revision $Revision (win32-toolkit)`r`n## win32-toolkit:Pre-Install:prior-check (end)`r`n## win32-toolkit:Pre-Install:remove-prior (begin) - x`r`n## win32-toolkit:Pre-Install:remove-prior (end)`r`n"
    [IO.File]::WriteAllText((Join-Path $p 'Invoke-AppDeployToolkit.ps1'), $blocks, [Text.UTF8Encoding]::new($true))
    $cfg = [ordered]@{ SchemaVersion = '1.0'; App = [ordered]@{ Vendor = 'Notepad++ Team'; Name = ''; DisplayName = 'Notepad++'; Version = '8.9.8.1'; Arch = 'x64'; ScriptAuthor = 'Contoso IT' }
        Installer = [ordered]@{ Type = 'msi'; FileName = 'npp.8.9.8.1.Installer.x64.msi' }
        OwnIdentity = [ordered]@{ SchemaVersion = '1.0'; ProductCode = $PC; UpgradeCode = ''; ArpKeys = @([ordered]@{ Key = $PC; View = 'Native' }); CapturedOn = '2026-10-25' } }
    if ($null -ne $Entries) { $cfg['PriorInstalls'] = [ordered]@{ SchemaVersion = '1.0'; Entries = @($Entries) } }
    [IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), $utf8)
    $capture = [ordered]@{ InstallationInfo = [ordered]@{ Timestamp = '20261025_101010'; PsadtExitCode = 0 }; NewFiles = @(
            [ordered]@{ Path = 'C:\Program Files\Notepad++\notepad++.exe'; Type = 'File' }, [ordered]@{ Path = 'C:\Program Files\Notepad++\SciLexer.dll'; Type = 'File' },
            [ordered]@{ Path = 'C:\Program Files\Notepad++\readme.txt'; Type = 'File' }, [ordered]@{ Path = 'C:\Program Files (x86)\Microsoft\EdgeUpdate\x.exe'; Type = 'File' },
            [ordered]@{ Path = 'C:\Users\x\AppData\app.exe'; Type = 'File' }, [ordered]@{ Path = 'C:\Program Files\Notepad++'; Type = 'Directory' }) }
    [IO.File]::WriteAllText((Join-Path $p 'Documentation\InstallationChanges_20261025_101010.json'), ($capture | ConvertTo-Json -Depth 6), $utf8)
    $p
}

try {
    # == [1] the generated assertion script and data file =============================================
    Write-Host '[1] New-UpdateAssertionScript: data file, verbatim catalog texts, RESULT COMPLETE last' -ForegroundColor Cyan
    $p = New-ProofProject 'gen' @((Entry 'nsis-x64'), (Entry 'inno-x86' 'Enforce' @{ View = 'Wow6432'; UninstallerType = 'inno'; Key = 'App_is1' }))
    $scriptPath = New-UpdateAssertionScript -ProjectPath $p -OldVersion '8.8.9' -ProofEntryIds @('nsis-x64') -OtherEntryIds @('inno-x86')
    $dataFile = Join-Path $p 'Sandbox\UpdateAssertionData.json'
    $bytes = [IO.File]::ReadAllBytes($dataFile)
    $data = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) -and $data.SchemaVersion -eq '1.0' -and @($data.ProofEntryIds) -join ',' -eq 'nsis-x64' -and @($data.OtherEntryIds) -join ',' -eq 'inno-x86' -and $data.SeedUserData -eq $true -and $data.OwnProductCode -ceq $PC) {
        Ok 'the data file is BOM-less: proof ids, other ids, SeedUserData, the own product code'
    } else { Bad "data file: $([Text.Encoding]::UTF8.GetString($bytes))" }
    if ((@($data.NewAppFiles) -join '|') -ceq 'C:\Program Files\Notepad++\SciLexer.dll|C:\Program Files\Notepad++\notepad++.exe') { Ok 'NewAppFiles: .exe/.dll under Program Files from the newest capture, shared folders and profiles excluded, sorted ordinal' } else { Bad "NewAppFiles: $(@($data.NewAppFiles) -join '|')" }
    $text = [IO.File]::ReadAllText($scriptPath)
    $lf = $text -replace "`r`n", "`n"
    if ($lf.Contains((Get-Win32ToolkitDeployScriptBlock -Name PriorPredicate)) -and $lf.Contains((Get-Win32ToolkitDeployScriptBlock -Name PriorEvaluate))) { Ok 'the catalog PriorPredicate and PriorEvaluate texts are embedded verbatim' } else { Bad 'catalog texts not verbatim' }
    if (-not $text.Contains('nsis-x64') -and -not $text.Contains('inno-x86') -and -not $text.Contains('SciLexer')) { Ok 'no value of the data file is in the script (ids, files)' } else { Bad 'a data value was spliced into the script' }
    # Live row OP-NEWER: after a refused update the post-update requirement failure does not claim broken presence signals only.
    # Live row OP-NEWER: the pre-update failure said 'the update itself may still work' for a prior above VersionMax, which
    # refuses with 69102: the text names that case (not applicable by design) and promises nothing.
    if ($text.Contains('= FAIL (rule did not detect the installed old version - the update app would be NOT APPLICABLE on devices like this one: an install of the app it has no signal for, or a prior install above its Enforce rule''s VersionMax, which is not applicable by design)') -and -not $text.Contains('may still work')) { Ok 'Requirement-PreUpdate FAIL names a prior above VersionMax (not applicable by design) and no longer says the update may still work' } else { Bad 'Requirement-PreUpdate text' }
    # Live rows OP-CONTROL, RC2-BLOCK (round 2): the causes follow the project's rules (constant texts chosen on the host): none
    # without rules; a Block (or Report) rule's prior is named as left out of the update requirement by design (D28).
    $pBlk = New-ProofProject 'gen-block' @((Entry 'nsis-x64' 'Block'))
    $tBlk = [IO.File]::ReadAllText((New-UpdateAssertionScript -ProjectPath $pBlk -OldVersion '8.8.9'))
    $pNone = New-ProofProject 'gen-none' $null
    $tNone = [IO.File]::ReadAllText((New-UpdateAssertionScript -ProjectPath $pNone -OldVersion '8.8.9'))
    $preLine = { param([string]$T) [regex]::Match($T, 'Requirement-\$Phase = FAIL \(rule did not detect the installed[^\r\n]*').Value }
    $lNone = & $preLine $tNone; $lBlk = & $preLine $tBlk
    if ($lNone.EndsWith('on devices like this one: an install of the app it has no signal for)" }') -and $lNone -notmatch 'VersionMax|Block or Report' -and
        $lBlk.EndsWith('an install of the app it has no signal for, or a prior install only a Block or Report rule names, which the update requirement leaves out by design (it holds Enforce rules only))" }') -and $lBlk -notmatch 'VersionMax' -and
        -not $tBlk.Contains('<<W32T-PREUPDATE-CAUSES>>') -and -not $tNone.Contains('<<W32T-PREUPDATE-CAUSES>>')) {
        Ok 'Requirement-PreUpdate FAIL names only the causes the rules allow (none without rules; Block/Report: left out by design)'
    } else { Bad "pre-update causes: none=$lNone block=$lBlk" }
    if ($text.Contains('= FAIL (rule did not detect the app AFTER the update - the update did not install the app (see the exit code of the update), or its presence signals are broken)')) { Ok 'Requirement-PostUpdate FAIL names an update that did not install the app before broken presence signals' } else { Bad 'Requirement-PostUpdate text' }
    $iComplete = $text.LastIndexOf("RESULT COMPLETE")
    $lastPrior = [Math]::Max([Math]::Max($text.LastIndexOf('PriorAbsent-PostUpdate'), $text.LastIndexOf('NewAppIntact-PostUpdate')), [Math]::Max($text.LastIndexOf('DATA UserDataKept-PostUpdate'), $text.LastIndexOf('OtherPriorAbsent-PostUpdate')))
    if ($iComplete -gt $lastPrior -and $lastPrior -gt 0 -and $text.LastIndexOf('ASSERT Tattoo-PostUpdate') -lt $text.IndexOf('## ---- win32-toolkit prior-install assertions')) { Ok "'RESULT COMPLETE' comes after every prior-install line (the text sits between the tattoo block and the footer)" } else { Bad "order: complete $iComplete, last prior $lastPrior" }
    $e = $null; [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$e)
    $e51 = if (Test-Path -LiteralPath $ps51) { & $ps51 -NoProfile -Command "`$e = `$null; [void][Management.Automation.Language.Parser]::ParseFile('$scriptPath', [ref]`$null, [ref]`$e); @(`$e).Count" } else { '0' }
    if (@($e).Count -eq 0 -and "$e51".Trim() -eq '0') { Ok 'UpdateAssertions.ps1 parses (host and Windows PowerShell 5.1)' } else { Bad "parse: host $(@($e).Count), 5.1 $e51" }
    $p0 = New-ProofProject 'gen0' $null
    $null = New-UpdateAssertionScript -ProjectPath $p0 -OldVersion '8.8.9'
    $d0 = Get-Content -LiteralPath (Join-Path $p0 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    if (@($d0.ProofEntryIds).Count -eq 0 -and $d0.SeedUserData -eq $false) { Ok 'a project without rules: empty id lists, no user-data seed' } else { Bad 'gen0 data' }

    # == [2] the assertion text in Windows PowerShell 5.1 ===============================================
    Write-Host '[2] the prior-install assertion text under Windows PowerShell 5.1' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $ps51)) { Write-Host '  SKIP: no Windows PowerShell 5.1' -ForegroundColor DarkYellow }
    else {
        $start = $lf.IndexOf('## win32-toolkit prior-install predicate')
        $end = $lf.IndexOf('Write-AssertLine "=== End $Phase ==="')
        # The script's own JSON-array reader (its header defines it; the prior text uses it for PriorSeeds.json).
        $priorText = [regex]::Match($lf, '(?s)function Read-JsonArray.*?\n\}').Value + "`n" + $lf.Substring($start, $end - $start)
        $w = Join-Path $env:USERPROFILE ('AppData\Local\Temp\w32tpa-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $null = New-Item -ItemType Directory -Path $w -Force
        $priorText = $priorText.Replace("'C:\PSADT\Sandbox\UpdateAssertionData.json'", "'$w\data.json'").Replace("'C:\PSADT\SupportFiles\AppConfig.json'", "'$w\AppConfig.json'")
        [IO.File]::WriteAllText("$w\prior.ps1", $priorText, [Text.UTF8Encoding]::new($true))
        $harness = @'
param([string]$W)
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$env:ProgramFiles = "$W\PF"
$logDir = "$W\Logs"
[void][IO.Directory]::CreateDirectory($logDir)
$script:lines = @()
function Write-AssertLine([string]$Message) { $script:lines += $Message }
$script:reg = @{}
$script:services = @()
$script:prov = @()
function Test-Path { [CmdletBinding()] param([string]$LiteralPath, [string]$Path, [string]$PathType) $p = $LiteralPath; if (-not $p) { $p = $Path }
    if ($p -like 'HKLM:*') { return $script:reg.ContainsKey($p.ToLowerInvariant()) }; Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
function Get-ItemProperty { [CmdletBinding()] param([string]$LiteralPath, [string]$Name)
    $k = $script:reg[$LiteralPath.ToLowerInvariant()]; if ($null -eq $k) { throw "no key $LiteralPath" }
    $o = New-Object psobject; foreach ($n in @($k.Keys)) { $o | Add-Member -MemberType NoteProperty -Name $n -Value $k[$n] }; $o }
function Get-Acl { [CmdletBinding()] param([string]$LiteralPath)
    $o = New-Object psobject; $o | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($t) New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18' }
    $o | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value { param($a, $b, $t) , @() }; $o }
function Get-AuthenticodeSignature { [CmdletBinding()] param([string]$LiteralPath) New-Object psobject -Property @{ Status = 'NotSigned'; SignerCertificate = $null } }
function Get-Service { [CmdletBinding()] param([string]$Name) if ($script:services -contains $Name) { New-Object psobject -Property @{ Name = $Name } } }
function Get-AppxProvisionedPackage { [CmdletBinding()] param([switch]$Online) $script:prov | ForEach-Object { New-Object psobject -Property @{ DisplayName = $_ } } }
$script:ownState = 5
function New-Object { param([Parameter(Position = 0)][string]$TypeName, [Parameter(Position = 1)][object[]]$ArgumentList, [string]$ComObject, [hashtable]$Property)
    if ($ComObject) { $f = Microsoft.PowerShell.Utility\New-Object psobject; $f | Add-Member -MemberType ScriptMethod -Name ProductState -Value { param($c) $script:ownState }; return $f }
    Microsoft.PowerShell.Utility\New-Object @PSBoundParameters }
$arp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
function Set-Prior([string]$Key = 'App', [string]$Version = '8.9.5') {
    $dir = "$W\PF\App"; [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText("$dir\uninstall.exe", 'x'); [IO.File]::WriteAllText("$dir\app.exe", 'x')
    $script:reg[("$arp\$Key").ToLowerInvariant()] = @{ DisplayName = 'App (64-bit)'; DisplayVersion = $Version; Publisher = 'Vendor Team'; UninstallString = '"' + "$dir\uninstall.exe" + '"' }
}
function Set-Data([hashtable]$D) { [IO.File]::WriteAllText("$W\data.json", ($D | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false))) }
function Run([string]$Phase) { $script:lines = @(); . "$W\prior.ps1"; $script:lines }
$e1 = [ordered]@{ Id = 'nsis-x64'; Kind = 'ArpKey'; Mode = 'Enforce'; Key = 'App'; View = 'Native'; Publisher = 'Vendor Team'; DisplayName = 'App (64-bit)'; DisplayNameTemplate = ''
    VersionMin = '8.0'; VersionMax = '8.9.8.1'; UninstallerType = 'nullsoft'; UninstallerFileName = 'uninstall.exe'; UninstallerSigner = ''; InstallDir = '%ProgramFiles%\App'; MainExe = 'app.exe'; ProcessNames = @('app') }
$e2 = [ordered]@{ Id = 'other-x86'; Kind = 'ArpKey'; Mode = 'Block'; Key = 'Other'; View = 'Native'; Publisher = 'Other'; DisplayName = 'Other'; VersionMin = '1.0'; VersionMax = '2.0' }
$cfg = [ordered]@{ App = @{ Version = '9.0'; ScriptAuthor = 'Contoso IT' }; Installer = @{ Type = 'msi' }; OwnIdentity = @{ ProductCode = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'; ArpKeys = @() }; PriorInstalls = @{ Entries = @($e1, $e2) } }
[IO.File]::WriteAllText("$W\AppConfig.json", ($cfg | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
[void][IO.Directory]::CreateDirectory("$W\PF\New"); [IO.File]::WriteAllText("$W\PF\New\new.exe", 'x')
$base = @{ SchemaVersion = '1.0'; ProofEntryIds = @('nsis-x64'); OtherEntryIds = @('other-x86'); NewAppFiles = @("$W\PF\New\new.exe"); OwnProductCode = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'; OwnAppxName = ''; SeedUserData = $true
    Sibling = @{ 'nsis-x64' = @{ ObservedVersion = '8.9.5'; Services = @('AppSvc'); Shortcuts = @('C:\x.lnk'); Tasks = @() } } }
# (a) PreUpdate: the prior is present, the other is absent
Set-Prior; Set-Data $base
$l = Run 'PreUpdate'
"A|" + ($l -join '|')
$obs = Get-Content -LiteralPath "$logDir\PriorObservations.json" -Raw | ConvertFrom-Json
"OBS|" + (@($obs) | ForEach-Object { $_.Id + '=' + $_.Outcome + '=' + $_.Version }) -join ','
"SEED|" + (Test-Path -LiteralPath "$W\PF\App\w32t-userdata-nsis-x64.ini")
# (b) PostUpdate: removed (key gone, seed deleted), service gone, new app intact
[void]$script:reg.Remove(("$arp\App").ToLowerInvariant()); Remove-Item -LiteralPath "$W\PF\App\w32t-userdata-nsis-x64.ini"
$l = Run 'PostUpdate'
"B|" + ($l -join '|')
# (c) PostUpdate: still registered, service left, user file kept, own MSI not registered
Set-Prior; Set-Data $base; $null = Run 'PreUpdate'; $script:services = @('AppSvc'); $script:ownState = -1
$script:reg['hklm:\software\contoso it\win32-toolkit'] = @{ LastRefusal = '2026-10-25 69101 9.0' }
$script:reg['hklm:\software\contoso it\win32-toolkit\priorinstalls\native\app'] = @{ LastSeen = '2026-10-25 Unproven 69104 8.9.5' }
$l = Run 'PostUpdate'
"C|" + ($l -join '|')
[void]$script:reg.Remove('hklm:\software\contoso it\win32-toolkit'); [void]$script:reg.Remove('hklm:\software\contoso it\win32-toolkit\priorinstalls\native\app')
$script:services = @(); $script:ownState = 5
# (d) PreUpdate: the prior absent before, the other present, another observed version
[void]$script:reg.Remove(("$arp\App").ToLowerInvariant())
$script:reg[("$arp\Other").ToLowerInvariant()] = @{ DisplayName = 'Other'; DisplayVersion = '1.5'; Publisher = 'Other'; UninstallString = 'x' }
$l = Run 'PreUpdate'
"D|" + ($l -join '|')
$script:reg.Clear()
Set-Prior -Version '8.9.6'; $l = Run 'PreUpdate'
"E|" + ($l -join '|')
# (f) MSIX: no files, provisioned / not provisioned; no files and no package -> SKIP
$msix = $base.Clone(); $msix.NewAppFiles = @(); $msix.OwnAppxName = 'Vendor.App'; $msix.ProofEntryIds = @(); Set-Data $msix
$script:prov = @('Vendor.App'); $l = Run 'PostUpdate'; "F1|" + ($l -join '|')
$script:prov = @(); $l = Run 'PostUpdate'; "F2|" + ($l -join '|')
$none = $base.Clone(); $none.NewAppFiles = @(); $none.ProofEntryIds = @(); Set-Data $none
$l = Run 'PostUpdate'; "F3|" + ($l -join '|')
'@
        [IO.File]::WriteAllText("$w\harness.ps1", $harness, [Text.UTF8Encoding]::new($true))
        $out = @(& $ps51 -NoProfile -ExecutionPolicy Bypass -File "$w\harness.ps1" -W $w 2>&1 | ForEach-Object { "$_" })
        $row = { param([string]$Tag) ($out | Where-Object { $_ -like "$Tag|*" } | Select-Object -First 1) }
        $a = & $row 'A'
        if ($a -match 'ASSERT PriorPresent-PreUpdate\.nsis-x64 = PASS' -and $a -match 'ASSERT SiblingIdentityStable-PreUpdate\.nsis-x64 = PASS' -and $a -match 'ASSERT OtherPriorAbsent-PreUpdate\.other-x86 = PASS') { Ok 'PreUpdate: PriorPresent, SiblingIdentityStable and OtherPriorAbsent PASS (the deploy evaluation plans the removal)' } else { Bad "A: $a" }
        if ((& $row 'OBS') -eq 'OBS|nsis-x64=Plan=8.9.5' -and (& $row 'SEED') -eq 'SEED|True') { Ok 'PriorObservations.json records the observed version; a user file is seeded in the prior folder' } else { Bad "obs/seed: $(& $row 'OBS') $(& $row 'SEED')" }
        $b = & $row 'B'
        if ($b -match 'ASSERT PriorAbsent-PostUpdate\.nsis-x64 = PASS' -and $b -match 'DATA UserDataKept-PostUpdate\.nsis-x64 = LOST' -and $b -notmatch 'ASSERT UserDataKept' -and $b -match 'ASSERT PriorResidue-PostUpdate\.nsis-x64 = PASS' -and $b -match 'NOTE PriorResidue nsis-x64: listed residue C:\\x\.lnk' -and $b -match 'ASSERT NewAppIntact-PostUpdate = PASS' -and $b -match 'ASSERT OtherPriorAbsent-PostUpdate\.other-x86 = PASS') {
            Ok 'PostUpdate: PriorAbsent / PriorResidue / NewAppIntact / OtherPriorAbsent PASS; the deleted user file is a DATA ... = LOST line, never an ASSERT (L14)'
        } else { Bad "B: $b" }
        $c = & $row 'C'
        if ($c -match 'ASSERT PriorAbsent-PostUpdate\.nsis-x64 = FAIL \(still registered' -and $c -match 'DATA UserDataKept-PostUpdate\.nsis-x64 = KEPT' -and $c -match 'ASSERT PriorResidue-PostUpdate\.nsis-x64 = FAIL \(service' -and $c -match 'ASSERT NewAppIntact-PostUpdate = FAIL \(own MSI not registered\)' -and $c -notmatch 'missing: ;') {
            Ok 'still registered -> PriorAbsent FAIL; a service left -> PriorResidue FAIL; the own MSI not registered -> NewAppIntact FAIL naming only that (no empty missing list, live row OP-NEWER); the user file kept -> DATA KEPT'
        } else { Bad "C: $c" }
        # Live rows OP-BLOCK, RC2-BLOCK, APP-RUNNING, OP-PROOF: the device markers reach the log as NOTE lines (never a verdict).
        if ($c -match 'NOTE PriorMarker LastRefusal: 2026-10-25 69101 9\.0' -and $c -match 'NOTE PriorMarker nsis-x64: LastSeen=2026-10-25 Unproven 69104 8\.9\.5' -and $c -notmatch 'NOTE PriorMarker other-x86' -and $b -notmatch 'NOTE PriorMarker') { Ok 'PostUpdate: the device markers (LastRefusal; an entry''s Removed/Version/LastSeen) are NOTE lines; none when the device has none' } else { Bad "markers: C=$c B=$b" }
        $d = & $row 'D'
        if ($d -match 'ASSERT PriorPresent-PreUpdate\.nsis-x64 = FAIL' -and $d -match 'ASSERT OtherPriorAbsent-PreUpdate\.other-x86 = FAIL') { Ok 'the prior absent before the update -> PriorPresent FAIL; the other entry present -> OtherPriorAbsent FAIL' } else { Bad "D: $d" }
        if ((& $row 'E') -match 'ASSERT SiblingIdentityStable-PreUpdate\.nsis-x64 = FAIL \(observed version 8\.9\.6, captured 8\.9\.5\)') { Ok 'another observed version than the floor capture -> SiblingIdentityStable FAIL' } else { Bad "E: $(& $row 'E')" }
        if ((& $row 'F1') -match 'ASSERT NewAppIntact-PostUpdate = PASS' -and (& $row 'F2') -match 'ASSERT NewAppIntact-PostUpdate = FAIL \(the package is not provisioned\)' -and (& $row 'F3') -match 'ASSERT NewAppIntact-PostUpdate = SKIP') { Ok 'MSIX: provisioned -> PASS, not -> FAIL; no capture files and no package -> SKIP' } else { Bad "F: $(& $row 'F1') / $(& $row 'F2') / $(& $row 'F3')" }
        if (@($out | Where-Object { $_ -match 'Exception|error' -and $_ -notmatch '^[A-F]\d?\|' }).Count -eq 0) { Ok 'the text ran without errors' } else { Bad "errors: $(@($out | Where-Object { $_ -match 'Exception|error' }) -join ' / ')" }
        Remove-Item -LiteralPath $w -Recurse -Force -ErrorAction SilentlyContinue
    }

    # == [3] Test-Win32ToolkitProject -Scenario Update: groups, baseline pin, Proof =========================
    Write-Host '[3] the Update test as a proof run (Hyper-V, shadowed)' -ForegroundColor Cyan
    $script:testBackend = 'HyperV'; $script:testModeCfg = 'Unattended'
    function Get-Win32ToolkitTestBackend { param($Backend) if ($Backend) { $Backend } else { $script:testBackend } }
    function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($Name -like '*TestMode') { $script:testModeCfg } else { $Default } }
    function Test-Win32ToolkitHostNonInteractive { $false }
    function Test-Win32ToolkitNonInteractiveSwitch { $false }
    $script:prechecks = 0
    $script:staged = 0
    function Invoke-Win32ToolkitParityPrecheck { $script:prechecks++; [pscustomobject]@{ Blocked = $false; Risk = $null; Seconds = 0; FromCache = $false; Lane = $null } }
    function Get-Win32ToolkitCleanupPathFinding { @() }
    ${function:Initialize-Win32ToolkitDependencyStaging} = { $script:staged++; 0 }
    function Get-WingetVersions { @('8.8.9', '8.8.8') }
    function Write-Win32ToolkitIdentityDelta { }
    function Get-Win32ToolkitTechnologySwitch { @() }
    function Wait-Win32ToolkitCollectedLog { $true }
    $script:requirementFifth = $true
    function Get-Win32ToolkitRequirementRule {
        param($ProjectPath)
        $body = if ($script:requirementFifth) { '$w32tPrData = ''x''' } else { '# no fifth signal' }
        [IO.File]::WriteAllText((Join-Path $ProjectPath 'SupportFiles\UpdateRequirement.ps1'), $body, [Text.UTF8Encoding]::new($true))
        @{ displayName = 'x' }
    }
    $script:dl = [System.Collections.Generic.List[hashtable]]::new()
    $baselineFile = Join-Path $root 'baseline-installer.exe'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    [IO.File]::WriteAllText($baselineFile, 'nsis baseline bytes', $utf8)
    # Version 8.8.8 is another release: another file (another SHA-256 than every floor record below).
    $otherBaselineFile = Join-Path $root 'baseline-installer-888.exe'
    [IO.File]::WriteAllText($otherBaselineFile, 'nsis 8.8.8 bytes', $utf8)
    ${function:Download-OldVersionInstaller} = {
        param($AppId, $Version, $ProjectPath, $DestinationDir, $Architecture, $Scope, $InstallerType, $Locale, [switch]$FamilyPin, [switch]$ExactType)
        $h = @{}; foreach ($k in $PSBoundParameters.Keys) { $h[$k] = $PSBoundParameters[$k] }; $script:dl.Add($h)
        [pscustomobject]@{ InstallerPath = $(if ($Version -eq '8.8.8') { $otherBaselineFile } else { $baselineFile }); InstallerName = 'old.exe'; InstallerType = 'exe'; SilentArgs = '/S'; UsedFallback = $false; RequestedInstallerType = $InstallerType
            ManifestInstallerType = $InstallerType; ManifestProductCode = 'App'; Scope = 'machine'; Locale = ''; Family = 'exe'; TriedTypes = @($InstallerType); ScopeRelaxed = $false }
    }
    $script:hvRuns = 0
    $script:hvAction = { param($P) }
    $script:hvPhases = @()
    function Invoke-Win32ToolkitHyperVRun {
        param($ProjectPath, $Phase, $Output, $ParityExitNote, $RunInfo, $BaselineProjectPath)
        $script:hvRuns++
        $script:hvPhases = @($Phase)
        $ld = Join-Path $ProjectPath 'Sandbox\Logs'
        $null = New-Item -ItemType Directory -Path $ld -Force
        [IO.File]::WriteAllText((Join-Path $ld 'UpdateAssertions.log'), "[t] ASSERT Tattoo-PostUpdate = PASS`r`n[t] DATA UserDataKept-PostUpdate.nsis-x64 = LOST (deleted)`r`n[t] DATA UserDataKept-PostUpdate.unknown = LOST`r`n[t] RESULT COMPLETE`r`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $ld 'PriorObservations.json'), '[{"Id":"nsis-x64","Outcome":"Plan","Version":"8.9.5"},{"Id":"inno-x86","Outcome":"Plan","Version":"5.0"},{"Id":"BAD ID","Version":"1"}]', $utf8)
        & $script:hvAction $ProjectPath
        $true
    }
    function Wait-Win32ToolkitUpdateAssertion { $true }
    $script:outcomes = [System.Collections.Generic.List[object]]::new()
    function Write-Win32ToolkitTestOutcome { param($ProjectPath, $Scenario, $Backend, $Mode, $Verdict, $Baseline, $LogFolder, $Notes, $Timing, $Lane, $LogFileName, [hashtable]$Proof)
        $script:outcomes.Add([pscustomobject]@{ Scenario = $Scenario; Backend = $Backend; Verdict = $Verdict; Proof = $Proof; HasProof = $PSBoundParameters.ContainsKey('Proof') }) }
    function Reset-Run { $script:dl.Clear(); $script:outcomes.Clear(); $script:hvRuns = 0; $script:hvAction = { param($P) }; $script:launches = 0; $script:prechecks = 0; $script:staged = 0 }

    $pp = New-ProofProject 'proof' @((Entry 'nsis-x64'), (Entry 'inno-x86' 'Enforce' @{ View = 'Wow6432'; UninstallerType = 'inno'; Key = 'App_is1'; UninstallerFileName = 'unins000.exe' }), (Entry 'blk' 'Block' @{ Key = 'Blk'; UninstallerType = '' }))
    Reset-Run
    $w = $null
    $v = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $d0 = if ($script:dl.Count) { $script:dl[0] } else { @{} }
    $data = Get-Content -LiteralPath (Join-Path $pp 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    if ($d0['InstallerType'] -eq 'inno' -and $d0['Architecture'] -eq 'x86' -and (@($data.ProofEntryIds) -join ',') -eq 'inno-x86' -and (@($data.OtherEntryIds) -join ',') -eq 'nsis-x64,blk') {
        Ok 'no options: the first group in Id order (inno-x86, Wow6432) -> the inno technology pinned, an x86 baseline; nsis-x64 and blk asserted absent'
    } else { Bad "first group: type=$($d0['InstallerType']) arch=$($d0['Architecture']) proof=$(@($data.ProofEntryIds) -join ',') other=$(@($data.OtherEntryIds) -join ',')" }
    if (@($w | Where-Object { "$_" -match 'cannot prove them|not checked|not asserted by this test' }).Count -eq 0) { Ok 'a Hyper-V unattended run: no "cannot prove" warning (it can prove)' } else { Bad "hv unattended warned: $($w -join ' | ')" }
    # Live row OP-OWN: a toolkit-package baseline checks no rule; the run says so instead of staying silent.
    $baseProj = New-ProofProject 'baseprj' $null
    Reset-Run
    $w = $null
    $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -BaselineProjectPath $baseProj -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $data = Get-Content -LiteralPath (Join-Path $pp 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    if (@($data.ProofEntryIds).Count -eq 0 -and @($w | Where-Object { "$_" -match '^Prior installs: not asserted by this test\. A -BaselineProjectPath baseline installs a toolkit package, so this run neither checks nor proves the Enforce rule\(s\) (inno-x86, nsis-x64|nsis-x64, inno-x86) \(the package''s own prior-check and remove-prior still run in the guest and may refuse\);' }).Count -eq 1) {
        Ok '-BaselineProjectPath: no rule checked, and one warning names the Enforce rules it neither checks nor proves'
    } else { Bad "baseline project: proof=$(@($data.ProofEntryIds) -join ',') warnings=$($w -join ' | ')" }
    Reset-Run
    $v = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -ProofEntryId nsis-x64 -WarningAction SilentlyContinue 6>$null
    $d0 = if ($script:dl.Count) { $script:dl[0] } else { @{} }
    $o = $script:outcomes[0]
    $binding = Get-Win32ToolkitPriorProofBinding -ProjectPath $pp
    $bsha = (Get-FileHash -LiteralPath $baselineFile -Algorithm SHA256).Hash
    if ($v -eq $true -and $d0['InstallerType'] -eq 'nullsoft' -and $d0['Architecture'] -eq 'x64') { Ok '-ProofEntryId nsis-x64 -> the nullsoft technology pinned (Origin Entry), the package architecture' } else { Bad "nsis group: v=$v type=$($d0['InstallerType']) arch=$($d0['Architecture'])" }
    if ($o -and $o.HasProof -and $o.Proof.PriorInstallsHash -ceq $binding.PriorInstallsHash -and $o.Proof.FilesSha256 -ceq $binding.FilesSha256 -and $o.Proof.ScriptSha256 -ceq $binding.ScriptSha256 -and
        $o.Proof.SupportFilesSha256 -ceq $binding.SupportFilesSha256 -and $o.Proof.CatalogVersion -ceq $binding.CatalogVersion -and $o.Proof.BaselineInstallerSha256 -ceq $bsha -and (@($o.Proof.EntryIds) -join ',') -eq 'nsis-x64' -and $o.Proof.RequirementChecked -eq $true) {
        Ok 'the record gets the Proof: the binding taken before the run, the baseline installer hash, the entries, RequirementChecked'
    } else { Bad "proof: $($o.Proof | ConvertTo-Json -Compress)" }
    if ($o.Proof.ObservedVersions['nsis-x64'] -eq '8.9.5' -and -not $o.Proof.ObservedVersions.ContainsKey('inno-x86') -and (@($o.Proof.DataLoss) -join ',') -eq 'nsis-x64') { Ok 'ObservedVersions and DataLoss: only the run''s entries, from PriorObservations.json and the DATA lines' } else { Bad "observed/dataloss: $($o.Proof.ObservedVersions | ConvertTo-Json -Compress) $(@($o.Proof.DataLoss) -join ',')" }
    # Live row TIMEOUT (2026-10-27): remove-prior may run the prior's uninstaller for 30 minutes before the install, but the
    # Intune-parity update kept the runner's 25 minutes. A project with Enforce rules: 55 (the backstop 60), PriorRemoval.
    $up = @($script:hvPhases | Where-Object { $_.Label -eq 'Update (Intune parity)' })[0]
    if ($up -and $up.RunnerTimeoutMinutes -eq 55 -and $up.PriorRemoval -eq $true -and $up.Command -ceq '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -IntuneParity -DeploymentType Install -TimeoutMinutes 55 -Label update; exit $LASTEXITCODE') {
        Ok 'a project with Enforce rules: the Intune-parity update runs with the 55-minute runner limit (-TimeoutMinutes 55, PriorRemoval)'
    } else { Bad "update phase: $($up | ConvertTo-Json -Compress)" }
    # Live rows TIMEOUT, RC2-BLOCK: the provider names what a remove-prior code means (the phase's ExitMeaning).
    if ($up -and $up.ExitMeaning -is [hashtable] -and [string]$up.ExitMeaning[69101] -match '^a Block prior-install rule refused the install' -and [string]$up.ExitMeaning[69108] -match 'uninstaller failed, or ran longer than 30 minutes' -and $up.ExitMeaning.Contains(1618)) {
        Ok 'the Intune-parity update phase carries ExitMeaning (69101 ... 69112, 1618) for the provider''s warning and note'
    } else { Bad "update ExitMeaning: $($up.ExitMeaning | ConvertTo-Json -Compress)" }
    # Live rows TIMEOUT (no unit test pinned the install phase) and MSIBUSY (the watched phases kept 25 minutes): the
    # install/uninstall test's parity install, and the watched install and update, get the 55 minutes and the meanings too.
    Reset-Run
    $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario InstallUninstall -WarningAction SilentlyContinue 6>$null
    $ip = @($script:hvPhases | Where-Object { $_.Label -eq 'Install (Intune parity)' })[0]
    if ($ip -and $ip.RunnerTimeoutMinutes -eq 55 -and $ip.PriorRemoval -eq $true -and $ip.Command -ceq '& ''C:\PSADT\Sandbox\Invoke-PsadtPackage.ps1'' -IntuneParity -DeploymentType Install -TimeoutMinutes 55 -Label app; exit $LASTEXITCODE' -and
        $ip.ExitMeaning -is [hashtable] -and $ip.ExitMeaning.Contains(69108)) {
        Ok 'install/uninstall test of an Enforce project: the Intune-parity install runs with 55 minutes (PriorRemoval) and carries ExitMeaning'
    } else { Bad "iu install phase: $($ip | ConvertTo-Json -Compress -Depth 3)" }
    Reset-Run
    $script:testModeCfg = 'Interactive'
    $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario InstallUninstall -WarningAction SilentlyContinue 6>$null
    $gi = @($script:hvPhases | Where-Object { $_.Label -eq 'Install (GUI)' })[0]
    Reset-Run
    $script:hvPhases = @()
    # -SpecificVersion: a watched run would otherwise ask for the baseline version.
    $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -ProofEntryId nsis-x64 -SpecificVersion '8.8.9' -WarningAction SilentlyContinue 6>$null
    $gu = @($script:hvPhases | Where-Object { $_.Label -eq 'Update (PSADT GUI)' })[0]
    $script:testModeCfg = 'Unattended'
    if ($gi -and $gi.RunnerTimeoutMinutes -eq 55 -and $gi.PriorRemoval -eq $true -and $gi.Command -match '-DeployMode Interactive -TimeoutMinutes 55 -Label app;' -and $gi.ExitMeaning.Contains(69101) -and
        $gu -and $gu.RunnerTimeoutMinutes -eq 55 -and $gu.PriorRemoval -eq $true -and $gu.Command -match '-DeployMode Interactive -TimeoutMinutes 55 -Label update;' -and $gu.ExitMeaning.Contains(69101)) {
        Ok 'watched Hyper-V runs of an Enforce project: the GUI install and the GUI update get the 55 minutes too (PriorRemoval, ExitMeaning)'
    } else { Bad "watched phases: install=$($gi | ConvertTo-Json -Compress -Depth 2) update=$($gu | ConvertTo-Json -Compress -Depth 2)" }
    Reset-Run
    $script:requirementFifth = $false
    $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -ProofEntryId nsis-x64 -WarningAction SilentlyContinue 6>$null
    $script:requirementFifth = $true
    if ($script:outcomes[0].Proof.RequirementChecked -eq $false) { Ok 'a requirement without the prior-install signal -> RequirementChecked false' } else { Bad 'RequirementChecked' }
    Reset-Run
    $thrown = try { $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -ProofEntryId nsis-x64, inno-x86 -ErrorAction Stop 6>$null; '' } catch { $_.Exception.Message }
    if ($thrown -match 'ONE proof group' -and $script:dl.Count -eq 0 -and $script:hvRuns -eq 0 -and $script:staged -eq 0 -and $script:prechecks -eq 0) { Ok '-ProofEntryId across two groups -> an error before anything is checked, staged, downloaded or run' } else { Bad "two groups: '$thrown' dl=$($script:dl.Count) staged=$($script:staged) prechecks=$($script:prechecks)" }
    Reset-Run
    $pnr = New-ProofProject 'noentries' $null
    $thrown = try { $null = Test-Win32ToolkitProject -ProjectPath $pnr -Scenario Update -ProofEntryId nsis-x64 -ErrorAction Stop 6>$null; '' } catch { $_.Exception.Message }
    if ($thrown -match 'ONE proof group' -and $thrown -match 'no Enforce entry' -and $script:dl.Count -eq 0 -and $script:hvRuns -eq 0 -and $script:staged -eq 0 -and $script:outcomes.Count -eq 0) { Ok '-ProofEntryId on a project without prior-install rules -> the same error (never an ordinary run), nothing staged or run' } else { Bad "no entries: '$thrown' runs=$($script:hvRuns) outcomes=$($script:outcomes.Count)" }
    Reset-Run
    $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -BaselineInstallerType nullsoft -SpecificVersion '8.8.9' -WarningAction SilentlyContinue 6>$null
    $data = Get-Content -LiteralPath (Join-Path $pp 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    if ((@($data.ProofEntryIds) -join ',') -eq 'nsis-x64' -and $script:dl[0]['InstallerType'] -eq 'nullsoft' -and $script:dl[0]['Architecture'] -eq 'x64') { Ok 'an explicit -BaselineInstallerType nullsoft checks the nullsoft group; the explicit choice is kept' } else { Bad "explicit: $(@($data.ProofEntryIds) -join ',')" }
    # Two groups of one technology in two registry views (the Wow6432 one first in Id order): a chosen technology checks
    # the group whose view this run's old version writes (an x64 package: Native) and asserts the other one absent.
    $pv = New-ProofProject 'views' @((Entry 'a-wow' 'Enforce' @{ View = 'Wow6432' }), (Entry 'b-native'))
    Reset-Run
    $null = Test-Win32ToolkitProject -ProjectPath $pv -Scenario Update -BaselineInstallerType nullsoft -SpecificVersion '8.8.9' -WarningAction SilentlyContinue 6>$null
    $data = Get-Content -LiteralPath (Join-Path $pv 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    if ((@($data.ProofEntryIds) -join ',') -eq 'b-native' -and (@($data.OtherEntryIds) -join ',') -eq 'a-wow' -and $script:dl[0]['Architecture'] -eq 'x64') { Ok 'an explicit technology with groups in two views -> the group of the view the x64 old version writes (Native); the Wow6432 one asserted absent' } else { Bad "views: proof=$(@($data.ProofEntryIds) -join ',') other=$(@($data.OtherEntryIds) -join ',')" }
    # -BaselineInstallerType Packaged (also the first leg of Both): the packaged technology is the run's technology.
    $cfgPath = Join-Path $pv 'SupportFiles\AppConfig.json'
    $cfgPv = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    $cfgPv | Add-Member -NotePropertyName Source -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; InstallerType = 'nullsoft'; Family = 'exe'; Scope = 'machine'; Architecture = 'x64'; Locale = ''; PinnedBy = 'parameter' })
    [IO.File]::WriteAllText($cfgPath, ($cfgPv | ConvertTo-Json -Depth 8), $utf8)
    Reset-Run
    $null = Test-Win32ToolkitProject -ProjectPath $pv -Scenario Update -BaselineInstallerType Packaged -SpecificVersion '8.8.9' -WarningAction SilentlyContinue 6>$null
    $data = Get-Content -LiteralPath (Join-Path $pv 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    if ((@($data.ProofEntryIds) -join ',') -eq 'b-native' -and $script:dl[0]['InstallerType'] -eq 'nullsoft') { Ok '-BaselineInstallerType Packaged of an NSIS package -> the nullsoft group of its view is checked' } else { Bad "packaged: proof=$(@($data.ProofEntryIds) -join ',') type=$($script:dl[0]['InstallerType'])" }
    # A version option chooses only the version: the group still pins its technology and the architecture of its view
    # (-SpecificVersion is how an operator reaches a version inside an entry's VersionMin..VersionMax window).
    $verCases = @(
        @{ Name = '-ProofEntryId nsis-x64 -SpecificVersion 8.8.9'; Args = @{ ProofEntryId = 'nsis-x64'; SpecificVersion = '8.8.9' }; Want = 'nullsoft/x64/8.8.9/nsis-x64/inno-x86,blk' }
        @{ Name = '-ProofEntryId nsis-x64 -VersionsBack 1'; Args = @{ ProofEntryId = 'nsis-x64'; VersionsBack = 1 }; Want = 'nullsoft/x64/8.8.9/nsis-x64/inno-x86,blk' }
        @{ Name = '-ProofEntryId inno-x86 -SpecificVersion 8.8.8'; Args = @{ ProofEntryId = 'inno-x86'; SpecificVersion = '8.8.8' }; Want = 'inno/x86/8.8.8/inno-x86/nsis-x64,blk' }
        @{ Name = '-SpecificVersion 8.8.9 (the first group)'; Args = @{ SpecificVersion = '8.8.9' }; Want = 'inno/x86/8.8.9/inno-x86/nsis-x64,blk' }
        @{ Name = '-BaselineInstallerType Auto -ProofEntryId nsis-x64 -SpecificVersion 8.8.9'; Args = @{ BaselineInstallerType = 'Auto'; ProofEntryId = 'nsis-x64'; SpecificVersion = '8.8.9' }; Want = 'nullsoft/x64/8.8.9/nsis-x64/inno-x86,blk' }
    )
    foreach ($vc in $verCases) {
        Reset-Run
        $vArgs = $vc.Args
        $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update @vArgs -WarningAction SilentlyContinue 6>$null
        $data = Get-Content -LiteralPath (Join-Path $pp 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
        $d0 = if ($script:dl.Count) { $script:dl[0] } else { @{} }
        $got = '{0}/{1}/{2}/{3}/{4}' -f $d0['InstallerType'], $d0['Architecture'], $d0['Version'], (@($data.ProofEntryIds) -join ','), (@($data.OtherEntryIds) -join ',')
        if ($got -eq $vc.Want -and $d0['FamilyPin']) { Ok "$($vc.Name) -> $($vc.Want -replace '^([^/]+)/([^/]+)/([^/]+)/.*$', '$1 at $2, version $3') (the group's technology and view; the version as given)" } else { Bad "$($vc.Name): got $got, want $($vc.Want)" }
    }
    # An x86 package (its Files\ manifest offers only the x86 installer): the old version of a chosen technology writes
    # WOW6432Node on the 64-bit guest, so the Wow6432 group is checked even when a Native group of that technology sorts
    # first; a Native group is proven from a 64-bit installer (an x86 old version can never produce it).
    $px = New-ProofProject 'x86pkg' @((Entry 'a-native'), (Entry 'b-wow' 'Enforce' @{ View = 'Wow6432' }))
    [IO.File]::WriteAllText((Join-Path $px 'Files\Notepad++.Notepad++.installer.yaml'), ("PackageIdentifier: Notepad++.Notepad++`nPackageVersion: 8.9.8.1`nInstallers:`n- Architecture: x86`n  InstallerType: nullsoft`n  Scope: machine`n" +
        "  InstallerUrl: https://example.invalid/npp.8.9.8.1.Installer.exe`n  InstallerSha256: $('E' * 64)`nManifestType: installer`nManifestVersion: 1.12.0`n"), $utf8)
    $cfgPath = Join-Path $px 'SupportFiles\AppConfig.json'
    $cfgX = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    $cfgX.App.Arch = 'x86'
    $cfgX | Add-Member -NotePropertyName Source -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; InstallerType = 'nullsoft'; Family = 'exe'; Scope = 'machine'; Architecture = 'x86'; Locale = ''; PinnedBy = 'parameter' })
    [IO.File]::WriteAllText($cfgPath, ($cfgX | ConvertTo-Json -Depth 8), $utf8)
    $gx = (@(Get-Win32ToolkitPriorProofGroup -ProjectPath $px) | ForEach-Object { "$($_.EntryIds -join '+'):$($_.View):$($_.Architecture)" }) -join ' | '
    if ($gx -eq 'a-native:Native:x64 | b-wow:Wow6432:x86') { Ok 'the proof groups of an x86 package: Native -> an x64 baseline, Wow6432 -> x86' } else { Bad "x86 groups: $gx" }
    Reset-Run
    $null = Test-Win32ToolkitProject -ProjectPath $px -Scenario Update -BaselineInstallerType nullsoft -SpecificVersion '8.8.9' -WarningAction SilentlyContinue 6>$null
    $data = Get-Content -LiteralPath (Join-Path $px 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    if ((@($data.ProofEntryIds) -join ',') -eq 'b-wow' -and (@($data.OtherEntryIds) -join ',') -eq 'a-native' -and $script:dl[0]['Architecture'] -eq 'x86') { Ok 'an x86 package, an explicit technology -> the group of the view its x86 old version writes (Wow6432); the Native one asserted absent' } else { Bad "x86 views: proof=$(@($data.ProofEntryIds) -join ',') other=$(@($data.OtherEntryIds) -join ',') arch=$($script:dl[0]['Architecture'])" }
    Reset-Run
    $null = Test-Win32ToolkitProject -ProjectPath $px -Scenario Update -ProofEntryId a-native -WarningAction SilentlyContinue 6>$null
    $data = Get-Content -LiteralPath (Join-Path $px 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    if ((@($data.ProofEntryIds) -join ',') -eq 'a-native' -and $script:dl[0]['InstallerType'] -eq 'nullsoft' -and $script:dl[0]['Architecture'] -eq 'x64') { Ok 'an x86 package, -ProofEntryId of its Native group -> the nullsoft technology at x64' } else { Bad "x86 native: proof=$(@($data.ProofEntryIds) -join ',') type=$($script:dl[0]['InstallerType']) arch=$($script:dl[0]['Architecture'])" }
    if ((@(Resolve-Win32ToolkitBaselineFamily -ProjectPath $pp -Mode Auto -EntryId nsis-x64 -NoProbe)[0]).InstallerType -eq 'nullsoft' -and (@(Resolve-Win32ToolkitBaselineFamily -ProjectPath $pp -Mode Auto -NoProbe)[0]).InstallerType -eq 'inno') { Ok 'Resolve-Win32ToolkitBaselineFamily: Auto -> the first group in Id order (inno); -EntryId nsis-x64 -> nullsoft' } else { Bad 'resolver -EntryId' }
    $pr = New-ProofProject 'oldrev' @((Entry 'nsis-x64')) -Revision 99
    Reset-Run
    $w = $null
    $null = Test-Win32ToolkitProject -ProjectPath $pr -Scenario Update -WarningVariable w -WarningAction SilentlyContinue 6>$null
    if (-not $script:outcomes[0].HasProof -and @($w | Where-Object { "$_" -match 'records no prior-install proof' -and "$_" -match 'Re-create the project' }).Count -eq 1) { Ok 'blocks of another catalog revision -> no Proof, one warning (L38)' } else { Bad "revision: proof=$($script:outcomes[0].HasProof) $($w -join ' | ')" }
    $pn = New-ProofProject 'norules' $null
    Reset-Run
    $null = Test-Win32ToolkitProject -ProjectPath $pn -Scenario Update -WarningAction SilentlyContinue 6>$null
    if ($script:outcomes.Count -eq 1 -and -not $script:outcomes[0].HasProof) { Ok 'a project without rules: no Proof (the old record shape)' } else { Bad 'norules proof' }

    # == [4] tripwire and the watched-Sandbox rule ======================================================
    Write-Host '[4] the tripwire and the watched-Sandbox rule' -ForegroundColor Cyan
    Reset-Run
    $script:hvAction = { param($P) [IO.File]::AppendAllText((Join-Path $P 'SupportFiles\AppConfig.json'), ' ') }
    $thrown = try { $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -ProofEntryId nsis-x64 -WarningAction SilentlyContinue 6>$null; '' } catch { $_.FullyQualifiedErrorId }
    if ($thrown -eq 'W32T.GuestTamper' -and $script:outcomes.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $pp 'Documentation\GuestTamper.json'))) { Ok 'Hyper-V: a project file changed during the guest run -> W32T.GuestTamper right after the run, no record' } else { Bad "hv tamper: '$thrown' outcomes=$($script:outcomes.Count)" }
    Remove-Item -LiteralPath (Join-Path $pp 'Documentation\GuestTamper.json')
    # InstallUninstall on Hyper-V with prior-install state
    function New-InstallAssertionScript { 'x' }
    function New-LogCollectorScript { 'x' }
    Reset-Run
    $script:hvAction = { param($P) [IO.File]::WriteAllText((Join-Path $P 'Documentation\TestResults.json'), '[]', $utf8) }
    $thrown = try { $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario InstallUninstall -WarningAction SilentlyContinue 6>$null; '' } catch { $_.FullyQualifiedErrorId }
    if ($thrown -eq 'W32T.GuestTamper' -and $script:outcomes.Count -eq 0) { Ok 'Hyper-V InstallUninstall of a project with rules: a forged record -> W32T.GuestTamper' } else { Bad "iu tamper: '$thrown'" }
    Remove-Item -LiteralPath (Join-Path $pp 'Documentation\GuestTamper.json'), (Join-Path $pp 'Documentation\TestResults.json') -ErrorAction SilentlyContinue
    # Live row INTERACTIVE: a watched Hyper-V Update run says before the run that it cannot prove the Enforce rule.
    Reset-Run
    $script:testModeCfg = 'Interactive'
    $w = $null
    try { $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -ProofEntryId nsis-x64 -WarningVariable w -WarningAction SilentlyContinue 6>$null } catch { $null = $_ }
    $script:testModeCfg = 'Unattended'
    if (@($w | Where-Object { "$_" -match '^This watched run checks the Enforce rule\(s\) nsis-x64 but cannot prove them, even when it passes' }).Count -eq 1) { Ok 'a watched Hyper-V Update run of an Enforce rule: one warning that it checks but cannot prove the rule' } else { Bad "hv watched cannot-prove: $($w -join ' | ')" }
    # Live row MSIBUSY: a watched run that hit a retry code revoked the proof without a word before the run.
    if (@($w | Where-Object { "$_" -match 'cannot prove them' -and "$_" -match 'If it fails \(also with a retry code such as 1618\), it revokes their current proof\.$' }).Count -eq 1) { Ok 'the watched-run warning also says that a failure (a retry code too) revokes the current proof' } else { Bad "revoke warning: $($w -join ' | ')" }
    Remove-Item -LiteralPath (Join-Path $pp 'Documentation\TestResults.json') -ErrorAction SilentlyContinue

    # Sandbox
    $script:testBackend = 'Sandbox'
    $script:launches = 0
    function Invoke-Win32ToolkitTestRun { param($Backend, $SandboxConfigPath) $script:launches++; [pscustomobject]@{ Launched = $true } }
    function New-CountdownScript { 'x' }
    foreach ($sc in 'Update', 'InstallUninstall') {
        Reset-Run
        $script:testModeCfg = 'Interactive'
        $thrown = try { $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario $sc -WarningAction SilentlyContinue 6>$null; '' } catch { $_.FullyQualifiedErrorId }
        $script:testModeCfg = 'Unattended'
        if ($thrown -eq 'W32T.PriorInstallRefused' -and $script:launches -eq 0 -and $script:dl.Count -eq 0) { Ok "a watched Sandbox $sc run of a project with rules -> W32T.PriorInstallRefused, nothing launched" } else { Bad "watched ${sc}: '$thrown' launches=$($script:launches)" }
    }
    # The rules a re-created project lost (Documentation\PriorInstallDropped.json) are prior-install state too: a guest
    # that deleted the file would silence ID-PRIOR-DROPPED, so the tripwire guards it and a watched run is refused.
    $pl = New-ProofProject 'lostonly' $null
    [IO.File]::WriteAllText((Join-Path $pl 'Documentation\PriorInstallDropped.json'), '{"SchemaVersion":"1.0","Entries":[{"Id":"nsis-x64","Kind":"ArpKey","Key":"Notepad++","View":"Native","From":"Notepad++_x64_8.9.8.1"}]}', $utf8)
    Reset-Run
    $script:testModeCfg = 'Interactive'
    $thrown = try { $null = Test-Win32ToolkitProject -ProjectPath $pl -Scenario InstallUninstall -WarningAction SilentlyContinue 6>$null; '' } catch { $_.FullyQualifiedErrorId }
    $script:testModeCfg = 'Unattended'
    if ($thrown -eq 'W32T.PriorInstallRefused' -and $script:launches -eq 0) { Ok 'a watched Sandbox run of a project whose only prior-install state is its lost rules (PriorInstallDropped.json) -> W32T.PriorInstallRefused, nothing launched' } else { Bad "watched lost-only: '$thrown' launches=$($script:launches)" }
    $script:sbFree = { $true }
    function Wait-Win32ToolkitSandboxFree { param($TimeoutSeconds, [switch]$OwnRun) & $script:sbFree $TimeoutSeconds $OwnRun }
    Reset-Run
    $script:sbFree = { param($t, $own) if ($own) { [IO.File]::WriteAllText((Join-Path $pp 'Documentation\TestResults.json'), '[{"forged":true}]', $utf8) }; $true }
    $thrown = try { $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -ProofEntryId nsis-x64 -WarningAction SilentlyContinue 6>$null; '' } catch { $_.FullyQualifiedErrorId }
    if ($thrown -eq 'W32T.GuestTamper' -and $script:outcomes.Count -eq 0) { Ok 'Sandbox: a record forged AFTER the waiter returned, before the sandbox closed -> W32T.GuestTamper, no record' } else { Bad "sb forged: '$thrown' outcomes=$($script:outcomes.Count)" }
    Remove-Item -LiteralPath (Join-Path $pp 'Documentation\GuestTamper.json'), (Join-Path $pp 'Documentation\TestResults.json') -ErrorAction SilentlyContinue
    Reset-Run
    # The start-up guard (90 s) finds no sandbox; this run's own sandbox never confirms closed (10 min, then 60 s).
    $script:sbFree = { param($t, $own) $t -eq 90 }
    $msg = try { $null = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -ProofEntryId nsis-x64 -WarningAction SilentlyContinue 6>$null; '' } catch { $_.FullyQualifiedErrorId + '|' + $_.Exception.Message }
    if ($msg -like 'W32T.GuestTamper|*could not be confirmed closed*' -and $script:outcomes.Count -eq 0) { Ok 'Sandbox: the sandbox cannot be confirmed closed -> W32T.GuestTamper with that reason' } else { Bad "sb open: '$msg'" }
    Remove-Item -LiteralPath (Join-Path $pp 'Documentation\GuestTamper.json') -ErrorAction SilentlyContinue
    Reset-Run
    $script:sbFree = { param($t, $own) $true }
    $w = $null
    $v = Test-Win32ToolkitProject -ProjectPath $pp -Scenario Update -ProofEntryId nsis-x64 -WarningVariable w -WarningAction SilentlyContinue 6>$null
    if ($v -eq $true -and $script:outcomes.Count -eq 1 -and $script:outcomes[0].Backend -eq 'Sandbox' -and $script:outcomes[0].HasProof) { Ok 'an untouched unattended Sandbox run: recorded (Backend Sandbox, with the Proof it checked - it never proves)' } else { Bad "sb ok: v=$v outcomes=$($script:outcomes.Count)" }
    # Live row INTERACTIVE: the operator is told before the run that it checks the Enforce rule but cannot prove it.
    if (@($w | Where-Object { "$_" -match '^This Windows Sandbox run checks the Enforce rule\(s\) nsis-x64 but cannot prove them, even when it passes: an Enforce rule is proven only by an Update test on Hyper-V, unattended' }).Count -eq 1) { Ok 'a Sandbox Update run of an Enforce rule: one warning that it checks but cannot prove the rule' } else { Bad "sb cannot-prove: $($w -join ' | ')" }
    # == [5] rules from a sibling capture: the floor capture is the baseline (installer-identity PR 3b, C2) ===========
    Write-Host '[5] a capture-lineage group: the floor capture is the baseline' -ForegroundColor Cyan
    $script:testBackend = 'HyperV'; $script:testModeCfg = 'Unattended'
    Remove-Item Function:\Wait-Win32ToolkitSandboxFree -ErrorAction SilentlyContinue
    $writeFloor = {
        param([string]$P, [string]$Sha)
        $rec = ConvertTo-Win32ToolkitSiblingCaptureRecord -InputObject ([ordered]@{
                SchemaVersion = '1.0'; CaptureKey = 'nullsoft-8.8.9'
                Package = [ordered]@{ WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; Architecture = 'x64'; InstallerType = 'wix'; Family = 'msi' }
                Sibling = [ordered]@{ InstallerType = 'nullsoft'; EffectiveType = 'nullsoft'; Version = '8.8.9'; Role = 'Floor'; ReleaseDate = '2025-12-09'; Scope = 'machine'; Locale = ''; Architecture = 'x64'
                    InstallerFile = 'npp.8.8.9.Installer.x64.exe'; InstallerSha256 = $Sha; SilentArgs = '/S'; SilentArgsSource = 'catalog'; Manifest = [ordered]@{ ProductCodes = @('App') } }
                Run = [ordered]@{ Backend = 'HyperV'; Mode = 'Unattended'; GuestScriptSha256 = ('C' * 64) }
                Install = [ordered]@{ ExitCode = 0; Completed = $true }
                Observation = [ordered]@{ Candidates = @([ordered]@{ Key = 'App'; View = 'Native'; DisplayName = 'App (64-bit)'; DisplayVersion = '8.8.9'; Publisher = 'Vendor Team' })
                    Services = @([ordered]@{ Name = 'AppUpdater'; DisplayName = 'App updater'; ImageLeaf = 'upd.exe' }); Shortcuts = @('C:\ProgramData\Microsoft\Windows\Start Menu\Programs\App.lnk')
                    Tasks = @([ordered]@{ Path = '\AppTask'; ActionLeaf = 'upd.exe' }); NoiseControl = 'Verified'; ProvisionalPrimary = 'App' }
                Probe = [ordered]@{ Result = 'Clean'; ProbedKey = 'App'; ProbedView = 'Native' }
                HostChecks = [ordered]@{ NsisMagic = $true } })
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $rec -Depth 12 -Compress -EscapeHandling EscapeNonAscii))
        $hasher = [Security.Cryptography.SHA256]::Create(); $id = (-join ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16); $hasher.Dispose()
        $null = New-Item -ItemType Directory -Path (Join-Path $P 'Documentation\SiblingCapture') -Force
        [IO.File]::WriteAllBytes((Join-Path $P "Documentation\SiblingCapture\$id.json"), $bytes)
        $id
    }
    $bsha = (Get-FileHash -LiteralPath $baselineFile -Algorithm SHA256).Hash
    $pc = Join-Path $root 'capture'
    $null = New-Item -ItemType Directory -Path $pc -Force
    $cid = & $writeFloor $pc $bsha
    $pc = New-ProofProject 'capture' @((Entry 'nsis-x64' 'Enforce' @{ Source = 'SiblingCapture'; CaptureId = $cid; VersionMin = '8.8.9' }))
    Reset-Run
    $w = $null
    $v = Test-Win32ToolkitProject -ProjectPath $pc -Scenario Update -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $d0 = if ($script:dl.Count) { $script:dl[0] } else { @{} }
    $data = Get-Content -LiteralPath (Join-Path $pc 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    $o = $script:outcomes[0]
    if ($v -eq $true -and $d0['ExactType'] -and -not $d0.ContainsKey('FamilyPin') -and $d0['InstallerType'] -eq 'nullsoft' -and $d0['Version'] -eq '8.8.9' -and $d0['Architecture'] -eq 'x64' -and $d0['Scope'] -eq 'machine') { Ok 'no baseline options: -ExactType nullsoft at the floor version 8.8.9, its architecture and scope (never the family, never the picker)' } else { Bad "floor download: $($d0 | ConvertTo-Json -Compress)" }
    $sd = $data.Sibling.'nsis-x64'
    if ($sd.ObservedVersion -eq '8.8.9' -and (@($sd.Services) -join ',') -eq 'AppUpdater' -and (@($sd.Tasks) -join ',') -eq '\AppTask' -and @($sd.Shortcuts).Count -eq 1) { Ok 'the data file carries Sibling.nsis-x64 from the floor record (observed version, services, shortcuts, tasks)' } else { Bad "sibling data: $($data.Sibling | ConvertTo-Json -Depth 4 -Compress)" }
    if ($o.HasProof -and (@($o.Proof.CaptureIds) -join ',') -eq $cid -and $o.Proof.BaselineInstallerSha256 -ceq $bsha -and @($w | Where-Object { "$_" -match 'cannot prove' }).Count -eq 0) { Ok 'the Proof names the CaptureIds and the floor installer hash; no warning' } else { Bad "proof: $($o.Proof | ConvertTo-Json -Compress) warnings $($w -join ' | ')" }
    Reset-Run
    $pm = Join-Path $root 'mismatch'; $null = New-Item -ItemType Directory -Path $pm -Force
    $cid2 = & $writeFloor $pm ('D' * 64)
    $pm = New-ProofProject 'mismatch' @((Entry 'nsis-x64' 'Enforce' @{ Source = 'SiblingCapture'; CaptureId = $cid2; VersionMin = '8.8.9' }))
    $msg = try { $null = Test-Win32ToolkitProject -ProjectPath $pm -Scenario Update -WarningAction SilentlyContinue -ErrorAction Stop 6>$null; '' } catch { $_.Exception.Message }
    if ($msg -match 'is not the one the floor capture' -and $script:hvRuns -eq 0 -and $script:outcomes.Count -eq 0) { Ok "the downloaded installer's SHA-256 differs from the floor record's -> an error before the guest, nothing recorded" } else { Bad "mismatch: '$msg' runs=$($script:hvRuns)" }
    Reset-Run
    $w = $null
    $null = Test-Win32ToolkitProject -ProjectPath $pc -Scenario Update -BaselineInstallerType nullsoft -SpecificVersion '8.8.9' -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $okEq = @($w | Where-Object { "$_" -match 'cannot prove' }).Count -eq 0 -and $script:dl[0]['FamilyPin']
    Reset-Run
    $w = $null
    $null = Test-Win32ToolkitProject -ProjectPath $pc -Scenario Update -BaselineInstallerType nullsoft -SpecificVersion '8.8.8' -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $data = Get-Content -LiteralPath (Join-Path $pc 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    if ($okEq -and @($w | Where-Object { "$_" -match '^nsis-x64 comes from a sibling capture whose floor is version 8\.8\.9; this run uses version 8\.8\.8' -and "$_" -match 'cannot prove' }).Count -eq 1 -and (@($data.ProofEntryIds) -join ',') -eq 'nsis-x64') { Ok 'an explicit version equal to the floor -> no warning; another version -> the "cannot prove" warning, the group still checked' } else { Bad "explicit: eq=$okEq warnings $($w -join ' | ')" }
    # Live run GOAL-UPDATE-NULLSOFT (2026-10-27): the run from 8.9.8 got the FLOOR record's facts, so the guest compared the
    # observed 8.9.8 with the captured 8.8.9, SiblingIdentityStable FAILED and the newest failed run revoked the proven rule.
    # Another installer than the floor's gets no Sibling data (nothing to compare it with); the floor's file gets it.
    if (@($data.Sibling.PSObject.Properties).Count -eq 0) { Ok 'another baseline than the floor capture''s installer -> no Sibling data in the data file (no SiblingIdentityStable / PriorResidue check against the floor record)' } else { Bad "non-floor sibling data: $($data.Sibling | ConvertTo-Json -Compress)" }
    Reset-Run
    $w = $null
    $null = Test-Win32ToolkitProject -ProjectPath $pc -Scenario Update -BaselineInstallerType nullsoft -VersionsBack 1 -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $data = Get-Content -LiteralPath (Join-Path $pc 'Sandbox\UpdateAssertionData.json') -Raw | ConvertFrom-Json
    if ($script:dl[0]['Version'] -eq '8.8.9' -and @($w | Where-Object { "$_" -match 'cannot prove' }).Count -eq 0 -and $data.Sibling.'nsis-x64'.ObservedVersion -eq '8.8.9') { Ok '-BaselineInstallerType nullsoft -VersionsBack 1 resolving to the floor''s installer (SHA-256 equal) -> no "cannot prove" warning, the floor record''s Sibling data' } else { Bad "versionsback floor: v=$($script:dl[0]['Version']) warnings $($w -join ' | ') sibling $($data.Sibling | ConvertTo-Json -Compress)" }
    Reset-Run
    $w = $null
    $null = Test-Win32ToolkitProject -ProjectPath $pc -Scenario Update -SpecificVersion '8.8.8' -WarningVariable w -WarningAction SilentlyContinue 6>$null
    $d0 = if ($script:dl.Count) { $script:dl[0] } else { @{} }
    if (@($w | Where-Object { "$_" -match 'this run uses version 8\.8\.8' -and "$_" -match 'cannot prove' }).Count -eq 1 -and $d0['InstallerType'] -eq 'nullsoft' -and $d0['FamilyPin'] -and -not $d0['ExactType'] -and $d0['Architecture'] -eq 'x64' -and $d0['Version'] -eq '8.8.8') {
        Ok 'only -SpecificVersion on a captured group -> the group''s technology and architecture at that version (never the floor pin), one "cannot prove" warning'
    } else { Bad "captured + version: $($d0 | ConvertTo-Json -Compress) warnings $($w -join ' | ')" }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All UpdateProofRun tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail UpdateProofRun test(s) FAILED." -ForegroundColor Red; exit 1 }
