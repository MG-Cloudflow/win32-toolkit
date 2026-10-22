<#
    Installer-identity PR 1 (spec 2.11, 2.12): the technology-switch finding (ID-TECH-SWITCH).

      [1] ConvertFrom-Win32ToolkitArpSurvivor: the real Notepad++ OldArpGone FAIL line, two survivors, a
          WOW6432Node key, an HKCU key, garbage / PASS / empty lines, hostile names (ESC, U+202E), the 10-entry cap.
      [2b] Write-Win32ToolkitTestOutcome records -Baseline and the survivors of the real Notepad++ log end to end.
      [2] Get-Win32ToolkitTechnologySwitch on recorded Update tests (Baseline records): a cross-family FAIL is a
          finding with the spec text; same family, PASS, a newer PASS of the family -> none; a newer Unavailable
          record never hides an older FAIL; two families (a Both test) are judged separately.
      [3] Records written before PR 1 (no Baseline): judged only when newest, without TattooBaseline-PreUpdate
          and when Sandbox\OldVersion matches the generated $expectedOldVersion; then Legacy with the
          manifest's type and version and the log's survivors. An Unavailable -FamilyPin baseline download (the real
          Download-OldVersionInstaller, winget shadowed) leaves Sandbox\OldVersion as it was, so the legacy FAIL is
          still judged after it (L21).
      [4] Robustness: a corrupt TestResults.json, no records, an unknown package family -> no finding, no throw.
      [5] File hygiene: every Get-Content passes -Encoding; every catch of the new WP-4 files starts with the
          C-2 line (K1); ASCII-only; one function per file, no top-level code.

    No network, no winget, nothing installed. Fixtures are copied to %TEMP%.

    Run:  pwsh -File Tests\TechnologySwitch.unit.ps1
#>
# Test shadows keep the real command names (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\ConvertFrom-Win32ToolkitArpSurvivor.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerFamily.ps1')
. (Join-Path $repo 'Private\Get-WingetManifestFile.ps1')
. (Join-Path $repo 'Private\Add-Win32ToolkitTestResult.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitTestResult.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitTechnologySwitch.ps1')
. (Join-Path $repo 'Private\Write-Win32ToolkitTestOutcome.ps1')

