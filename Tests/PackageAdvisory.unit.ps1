<#
    Installer-identity PR 1 (spec 2.13, WP-5): Get-Win32ToolkitPackageAdvisory and
    Write-Win32ToolkitPackageAdvisory, and their call sites (Export, Publish, the TUI publish action).

      Update    : the latest judged record per baseline family -> UPDATE-FAILED (Warning) or
                  UPDATE-INCONCLUSIVE (Info); an Unavailable record never hides an older failure; the
                  legacy (pre-PR-1) record and its Sandbox\OldVersion conditions.
      Identity  : the REAL Get-Win32ToolkitIdentityDelta over a stored IdentityDelta.json built from the
                  Tests\Fixtures\winget-manifests manifests (Invoke-WebRequest shadowed: no network);
                  ID-SIBLING-UNTESTED and the Info downgrade of ID-SIBLING-FAMILY.
      WP-4      : Get-Win32ToolkitTechnologySwitch is SHADOWED (its spec 2.12 contract).
      Cleanup   : UNSAFE-CLEANUP at Publish / Tui only (Get-Win32ToolkitCleanupPathFinding shadowed), also
                  for an AppConfig.json PowerShell 7 cannot read ('+1': Windows PowerShell 5.1 still reads it).
      Fail-open : a corrupt TestResults.json or a throwing helper -> warnings, never a throw.
      Writer    : prefixes, the run scope (printed once, at most one probe request), nothing written; a
                  relative -ProjectPath is resolved against the PowerShell location (prefix and scope key).
      Source    : K1 / K4 first statements; Export / Publish / TUI call order and run scope (AST);
                  D1 (no W32T.UpdateTestFailed, no -AllowFailedUpdateTest).

    Fixtures are built under %TEMP% and removed at the end; nothing is installed or run.

    Run:  pwsh -File Tests\PackageAdvisory.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: new files carry no PSSA warning).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Invoke-WebRequest is shadowed: the suite never touches the network')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test fixture builders')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# Every Private helper is real (each file defines only its function), then the shadows below win.
Get-ChildItem (Join-Path $repo 'Private') -Filter *.ps1 | ForEach-Object { . $_.FullName }
$realCleanup = ${function:Get-Win32ToolkitCleanupPathFinding}
$realDeltaFile = Join-Path $repo 'Private\Get-Win32ToolkitIdentityDelta.ps1'

# --- Network: the sibling probe's only request, counted ----------------------------------------------
$fx = Join-Path $repo 'Tests\Fixtures\winget-manifests'
$script:gets = 0
$script:body = ''
function Invoke-WebRequest {
    [CmdletBinding()]
    param([string]$Uri, [int]$TimeoutSec, [int]$MaximumRedirection, [switch]$SkipHttpErrorCheck)
    $script:gets++
    [pscustomobject]@{ StatusCode = 200; Content = $script:body }
}

# --- WP-4 contract (spec 2.12), shadowed: the technology switches the Update tests saw ----------------
$script:switches = @()
$script:switchArgs = $null
function Get-Win32ToolkitTechnologySwitch {
    [CmdletBinding()]
    param([string]$ProjectPath, [string]$PackageType, [string]$PackageFamily)
    $script:switchArgs = [pscustomobject]$PSBoundParameters
    if ($script:switches -is [scriptblock]) { return & $script:switches }
    $script:switches
}

# --- WP-1 finding helper, shadowed ($script:cleanupReal = $true runs the real one) --------------------
$script:cleanup = @()
$script:cleanupReal = $false
$script:cleanupCalls = 0
function Get-Win32ToolkitCleanupPathFinding {
    [CmdletBinding()]
    param([string]$ProjectPath)
    $script:cleanupCalls++
    if ($script:cleanupReal) { return & $realCleanup -ProjectPath $ProjectPath }
    $script:cleanup
}

# --- Fixture builders ----------------------------------------------------------------------------------
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32adv_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:n = 0
function Set-TestResultFile([string]$Project, [object[]]$Entries) {
    $doc = Join-Path $Project 'Documentation'
    New-Item -ItemType Directory -Path $doc -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $doc 'TestResults.json'), (ConvertTo-Json -InputObject @($Entries) -Depth 6), [System.Text.UTF8Encoding]::new($false))
}
# One Update record in the spec 2.11 shape (or, with -Legacy, the pre-PR-1 shape without Baseline).
function New-Record {
    param([string]$Verdict = 'Failed', [string]$Type = 'nullsoft', [string]$Family = 'exe', [string]$Version = '8.8.9',
          [string]$When = '2026-10-19T11:03:09Z', [string[]]$Fail = @('OldArpGone-PostUpdate'), [string[]]$Pass = @('Tattoo-PostUpdate'),
          [switch]$Unavailable, [switch]$Legacy, [string]$Mode = 'Auto', [string]$Origin = 'Sibling')
    $assertions = @(@($Pass | ForEach-Object { [ordered]@{ Name = $_; Result = 'PASS' } }) + @($Fail | ForEach-Object { [ordered]@{ Name = $_; Result = 'FAIL' } }))
    $r = [ordered]@{ Scenario = 'Update'; Backend = 'HyperV'; Mode = 'Unattended'; TimestampUtc = $When; Verdict = $Verdict; Assertions = $assertions; Notes = '' }
    if ($Unavailable) { $r.Verdict = 'Inconclusive'; $r.Assertions = @(); $r.Notes = 'Baseline unavailable: winget offers no installer' }
    if (-not $Legacy) {
        $r['Baseline'] = [ordered]@{
            Version = $Version; Mode = $Mode; Origin = $Origin; RequestedInstallerType = $Type; InstallerType = $(if ($Unavailable) { '' } else { $Type })
            Family = $Family; UsedFallback = $false; FallbackReason = ''; RequestedScope = 'machine'; Scope = 'machine'; ScopeRelaxed = $false
            Unavailable = [bool]$Unavailable; Locale = 'en-US'; Source = 'winget'; ProjectName = ''
        }
    }
    [pscustomobject]$r
}
# A project with a persisted AppConfig.Source; -Manifest stores Documentation\IdentityDelta.json from a
# real (shadowed-network) sibling probe of that fixture, exactly as configure time writes it.
function New-AdvProject {
    param([string]$Name = 'Notepad++_x64_8.9.8.1', [hashtable]$Source = @{}, [hashtable]$App = @{}, [object[]]$Results, [string]$Manifest = '')
    $script:n++
    $p = Join-Path $tmpRoot ('Projects\T{0}\{1}' -f $script:n, $Name)
    New-Item -ItemType Directory -Path (Join-Path $p 'SupportFiles') -Force | Out-Null
    $src = [ordered]@{
        SchemaVersion = '1.0'; WingetId = 'Notepad++.Notepad++'; Version = '8.9.8.1'; InstallerType = 'wix'; Family = 'msi'; Scope = 'machine'
        Architecture = 'x64'; Locale = 'en-US'; PinnedBy = 'winget-default'; RequestedInstallerType = ''; WingetClient = '1.29.380'
        ProductCode = ''; UpgradeCode = ''; UpgradeBehavior = 'install'
    }
    foreach ($k in $Source.Keys) { $src[$k] = $Source[$k] }
    $appCfg = [ordered]@{ Vendor = 'Notepad++ Team'; Name = 'Notepad++'; DisplayName = 'Notepad++'; Version = $src.Version; Arch = 'x64'; ScriptAuthor = 'Contoso IT' }
    foreach ($k in $App.Keys) { $appCfg[$k] = $App[$k] }
    $cfg = [ordered]@{ SchemaVersion = '1.0'; App = $appCfg; Installer = [ordered]@{ Type = $src.InstallerType }; Source = $src }
    [System.IO.File]::WriteAllText((Join-Path $p 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    if ($null -ne $Results) { Set-TestResultFile $p $Results }
    if ($Manifest) {
        $script:body = Get-Content -LiteralPath (Join-Path $fx $Manifest) -Raw -Encoding UTF8
        $script:W32TSiblingProbeMemo = $null
        $null = Write-Win32ToolkitIdentityDelta -ProjectPath $p -Quiet
        $script:W32TSiblingProbeMemo = $null
    }
    $script:gets = 0
    $p
}
function Get-Advisory([string]$Project, [string]$Context = 'Publish', [switch]$Probe) {
    Get-Win32ToolkitPackageAdvisory -ProjectPath $Project -Context $Context -ProbeIfMissing:$Probe 3>$null
}
$allMessages = [System.Collections.Generic.HashSet[string]]::new()
function Codes($a) { foreach ($f in @($a.Findings)) { [void]$allMessages.Add([string]$f.Message) }; (@($a.Findings) | ForEach-Object Code) -join ',' }
function Find($a, [string]$Code) { @($a.Findings) | Where-Object Code -eq $Code | Select-Object -First 1 }
# Every entry by name, every file by size and time. A folder's own time is left out: Windows updates it a
# moment after the fixture files are created, whoever reads the folder.
function Get-Listing([string]$Path) {
    @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
            if ($_.PSIsContainer) { '{0}|d' -f $_.FullName } else { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }
        }) -join "`n"
}

