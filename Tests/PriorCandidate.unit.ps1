<#
    Installer-identity PR 3 (spec 2.10 host step 3, V15, C-14): Get-Win32ToolkitPriorInstallCandidate turns the old
    installs a failed Update test left behind (the guest's Sandbox\Logs\PriorCandidates.json) into
    Documentation\PriorInstallCandidates.json, the input of Set-Win32ToolkitPriorInstall -FromUpdateTest.

      [1] mapping: Notepad++ NSIS (High: key = the manifest ProductCode and a manifest publisher), the {v} template,
          the uninstaller leaf and folder tokenised to %ProgramFiles%, MainExe from the DisplayIcon, ProcessNames; an Inno
          entry (marker + _is1 -> inno); a non-Program-Files folder -> InstallDir ''; the only other .exe as MainExe;
          another publisher or key -> Low; WindowsInstaller kept; ids -2 on a collision; the frozen field order; the
          hint line names -FromUpdateTest -Mode Block.
      [2] hostile guest output: CR/LF, ANSI escape and bidi controls neutralised; a key with a backslash, a bad view, a
          '..' folder, a traversal leaf, unknown fields -> dropped or emptied; a 10 MB file -> nothing written, one
          warning; no guest file -> nothing.
      [3] the guest side: the generated UpdateAssertions.ps1 reads an uninstaller with the deploy script's rule
          (quoted / unquoted .exe, never an 8.3 name or a relative part), under Windows PowerShell 5.1.

    Projects under %TEMP%. Run:  pwsh -File Tests\PriorCandidate.unit.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

foreach ($f in 'Get-Win32ToolkitPriorInstallCandidate', 'ConvertTo-Win32ToolkitSafeText', 'New-UpdateAssertionScript', 'Get-Win32ToolkitAppConfig', 'ConvertTo-PSSingleQuoted', 'Get-Win32ToolkitDeployScriptBlock',
    'ConvertTo-Win32ToolkitPriorVersion',   # C-9: the candidate lines compare the observed version with a rule's window
    'Get-Win32ToolkitDeployScriptShape', 'Test-Win32ToolkitPsadtVersionSupported') {   # C-9: ... and read the project's remove-prior slots
    . (Join-Path $repo "Private\$f.ps1")
}
$script:PsadtSupportedRange = [pscustomobject]@{ Min = [version]'4.1.0'; MaxExclusive = [version]'4.3.0'; Display = '4.1.x and 4.2.x' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('w32cand_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$utf8 = [Text.UTF8Encoding]::new($false)
function New-CandProject([string]$Name, [object]$Guest, [object]$Raw = $null) {
    $p = Join-Path $root $Name
    $null = New-Item -ItemType Directory -Path (Join-Path $p 'Sandbox\Logs'), (Join-Path $p 'Sandbox\OldVersion'), (Join-Path $p 'Documentation') -Force
    Copy-Item -LiteralPath (Join-Path $repo 'Tests\Fixtures\winget-manifests\Notepad++.Notepad++\8.8.9.installer.yaml') -Destination (Join-Path $p 'Sandbox\OldVersion\Notepad++.Notepad++.installer.yaml')
    [IO.File]::WriteAllText((Join-Path $p 'Sandbox\OldVersion\Notepad++.Notepad++.locale.en-US.yaml'), "PackageIdentifier: Notepad++.Notepad++`r`nPublisher: Notepad++ Team`r`n", $utf8)
    $text = if ($null -ne $Raw) { $Raw } else { ConvertTo-Json -InputObject @($Guest) -Depth 4 }
    [IO.File]::WriteAllText((Join-Path $p 'Sandbox\Logs\PriorCandidates.json'), $text, [Text.UTF8Encoding]::new($true))
    $p
}
function Cand([hashtable]$Over = @{}) {
    $c = [ordered]@{ Key = 'Notepad++'; View = 'Native'; DisplayName = 'Notepad++ (64-bit x64)'; Publisher = 'Notepad++ Team'; DisplayVersion = '8.8.9'; WindowsInstaller = $false
        InstallLocation = 'C:\Program Files\Notepad++'; UninstallerLeaf = 'uninstall.exe'; UninstallerFolder = 'C:\Program Files\Notepad++'; DisplayIconLeaf = 'notepad++.exe'; InnoAppPath = $false
        Exes = @('notepad++.exe', 'uninstall.exe') }
    foreach ($k in $Over.Keys) { $c[$k] = $Over[$k] }
    $c
}
$baseline = @{ Version = '8.8.9'; InstallerType = 'nullsoft'; Family = 'exe' }
function Run([string]$P, [string]$Pc = 'Notepad++', [hashtable]$B = $baseline) { @(Get-Win32ToolkitPriorInstallCandidate -ProjectPath $P -Baseline $B -Architecture x64 -ManifestProductCode $Pc -ManifestPath (Join-Path $P 'Sandbox\OldVersion') 6>$null) }

try {
    Write-Host '[1] mapping' -ForegroundColor Cyan
    $p = New-CandProject 'npp' @((Cand))
    $out = @(Get-Win32ToolkitPriorInstallCandidate -ProjectPath $p -Baseline $baseline -Architecture x64 -ManifestProductCode 'Notepad++' -ManifestPath (Join-Path $p 'Sandbox\OldVersion') 6>&1)
    $c = @($out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
    $hint = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
    $doc = Get-Content -LiteralPath (Join-Path $p 'Documentation\PriorInstallCandidates.json') -Raw | ConvertFrom-Json
    if ($c.ProposedId -eq 'nsis-x64' -and $c.Confidence -eq 'High' -and $c.UninstallerType -eq 'nullsoft' -and $c.InstallDir -ceq '%ProgramFiles%\Notepad++' -and $c.MainExe -ceq 'notepad++.exe' -and (@($c.ProcessNames) -join ',') -ceq 'notepad++' -and $c.ObservedVersion -eq '8.8.9' -and $c.DisplayName -ceq 'Notepad++ (64-bit x64)') {
        Ok 'Notepad++ NSIS: nsis-x64, High (key = manifest ProductCode, publisher from the manifest), nullsoft, %ProgramFiles%\Notepad++, notepad++.exe'
    } else { Bad "npp: $($c | ConvertTo-Json -Compress)" }
    if ((@($doc.Candidates[0].PSObject.Properties.Name) -join ',') -eq 'ProposedId,Confidence,Key,View,Publisher,DisplayName,DisplayNameTemplate,ObservedVersion,WindowsInstaller,UninstallerType,UninstallerFileName,InstallDir,MainExe,ProcessNames' -and
        $doc.SchemaVersion -eq '1.0' -and $doc.Baseline.ManifestProductCode -eq 'Notepad++' -and $doc.Baseline.ManifestPublisher -eq 'Notepad++ Team' -and $doc.Baseline.Architecture -eq 'x64') { Ok 'PriorInstallCandidates.json: the frozen schema and field order' } else { Bad "doc: $($doc | ConvertTo-Json -Depth 4 -Compress)" }
    if (@($hint | Where-Object { $_ -like "*Set-Win32ToolkitPriorInstall -ProjectPath '$p' -FromUpdateTest -Mode Block" }).Count -eq 1) { Ok 'the hint line names -FromUpdateTest -Mode Block' } else { Bad "hint: $($hint -join ' | ')" }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $p 'Documentation\PriorInstallCandidates.json'))
    if (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) { Ok 'written BOM-less' } else { Bad 'BOM' }
    $c = (Run (New-CandProject 'tmpl' @((Cand @{ DisplayName = 'Wireshark 8.8.9 x64' }))))[0]
    if ($c.DisplayName -eq '' -and $c.DisplayNameTemplate -ceq 'Wireshark {v} x64') { Ok "a name holding the observed version -> DisplayNameTemplate 'Wireshark {v} x64', DisplayName ''" } else { Bad "template: $($c | ConvertTo-Json -Compress)" }
    $c = (Run (New-CandProject 'inno' @((Cand @{ Key = 'App_is1'; InnoAppPath = $true; UninstallerLeaf = 'unins000.exe'; Exes = @('unins000.exe', 'app.exe'); DisplayIconLeaf = '' }))) 'other' @{ Version = '1.0'; InstallerType = 'exe'; Family = 'exe' })[0]
    if ($c.UninstallerType -eq 'inno' -and $c.ProposedId -eq 'inno-x64' -and $c.MainExe -eq 'app.exe' -and $c.Confidence -eq 'Low') { Ok 'Inno marker + _is1 -> inno; the only other .exe as MainExe; another key than the manifest ProductCode -> Low' } else { Bad "inno: $($c | ConvertTo-Json -Compress)" }
    $c = (Run (New-CandProject 'exe' @((Cand @{ UninstallerFolder = 'C:\Tools\App' }))) 'Notepad++' @{ Version = '1.0'; InstallerType = 'burn'; Family = 'exe' })[0]
    if ($c.UninstallerType -eq '' -and $c.ProposedId -eq 'exe-x64' -and $c.InstallDir -eq '') { Ok "an unknown technology -> UninstallerType '' (Block/Report only); a folder outside Program Files -> InstallDir ''" } else { Bad "exe: $($c | ConvertTo-Json -Compress)" }
    $c = (Run (New-CandProject 'pub' @((Cand @{ Publisher = 'Don Ho' }))))[0]
    if ($c.Confidence -eq 'Low') { Ok 'another publisher than the manifest -> Low' } else { Bad 'publisher High' }
    $cs = Run (New-CandProject 'two' @((Cand), (Cand @{ Key = 'Notepad++ x86'; View = 'Wow6432' })))
    if ($cs.Count -eq 2 -and $cs[1].ProposedId -eq 'nsis-x64-2' -and $cs[1].View -eq 'Wow6432') { Ok 'a second candidate of the same kind -> nsis-x64-2; the view kept' } else { Bad "two: $($cs | ConvertTo-Json -Compress)" }
    # Live row SB-REGRESSION: a Windows Installer survivor was labelled 'exe-x64'.
    $cs = Run (New-CandProject 'msi-stem' @((Cand), (Cand @{ Key = '{224C0E17-FB79-4AE2-9A47-5556FCEF39C4}'; View = 'Native'; WindowsInstaller = $true })))
    if ($cs.Count -eq 2 -and $cs[1].ProposedId -eq 'msi-x64' -and $cs[1].WindowsInstaller -eq $true) { Ok "a Windows Installer survivor -> 'msi-x64' (not 'exe-x64'); WindowsInstaller kept" } else { Bad "msi stem: $($cs | ConvertTo-Json -Compress)" }
    # Live row OP-OWN: after a 69106 refusal the same-version baseline MSI 'survived': this package's OWN product was listed
    # as a candidate (exe-x64) and replaced the NSIS candidate in the file.
    $OWN = '{5C6F8543-7EA8-40B9-B78F-04C78300DE7F}'
    $po = New-CandProject 'own' @((Cand), (Cand @{ Key = $OWN; DisplayName = 'Notepad++ (x64)'; WindowsInstaller = $true }))
    $null = New-Item -ItemType Directory -Path (Join-Path $po 'SupportFiles') -Force
    [IO.File]::WriteAllText((Join-Path $po 'SupportFiles\AppConfig.json'), (ConvertTo-Json -InputObject ([ordered]@{ SchemaVersion = '1.0'; OwnIdentity = [ordered]@{ ProductCode = $OWN; ArpKeys = @([ordered]@{ Key = $OWN; View = 'Native' }) } }) -Depth 5), $utf8)
    $outO = @(Get-Win32ToolkitPriorInstallCandidate -ProjectPath $po -Baseline $baseline -Architecture x64 -ManifestProductCode 'Notepad++' -ManifestPath (Join-Path $po 'Sandbox\OldVersion') 6>&1)
    $csO = @($outO | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
    $docO = Get-Content -LiteralPath (Join-Path $po 'Documentation\PriorInstallCandidates.json') -Raw | ConvertFrom-Json
    if ($csO.Count -eq 1 -and $csO[0].Key -eq 'Notepad++' -and @($docO.Candidates).Count -eq 1 -and @($outO | Where-Object { "$_" -like "Old install left after the update: $OWN [[]Native]*this package's own product*" }).Count -eq 1) { Ok "this package's own MSI product is no candidate: one host line names it as the package's own; the file keeps the NSIS one" } else { Bad "own: $($csO | ConvertTo-Json -Compress) // $(@($outO | ForEach-Object { "$_" }) -join ' | ')" }
    [IO.File]::WriteAllText((Join-Path $po 'Sandbox\Logs\PriorCandidates.json'), (ConvertTo-Json -InputObject @((Cand @{ Key = $OWN; WindowsInstaller = $true })) -Depth 4), [Text.UTF8Encoding]::new($true))
    $csO2 = @(Run $po)
    $docO2 = Get-Content -LiteralPath (Join-Path $po 'Documentation\PriorInstallCandidates.json') -Raw | ConvertFrom-Json
    if ($csO2.Count -eq 0 -and @($docO2.Candidates).Count -eq 1 -and $docO2.Candidates[0].Key -eq 'Notepad++') { Ok 'only the own product left -> nothing written (the earlier candidates file stays)' } else { Bad "own only: $($csO2.Count) $($docO2 | ConvertTo-Json -Compress -Depth 4)" }
    $c = (Run (New-CandProject 'x86dir' @((Cand @{ UninstallerFolder = 'C:\Program Files (x86)\Notepad++' }))))[0]
    if ($c.InstallDir -ceq '%ProgramFiles(x86)%\Notepad++') { Ok 'C:\Program Files (x86)\... -> %ProgramFiles(x86)%\...' } else { Bad "x86 dir: $($c.InstallDir)" }

    Write-Host '[1b] the next step per candidate: an existing rule, a Windows Installer key, Low candidates' -ForegroundColor Cyan
    # Live checks OP-BLOCK, OP-REPORT, OP-UNPROVEN, OP-NEWER, KILL-*, APP-RUNNING, MSIBUSY, RC2-*, DEMOTE, GOAL-PROOF: after a
    # refusal the hint said "Declare it ... -FromUpdateTest -Mode Block" for a key a rule already names, and that command
    # was refused (nsis-x64-2: another entry names the same uninstall key). SB-REGRESSION: an MSI survivor got the same hint.
    $hostLines = { param([string]$P) @(Get-Win32ToolkitPriorInstallCandidate -ProjectPath $P -Baseline $baseline -Architecture x64 -ManifestProductCode 'Notepad++' -ManifestPath (Join-Path $P 'Sandbox\OldVersion') 6>&1 |
                Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) }
    $withRule = {
        param([string]$Name, [hashtable]$Over = @{})
        $p0 = New-CandProject $Name @((Cand))
        $e = [ordered]@{ Id = 'nsis-x64'; Kind = 'ArpKey'; Mode = 'Block'; Key = 'notepad++'; View = 'Native'; Publisher = 'Notepad++ Team'; DisplayName = 'Notepad++ (64-bit x64)'; VersionMin = '8.0'; VersionMax = '8.9.8.1' }
        foreach ($k in $Over.Keys) { $e[$k] = $Over[$k] }
        $null = New-Item -ItemType Directory -Path (Join-Path $p0 'SupportFiles') -Force
        [IO.File]::WriteAllText((Join-Path $p0 'SupportFiles\AppConfig.json'), (ConvertTo-Json -InputObject ([ordered]@{ SchemaVersion = '1.0'; PriorInstalls = [ordered]@{ SchemaVersion = '1.0'; Entries = @($e) } }) -Depth 5), $utf8)
        $p0
    }
    $h = & $hostLines (& $withRule 'rule-block')
    if (@($h | Where-Object { $_ -like "Prior install candidate: nsis-x64 (High) - Notepad++ [[]Native] 8.8.9*already the Block rule 'nsis-x64'" }).Count -eq 1 -and @($h | Where-Object { $_ -like 'Declare it*' }).Count -eq 0) { Ok 'a key a Block rule already names (case-insensitive) -> "already the Block rule ''nsis-x64''", no declare command' } else { Bad "rule block: $($h -join ' | ')" }
    # Live rows OP-UNPROVEN, OP-NEWER (round 2): "replace it: ... -Remove nsis-x64, then declare it again" named no declare
    # command, and followed literally (-FromUpdateTest -Mode Block) it turned the operator's Enforce rule [8.9.0, 8.9.7] into a
    # Block rule of the observed version only. The replacement keeps the mode and widens the window to the observed version.
    $pU = & $withRule 'rule-unproven' @{ Mode = 'Enforce'; Publisher = 'Other Team' }
    $h = & $hostLines $pU
    if (@($h | Where-Object { $_.EndsWith("already the Enforce rule 'nsis-x64': its publisher 'Other Team' is not the observed 'Notepad++ Team' (replace it from this candidate, keeping its mode: Set-Win32ToolkitPriorInstall -ProjectPath '$pU' -FromUpdateTest -Id nsis-x64 -Mode Enforce -VersionMin '8.0' -VersionMax '8.9.8.1')", [StringComparison]::Ordinal) }).Count -eq 1 -and @($h | Where-Object { $_ -like 'Declare it*' -or $_ -like '*-Remove*' }).Count -eq 0) { Ok 'an Enforce rule with another publisher -> the line names both publishers and the replacement from the candidate (mode and window kept)' } else { Bad "rule unproven: $($h -join ' | ')" }
    $pN = & $withRule 'rule-newer' @{ Mode = 'Enforce'; VersionMin = '8.5'; VersionMax = '8.8.8' }
    $h = & $hostLines $pN
    if (@($h | Where-Object { $_.EndsWith("already the Enforce rule 'nsis-x64': the observed version 8.8.9 is above its VersionMax 8.8.8 (replace it from this candidate, keeping its mode: Set-Win32ToolkitPriorInstall -ProjectPath '$pN' -FromUpdateTest -Id nsis-x64 -Mode Enforce -VersionMin '8.5' -VersionMax '8.8.9')", [StringComparison]::Ordinal) }).Count -eq 1) { Ok 'an Enforce rule whose VersionMax is below the observed version -> the line says so (the 69102 cause) and widens only VersionMax (mode and floor kept)' } else { Bad "rule newer: $($h -join ' | ')" }
    $h = & $hostLines (& $withRule 'rule-captured' @{ Mode = 'Enforce'; VersionMax = '8.8.8'; Source = 'SiblingCapture'; CaptureId = '0123456789abcdef' })
    if (@($h | Where-Object { $_ -match "VersionMax 8\.8\.8 \(a captured rule changes only through its capture: Test-Win32ToolkitProject -ProjectPath '.*' -Scenario SiblingCapture, then apply its proposal again\)$" }).Count -eq 1) { Ok 'a captured rule -> capture again (its window is never typed)' } else { Bad "rule captured: $($h -join ' | ')" }
    # Live row OP-CONTROL (round 2): the declare command was printed for a project whose remove-prior blocks are another catalog
    # revision; it was refused (W32T.PriorInstallSlotsMissing), and re-creating the project drops the candidates.
    $pS = New-CandProject 'old-slots' @((Cand))
    $oldRev = [int](Get-Win32ToolkitDeployScriptBlock -Name RemovePriorRevision) - 1
    [IO.File]::WriteAllText((Join-Path $pS 'Invoke-AppDeployToolkit.ps1'), "## win32-toolkit:Pre-Install:prior-check (begin)`n## remove-prior catalog revision $oldRev (win32-toolkit)`n## win32-toolkit:Pre-Install:prior-check (end)`n## win32-toolkit:Pre-Install:remove-prior (begin)`n## win32-toolkit:Pre-Install:remove-prior (end)`n", [Text.UTF8Encoding]::new($true))
    $h = & $hostLines $pS
    if (@($h | Where-Object { $_ -ceq "This project cannot take a prior-install rule yet: its remove-prior blocks are catalog revision $oldRev, this version writes revision $($oldRev + 1). Re-create it with this win32-toolkit version (Invoke-Win32Toolkit -Force or New-Win32ToolkitManualApp; copy hand-written Install code out first), run this Update test again (re-creating drops the candidates), then declare it (Block first): Set-Win32ToolkitPriorInstall -ProjectPath '$pS' -FromUpdateTest -Mode Block" }).Count -eq 1 -and
        @($h | Where-Object { $_ -like 'Declare it*' }).Count -eq 0) { Ok 'a project of another remove-prior catalog revision -> re-create it and run the Update test again before declaring' } else { Bad "old slots: $($h -join ' | ')" }
    $h = & $hostLines (New-CandProject 'msi-only' @((Cand @{ Key = '{224C0E17-FB79-4AE2-9A47-5556FCEF39C4}'; WindowsInstaller = $true })))
    if (@($h | Where-Object { $_ -like '*registered by Windows Installer: not a prior install of this kind, nothing to declare' }).Count -eq 1 -and @($h | Where-Object { $_ -like 'Declare it*' }).Count -eq 0) { Ok 'a Windows Installer survivor -> named as not declarable, no declare command' } else { Bad "msi: $($h -join ' | ')" }
    $pLow = New-CandProject 'low-only' @((Cand @{ Publisher = 'Don Ho' }))
    $h = & $hostLines $pLow
    if (@($h | Where-Object { $_ -ceq "Declare it (Block first): Set-Win32ToolkitPriorInstall -ProjectPath '$pLow' -FromUpdateTest -Mode Block -CandidateKey 'Notepad++'" }).Count -eq 1) { Ok 'only a Low candidate -> the declare command names it with -CandidateKey' } else { Bad "low: $($h -join ' | ')" }

    Write-Host '[2] hostile guest output' -ForegroundColor Cyan
    $hostile = @(
        (Cand @{ DisplayName = "Note`rpad++`n$([char]0x1B)[31m"; Publisher = "Notepad++ Team$([char]0x202E)"; Unknown = 'dropped'; DisplayVersion = "8.8.9$([char]0x2028)" })
        (Cand @{ Key = 'HKLM\Evil' })
        (Cand @{ Key = '..' })
        (Cand @{ View = 'native' })
        (Cand @{ UninstallerFolder = 'C:\Program Files\..\Windows'; UninstallerLeaf = '..\cmd.exe'; DisplayIconLeaf = '..\x.exe'; Exes = @('..\evil.exe', 'C:\abs.exe') })
    )
    $cs = Run (New-CandProject 'hostile' $hostile)
    $c = $cs[0]
    if ($cs.Count -eq 2 -and $c.DisplayName -notmatch '[\r\n\x1B]' -and $c.Publisher -notmatch [char]0x202E -and $c.ObservedVersion -notmatch [char]0x2028 -and -not $c.PSObject.Properties['Unknown']) { Ok 'CR/LF, ESC, bidi and line separators neutralised; unknown fields dropped; bad keys and views dropped' } else { Bad "hostile: $($cs | ConvertTo-Json -Compress)" }
    $h = $cs[1]
    if ($h.InstallDir -eq '' -and $h.UninstallerFileName -eq '' -and $h.MainExe -eq '' -and @($h.ProcessNames).Count -eq 0) { Ok "a '..' folder, traversal leaves and absolute exes -> emptied (Block/Report only)" } else { Bad "traversal: $($h | ConvertTo-Json -Compress)" }
    $pb = New-CandProject 'big' $null ('[' + ('{"Key":"x"},' * 800000) + '{}]')
    $w = $null
    $cs = @(Get-Win32ToolkitPriorInstallCandidate -ProjectPath $pb -Baseline $baseline -WarningVariable w -WarningAction SilentlyContinue 6>$null)
    if ($cs.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $pb 'Documentation\PriorInstallCandidates.json')) -and @($w).Count -eq 1 -and "$($w[0])" -match 'larger than 1 MB') { Ok 'a 10 MB guest file -> nothing written, one warning' } else { Bad "big: $($cs.Count) $($w -join '|')" }
    $pn = New-CandProject 'none' @()
    Remove-Item -LiteralPath (Join-Path $pn 'Sandbox\Logs\PriorCandidates.json')
    if ((Run $pn).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $pn 'Documentation\PriorInstallCandidates.json'))) { Ok 'no guest file -> nothing' } else { Bad 'none' }
    $pj = New-CandProject 'junk' $null '{ not json'
    $w = $null
    $cs = @(Get-Win32ToolkitPriorInstallCandidate -ProjectPath $pj -Baseline $baseline -WarningVariable w -WarningAction SilentlyContinue 6>$null)
    if ($cs.Count -eq 0 -and @($w).Count -eq 1) { Ok 'unparsable guest JSON -> nothing written, one warning' } else { Bad 'junk' }

    Write-Host '[3] the guest reads an uninstaller with the deploy script''s rule (Windows PowerShell 5.1)' -ForegroundColor Cyan
    $ps51 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $pg = Join-Path $root 'gen'
    $null = New-Item -ItemType Directory -Path (Join-Path $pg 'SupportFiles') -Force
    $sp = New-UpdateAssertionScript -ProjectPath $pg -OldVersion '1.0'
    $text = [IO.File]::ReadAllText($sp)
    $fn = [regex]::Match($text, '(?s)function Get-UninstallerParts.*?\r?\n}\r?\n').Value
    if ($fn -and (Test-Path -LiteralPath $ps51)) {
        $h = $fn + @'
foreach ($c in @('"C:\Program Files\App\uninstall.exe" /S', 'C:\Program Files\App\uninstall.exe /S', '"C:\PROGRA~1\App\uninstall.exe"', '"C:\Program Files\App\..\App\uninstall.exe"', 'MsiExec.exe /X{1}', '')) {
    $r = Get-UninstallerParts $c; 'P|' + $r.Leaf + '|' + $r.Folder
}
'@
        [IO.File]::WriteAllText("$root\parts.ps1", $h, [Text.UTF8Encoding]::new($true))
        $o = @(& $ps51 -NoProfile -ExecutionPolicy Bypass -File "$root\parts.ps1" 2>&1 | ForEach-Object { "$_" })
        $want = @('P|uninstall.exe|C:\Program Files\App', 'P|uninstall.exe|C:\Program Files\App', 'P||', 'P||', 'P||', 'P||')
        if (($o -join ';') -ceq ($want -join ';')) { Ok 'quoted and unquoted .exe paths read; an 8.3 name, a relative part, msiexec and an empty command give nothing' } else { Bad "parts: $($o -join ';')" }
    } else { Bad 'Get-UninstallerParts not found in the generated script (or no Windows PowerShell 5.1)' }
    if ($text -match "Set-Content -LiteralPath \(Join-Path \`$logDir 'PriorCandidates\.json'\)") { Ok 'the guest writes PriorCandidates.json next to its logs when OldArpGone fails' } else { Bad 'PriorCandidates.json writer missing' }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PriorCandidate tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PriorCandidate test(s) FAILED." -ForegroundColor Red; exit 1 }