# The package's technology (WP-3 contract, shadowed): a WiX MSI, like Notepad++ 8.9.8.1 x64 from winget.
$script:source = [pscustomobject]@{ InstallerType = 'wix'; Family = 'msi'; Rebuilt = $true }
$script:sourceCalls = 0
function Get-Win32ToolkitProjectSource { param($ProjectPath) $script:sourceCalls++; $script:source }

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32ts_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
function New-Proj {
    $p = Join-Path $tmpRoot ('p_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    $p
}
$nppLine = '[2026-10-19 11:01:39] ASSERT OldArpGone-PostUpdate = FAIL (old version still registered: Notepad++ (64-bit x64) [Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++])'
$nppSurvivor = @{ DisplayName = 'Notepad++ (64-bit x64)'; Key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'; KeyLeaf = 'Notepad++'; View = 'Native' }
$failA = @(@{ Name = 'Requirement-PreUpdate'; Result = 'SKIP' }, @{ Name = 'OldArpGone-PostUpdate'; Result = 'FAIL' }, @{ Name = 'Tattoo-PostUpdate'; Result = 'PASS' })
$passA = @(@{ Name = 'OldArpGone-PostUpdate'; Result = 'PASS' }, @{ Name = 'Tattoo-PostUpdate'; Result = 'PASS' })
function New-Baseline([string]$Type, [string]$Family, [string]$Version = '8.8.9', [switch]$Unavailable) {
    @{ Version = $Version; Mode = 'Auto'; Origin = 'Sibling'; RequestedInstallerType = $Type; InstallerType = $(if ($Unavailable) { '' } else { $Type })
       Family = $Family; UsedFallback = $false; FallbackReason = ''; RequestedScope = 'machine'; Scope = 'machine'; ScopeRelaxed = $false
       Unavailable = [bool]$Unavailable; Locale = 'en-US'; Source = 'winget'; ProjectName = '' }
}
function Add-Rec($Proj, $Verdict, $Assertions, $Baseline, $Survivors) {
    $a = @{ ProjectPath = $Proj; Scenario = 'Update'; Backend = 'HyperV'; Verdict = $Verdict; Mode = 'Unattended'; Assertions = $Assertions }
    if ($Baseline) { $a['Baseline'] = $Baseline }
    if ($Survivors) { $a['OldArpSurvivors'] = $Survivors }
    $null = Add-Win32ToolkitTestResult @a
}
$expectedMsg = "Technology switch: the vendor nullsoft install of v8.8.9 (Notepad++ (64-bit x64), ARP key 'Notepad++') was still registered after the wix package installed. Devices that have the vendor EXE install get two registrations over one folder. Do not publish this package to them; see docs/packaging.md, Installer technology."

try {
    # -- [1] the survivor parser ------------------------------------------------------------------------
    Write-Host '[1] ConvertFrom-Win32ToolkitArpSurvivor' -ForegroundColor Cyan
    $s = @(ConvertFrom-Win32ToolkitArpSurvivor -Line $nppLine)
    if ($s.Count -eq 1 -and $s[0].DisplayName -eq 'Notepad++ (64-bit x64)' -and $s[0].Key -eq 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++' -and
        $s[0].KeyLeaf -eq 'Notepad++' -and $s[0].View -eq 'Native') { Ok 'the real Notepad++ line -> one survivor (provider prefix dropped, HKLM, KeyLeaf Notepad++, Native)' }
    else { Bad "npp: $($s | ConvertTo-Json -Compress)" }

    $two = 'ASSERT OldArpGone-PostUpdate = FAIL (old version still registered: Acme [x64] [Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{11111111-2222-3333-4444-555555555555}]; Acme Helper [Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\AcmeHelper])'
    $s2 = @(ConvertFrom-Win32ToolkitArpSurvivor -Line $two)
    if ($s2.Count -eq 2) { Ok 'two survivors parsed' } else { Bad "two: count $($s2.Count)" }
    if ($s2[0].DisplayName -eq 'Acme [x64]' -and $s2[0].View -eq 'Wow6432' -and $s2[0].KeyLeaf -eq '{11111111-2222-3333-4444-555555555555}' -and
        $s2[0].Key -like 'HKLM\SOFTWARE\WOW6432Node\*') { Ok 'a WOW6432Node key -> View Wow6432 (a name with [brackets] is kept whole)' } else { Bad "wow: $($s2[0] | ConvertTo-Json -Compress)" }
    if ($s2[1].DisplayName -eq 'Acme Helper' -and $s2[1].View -eq 'User' -and $s2[1].Key -like 'HKCU\SOFTWARE\*' -and $s2[1].KeyLeaf -eq 'AcmeHelper') { Ok 'an HKCU key -> View User, HKCU prefix' } else { Bad "hkcu: $($s2[1] | ConvertTo-Json -Compress)" }

    $none = @(
        @(ConvertFrom-Win32ToolkitArpSurvivor -Line 'ASSERT OldArpGone-PostUpdate = PASS'),
        @(ConvertFrom-Win32ToolkitArpSurvivor -Line 'ASSERT OldArpGone-PostUpdate = SKIP (no old-app ARP entry identified)'),
        @(ConvertFrom-Win32ToolkitArpSurvivor -Line 'garbage [x] not an assertion'),
        @(ConvertFrom-Win32ToolkitArpSurvivor -Line ''),
        @(ConvertFrom-Win32ToolkitArpSurvivor -Line $null),
        @(ConvertFrom-Win32ToolkitArpSurvivor -Line 'ASSERT OldArpGone-PostUpdate = FAIL (old version still registered: no key here)')
    ) | ForEach-Object { $_.Count }
    if (@($none | Where-Object { $_ -ne 0 }).Count -eq 0) { Ok 'PASS / SKIP / garbage / empty / $null / no [key] -> nothing' } else { Bad "non-empty: $($none -join ',')" }

    $esc = [char]27; $rlo = [char]0x202E
    $hostile = "ASSERT OldArpGone-PostUpdate = FAIL (old version still registered: Evil$esc[31mRed${rlo}exe [Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Ev${esc}il])"
    $h = @(ConvertFrom-Win32ToolkitArpSurvivor -Line $hostile)
    $allText = (@($h | ForEach-Object { $_.DisplayName; $_.Key; $_.KeyLeaf }) -join '|')
    if ($h.Count -eq 1 -and $allText -notmatch '[\x00-\x1f\u202e]' -and $h[0].DisplayName -like 'Evil?*Red?exe' -and $h[0].KeyLeaf -eq 'Ev?il') { Ok 'hostile ESC / U+202E in the name and the key -> ? (no control or bidi character survives)' }
    else { Bad "hostile: $($h | ConvertTo-Json -Compress)" }

    $many = 'ASSERT OldArpGone-PostUpdate = FAIL (old version still registered: ' + ((1..12 | ForEach-Object { "App$_ [HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\App$_]" }) -join '; ') + ')'
    $m = @(ConvertFrom-Win32ToolkitArpSurvivor -Line $many)
    if ($m.Count -eq 10 -and $m[9].KeyLeaf -eq 'App10' -and $m[0].Key -eq 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\App1') { Ok 'at most 10 entries; a key without the provider prefix is accepted' } else { Bad "cap: $($m.Count)" }

    # -- [2] records with a Baseline --------------------------------------------------------------------
    Write-Host '[2] Get-Win32ToolkitTechnologySwitch on Baseline records' -ForegroundColor Cyan
    $p = New-Proj
    Add-Rec $p 'Failed' $failA (New-Baseline nullsoft exe) @($nppSurvivor)
    $f = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)
    if ($f.Count -eq 1 -and $f[0].Code -eq 'ID-TECH-SWITCH' -and $f[0].Message -eq $expectedMsg) { Ok 'FAIL with a vendor EXE (exe) baseline under a WiX package (msi) -> one ID-TECH-SWITCH with the spec text' }
    else { Bad "finding: $($f | ConvertTo-Json -Compress -Depth 5)" }
    if ($f.Count -eq 1 -and $f[0].PackageType -eq 'wix' -and $f[0].PackageFamily -eq 'msi' -and $f[0].BaselineType -eq 'nullsoft' -and $f[0].BaselineFamily -eq 'exe' -and
        $f[0].BaselineVersion -eq '8.8.9' -and -not $f[0].Legacy -and @($f[0].Survivors).Count -eq 1 -and $f[0].TimestampUtc -match '^\d{4}-\d{2}-\d{2}T') { Ok 'finding fields: package/baseline type and family, version, survivors, ISO timestamp, Legacy false' }
    else { Bad "fields: $($f | ConvertTo-Json -Compress -Depth 5)" }
    if (@($f[0].Message.ToCharArray() | Where-Object { [int]$_ -gt 126 -or [int]$_ -lt 32 }).Count -eq 0) { Ok 'the message is printable ASCII' } else { Bad 'non-ASCII message' }

    $p = New-Proj
    Add-Rec $p 'Failed' $failA (New-Baseline wix msi) @($nppSurvivor)
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 0) { Ok 'same family (msi over msi) FAIL -> none (not a technology switch)' } else { Bad 'same family reported' }

    $p = New-Proj
    Add-Rec $p 'Passed' $passA (New-Baseline nullsoft exe)
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 0) { Ok 'PASS -> none' } else { Bad 'PASS reported' }

    $p = New-Proj
    Add-Rec $p 'Failed' $failA (New-Baseline nullsoft exe) @($nppSurvivor)
    Add-Rec $p 'Passed' $passA (New-Baseline nullsoft exe '8.8.8')
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 0) { Ok 'a newer PASS of the same family after an older FAIL -> none (latest record per family)' } else { Bad 'older FAIL still judged' }

    $p = New-Proj
    Add-Rec $p 'Failed' $failA (New-Baseline nullsoft exe) @($nppSurvivor)
    Add-Rec $p 'Inconclusive' @() (New-Baseline nullsoft exe '8.8.7' -Unavailable)
    $fu = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)
    if ($fu.Count -eq 1 -and $fu[0].BaselineVersion -eq '8.8.9') { Ok 'a newer Unavailable record never hides the older FAIL of its family (L21)' } else { Bad "unavailable: $($fu.Count)" }

    $p = New-Proj
    Add-Rec $p 'Failed' $failA (New-Baseline nullsoft exe) @($nppSurvivor)
    Add-Rec $p 'Passed' $passA (New-Baseline wix msi)
    $fb = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)
    if ($fb.Count -eq 1 -and $fb[0].BaselineFamily -eq 'exe') { Ok 'two families (a Both test): the msi PASS does not hide the exe FAIL (judged separately)' } else { Bad "both: $($fb.Count)" }

    $p = New-Proj
    Add-Rec $p 'Failed' $failA (New-Baseline nullsoft exe)
    $fn = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)
    if ($fn.Count -eq 1 -and $fn[0].Message -like 'Technology switch: the vendor nullsoft install of v8.8.9 was still registered after the wix package installed.*') { Ok 'no survivors recorded -> the message drops the name/key part' } else { Bad "nosurv: $($fn.Message)" }

    $script:sourceCalls = 0
    $fp = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p -PackageType 'nullsoft' -PackageFamily 'exe')
    if ($fp.Count -eq 0 -and $script:sourceCalls -eq 0) { Ok '-PackageType/-PackageFamily override the source (exe package, exe baseline -> none; source not read)' } else { Bad "override: $($fp.Count) calls $script:sourceCalls" }

    $p = New-Proj
    Add-Rec $p 'Failed' $failA (New-Baseline 'pwa' 'other') @($nppSurvivor)
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 0) { Ok "an unknown baseline family ('other') -> none" } else { Bad 'other family reported' }

    # -- [2b] the recorder, end to end ----------------------------------------------------------------------
    Write-Host '[2b] Write-Win32ToolkitTestOutcome: -Baseline and the OldArpGone survivors reach the record' -ForegroundColor Cyan
    $p = New-Proj
    New-Item -ItemType Directory -Path (Join-Path $p 'Sandbox\Logs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'Sandbox\Logs\UpdateAssertions.log') -Encoding UTF8 -Value @(
        '[2026-10-19 11:01:39] === Phase: PostUpdate ===', '[2026-10-19 11:01:39] ASSERT Requirement-PostUpdate = SKIP (disabled)', $nppLine,
        '[2026-10-19 11:01:39] ASSERT Tattoo-PostUpdate = PASS', '[2026-10-19 11:01:39] RESULT COMPLETE')
    Write-Win32ToolkitTestOutcome -ProjectPath $p -Scenario Update -Backend HyperV -Mode Interactive -Verdict $false -Baseline (New-Baseline nullsoft exe)
    $rec = (Get-Win32ToolkitTestResult -ProjectPath $p)[-1]
    if ($rec.Verdict -eq 'Failed' -and $rec.Baseline.Family -eq 'exe' -and @($rec.OldArpSurvivors).Count -eq 1 -and $rec.OldArpSurvivors[0].KeyLeaf -eq 'Notepad++' -and
        $rec.OldArpSurvivors[0].DisplayName -eq 'Notepad++ (64-bit x64)' -and @($rec.Assertions | Where-Object { $_.Name -eq 'OldArpGone-PostUpdate' -and $_.Result -eq 'FAIL' }).Count -eq 1) { Ok 'the FAIL line of the log becomes OldArpSurvivors; -Baseline is recorded' }
    else { Bad "recorded: $($rec | ConvertTo-Json -Compress -Depth 5)" }
    $fe = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)
    if ($fe.Count -eq 1 -and $fe[0].Message -eq $expectedMsg) { Ok 'recorder + finder: the Notepad++ evidence gives the spec message' } else { Bad "e2e: $($fe | ConvertTo-Json -Compress -Depth 5)" }
    Write-Win32ToolkitTestOutcome -ProjectPath $p -Scenario InstallUninstall -Backend HyperV -Verdict $false
    $rec2 = (Get-Win32ToolkitTestResult -ProjectPath $p)[-1]
    if (-not $rec2.PSObject.Properties['OldArpSurvivors'] -and -not $rec2.PSObject.Properties['Baseline']) { Ok 'InstallUninstall: no survivors, no Baseline (the old record shape)' } else { Bad 'IU record got Update fields' }
    Set-Content -LiteralPath (Join-Path $p 'Sandbox\Logs\UpdateAssertions.log') -Encoding UTF8 -Value @($nppLine, '[t] ASSERT OldArpGone-PostUpdate = PASS', '[t] RESULT COMPLETE')
    Write-Win32ToolkitTestOutcome -ProjectPath $p -Scenario Update -Backend HyperV -Verdict $true
    $rec3 = (Get-Win32ToolkitTestResult -ProjectPath $p)[-1]
    if (-not $rec3.PSObject.Properties['OldArpSurvivors'] -and -not $rec3.PSObject.Properties['Baseline']) { Ok 'a later PASS line of the same assertion wins: no survivors; no -Baseline -> no Baseline' } else { Bad "pass: $($rec3 | ConvertTo-Json -Compress -Depth 5)" }
    # -- [3] records from before PR 1 -------------------------------------------------------------------
    Write-Host '[3] Legacy records (no Baseline): the L5 conditions' -ForegroundColor Cyan
    function New-LegacyProj([string]$Expected = '8.8.9', [switch]$NoLog) {
        $lp = New-Proj
        $ov = Join-Path $lp 'Sandbox\OldVersion'; New-Item -ItemType Directory -Path $ov -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'Tests\Fixtures\winget-manifests\Notepad++.Notepad++\8.8.9.installer.yaml') -Destination (Join-Path $ov 'Notepad++_8.8.9_Machine_X64_nullsoft_en-US.yaml')
        [System.IO.File]::WriteAllText((Join-Path $lp 'Sandbox\UpdateAssertions.ps1'), "param([string]`$Phase)`r`n`$candidateNames = @('Notepad++')`r`n`$expectedOldVersion = '$Expected'`r`n", $utf8)
        if (-not $NoLog) {
            New-Item -ItemType Directory -Path (Join-Path $lp 'Sandbox\Logs') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $lp 'Sandbox\Logs\UpdateAssertions.log') -Encoding UTF8 -Value @(
                '[2026-10-19 10:58:08] === Phase: PreUpdate ===', $nppLine, '[2026-10-19 11:01:39] ASSERT Tattoo-PostUpdate = PASS', '[2026-10-19 11:01:39] RESULT COMPLETE')
        }
        $lp
    }
    $p = New-LegacyProj
    Add-Rec $p 'Failed' $failA $null $null
    $fl = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)
    if ($fl.Count -eq 1 -and $fl[0].Legacy -and $fl[0].BaselineVersion -eq '8.8.9' -and $fl[0].BaselineType -eq 'nullsoft' -and $fl[0].BaselineFamily -eq 'exe' -and
        @($fl[0].Survivors).Count -eq 1 -and $fl[0].Message -eq $expectedMsg) { Ok 'legacy FAIL + OldVersion nullsoft 8.8.9 + $expectedOldVersion 8.8.9 + log -> finding (Legacy, v8.8.9, survivor from the log)' }
    else { Bad "legacy: $($fl | ConvertTo-Json -Compress -Depth 5)" }

    $p = New-LegacyProj -NoLog
    Add-Rec $p 'Failed' $failA $null $null
    $fl2 = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)
    if ($fl2.Count -eq 1 -and @($fl2[0].Survivors).Count -eq 0) { Ok 'legacy without the log -> finding without survivors' } else { Bad "legacy nolog: $($fl2.Count)" }

    $p = New-LegacyProj
    Add-Rec $p 'Failed' ($failA + @(@{ Name = 'TattooBaseline-PreUpdate'; Result = 'PASS' })) $null $null
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 0) { Ok 'legacy record with TattooBaseline-PreUpdate (a project baseline) -> none' } else { Bad 'project-baseline legacy record judged' }

    $p = New-LegacyProj -Expected '8.8.8'
    Add-Rec $p 'Failed' $failA $null $null
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 0) { Ok "`$expectedOldVersion = '8.8.8' does not match the OldVersion manifest (8.8.9) -> none" } else { Bad 'stale OldVersion judged' }

    $p = New-LegacyProj
    Add-Rec $p 'Failed' $failA $null $null
    Add-Rec $p 'Passed' $passA (New-Baseline wix msi '8.8.9')
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 0) { Ok 'legacy record that is not the newest Update record -> ignored' } else { Bad 'older legacy record judged' }

    $p = New-LegacyProj
    Add-Rec $p 'Failed' $failA $null $null
    $null = Add-Win32ToolkitTestResult -ProjectPath $p -Scenario 'InstallUninstall' -Backend 'HyperV' -Verdict 'Passed'
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 1) { Ok 'a newer InstallUninstall record does not hide the newest Update record' } else { Bad 'IU record hid the Update record' }

    $p = New-LegacyProj
    Add-Rec $p 'Failed' $failA $null $null
    Add-Rec $p 'Inconclusive' @() (New-Baseline nullsoft exe '8.8.7' -Unavailable)
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 1) { Ok 'a newer Unavailable record does not make the legacy record "not newest" (never judged)' } else { Bad 'Unavailable record hid the legacy record' }

    # Installer-identity PR 2: a test the Intune-parity pre-check did not start (NotRun: no Baseline, no assertions) is
    # never judged - not as the newest legacy record (no read of Sandbox\OldVersion and a stale log for it), and it never
    # hides an older record.
    $addNotRun = { param($Proj) $null = Add-Win32ToolkitTestResult -ProjectPath $Proj -Scenario 'Update' -Backend 'HyperV' -Mode 'Unattended' -Verdict 'Inconclusive' -Assertions @() `
            -Notes 'Not run (Intune-parity pre-check): x' -NotRun @{ Code = 'PARITY-DIALOG-WAIT'; Shape = 'Psadt41'; ProcessesToClose = 0; Welcome = 'OrgUi'; SignedInSessions = 1 } }
    $p = New-LegacyProj
    Add-Rec $p 'Failed' $failA $null $null
    & $addNotRun $p
    $fnr = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)
    if ($fnr.Count -eq 1 -and $fnr[0].Legacy -and $fnr[0].BaselineVersion -eq '8.8.9') { Ok 'a newer NotRun record does not make the legacy FAIL "not newest" (still judged)' } else { Bad "legacy + NotRun: $($fnr | ConvertTo-Json -Compress -Depth 5)" }
    $realManifest = ${function:Get-WingetManifestFile}
    $script:manifestReads = 0
    ${function:Get-WingetManifestFile} = { param([string]$Path, [string]$Kind) $script:manifestReads++; & $realManifest -Path $Path -Kind $Kind }
    $p = New-LegacyProj   # a stale Sandbox\OldVersion + UpdateAssertions.log that belong to no recorded run
    Add-Rec $p 'Failed' $failA (New-Baseline nullsoft exe) @($nppSurvivor)
    & $addNotRun $p
    $fnr2 = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)
    if ($fnr2.Count -eq 1 -and -not $fnr2[0].Legacy -and $fnr2[0].Message -eq $expectedMsg -and $script:manifestReads -eq 0) { Ok 'a newest NotRun record is skipped: no legacy-path read of the stale log; the older Baseline FAIL is still judged' }
    else { Bad "NotRun newest: reads=$script:manifestReads findings=$($fnr2 | ConvertTo-Json -Compress -Depth 5)" }
    ${function:Get-WingetManifestFile} = $realManifest

    # End to end with the real -FamilyPin download (winget shadowed: no type of the family is offered): the
    # Unavailable run leaves Sandbox\OldVersion paired with UpdateAssertions.ps1, so the legacy FAIL is still judged (L21).
    . (Join-Path $repo 'Private\Test-Win32ToolkitWingetNoApplicableInstaller.ps1')
    . (Join-Path $repo 'Private\Invoke-Win32ToolkitWingetDownload.ps1')   # every winget download runs through it (C-9)
    . (Join-Path $repo 'Private\Download-OldVersionInstaller.ps1')
    function Get-Win32ToolkitPipelineCacheRoot { $null }
    $script:wingetCalls = 0
    function winget { $script:wingetCalls++; $global:LASTEXITCODE = -1978335216 }   # 0x8A150010 no applicable installer, every type
    $p = New-LegacyProj
    Add-Rec $p 'Failed' $failA $null $null
    $ovBefore = @(Get-ChildItem -LiteralPath (Join-Path $p 'Sandbox\OldVersion') -Force | ForEach-Object Name)
    $err = $null
    try { $null = Download-OldVersionInstaller -AppId 'Notepad++.Notepad++' -Version '8.8.7' -ProjectPath $p -Architecture x64 -Scope machine -InstallerType nullsoft -FamilyPin 6>$null 3>$null } catch { $err = $_ }
    Add-Rec $p 'Inconclusive' @() (New-Baseline nullsoft exe '8.8.7' -Unavailable)
    $ovAfter = @(Get-ChildItem -LiteralPath (Join-Path $p 'Sandbox\OldVersion') -Force | ForEach-Object Name)
    $fa = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)
    if ($err -and $err.FullyQualifiedErrorId -eq 'W32T.InstallerVariantUnavailable' -and $script:wingetCalls -eq 8 -and ($ovAfter -join ',') -eq ($ovBefore -join ',') -and $ovAfter -contains 'Notepad++_8.8.9_Machine_X64_nullsoft_en-US.yaml') { Ok 'an Unavailable -FamilyPin download (8 attempts) leaves Sandbox\OldVersion as it was' }
    else { Bad "unavailable download: fqid=$($err.FullyQualifiedErrorId) calls=$script:wingetCalls before=$($ovBefore -join ',') after=$($ovAfter -join ',')" }
    if ($fa.Count -eq 1 -and $fa[0].Legacy -and $fa[0].BaselineVersion -eq '8.8.9' -and $fa[0].BaselineType -eq 'nullsoft' -and $fa[0].Message -eq $expectedMsg) { Ok 'the legacy FAIL is still judged after the Unavailable run (ID-TECH-SWITCH, Legacy, v8.8.9)' }
    else { Bad "legacy after unavailable: $($fa | ConvertTo-Json -Compress -Depth 5)" }

    $p = New-Proj
    Add-Rec $p 'Failed' $failA $null $null
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 0) { Ok 'legacy record without Sandbox\OldVersion -> none' } else { Bad 'legacy without OldVersion judged' }

    # -- [4] robustness ---------------------------------------------------------------------------------
    Write-Host '[4] Robustness: never throws' -ForegroundColor Cyan
    $p = New-Proj
    New-Item -ItemType Directory -Path (Join-Path $p 'Documentation') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $p 'Documentation\TestResults.json') -Value '{ not json ][' -Encoding UTF8
    $threw = $false; $r = $null
    try { $r = @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p -ErrorAction Stop 3>$null) } catch { $threw = $true }
    if (-not $threw -and $r.Count -eq 0) { Ok 'corrupt TestResults.json -> no finding, no throw' } else { Bad "corrupt: threw=$threw" }
    $p = New-Proj
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 0) { Ok 'no TestResults.json -> none' } else { Bad 'phantom finding' }
    $script:source = [pscustomobject]@{ InstallerType = ''; Family = ''; Rebuilt = $true }
    $p = New-Proj
    Add-Rec $p 'Failed' $failA (New-Baseline nullsoft exe) @($nppSurvivor)
    if (@(Get-Win32ToolkitTechnologySwitch -ProjectPath $p).Count -eq 0) { Ok 'unknown package technology -> nothing to compare' } else { Bad 'compared against an unknown package family' }
    $script:source = [pscustomobject]@{ InstallerType = 'wix'; Family = 'msi'; Rebuilt = $true }

    # -- [5] file hygiene -------------------------------------------------------------------------------
    Write-Host '[5] -Encoding on every Get-Content; K1; ASCII; one function per file' -ForegroundColor Cyan
    $tsFile = Join-Path $repo 'Private\Get-Win32ToolkitTechnologySwitch.ps1'
    $tsAst = [System.Management.Automation.Language.Parser]::ParseFile($tsFile, [ref]$null, [ref]$null)
    $gc = @($tsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Get-Content', 'gc') }, $true))
    $bare = @($gc | Where-Object { @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Encoding' }).Count -eq 0 })
    if ($gc.Count -ge 3 -and $bare.Count -eq 0) { Ok "Get-Win32ToolkitTechnologySwitch: $($gc.Count) Get-Content call(s), all with -Encoding" } else { Bad "Get-Content without -Encoding: $($bare.Count) of $($gc.Count)" }

    $c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
    $totalCatches = 0
    foreach ($name in 'Get-Win32ToolkitTechnologySwitch', 'ConvertFrom-Win32ToolkitArpSurvivor', 'Resolve-Win32ToolkitBaselineFamily') {
        $file = Join-Path $repo "Private\$name.ps1"
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
        $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        $totalCatches += $catches.Count
        $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
        $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
        $top = @($ast.EndBlock.Statements)
        $oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq $name -and
                       -not $ast.BeginBlock -and -not $ast.ProcessBlock -and -not $ast.ParamBlock
        if (@($errs).Count -eq 0 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "$name : $($catches.Count) catch(es) with the C-2 line, ASCII, one function, no top-level code" }
        else { Bad "$name : parse errors $(@($errs).Count), bad catches $($badCatch.Count), ascii $ascii, oneFunction $oneFunction" }
    }
    if ($totalCatches -ge 3) { Ok "$totalCatches catch clauses checked" } else { Bad "only $totalCatches catch clauses found - the K1 scan looks wrong" }
}
finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TechnologySwitch tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TechnologySwitch test(s) FAILED." -ForegroundColor Red; exit 1 }