try {
    # ======================== [1] Update records ========================
    Write-Host '[1] Notepad++ 8.9.8.1 wix: a Failed nullsoft (exe) Update record -> UPDATE-FAILED + the identity warnings' -ForegroundColor Cyan
    $npp = New-AdvProject -Results @(New-Record) -Manifest 'Notepad++.Notepad++\8.9.8.1.installer.yaml'
    if (Test-Path -LiteralPath (Join-Path $npp 'Documentation\IdentityDelta.json')) { Ok 'fixture: IdentityDelta.json stored from the Notepad++ 8.9.8.1 manifest' } else { Bad 'fixture: no IdentityDelta.json' }
    $a = Get-Advisory $npp
    if ((Codes $a) -eq 'UPDATE-FAILED,ID-SIBLING-UNTESTED,ID-SIBLING-FAMILY,ID-NO-ANCHOR') { Ok 'codes = UPDATE-FAILED, ID-SIBLING-UNTESTED, ID-SIBLING-FAMILY, ID-NO-ANCHOR (in that order)' } else { Bad "codes = $(Codes $a)" }
    $uf = Find $a 'UPDATE-FAILED'
    $want = 'The latest Update test with a nullsoft (vendor EXE, NSIS) baseline (v8.8.9, HyperV/Unattended, 2026-10-19) FAILED: OldArpGone-PostUpdate. This only warns: publishing continues. Review Sandbox\Logs\UpdateAssertions.log before you assign it.'
    if ($uf.Severity -eq 'Warning' -and $uf.Source -eq 'UpdateTest' -and $uf.Message -ceq $want) { Ok 'UPDATE-FAILED (Warning) names the baseline technology, version, backend, date and OldArpGone-PostUpdate' } else { Bad "UPDATE-FAILED = $($uf | ConvertTo-Json -Compress)" }
    $u = @($a.Update)
    if ($u.Count -eq 1 -and $u[0].BaselineFamily -eq 'exe' -and $u[0].BaselineType -eq 'nullsoft' -and $u[0].BaselineVersion -eq '8.8.9' -and $u[0].Verdict -eq 'Failed' -and
        (@($u[0].FailedAssertions) -join ',') -eq 'OldArpGone-PostUpdate' -and $u[0].Legacy -eq $false -and $u[0].Backend -eq 'HyperV' -and $u[0].Mode -eq 'Unattended' -and $u[0].TimestampUtc -like '2026-10-19T11:03:09*') {
        Ok 'Update = one entry (exe, nullsoft, 8.8.9, Failed, OldArpGone-PostUpdate, HyperV/Unattended, not legacy)'
    } else { Bad "Update = $($a.Update | ConvertTo-Json -Compress -Depth 4)" }
    if ($a.SchemaVersion -eq '1.0' -and $a.PackageType -eq 'wix' -and $a.PackageFamily -eq 'msi') { Ok 'SchemaVersion 1.0, PackageType wix, PackageFamily msi' } else { Bad "header: $($a.SchemaVersion) $($a.PackageType) $($a.PackageFamily)" }
    $su = Find $a 'ID-SIBLING-UNTESTED'
    $wantSu = "winget also ships nullsoft (vendor EXE, NSIS), but no Update test has passed from an exe install. Run: Test-Win32ToolkitProject -ProjectPath '$npp' -Scenario Update -BaselineInstallerType Both"
    if ($su.Severity -eq 'Warning' -and $su.Message -ceq $wantSu) { Ok 'ID-SIBLING-UNTESTED (Warning) names the technology and the -BaselineInstallerType Both command' } else { Bad "ID-SIBLING-UNTESTED = $($su.Message)" }
    if ((Find $a 'ID-SIBLING-FAMILY').Severity -eq 'Warning' -and (Find $a 'ID-SIBLING-FAMILY').Source -eq 'IdentityDelta') { Ok 'ID-SIBLING-FAMILY stays a Warning (no passed exe record), Source IdentityDelta' } else { Bad 'ID-SIBLING-FAMILY severity/source' }
    if ($script:switchArgs.PackageType -eq 'wix' -and $script:switchArgs.PackageFamily -eq 'msi' -and $script:switchArgs.ProjectPath -eq $npp) { Ok 'Get-Win32ToolkitTechnologySwitch gets the project and the packaged type/family' } else { Bad "switch args $($script:switchArgs | ConvertTo-Json -Compress)" }
    if ($script:gets -eq 0) { Ok 'the stored probe is reused: no request' } else { Bad "$($script:gets) request(s)" }
    $ae = Get-Advisory $npp -Context Export
    # Worded so it also holds for Export -WhatIf, which packages nothing (re-verification 2026-10-21, A2 sb#1).
    $aeMsg = (Find $ae 'UPDATE-FAILED').Message
    if ($aeMsg -match 'This only warns: it does not stop packaging\.' -and $aeMsg -notmatch 'is still packaged') { Ok "-Context Export words it 'it does not stop packaging' (no claim that a package was built)" } else { Bad "Export wording: $aeMsg" }

    Write-Host '[2] Passed / Inconclusive / two families (Both) / Unavailable records' -ForegroundColor Cyan
    Set-TestResultFile $npp @(New-Record -Verdict Passed -Fail @())
    $a = Get-Advisory $npp
    $sf = Find $a 'ID-SIBLING-FAMILY'
    if ((Codes $a) -eq 'ID-NO-ANCHOR,ID-SIBLING-FAMILY' -and $sf.Severity -eq 'Info' -and $sf.Message -cmatch ' \(tested: Update from exe passed on 2026-10-19\)$') {
        Ok 'Passed exe record -> no UPDATE-FAILED, no ID-SIBLING-UNTESTED; ID-SIBLING-FAMILY downgraded to Info (tested: ... passed on <date>)'
    } else { Bad "Passed -> $(Codes $a) / $($sf.Severity) / $($sf.Message)" }

    Set-TestResultFile $npp @(New-Record -Verdict Inconclusive -Fail @())
    $a = Get-Advisory $npp
    $ui = Find $a 'UPDATE-INCONCLUSIVE'
    if ((Codes $a) -eq 'ID-SIBLING-UNTESTED,ID-SIBLING-FAMILY,ID-NO-ANCHOR,UPDATE-INCONCLUSIVE' -and $ui.Severity -eq 'Info' -and $ui.Message -match '^The latest Update test with a nullsoft .* gave no verdict \(Inconclusive\)') {
        Ok 'Inconclusive -> UPDATE-INCONCLUSIVE (Info, last); the exe family is still untested'
    } else { Bad "Inconclusive -> $(Codes $a) / $($ui.Message)" }

    Set-TestResultFile $npp @(
        (New-Record -Mode Both -Origin Packaged -Type wix -Family msi -Verdict Passed -Fail @() -When '2026-10-20T08:00:00Z'),
        (New-Record -Mode Both -Origin Sibling -When '2026-10-20T08:30:00Z'))
    $a = Get-Advisory $npp
    $failed = @($a.Findings | Where-Object Code -eq 'UPDATE-FAILED')
    if ($failed.Count -eq 1 -and $failed[0].Message -match 'with a nullsoft \(vendor EXE, NSIS\) baseline' -and @($a.Update).Count -eq 2 -and
        (@($a.Update | ForEach-Object BaselineFamily) -join ',') -eq 'msi,exe' -and (Find $a 'ID-SIBLING-UNTESTED')) {
        Ok 'Both: msi Passed + exe Failed -> one UPDATE-FAILED (the exe leg), two Update entries, exe still untested'
    } else { Bad "Both -> $(Codes $a) / Update $(($a.Update | ConvertTo-Json -Compress -Depth 4))" }
    # Test campaign F2: each run keeps its own logs (LogFolder); UPDATE-FAILED names the failed leg's folder, not the shared top-level log.
    $legPass = New-Record -Mode Both -Origin Packaged -Type wix -Family msi -Verdict Passed -Fail @() -When '2026-10-20T08:00:00Z'
    $legPass | Add-Member -NotePropertyName LogFolder -NotePropertyValue 'Sandbox\Logs\Runs\20261020-100000_Update_msi'
    $legFail = New-Record -Mode Both -Origin Sibling -When '2026-10-20T08:30:00Z'
    $legFail | Add-Member -NotePropertyName LogFolder -NotePropertyValue 'Sandbox\Logs\Runs\20261020-103000_Update_exe'
    Set-TestResultFile $npp @($legPass, $legFail)
    $a = Get-Advisory $npp
    $wantLf = 'The latest Update test with a nullsoft (vendor EXE, NSIS) baseline (v8.8.9, HyperV/Unattended, 2026-10-20) FAILED: OldArpGone-PostUpdate. This only warns: publishing continues. Review Sandbox\Logs\Runs\20261020-103000_Update_exe\UpdateAssertions.log before you assign it.'
    if ((Find $a 'UPDATE-FAILED').Message -ceq $wantLf -and (@($a.Update | ForEach-Object LogFolder) -join ',') -eq 'Sandbox\Logs\Runs\20261020-100000_Update_msi,Sandbox\Logs\Runs\20261020-103000_Update_exe') {
        Ok "a record with its own LogFolder -> UPDATE-FAILED names that run's UpdateAssertions.log; Update entries carry LogFolder"
    } else { Bad "LogFolder -> $((Find $a 'UPDATE-FAILED').Message) / $(@($a.Update | ForEach-Object LogFolder) -join ',')" }
    foreach ($badFolder in 'Sandbox\Logs\Runs\..\..\..\Windows', 'C:\Windows', "Sandbox\Logs\Runs\x`e[2J") {
        $legFail.LogFolder = $badFolder
        Set-TestResultFile $npp @($legFail)
        $a = Get-Advisory $npp
        if ((Find $a 'UPDATE-FAILED').Message -cmatch 'Review Sandbox\\Logs\\UpdateAssertions\.log before you assign it\.$' -and $a.Update[0].LogFolder -eq '') { Ok "a LogFolder outside Sandbox\Logs\Runs\<name> ('$($badFolder -replace "`e", '<ESC>')') is ignored (the record is data)" }
        else { Bad "bad LogFolder -> $((Find $a 'UPDATE-FAILED').Message)" }
    }
    Set-TestResultFile $npp @((New-Record -When '2026-10-19T09:00:00Z'), (New-Record -Unavailable -When '2026-10-20T09:00:00Z'))
    $a = Get-Advisory $npp
    if ((Find $a 'UPDATE-FAILED').Message -match '2026-10-19\) FAILED' -and @($a.Update).Count -eq 1 -and $a.Update[0].Verdict -eq 'Failed') {
        Ok 'a newer Unavailable record of the same family does not hide the older FAIL (UPDATE-FAILED still raised)'
    } else { Bad "Unavailable after Failed -> $(Codes $a)" }
    Set-TestResultFile $npp @((New-Record -Unavailable))
    $a = Get-Advisory $npp
    if (@($a.Update).Count -eq 0 -and -not (Find $a 'UPDATE-FAILED') -and -not (Find $a 'UPDATE-INCONCLUSIVE') -and (Find $a 'ID-SIBLING-UNTESTED')) { Ok 'an Unavailable record alone is never judged (no Update entry, no UPDATE-* finding)' } else { Bad "Unavailable only -> $(Codes $a)" }
    Set-TestResultFile $npp @((New-Record -When '2026-10-19T09:00:00Z'), (New-Record -Verdict Passed -Fail @() -When '2026-10-20T09:00:00Z'))
    $a = Get-Advisory $npp
    if (-not (Find $a 'UPDATE-FAILED') -and (Find $a 'ID-SIBLING-FAMILY').Severity -eq 'Info') { Ok 'an older FAIL followed by a newer PASS of the same family -> no UPDATE-FAILED' } else { Bad "Failed then Passed -> $(Codes $a)" }
    Set-TestResultFile $npp @((New-Record -Verdict Passed -Fail @() -When '2026-10-19T09:00:00Z'), (New-Record -When '2026-10-20T09:00:00Z'))
    $a = Get-Advisory $npp
    $sf = Find $a 'ID-SIBLING-FAMILY'
    if ((Codes $a) -eq 'UPDATE-FAILED,ID-SIBLING-UNTESTED,ID-SIBLING-FAMILY,ID-NO-ANCHOR' -and (Find $a 'UPDATE-FAILED').Message -match '2026-10-20\) FAILED' -and
        $sf.Severity -eq 'Warning' -and $sf.Message -notmatch '\(tested: ') {
        Ok 'an older PASS followed by a newer FAIL of the same family -> UPDATE-FAILED; ID-SIBLING-FAMILY stays a Warning, no (tested: ...) suffix'
    } else { Bad "Passed then Failed -> $(Codes $a) / $($sf.Severity) / $($sf.Message)" }
    $install = [pscustomobject]@{ Scenario = 'InstallUninstall'; Backend = 'Sandbox'; Mode = 'Unattended'; TimestampUtc = '2026-10-21T09:00:00Z'; Verdict = 'Failed'
                                  Assertions = @([pscustomobject]@{ Name = 'Installed'; Result = 'FAIL' }); Notes = '' }
    Set-TestResultFile $npp @($install)
    $a = Get-Advisory $npp
    if (-not (Find $a 'UPDATE-FAILED') -and @($a.Update).Count -eq 0) { Ok 'an InstallUninstall record is not an Update test' } else { Bad "InstallUninstall -> $(Codes $a)" }

    Write-Host '[3] Legacy record (no Baseline): the spec 2.12 conditions decide its technology' -ForegroundColor Cyan
    $old = Join-Path $npp 'Sandbox\OldVersion'
    New-Item -ItemType Directory -Path $old -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $fx 'Notepad++.Notepad++\8.8.9.installer.yaml') -Destination (Join-Path $old 'Notepad++_8.8.9_Machine_X64_nullsoft_en-US.yaml')
    $assertPs1 = Join-Path $npp 'Sandbox\UpdateAssertions.ps1'
    [System.IO.File]::WriteAllText($assertPs1, "# generated (test fixture, never run)`r`n`$expectedOldVersion = '8.8.9'`r`n", [System.Text.UTF8Encoding]::new($true))
    $legacy = New-Record -Legacy -Pass @('Requirement-PreUpdate', 'Tattoo-PostUpdate')
    Set-TestResultFile $npp @($legacy)
    $a = Get-Advisory $npp
    $u = @($a.Update)
    if ($u.Count -eq 1 -and $u[0].Legacy -eq $true -and $u[0].BaselineFamily -eq 'exe' -and $u[0].BaselineType -eq 'nullsoft' -and $u[0].BaselineVersion -eq '8.8.9' -and
        (Find $a 'UPDATE-FAILED').Message -match 'with a nullsoft \(vendor EXE, NSIS\) baseline \(v8\.8\.9,' -and (Find $a 'ID-SIBLING-UNTESTED')) {
        Ok 'legacy winget baseline + OldVersion PackageVersion 8.8.9 = $expectedOldVersion -> exe / nullsoft / 8.8.9, Legacy'
    } else { Bad "legacy -> $(Codes $a) / $($a.Update | ConvertTo-Json -Compress -Depth 4)" }
    Set-TestResultFile $npp @(New-Record -Legacy -Pass @('TattooBaseline-PreUpdate'))
    $a = Get-Advisory $npp
    if ($a.Update[0].BaselineFamily -eq '' -and (Find $a 'UPDATE-FAILED').Message -cmatch '^The latest Update test \(HyperV/Unattended, 2026-10-19\) FAILED: OldArpGone-PostUpdate\.') {
        Ok 'legacy record with TattooBaseline-PreUpdate (a project baseline) -> technology unknown, UPDATE-FAILED still raised (D1)'
    } else { Bad "legacy project baseline -> $(Codes $a) / $((Find $a 'UPDATE-FAILED').Message)" }
    [System.IO.File]::WriteAllText($assertPs1, "`$expectedOldVersion = '8.8.8'`r`n", [System.Text.UTF8Encoding]::new($true))
    Set-TestResultFile $npp @($legacy)
    $a = Get-Advisory $npp
    if ($a.Update[0].BaselineFamily -eq '' -and $a.Update[0].Legacy -and (Find $a 'UPDATE-FAILED')) { Ok "`$expectedOldVersion '8.8.8' <> OldVersion 8.8.9 -> technology unknown (a stale OldVersion is never trusted)" } else { Bad "stale OldVersion -> $($a.Update | ConvertTo-Json -Compress -Depth 4)" }
    [System.IO.File]::WriteAllText($assertPs1, "`$expectedOldVersion = '8.8.9'`r`n", [System.Text.UTF8Encoding]::new($true))
    Set-TestResultFile $npp @($legacy, (New-Record -Type wix -Family msi -Verdict Passed -Fail @() -When '2026-10-20T09:00:00Z'))
    $a = Get-Advisory $npp
    if (@($a.Update).Count -eq 1 -and $a.Update[0].BaselineFamily -eq 'msi' -and -not (Find $a 'UPDATE-FAILED')) { Ok 'a legacy record that is not the newest Update record is ignored' } else { Bad "legacy not newest -> $(Codes $a)" }
    Set-TestResultFile $npp @($legacy, (New-Record -Unavailable -When '2026-10-20T09:00:00Z'))
    $a = Get-Advisory $npp
    if (@($a.Update).Count -eq 1 -and $a.Update[0].Legacy -and (Find $a 'UPDATE-FAILED')) { Ok 'a newer Unavailable record does not hide the legacy FAIL' } else { Bad "legacy + Unavailable -> $(Codes $a)" }
    # The legacy lookup only names the technology: when it cannot, the FAIL is still reported (D1).
    [System.IO.File]::WriteAllText($assertPs1, '', [System.Text.UTF8Encoding]::new($false))
    Set-TestResultFile $npp @($legacy)
    $a = Get-Advisory $npp
    if (@($a.Update).Count -eq 1 -and $a.Update[0].Legacy -and $a.Update[0].BaselineFamily -eq '' -and
        (Find $a 'UPDATE-FAILED').Message -cmatch '^The latest Update test \(HyperV/Unattended, 2026-10-19\) FAILED: OldArpGone-PostUpdate\.' -and -not (Find $a 'ADVISORY-UNAVAILABLE')) {
        Ok 'an empty Sandbox\UpdateAssertions.ps1 -> technology unknown; the newest legacy FAIL still raises UPDATE-FAILED (no Could-not-check finding)'
    } else { Bad "legacy + empty UpdateAssertions.ps1 -> $(Codes $a) / $($a.Update | ConvertTo-Json -Compress -Depth 4)" }
    [System.IO.File]::WriteAllText($assertPs1, "`$expectedOldVersion = '8.8.9'`r`n", [System.Text.UTF8Encoding]::new($true))
    function Get-WingetManifestFile { [CmdletBinding()] param([string]$Path, [string]$Kind) throw [System.IO.IOException]::new('manifest folder exploded') }
    $verbose = @(Get-Win32ToolkitPackageAdvisory -ProjectPath $npp -Verbose 4>&1 3>$null)
    $a = @($verbose | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }) | Select-Object -First 1
    if (@($a.Update).Count -eq 1 -and $a.Update[0].Legacy -and $a.Update[0].BaselineFamily -eq '' -and (Find $a 'UPDATE-FAILED') -and -not (Find $a 'ADVISORY-UNAVAILABLE') -and
        @($verbose | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] -and "$_" -match 'legacy Update record; its technology is unknown: manifest folder exploded' }).Count -eq 1) {
        Ok 'a throwing legacy lookup -> Write-Verbose, technology unknown, UPDATE-FAILED still raised (no Could-not-check finding)'
    } else { Bad "legacy + throwing lookup -> $(Codes $a)" }
    . (Join-Path $repo 'Private\Get-WingetManifestFile.ps1')

    # ======================== [4] Technology switch (WP-4 shadow) ========================
    Write-Host '[4] ID-TECH-SWITCH: every Get-Win32ToolkitTechnologySwitch result, sanitised' -ForegroundColor Cyan
    Set-TestResultFile $npp @(New-Record)
    $esc = [char]0x1B; $rlo = [char]0x202E
    $script:switches = @([pscustomobject]@{ Code = 'ID-TECH-SWITCH'; Message = "Technology switch: the vendor nullsoft install of v8.8.9 (Notepad++ ${esc}[2J(64-bit x64)${rlo}, ARP key 'Notepad++') was still registered after the wix package installed." })
    $a = Get-Advisory $npp
    $ts = Find $a 'ID-TECH-SWITCH'
    if ((Codes $a) -eq 'UPDATE-FAILED,ID-TECH-SWITCH,ID-SIBLING-UNTESTED,ID-SIBLING-FAMILY,ID-NO-ANCHOR' -and $ts.Severity -eq 'Warning' -and $ts.Source -eq 'UpdateTest') { Ok 'ID-TECH-SWITCH (Warning, UpdateTest) right after UPDATE-FAILED' } else { Bad "switch -> $(Codes $a)" }
    if ($ts.Message -notmatch '[\x00-\x1F\u202E]' -and $ts.Message -match 'Notepad\+\+ \?\[2J\(64-bit x64\)\?, ARP key') { Ok 'control / bidi characters in a switch message are replaced' } else { Bad "switch message: $($ts.Message)" }
    $script:switches = @()

    # ======================== [5] Fixture deltas ========================
    Write-Host '[5] TeamViewer (zip-wrapped msi only) and Paint.NET (registers as its own wix)' -ForegroundColor Cyan
    $tv = New-AdvProject -Name 'TeamViewer_x64_15.82.6' -Source @{ WingetId = 'TeamViewer.TeamViewer'; Version = '15.82.6'; InstallerType = 'nullsoft'; Family = 'exe' } `
        -App @{ Vendor = 'TeamViewer'; Name = 'TeamViewer'; DisplayName = 'TeamViewer' } -Manifest 'TeamViewer.TeamViewer\15.82.6.installer.yaml'
    $a = Get-Advisory $tv
    $un = Find $a 'ID-SIBLING-UNTESTABLE'
    if ((Codes $a) -eq 'ID-SIBLING-UNTESTABLE' -and $un.Severity -eq 'Info' -and $un.Message -match 'wix \(MSI\), zip-wrapped') { Ok 'TeamViewer -> one ID-SIBLING-UNTESTABLE (Info), no ID-SIBLING-UNTESTED, no ID-SIBLING-FAMILY' } else { Bad "TeamViewer -> $(Codes $a)" }
    $pdn = New-AdvProject -Name 'Paint.NET_x64_5.1' -Source @{ WingetId = 'dotPDN.PaintDotNet'; Version = '5.1' } `
        -App @{ Vendor = 'dotPDN LLC'; Name = 'Paint.NET'; DisplayName = 'Paint.NET' } -Manifest 'dotPDN.PaintDotNet\5.1.installer.yaml'
    $a = Get-Advisory $pdn
    if ((Codes $a) -eq '') { Ok 'Paint.NET wix -> no sibling finding at all' } else { Bad "Paint.NET -> $(Codes $a)" }

    Write-Host '[6] No files -> no findings; a corrupt TestResults.json -> the reader''s own warning only' -ForegroundColor Cyan
    $bare = Join-Path $tmpRoot 'Projects\Bare\Empty_x64_1.0'
    New-Item -ItemType Directory -Path $bare -Force | Out-Null
    $script:cleanupReal = $true
    $a = Get-Advisory $bare
    if ((Codes $a) -eq '' -and @($a.Update).Count -eq 0 -and $a.PackageType -eq '') { Ok 'an empty project folder -> no findings, no Update entry (no AppConfig.json: the real cleanup helper reads the empty seed config, so there is nothing to check)' } else { Bad "bare -> $(Codes $a)" }
    $script:cleanupReal = $false
    [System.IO.File]::WriteAllText((Join-Path $npp 'Documentation\TestResults.json'), '{ corrupt json', [System.Text.UTF8Encoding]::new($false))
    $warn = @(); $threw = $false
    try { $a = Get-Win32ToolkitPackageAdvisory -ProjectPath $npp -WarningVariable warn -ErrorAction Stop 3>$null } catch { $threw = $true }
    if (-not $threw -and @($warn | Where-Object { "$_" -like 'TestResults.json is unparseable; returning no results.*' }).Count -eq 1 -and
        @($a.Update).Count -eq 0 -and -not (Find $a 'UPDATE-FAILED') -and -not (Find $a 'ADVISORY-UNAVAILABLE')) {
        Ok "corrupt TestResults.json -> 'TestResults.json is unparseable; returning no results.', no Update finding, no throw"
    } else { Bad "corrupt -> threw=$threw warn=$($warn -join ' | ') codes=$(Codes $a)" }

    Write-Host '[7] Fail-open: a throwing helper -> one Could-not-check warning finding, the rest still reported' -ForegroundColor Cyan
    Set-TestResultFile $npp @(New-Record)
    $script:switches = { throw [System.InvalidOperationException]::new('switch exploded') }
    $threw = $false
    try { $a = Get-Win32ToolkitPackageAdvisory -ProjectPath $npp -ErrorAction Stop } catch { $threw = $true }
    $cn = @($a.Findings | Where-Object Code -eq 'ADVISORY-UNAVAILABLE')
    if (-not $threw -and $cn.Count -eq 1 -and $cn[0].Severity -eq 'Warning' -and $cn[0].Message -ceq 'Could not check the Update test and identity warnings: switch exploded' -and (Find $a 'UPDATE-FAILED') -and (Find $a 'ID-SIBLING-FAMILY')) {
        Ok "a throwing Get-Win32ToolkitTechnologySwitch -> one 'Could not check ...' finding; UPDATE-FAILED and the identity findings still there; no throw under -ErrorAction Stop"
    } else { Bad "throwing switch -> threw=$threw codes=$(Codes $a)" }
    $warn = @(); $threw = $false
    try { $r = Write-Win32ToolkitPackageAdvisory -ProjectPath $npp -Context Export -WarningVariable warn -ErrorAction Stop 3>$null } catch { $threw = $true }
    if (-not $threw -and $r -and @($warn | Where-Object { "$_" -match 'Could not check the Update test and identity warnings: switch exploded' }).Count -eq 1) { Ok 'Write-...: the failure is printed once as a warning, the advisory is returned' } else { Bad "writer fail-open: threw=$threw warn=$($warn -join ' | ')" }
    $script:switches = @()
    function Get-Win32ToolkitIdentityDelta { [CmdletBinding()] param([string]$ProjectPath, [switch]$NoProbe, [switch]$ReuseProbe) throw 'delta exploded' }
    $threw = $false
    try { $a = Get-Win32ToolkitPackageAdvisory -ProjectPath $npp -ErrorAction Stop } catch { $threw = $true }
    $cn = @($a.Findings | Where-Object Code -eq 'ADVISORY-UNAVAILABLE')
    if (-not $threw -and $cn.Count -eq 1 -and $cn[0].Source -eq 'IdentityDelta' -and $cn[0].Message -match 'delta exploded' -and (Find $a 'UPDATE-FAILED')) { Ok 'a throwing identity check -> one finding (Source IdentityDelta), the Update finding is kept' } else { Bad "throwing delta -> threw=$threw codes=$(Codes $a)" }
    . $realDeltaFile

    # ======================== [8] UNSAFE-CLEANUP ========================
    Write-Host '[8] UNSAFE-CLEANUP at Publish / Tui only (the Export gate already refuses the project)' -ForegroundColor Cyan
    $script:cleanup = @(
        [pscustomobject]@{ Kind = 'CleanupPath'; Path = 'C:\Program Files (x86)'; Reasons = @('ShellFolder', 'OutsideInstallRoot'); Explanation = 'it is a Windows system folder itself; it is outside the app''s own install folder(s): C:\Program Files\Mozilla Firefox'; Message = 'x' }
        [pscustomobject]@{ Kind = 'CleanupPath'; Path = 'C:\Program Files (x86)\Mozilla Maintenance Service'; Reasons = @('OutsideInstallRoot'); Explanation = 'outside'; Message = 'y' }
    )
    $wantUc = "UNSAFE-CLEANUP: this project's uninstall would delete 2 folder(s) outside the app's own install folder as SYSTEM (first: 'C:\Program Files (x86)' - it is a Windows system folder itself; it is outside the app's own install folder(s): C:\Program Files\Mozilla Firefox). A package exported before this check carries them: re-export it (Export refuses it until the paths are fixed: re-run the install capture) before you publish."
    foreach ($ctx in 'Publish', 'Tui') {
        $a = Get-Advisory $npp -Context $ctx
        $uc = Find $a 'UNSAFE-CLEANUP'
        if ((Codes $a) -like 'UNSAFE-CLEANUP,UPDATE-FAILED,*' -and $uc.Severity -eq 'Warning' -and $uc.Source -eq 'AppConfig' -and $uc.Message -ceq $wantUc) { Ok "-Context $ctx -> UNSAFE-CLEANUP first, with the count, the first path and why" } else { Bad "$ctx -> $(Codes $a) / $($uc.Message)" }
    }
    $before = $script:cleanupCalls
    $a = Get-Advisory $npp -Context Export
    if (-not (Find $a 'UNSAFE-CLEANUP') -and $script:cleanupCalls -eq $before) { Ok '-Context Export -> no UNSAFE-CLEANUP and the cleanup helper is not even called' } else { Bad "Export -> $(Codes $a), calls $($script:cleanupCalls - $before)" }
    $script:cleanup = @([pscustomobject]@{ Kind = 'InstallRoot'; Path = 'C:\Program Files'; Reasons = @('ShellFolder'); Explanation = 'it is a Windows system folder itself'; Message = 'z' })
    if ((Find (Get-Advisory $npp) 'UNSAFE-CLEANUP').Message -match "delete 1 folder\(s\) .*first: 'C:\\Program Files' - it is a Windows system folder itself") { Ok 'an unsafe install root alone also raises it' } else { Bad 'InstallRoot finding not reported' }
    # Unreadable is no all-clear: Windows PowerShell 5.1 on the device may still read the file and delete its
    # cleanup paths (Export refuses it), so a package exported earlier is flagged too.
    $script:cleanup = @([pscustomobject]@{ Kind = 'Unreadable'; Path = ''; Reasons = @(); Explanation = 'bad json'; Message = 'AppConfig.json could not be read' })
    $uc = Find (Get-Advisory $npp) 'UNSAFE-CLEANUP'
    $wantUnread = "UNSAFE-CLEANUP: this project's uninstall cleanup paths could not be checked: SupportFiles\AppConfig.json could not be read (bad json). Windows PowerShell 5.1 on the device may still read it and delete them as SYSTEM. A package exported before this check carries them: fix the file (or re-create the project), re-export it (Export refuses it until the file can be read) before you publish."
    if ($uc -and $uc.Severity -eq 'Warning' -and $uc.Source -eq 'AppConfig' -and $uc.Message -ceq $wantUnread) { Ok "an Unreadable finding -> UNSAFE-CLEANUP worded 'cleanup paths could not be checked'" } else { Bad "Unreadable -> $($uc.Message)" }
    if (-not (Find (Get-Advisory $npp -Context Export) 'UNSAFE-CLEANUP')) { Ok '... but not at -Context Export (the gate errors there)' } else { Bad 'Unreadable reported at Export' }
    $script:cleanup = @(
        [pscustomobject]@{ Kind = 'Unreadable'; Path = ''; Reasons = @(); Explanation = 'bad json'; Message = 'u' }
        [pscustomobject]@{ Kind = 'CleanupPath'; Path = 'C:\Program Files (x86)'; Reasons = @('ShellFolder'); Explanation = 'it is a Windows system folder itself'; Message = 'c' }
    )
    $ucs = @((Get-Advisory $npp).Findings | Where-Object Code -eq 'UNSAFE-CLEANUP')
    if ($ucs.Count -eq 1 -and $ucs[0].Message -match "delete 1 folder\(s\) .*first: 'C:\\Program Files \(x86\)'") { Ok 'an unsafe path wins over Unreadable: one UNSAFE-CLEANUP, about the path' } else { Bad "both -> $(@($ucs.Message) -join ' | ')" }
    # The real helper over a real '+1' AppConfig (PowerShell 7 rejects it, Windows PowerShell 5.1 reads it).
    $plus = New-AdvProject -Name 'Plus_x64_1.0' -Source @{ WingetId = ''; InstallerType = 'exe'; Family = 'exe'; PinnedBy = 'parameter' } -App @{ Vendor = 'Plus'; Name = 'Plus'; DisplayName = 'Plus' }
    [System.IO.File]::WriteAllText((Join-Path $plus 'SupportFiles\AppConfig.json'), '{ "SchemaVersion": "1.0", "Revision": +1, "Uninstall": { "CleanupPaths": [ "C:\\Program Files (x86)" ] } }', [System.Text.UTF8Encoding]::new($false))
    $script:cleanupReal = $true
    $uc = Find (Get-Advisory $plus) 'UNSAFE-CLEANUP'
    $script:cleanupReal = $false
    if ($uc -and $uc.Message -match "^UNSAFE-CLEANUP: this project's uninstall cleanup paths could not be checked: SupportFiles\\AppConfig\.json could not be read \(") { Ok "real helper: a '+1' AppConfig.json -> UNSAFE-CLEANUP (could not be checked)" } else { Bad "'+1' -> $($uc.Message)" }
    $script:cleanup = @()

    # ======================== [9] Order ========================
    Write-Host '[9] Order: UNSAFE-CLEANUP, UPDATE-FAILED, ID-TECH-SWITCH, ID-FAMILY, ... ID-PREDECESSOR-AMBIGUOUS, other warnings, then Info' -ForegroundColor Cyan
    $script:cleanup = @([pscustomobject]@{ Kind = 'CleanupPath'; Path = 'C:\Program Files (x86)'; Reasons = @('ShellFolder'); Explanation = 'system'; Message = 'm' })
    $script:switches = @([pscustomobject]@{ Message = 'Technology switch: test' })
    function Get-Win32ToolkitIdentityDelta {
        [CmdletBinding()] param([string]$ProjectPath, [switch]$NoProbe, [switch]$ReuseProbe)
        $f = { param($c, $s) [pscustomobject]@{ Code = $c; Severity = $s; Message = "$c message"; Data = $null } }
        [pscustomobject]@{
            Siblings = @([pscustomobject]@{ EffectiveType = 'nullsoft'; Family = 'exe'; Registers = $true; Testable = $true; Label = 'nullsoft (vendor EXE, NSIS)' })
            Findings = @((& $f 'ID-VARIANT-SUBSTITUTE' 'Info'), (& $f 'ID-PREDECESSOR-AMBIGUOUS' 'Warning'), (& $f 'ID-FUTURE-CODE' 'Warning'), (& $f 'ID-PROBE-UNAVAILABLE' 'Warning'),
                         (& $f 'ID-SCOPE' 'Warning'), (& $f 'ID-SIBLING-UNTESTABLE' 'Info'), (& $f 'ID-TATTOO' 'Warning'), (& $f 'ID-NO-ANCHOR' 'Warning'),
                         (& $f 'ID-SIBLING-FAMILY' 'Warning'), (& $f 'ID-FAMILY' 'Warning'))
        }
    }
    $a = Get-Advisory $npp
    $wantOrder = 'UNSAFE-CLEANUP,UPDATE-FAILED,ID-TECH-SWITCH,ID-FAMILY,ID-SIBLING-UNTESTED,ID-SIBLING-FAMILY,ID-NO-ANCHOR,ID-TATTOO,ID-SCOPE,ID-PROBE-UNAVAILABLE,ID-PREDECESSOR-AMBIGUOUS,ID-FUTURE-CODE,ID-VARIANT-SUBSTITUTE,ID-SIBLING-UNTESTABLE'
    if ((Codes $a) -eq $wantOrder) { Ok 'the spec 2.13 order; an unknown warning code after the known ones; Info last in arrival order' } else { Bad "order = $(Codes $a)" }
    . $realDeltaFile
    $script:cleanup = @(); $script:switches = @()

    # ======================== [10] Probe only with -ProbeIfMissing ========================
    Write-Host '[10] No stored probe: -ProbeIfMissing absent -> no request; present -> one request, then the memo' -ForegroundColor Cyan
    $fresh = New-AdvProject -Results @(New-Record)
    $script:body = Get-Content -LiteralPath (Join-Path $fx 'Notepad++.Notepad++\8.9.8.1.installer.yaml') -Raw -Encoding UTF8
    $script:W32TSiblingProbeMemo = $null; $script:gets = 0
    $listing = Get-Listing $fresh
    $a = Get-Advisory $fresh
    if ($script:gets -eq 0 -and -not (Find $a 'ID-SIBLING-FAMILY') -and -not (Find $a 'ID-SIBLING-UNTESTED') -and (Find $a 'UPDATE-FAILED')) { Ok 'without -ProbeIfMissing: no request, no sibling finding, the Update finding still shown' } else { Bad "no probe -> gets $($script:gets), $(Codes $a)" }
    $a = Get-Advisory $fresh -Probe
    if ($script:gets -eq 1 -and (Find $a 'ID-SIBLING-FAMILY') -and (Find $a 'ID-SIBLING-UNTESTED')) { Ok '-ProbeIfMissing: one request, sibling findings' } else { Bad "probe -> gets $($script:gets), $(Codes $a)" }
    $null = Get-Advisory $fresh -Probe
    if ($script:gets -eq 1) { Ok 'a second -ProbeIfMissing in the same process makes no request (memo)' } else { Bad "memo -> gets $($script:gets)" }
    if ((Get-Listing $fresh) -ceq $listing -and -not (Test-Path -LiteralPath (Join-Path $fresh 'Documentation\IdentityDelta.json'))) { Ok 'nothing is written under the project (no IdentityDelta.json either, L6)' } else { Bad 'the advisory wrote under the project' }

    # ======================== [11] Writer ========================
    Write-Host '[11] Write-Win32ToolkitPackageAdvisory: prefixes, Warning -> Write-Warning, Info -> Write-Verbose' -ForegroundColor Cyan
    $script:W32TAdvisoryRun = $null
    Set-TestResultFile $npp @(New-Record)
    $warn = @()
    $r = Write-Win32ToolkitPackageAdvisory -ProjectPath $npp -Context Export -WarningVariable warn 3>$null
    $leaf = Split-Path $npp -Leaf
    $nWarn = @($r.Findings | Where-Object Severity -eq 'Warning').Count
    if ($nWarn -ge 4 -and @($warn).Count -eq $nWarn -and @($warn | Where-Object { -not "$_".StartsWith("${leaf}: ") }).Count -eq 0 -and "$($warn[0])" -ceq "${leaf}: $((Find $r 'UPDATE-FAILED').Message)") {
        Ok "Export: one warning per Warning finding ($nWarn), each prefixed '${leaf}: ', in order"
    } else { Bad "Export warnings: $($warn -join ' | ')" }
    # No run scope variable at all (a first call in the process): no VariableNotFound record in $Error or -ErrorVariable.
    Remove-Variable -Name W32TAdvisoryRun -Scope Script -ErrorAction Ignore
    $errBefore = $Error.Count; $advErr = $null
    $null = Write-Win32ToolkitPackageAdvisory -ProjectPath $npp -Context Export -ErrorVariable advErr 3>$null
    if (@($advErr).Count -eq 0 -and $Error.Count -eq $errBefore) { Ok 'no run scope variable yet -> no error record ($Error and -ErrorVariable stay empty)' }
    else { Bad "error records: -ErrorVariable $(@($advErr).Count), `$Error +$($Error.Count - $errBefore): $(@($advErr)[0])" }
    $script:W32TAdvisoryRun = $null
    $warn = @()
    $null = Write-Win32ToolkitPackageAdvisory -ProjectPath $npp -Context Publish -AppLabel 'Notepad++ (Update)' -WarningVariable warn 3>$null
    if (@($warn).Count -eq $nWarn -and @($warn | Where-Object { -not "$_".StartsWith("Publishing 'Notepad++ (Update)': ") }).Count -eq 0) { Ok "Publish: prefixed `"Publishing '<AppLabel>': `"" } else { Bad "Publish warnings: $($warn -join ' | ')" }
    $warn = @()
    $null = Write-Win32ToolkitPackageAdvisory -ProjectPath $npp -Context Publish -AppLabel "Evil${esc}[31m" -WarningVariable warn 3>$null
    if (@($warn | Where-Object { "$_" -match '[\x00-\x1F]' }).Count -eq 0 -and "$($warn[0])".StartsWith("Publishing 'Evil?[31m': ")) { Ok 'a hostile AppLabel is sanitised in the prefix' } else { Bad "hostile label: $($warn[0])" }
    $warn = @()
    $null = Write-Win32ToolkitPackageAdvisory -ProjectPath $npp -Context Publish -WarningVariable warn 3>$null
    if ("$($warn[0])".StartsWith("Publishing '${leaf}': ")) { Ok 'Publish without -AppLabel -> the project folder name' } else { Bad "no label: $($warn[0])" }
    $warn = @()
    $verbose = @(Write-Win32ToolkitPackageAdvisory -ProjectPath $tv -Context Export -WarningVariable warn -Verbose 4>&1 3>$null | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
    if (@($warn).Count -eq 0 -and @($verbose | Where-Object { "$_" -match '^TeamViewer_x64_15\.82\.6: winget also ships wix \(MSI\), zip-wrapped' }).Count -eq 1) { Ok 'an Info finding (ID-SIBLING-UNTESTABLE) goes to Write-Verbose, not Write-Warning' } else { Bad "Info routing: warn=$(@($warn).Count) verbose=$(@($verbose).Count)" }

    Write-Host '[12] Run scope (L20): printed once per project per action, at most one probe request' -ForegroundColor Cyan
    $scoped = New-AdvProject -Results @(New-Record)
    $other  = New-AdvProject -Name 'Other_x64_1.0' -Source @{ WingetId = ''; InstallerType = 'exe'; Family = 'exe'; PinnedBy = 'parameter' } -App @{ Vendor = 'Other'; Name = 'Other'; DisplayName = 'Other' } -Results @(New-Record)
    $script:body = Get-Content -LiteralPath (Join-Path $fx 'Notepad++.Notepad++\8.9.8.1.installer.yaml') -Raw -Encoding UTF8
    $script:W32TSiblingProbeMemo = $null; $script:gets = 0
    $listing = (Get-Listing $scoped) + (Get-Listing $other)
    $script:W32TAdvisoryRun = @{}
    $warn = @()
    $r1 = Write-Win32ToolkitPackageAdvisory -ProjectPath $scoped -Context Export -ProbeIfMissing -WarningVariable +warn 3>$null
    $r2 = Write-Win32ToolkitPackageAdvisory -ProjectPath $scoped -Context Publish -AppLabel 'Notepad++' -ProbeIfMissing -WarningVariable +warn 3>$null
    $r3 = Write-Win32ToolkitPackageAdvisory -ProjectPath ($scoped.ToUpperInvariant() + '\') -Context Publish -AppLabel 'Notepad++ (Update)' -ProbeIfMissing -WarningVariable +warn 3>$null
    $first = @($r1.Findings | Where-Object Severity -eq 'Warning').Count
    if ($r1 -and $null -eq $r2 -and $null -eq $r3 -and $first -ge 4 -and @($warn).Count -eq $first) { Ok "Export -> Publish -> Publish -AsUpdate in one scope: $first warnings printed once; the later calls return `$null (path compared case-insensitively, trailing \ ignored)" } else { Bad "scope: r2=$r2 r3=$r3 first=$first warnings=$(@($warn).Count)" }
    if ($script:gets -eq 1) { Ok 'one probe request for the whole action' } else { Bad "$($script:gets) probe requests" }
    $warn = @()
    $ro = Write-Win32ToolkitPackageAdvisory -ProjectPath $other -Context Publish -WarningVariable warn 3>$null
    if ($ro -and @($warn).Count -ge 1) { Ok 'another project in the same scope is printed' } else { Bad 'another project was suppressed' }
    $script:W32TAdvisoryRun = $null
    $warn = @()
    $r4 = Write-Win32ToolkitPackageAdvisory -ProjectPath $scoped -Context Export -ProbeIfMissing -WarningVariable warn 3>$null
    if ($r4 -and @($warn).Count -eq $first -and $script:gets -eq 1) { Ok 'after the scope closes, the next action prints again (and the probe memo still answers: no new request)' } else { Bad "after scope: r4=$([bool]$r4) warnings=$(@($warn).Count) gets=$($script:gets)" }
    $warn = @()
    $null = Write-Win32ToolkitPackageAdvisory -ProjectPath $scoped -Context Export -ProbeIfMissing -WarningVariable +warn 3>$null
    $null = Write-Win32ToolkitPackageAdvisory -ProjectPath $scoped -Context Export -ProbeIfMissing -WarningVariable +warn 3>$null
    if (@($warn).Count -eq 2 * $first -and $script:gets -eq 1) { Ok 'without an open scope every call prints (the memo still answers the probe)' } else { Bad "no scope: $(@($warn).Count) warnings, gets $($script:gets)" }
    if (((Get-Listing $scoped) + (Get-Listing $other)) -ceq $listing) { Ok 'nothing written under either project by the writer' } else { Bad 'the writer wrote under a project' }

    # A relative -ProjectPath (Export / Publish forward the caller's): resolved against the PowerShell
    # location, never the process directory, for the prefix, the run-scope key and the advisory itself.
    $savedCwd = [Environment]::CurrentDirectory
    $script:W32TAdvisoryRun = @{}
    Push-Location -LiteralPath $scoped
    try {
        [Environment]::CurrentDirectory = $tmpRoot
        $warn = @()
        $rd = Write-Win32ToolkitPackageAdvisory -ProjectPath '.' -Context Export -WarningVariable warn 3>$null
        $leafS = Split-Path $scoped -Leaf
        $absKey = [System.IO.Path]::GetFullPath($scoped).TrimEnd('\')
        if ($rd -and (Find $rd 'UPDATE-FAILED') -and @($warn).Count -ge 1 -and @($warn | Where-Object { -not "$_".StartsWith("${leafS}: ") }).Count -eq 0) { Ok "-ProjectPath '.' inside the project -> the project's own findings, prefixed '${leafS}: '" } else { Bad "'.' -> warnings: $($warn -join ' | ')" }
        if ($script:W32TAdvisoryRun.ContainsKey($absKey) -and $script:W32TAdvisoryRun.Count -eq 1) { Ok "the run-scope key is the absolute project path ($absKey)" } else { Bad "scope keys: $(@($script:W32TAdvisoryRun.Keys) -join ' | ')" }
        $warn = @()
        $ra = Write-Win32ToolkitPackageAdvisory -ProjectPath $scoped -Context Publish -AppLabel 'Notepad++' -WarningVariable warn 3>$null
        if ($null -eq $ra -and @($warn).Count -eq 0) { Ok 'the same project by its absolute path in the same scope prints nothing (one key for both spellings)' } else { Bad "absolute after '.': r=$([bool]$ra) warnings=$(@($warn).Count)" }
    }
    finally {
        [Environment]::CurrentDirectory = $savedCwd
        Pop-Location
        $script:W32TAdvisoryRun = $null
    }

    # ======================== [13] D1 + messages ========================
    Write-Host '[13] D1: no W32T.UpdateTestFailed / -AllowFailedUpdateTest; every message printable ASCII' -ForegroundColor Cyan
    $d1 = @(Get-ChildItem -Path (Join-Path $repo 'Public'), (Join-Path $repo 'Private') -Filter *.ps1 -File | Select-String -Pattern 'UpdateTestFailed|AllowFailedUpdateTest')
    if ($d1.Count -eq 0) { Ok 'no UpdateTestFailed / AllowFailedUpdateTest in Public\ or Private\' } else { Bad "found: $(($d1 | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ')" }
    $nonAscii = @($allMessages | Where-Object { $_ -match '[^\x20-\x7E]' })
    if ($allMessages.Count -ge 15 -and $nonAscii.Count -eq 0) { Ok "every advisory message is printable ASCII ($($allMessages.Count) checked)" } else { Bad "non-ASCII messages: $($nonAscii -join ' | ')" }
    if (@($allMessages | Where-Object { $_ -match 'CaptureSiblingTechnologies' }).Count -eq 0) { Ok 'no message names -CaptureSiblingTechnologies (L12)' } else { Bad 'L12 violated' }
}
finally {
    $script:W32TAdvisoryRun = $null
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ======================== [14] Source checks (AST) ========================
Write-Host '[14] K1: every catch of the two new files starts with the C-2 line; ASCII; one function, no top-level code' -ForegroundColor Cyan
$c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
foreach ($name in 'Get-Win32ToolkitPackageAdvisory', 'Write-Win32ToolkitPackageAdvisory') {
    $file = Join-Path $repo "Private\$name.ps1"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
    $catches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
    $badCatch = @($catches | Where-Object { $_.Body.Statements.Count -eq 0 -or (($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -ne $c2) })
    $ascii = @([System.IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0
    $top = @($ast.EndBlock.Statements)
    $oneFunction = $top.Count -eq 1 -and $top[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $top[0].Name -eq $name -and
                   -not $ast.BeginBlock -and -not $ast.ProcessBlock -and -not $ast.ParamBlock
    if (@($errs).Count -eq 0 -and $catches.Count -ge 1 -and $badCatch.Count -eq 0 -and $ascii -and $oneFunction) { Ok "$name : $($catches.Count) catch(es) with the C-2 line, ASCII, one function" }
    else { Bad "$name : parse errors $(@($errs).Count), catches $($catches.Count), bad $($badCatch.Count), ascii $ascii, oneFunction $oneFunction" }
}

Write-Host '[15] K4 at the three call sites; Export / Publish / TUI order and run scope' -ForegroundColor Cyan
function Get-Ast([string]$Rel) { [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $Rel), [ref]$null, [ref]$null) }
function Get-Call($Ast, [string]$Name) { @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }.GetNewClosure(), $true)) }
# The innermost try (with catch clauses) around a node.
function Get-GuardingTry($Node) {
    $p = $Node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.TryStatementAst] -and $p.CatchClauses.Count -gt 0 -and
            $Node.Extent.StartOffset -ge $p.Body.Extent.StartOffset -and $Node.Extent.EndOffset -le $p.Body.Extent.EndOffset) { return $p }
        $p = $p.Parent
    }
    $null
}
function Test-K4($Ast, [string]$Name, [string]$Label) {
    $calls = @(Get-Call $Ast $Name)
    if ($calls.Count -ne 1) { Bad "$Label : $($calls.Count) call(s) of $Name"; return $null }
    $try = Get-GuardingTry $calls[0]
    $catch = if ($try) { $try.CatchClauses[0] } else { $null }
    if ($catch -and (($catch.Body.Statements[0].Extent.Text -replace '\s+', ' ') -eq $c2) -and $catch.Body.Extent.Text -match 'Write-Warning "Could not check the Update test and identity warnings:') {
        Ok "$Label : $Name sits in a try whose catch starts with the C-2 line and warns 'Could not check ...' (K4)"
    } else { Bad "$Label : K4 catch = $($catch.Extent.Text)" }
    $calls[0]
}
# The run scope: opened (= @{}) before the function's outer try, closed (= $null) in that try's finally.
function Test-RunScope($Ast, [string]$FunctionName, [string]$Label) {
    $fn = $Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName }.GetNewClosure(), $true)
    $outer = @($fn.Body.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }) | Select-Object -First 1
    $opens = @($fn.Body.EndBlock.Statements | Where-Object { $_.Extent.Text -match '^if \(\$ownsAdvisoryRun\) \{ \$script:W32TAdvisoryRun = @\{\} \}$' })
    $owns  = @($fn.Body.EndBlock.Statements | Where-Object { $_.Extent.Text -ceq '$ownsAdvisoryRun = $null -eq $script:W32TAdvisoryRun' })
    $closed = $outer -and $outer.Finally -and $outer.Finally.Extent.Text -match 'if \(\$ownsAdvisoryRun\) \{ \$script:W32TAdvisoryRun = \$null \}'
    if ($outer -and $opens.Count -eq 1 -and $owns.Count -eq 1 -and $opens[0].Extent.EndOffset -lt $outer.Extent.StartOffset -and $closed) {
        Ok "$Label : the run scope is opened before the outer try (only when none is open) and closed in its finally"
    } else { Bad "$Label : run scope open=$($opens.Count) owns=$($owns.Count) closedInFinally=$closed" }
    $outer
}

$expPath = 'Public\Export-Win32ToolkitIntuneWin.ps1'
$expAst = Get-Ast $expPath
$expText = [System.IO.File]::ReadAllText((Join-Path $repo $expPath))
$expCall = Test-K4 $expAst 'Write-Win32ToolkitPackageAdvisory' 'Export'
$null = Test-RunScope $expAst 'Export-Win32ToolkitIntuneWin' 'Export'
$s6 = $expText.IndexOf('Step 6: Rename output'); $s7 = $expText.IndexOf('Step 7: Publish to Intune')
$pubCalls = @(Get-Call $expAst 'Publish-Win32ToolkitIntuneApp')
if ($expCall -and $s6 -gt 0 -and $expCall.Extent.StartOffset -gt $s6 -and $expCall.Extent.StartOffset -lt $s7 -and @($pubCalls | Where-Object { $_.Extent.StartOffset -lt $expCall.Extent.StartOffset }).Count -eq 0 -and
    $expCall.Extent.Text -match '-Context Export' -and $expCall.Extent.Text -match '-ProbeIfMissing') {
    Ok 'Export: Write-Win32ToolkitPackageAdvisory -Context Export -ProbeIfMissing after Step 6, before Step 7 (and before every Publish call)'
} else { Bad 'Export: the advisory call is not between Step 6 and Step 7' }
$paths = @(Get-Call $expAst 'Get-Win32ToolkitPaths')
if ($paths.Count -ge 1 -and $expCall -and $paths[0].Extent.StartOffset -lt $expCall.Extent.StartOffset) { Ok 'Export: the call comes after Get-Win32ToolkitPaths (the gate suites'' sentinel)' } else { Bad 'Export: the call precedes the Get-Win32ToolkitPaths sentinel' }

$pubPath = 'Public\Publish-Win32ToolkitIntuneApp.ps1'
$pubAst = Get-Ast $pubPath
$pubCall = Test-K4 $pubAst 'Write-Win32ToolkitPackageAdvisory' 'Publish'
$null = Test-RunScope $pubAst 'Publish-Win32ToolkitIntuneApp' 'Publish'
$f05 = @(Get-Call $pubAst 'Get-Win32ToolkitProjectPsadtVersion')
$should = $pubAst.Find({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'ShouldProcess' }, $true)
$connect = @(Get-Call $pubAst 'Connect-Win32ToolkitGraph')
if ($pubCall -and $f05.Count -eq 1 -and $should -and $pubCall.Extent.StartOffset -gt $f05[0].Extent.StartOffset -and $pubCall.Extent.StartOffset -lt $should.Extent.StartOffset -and
    $connect.Count -ge 1 -and $pubCall.Extent.StartOffset -lt $connect[0].Extent.StartOffset -and $pubCall.Extent.Text -match '-Context Publish' -and $pubCall.Extent.Text -match '-AppLabel \$displayName' -and $pubCall.Extent.Text -match '-ProbeIfMissing') {
    Ok 'Publish: -Context Publish -AppLabel $displayName -ProbeIfMissing after the F-05 block, before the -WhatIf gate and the Graph sign-in'
} else { Bad 'Publish: the advisory call is misplaced' }

$tuiPath = 'Private\Show-Win32ToolkitProjectActions.ps1'
$tuiAst = Get-Ast $tuiPath
$tuiText = [System.IO.File]::ReadAllText((Join-Path $repo $tuiPath))
$tuiCall = Test-K4 $tuiAst 'Get-Win32ToolkitPackageAdvisory' 'TUI'
$which = $tuiText.IndexOf("'Publish which app?'")
$tuiExport = @(Get-Call $tuiAst 'Export-Win32ToolkitIntuneWin' | Where-Object { $_.Extent.StartOffset -gt $which })
$open  = $tuiText.IndexOf('if ($ownsAdvisoryRun) { $script:W32TAdvisoryRun = @{} }')
$mark  = $tuiText.IndexOf('$script:W32TAdvisoryRun[[System.IO.Path]::GetFullPath($project.Path).TrimEnd(''\'')] = $true')
$close = $tuiText.IndexOf('if ($ownsAdvisoryRun) { $script:W32TAdvisoryRun = $null }')
if ($tuiCall -and $tuiCall.Extent.Text -match '-Context Tui' -and $open -gt 0 -and $open -lt $tuiCall.Extent.StartOffset -and $tuiCall.Extent.StartOffset -lt $mark -and $mark -lt $which -and
    $tuiExport.Count -eq 1 -and $tuiExport[0].Extent.StartOffset -lt $close) {
    Ok 'TUI publish: scope opened, advisory panel, project marked shown, then "Publish which app?" and Export, scope closed after Export'
} else { Bad "TUI publish order: open=$open call=$($tuiCall.Extent.StartOffset) mark=$mark which=$which close=$close" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PackageAdvisory tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PackageAdvisory test(s) FAILED." -ForegroundColor Red; exit 1 }
