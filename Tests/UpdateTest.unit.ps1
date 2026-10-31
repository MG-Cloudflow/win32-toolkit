<#
    Unit tests for the Update test scenario plumbing (no winget / no sandbox needed):
    - Select-Win32ToolkitOlderVersion: strictly-older filtering, numeric fallback, array-safe returns,
      refusal (throw) when no safe comparison exists.
    - New-UpdateAssertionScript: generated 5.1-safe script, escaped tattoo values, ASSERT markers.
    - Wait-Win32ToolkitUpdateAssertion: PASS/FAIL/timeout verdicts from a pre-written log.
    - [10] the baseline technology (installer-identity PR 1): Auto / Both / explicit legs, the pinned fallback,
      the Unavailable record, the soft scope (the Git case) and the K5/K6 catches.

    Run:  pwsh -File Tests\UpdateTest.unit.ps1
#>
# Test shadows keep the real command names and signatures (C-4: no PSScriptAnalyzer warning in the suites).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Select-Win32ToolkitOlderVersion.ps1')
. (Join-Path $repo 'Private\New-UpdateAssertionScript.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitDeployScriptBlock.ps1')   # C-9 (installer-identity PR 3): the generator embeds the prior-install catalog texts
# C-9 (lean deploy script PR 3): the catalog reads the prior-install texts from the verified extension module.
. (Join-Path $repo 'Private\Get-Win32ToolkitDeployExtension.ps1')
. (Join-Path $repo 'Private\Wait-Win32ToolkitUpdateAssertion.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\ConvertTo-PSSingleQuoted.ps1')
. (Join-Path $repo 'Private\ConvertTo-XmlEncoded.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitBaselineInstallCommand.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallerExtension.ps1')  # installer-extension source of truth (bundle support)
. (Join-Path $repo 'Private\Resolve-Win32ToolkitBaselineSilentArgs.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitWingetDownload.ps1')  # C-9: every winget download runs through it
. (Join-Path $repo 'Private\Download-OldVersionInstaller.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
. (Join-Path $repo 'Private\ConvertFrom-Win32ToolkitWingetManifest.ps1')   # C-9: Download-OldVersionInstaller reads the downloaded switches with it
. (Join-Path $repo 'Private\Get-Win32ToolkitTestMode.ps1')  # mode resolver (Interactive/Unattended)
. (Join-Path $repo 'Private\Wait-Win32ToolkitSandboxFree.ps1')
function Get-Win32ToolkitSandboxEnvironment { $null }   # C-9: no wsb answer -> the process check decides (test campaign F1)
. (Join-Path $repo 'Private\Get-Win32ToolkitConfigValue.ps1')   # New-TargetedDocumentation reads SandboxTestMode
. (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1')   # for -BaselineProjectPath validation (throws early)
# C-9 (speed-up PR 3): TestProjectLease On would take the project's lease; inert doubles (never a lock file), never used while
# the config reads return the test modes.
function Enter-Win32ToolkitHyperVLease { param($VMName, $VMId, $ProjectPath, $Purpose) [pscustomobject]@{ Kind = 'Project'; Epoch = 'inert'; Generation = 1; PreviousGeneration = 0; Nested = $false } }
function Exit-Win32ToolkitHyperVLease { param($Lease) }
function Get-Win32ToolkitSiblingCaptureRecord { param($ProjectPath, $CaptureId) $null = $ProjectPath, $CaptureId; @() }   # C-9 (installer-identity PR 3b, C2): a capture-lineage group reads its floor record
# C-9 (installer-identity PR 2 follow-up F7): every test first asks for the uninstall cleanup paths Export refuses. No
# finding by default; [10] (e) sets some.
$script:cleanupCalls = 0
$script:cleanupFindings = @()
function Get-Win32ToolkitCleanupPathFinding { param($ProjectPath) $null = $ProjectPath; $script:cleanupCalls++; @($script:cleanupFindings) }
. (Join-Path $repo 'Private\Initialize-Win32ToolkitTestRunLog.ps1')   # C-9: each run keeps its logs in Sandbox\Logs\Runs\<run> (real)
. (Join-Path $repo 'Private\Save-Win32ToolkitTestRunLog.ps1')
function Wait-Win32ToolkitCollectedLog { param($TimeoutSeconds) $script:collectWaits += [int]$TimeoutSeconds; $true }   # no wait for a guest log collector
$script:collectWaits = @()
. (Join-Path $repo 'Private\Test-Win32ToolkitSandboxRunning.ps1')
# Deterministic on any host (CI stdin is redirected, which would otherwise force Unattended).
function Test-Win32ToolkitHostNonInteractive { [bool]$script:hostNonInteractive }   # $false unless a test sets it (F5)
function Test-Win32ToolkitNonInteractiveSwitch { [bool]$script:noniSwitch }        # C-9: pwsh -NonInteractive in a console (F5); $false unless set
. (Join-Path $repo 'Private\Start-Win32ToolkitSandbox.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitTestRun.ps1')

$base = Join-Path ([System.IO.Path]::GetTempPath()) ("w32upd_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
    Write-Host "[1] Select-Win32ToolkitOlderVersion" -ForegroundColor Cyan

    # Exact match — everything after it
    $r = @(Select-Win32ToolkitOlderVersion -Versions @('2.55.0', '2.54.0', '2.53.0') -CurrentVersion '2.55.0')
    if (($r -join ',') -eq '2.54.0,2.53.0') { Ok 'exact match -> strictly older, order kept' } else { Bad "exact: [$($r -join ',')]" }

    # Exact match, current is oldest -> empty
    $r = @(Select-Win32ToolkitOlderVersion -Versions @('2.55.0', '2.54.0') -CurrentVersion '2.54.0')
    if ($r.Count -eq 0) { Ok 'current oldest -> empty' } else { Bad "oldest: [$($r -join ',')]" }

    # THE P1: current version pulled from winget -> numeric fallback, NEVER newer/equal entries
    $r = @(Select-Win32ToolkitOlderVersion -Versions @('8.9.6.4', '8.9.6.2', '8.9.6.1') -CurrentVersion '8.9.6.3' -WarningAction SilentlyContinue)
    if (($r -join ',') -eq '8.9.6.2,8.9.6.1') { Ok 'pulled current -> numeric fallback excludes newer 8.9.6.4' } else { Bad "pulled: [$($r -join ',')]" }

    # Formatting drift: 'v' prefix + prerelease suffixes still compare
    $r = @(Select-Win32ToolkitOlderVersion -Versions @('v2.0.0', '1.9.0-beta', '1.8.0') -CurrentVersion '1.9.5' -WarningAction SilentlyContinue)
    if (($r -join ',') -eq '1.9.0-beta,1.8.0') { Ok "'v'/prerelease normalization" } else { Bad "drift: [$($r -join ',')]" }

    # Single result via the documented @() call-site contract: 1 STRING element, so
    # '$older[$VersionsBack - 1]' yields the version, never a character (the char-indexing bug).
    $r = @(Select-Win32ToolkitOlderVersion -Versions @('2.55.0', '2.54.0') -CurrentVersion '2.55.0')
    if ($r.Count -eq 1 -and $r[0] -is [string] -and $r[0] -eq '2.54.0') { Ok 'single older version -> @() gives 1 string element (no char indexing)' } else { Bad "scalar: count=$($r.Count) [0]=$($r[0]) type=$($r[0].GetType().Name)" }

    # Case-insensitive exact match
    $r = @(Select-Win32ToolkitOlderVersion -Versions @('8.9.6.3-BETA', '8.9.6.2') -CurrentVersion '8.9.6.3-beta')
    if (($r -join ',') -eq '8.9.6.2') { Ok 'case-insensitive exact match' } else { Bad "case: [$($r -join ',')]" }

    # Unparseable current + not in list -> throws (never the unfiltered list)
    $threw = $false
    try { Select-Win32ToolkitOlderVersion -Versions @('2.55.0') -CurrentVersion 'not-a-version' -WarningAction SilentlyContinue | Out-Null }
    catch { $threw = $_.Exception.Message -match 'SpecificVersion' }
    if ($threw) { Ok 'unfilterable -> throws with -SpecificVersion guidance' } else { Bad 'unfilterable did not throw' }

    # Unparseable candidates are dropped, not misclassified
    $r = @(Select-Win32ToolkitOlderVersion -Versions @('weird-build', '1.0.0') -CurrentVersion '2.0.0' -WarningAction SilentlyContinue)
    if (($r -join ',') -eq '1.0.0') { Ok 'unparseable candidate dropped (conservative)' } else { Bad "drop: [$($r -join ',')]" }

    # Component-count drift: '25.4' is the SAME release as current '25.4.0' -> must be EXCLUDED
    $r = @(Select-Win32ToolkitOlderVersion -Versions @('25.4', '25.3') -CurrentVersion '25.4.0' -WarningAction SilentlyContinue)
    if (($r -join ',') -eq '25.3') { Ok "component padding: '25.4' == '25.4.0' (excluded, not an older baseline)" } else { Bad "pad: [$($r -join ',')]" }

    # All candidates non-comparable (5-part + alpha) -> honest throw (not "no versions older")
    $threw2 = $false
    try { Select-Win32ToolkitOlderVersion -Versions @('1.2.3.4.5', 'abc.def') -CurrentVersion '9.9.9' -WarningAction SilentlyContinue | Out-Null }
    catch { $threw2 = $_.Exception.Message -match 'comparable version strings' }
    if ($threw2) { Ok 'all candidates non-comparable -> honest throw with -SpecificVersion hint' } else { Bad 'all-dropped did not throw honestly' }

    Write-Host "`n[2] New-UpdateAssertionScript (hostile AppConfig values)" -ForegroundColor Cyan
    $proj = Join-Path $base 'proj'
    New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles') -Force | Out-Null
    $cfg = [pscustomobject]@{
        App = [pscustomobject]@{
            Vendor = "O'Reilly"; Name = ''; DisplayName = "Evil'App [x64]"; Version = '1.2.3'; ScriptAuthor = "O'Brien IT"
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $proj 'SupportFiles\AppConfig.json'), ($cfg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

    $scriptPath = New-UpdateAssertionScript -ProjectPath $proj
    $bomBytes = [System.IO.File]::ReadAllBytes($scriptPath)[0..2]
    if ($bomBytes[0] -eq 0xEF -and $bomBytes[1] -eq 0xBB -and $bomBytes[2] -eq 0xBF) { Ok 'written UTF-8 WITH BOM (5.1-safe for non-ASCII metadata)' } else { Bad 'no BOM — 5.1 would decode as ANSI' }
    $s = Get-Content -LiteralPath $scriptPath -Raw
    $errs = $null; [System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$null, [ref]$errs) | Out-Null
    if (-not ($errs -and $errs.Count)) { Ok 'generated script parses' } else { Bad "parse: $($errs[0].Message)" }
    if ($s -match [regex]::Escape("HKLM:\SOFTWARE\O''Brien IT\O''Reilly\Evil''App [x64]")) { Ok 'tattoo key escaped (apostrophes doubled, DisplayName used)' } else { Bad 'tattoo key wrong/unescaped' }
    if ($s -match '-LiteralPath \$tattooKey') { Ok 'tattoo read uses -LiteralPath (brackets literal)' } else { Bad 'tattoo read not literal' }
    if ($s -match 'ASSERT Requirement-\$Phase' -and $s -match 'ASSERT Tattoo-PostUpdate' -and $s -match 'RESULT COMPLETE') { Ok 'ASSERT markers + completion marker present' } else { Bad 'markers missing' }
    if ($s -notmatch 'UseDefaultMsi') { Ok 'no MSI exclusion (MSI apps assert too)' } else { Bad 'unexpected MSI exclusion' }

    # -SkipRequirement: requirement never runs (even if a stale UpdateRequirement.ps1 exists), tattoo stays
    New-Item -ItemType Directory -Path (Join-Path $proj 'SupportFiles') -Force | Out-Null
    Set-Content -Path (Join-Path $proj 'SupportFiles\UpdateRequirement.ps1') -Value 'exit 0' -Encoding UTF8
    $sSkip = Get-Content -LiteralPath (New-UpdateAssertionScript -ProjectPath $proj -SkipRequirement) -Raw
    $errsS = $null; [System.Management.Automation.Language.Parser]::ParseInput($sSkip, [ref]$null, [ref]$errsS) | Out-Null
    if (-not ($errsS -and $errsS.Count)) { Ok '-SkipRequirement script parses' } else { Bad "skip parse: $($errsS[0].Message)" }
    if ($sSkip -match 'ASSERT Requirement-\$Phase = SKIP \(requirement check disabled' -and $sSkip -notmatch 'UpdateRequirement\.ps1') { Ok '-SkipRequirement: requirement never invoked (stale script ignored)' } else { Bad '-SkipRequirement still references the requirement script' }
    if ($sSkip -match 'ASSERT Tattoo-PostUpdate') { Ok '-SkipRequirement: tattoo assertion kept' } else { Bad '-SkipRequirement dropped the tattoo assertion' }

    # No tattoo values -> SKIP branch, still parses
    $proj2 = Join-Path $base 'proj2'
    New-Item -ItemType Directory -Path (Join-Path $proj2 'SupportFiles') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $proj2 'SupportFiles\AppConfig.json'), ([pscustomobject]@{ App = [pscustomobject]@{ Name = ''; Version = '1.0' } } | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    $s2 = Get-Content -LiteralPath (New-UpdateAssertionScript -ProjectPath $proj2) -Raw
    if ($s2 -match 'ASSERT Tattoo-PostUpdate = SKIP') { Ok 'missing tattoo values -> SKIP branch generated' } else { Bad 'SKIP branch missing' }

    Write-Host "`n[3] Wait-Win32ToolkitUpdateAssertion verdicts" -ForegroundColor Cyan
    function New-AssertLog($projPath, $lines) {
        $dir = Join-Path $projPath 'Sandbox\Logs'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir 'UpdateAssertions.log') -Value $lines -Encoding UTF8
    }
    $pp = Join-Path $base 'wait-pass'
    New-AssertLog $pp @('[t] ASSERT Requirement-PreUpdate = PASS', '[t] ASSERT Requirement-PostUpdate = PASS', '[t] ASSERT Tattoo-PostUpdate = PASS', '[t] RESULT COMPLETE')
    if ((Wait-Win32ToolkitUpdateAssertion -ProjectPath $pp -TimeoutMinutes 1 6>$null) -eq $true) { Ok 'all PASS -> $true' } else { Bad 'PASS verdict wrong' }

    $pf = Join-Path $base 'wait-fail'
    New-AssertLog $pf @('[t] ASSERT Requirement-PreUpdate = FAIL (x)', '[t] ASSERT Tattoo-PostUpdate = PASS', '[t] RESULT COMPLETE')
    if ((Wait-Win32ToolkitUpdateAssertion -ProjectPath $pf -TimeoutMinutes 1 6>$null 3>$null) -eq $false) { Ok 'any FAIL -> $false' } else { Bad 'FAIL verdict wrong' }

    $ps = Join-Path $base 'wait-skip'
    New-AssertLog $ps @('[t] ASSERT Requirement-PreUpdate = SKIP (n/a)', '[t] ASSERT Tattoo-PostUpdate = SKIP (n/a)', '[t] RESULT COMPLETE')
    if ($null -eq (Wait-Win32ToolkitUpdateAssertion -ProjectPath $ps -TimeoutMinutes 1 6>$null 3>$null)) { Ok 'all SKIP -> $null (nothing verified)' } else { Bad 'SKIP verdict wrong' }

    # Live run SB-ENFORCE (2026-10-27): a complete log that lost lines (no Tattoo-/OldArpGone-/PriorAbsent-PostUpdate)
    # was PASSED on its three remaining lines. Names the guest always writes are required: one missing -> inconclusive.
    $req = @('Requirement-PreUpdate', 'Requirement-PostUpdate', 'Tattoo-PostUpdate')
    $vMissing = Wait-Win32ToolkitUpdateAssertion -ProjectPath $pp -TimeoutMinutes 1 -RequiredAssertion ($req + 'PriorAbsent-PostUpdate.nsis-x64') 6>$null 3>$null
    if ($null -eq $vMissing) { Ok 'a complete PASS log without a required assertion -> $null (lines were lost), not PASSED' } else { Bad 'missing required assertion still passed' }
    $vPresent = Wait-Win32ToolkitUpdateAssertion -ProjectPath $pp -TimeoutMinutes 1 -RequiredAssertion $req 6>$null
    if ($vPresent -eq $true) { Ok 'every required assertion present -> $true' } else { Bad 'required set present but not passed' }
    $vFail = Wait-Win32ToolkitUpdateAssertion -ProjectPath $pf -TimeoutMinutes 1 -RequiredAssertion ($req + 'OldArpGone-PostUpdate') 6>$null 3>$null
    if ($vFail -eq $false) { Ok 'a FAIL stays conclusive when required assertions are missing too' } else { Bad 'FAIL not conclusive with missing required' }
    $srcT = Get-Content -LiteralPath (Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1') -Raw
    if (([regex]::Matches($srcT, 'Wait-Win32ToolkitUpdateAssertion -ProjectPath \$ProjectPath[^\r\n]*-RequiredAssertion \$(updRequired|iuRequired)')).Count -eq 4 -and
        $srcT.Contains("'Requirement-PreUpdate', 'Requirement-PostUpdate', 'OldArpGone-PostUpdate', 'Tattoo-PostUpdate', 'NewAppIntact-PostUpdate'") -and $srcT.Contains('"PriorPresent-PreUpdate.$_"; "PriorAbsent-PostUpdate.$_"') -and
        $srcT.Contains("`$iuRequired = @('InstallDetected-PostInstall', 'UninstallClean-PostUninstall')")) { Ok 'all four waits (Update and Install/Uninstall, Sandbox and Hyper-V) pass the always-written names, one pair per checked prior-install entry' } else { Bad 'Test-Win32ToolkitProject does not pass -RequiredAssertion at every wait' }

    # Live rows OP-BLOCK, OP-NEWER, OP-OWN, KILL-*, APP-RUNNING, RC2-BLOCK: the console said "N assertion(s) failed" (in
    # hashtable order) while the record also held the host's UpdateExitCode-PostUpdate FAIL. -HostCheck rows count too,
    # listed first, with their sentence under the headline; the guest's follow in the order it wrote them.
    $ph = Join-Path $base 'wait-host'
    New-AssertLog $ph @('[t] ASSERT Requirement-PreUpdate = FAIL (x)', '[t] ASSERT Tattoo-PostUpdate = FAIL (y)', '[t] ASSERT NewAppIntact-PostUpdate = PASS', '[t] ASSERT OldArpGone-PostUpdate = FAIL (z)', '[t] RESULT COMPLETE')
    $hostRow = { @{ Name = 'UpdateExitCode-PostUpdate'; Result = 'FAIL'; Text = 'The update exited with code 69101: a Block prior-install rule refused the install.' } }
    $hostOut = @(Wait-Win32ToolkitUpdateAssertion -ProjectPath $ph -TimeoutMinutes 1 -HostCheck $hostRow 3>$null 6>&1 | ForEach-Object { "$_" })
    $verdictH = $hostOut | Where-Object { $_ -eq 'False' }
    $head = @($hostOut | Where-Object { $_ -match 'UPDATE TEST FAILED' })
    $idxHead = [array]::IndexOf($hostOut, ($head | Select-Object -First 1))
    if ($head.Count -eq 1 -and $head[0] -match '— 4 assertion\(s\) failed: UpdateExitCode-PostUpdate, Requirement-PreUpdate, Tattoo-PostUpdate, OldArpGone-PostUpdate$' -and
        $hostOut[$idxHead + 1] -match 'The update exited with code 69101: a Block prior-install rule' -and @($hostOut | Where-Object { $_ -match '^\s*ASSERT UpdateExitCode-PostUpdate = FAIL \(host\)$' }).Count -eq 1) {
        Ok '-HostCheck: the host FAIL is listed, counted first (4 = 3 guest + 1 host) and its sentence printed under the headline; the guest order kept'
    } else { Bad "host check summary: $($hostOut -join ' | ')" }
    if ($null -ne $verdictH -or @($hostOut)[-1] -eq 'False') { Ok '-HostCheck FAIL -> $false' } else { Bad "host check verdict: $($hostOut -join ' | ')" }
    $vHostOnly = Wait-Win32ToolkitUpdateAssertion -ProjectPath $pp -TimeoutMinutes 1 -HostCheck $hostRow 6>$null 3>$null
    if ($vHostOnly -eq $false) { Ok 'all guest assertions PASS but the host FAIL -> $false' } else { Bad 'host FAIL ignored on a passing log' }
    $vHostNone = Wait-Win32ToolkitUpdateAssertion -ProjectPath $pp -TimeoutMinutes 1 -HostCheck { } 6>$null
    if ($vHostNone -eq $true) { Ok 'a host check with no row leaves the verdict to the guest' } else { Bad 'empty host check' }
    $pn = Join-Path $base 'wait-host-none'
    New-Item -ItemType Directory -Path $pn -Force | Out-Null
    $vHostNoLog = Wait-Win32ToolkitUpdateAssertion -ProjectPath $pn -TimeoutMinutes 0 -HostCheck $hostRow 6>$null 3>$null
    if ($vHostNoLog -eq $false) { Ok 'no guest log but a host FAIL -> $false (the update failed)' } else { Bad 'no log + host FAIL' }

    $pt = Join-Path $base 'wait-timeout'
    New-Item -ItemType Directory -Path $pt -Force | Out-Null
    if ($null -eq (Wait-Win32ToolkitUpdateAssertion -ProjectPath $pt -TimeoutMinutes 0 6>$null 3>$null)) { Ok 'no log + timeout -> $null' } else { Bad 'timeout verdict wrong' }

    # Partial run (PASS lines but no RESULT COMPLETE) must be INCONCLUSIVE, never a pass
    $pi = Join-Path $base 'wait-partial'
    New-AssertLog $pi @('[t] ASSERT Requirement-PreUpdate = PASS')
    if ($null -eq (Wait-Win32ToolkitUpdateAssertion -ProjectPath $pi -TimeoutMinutes 0.04 -PollSeconds 1 6>$null 3>$null)) { Ok 'partial run (no COMPLETE marker) -> $null, not PASSED' } else { Bad 'partial run wrongly conclusive' }

    # Partial run WITH a FAIL is conclusive: fail
    $pj = Join-Path $base 'wait-partial-fail'
    New-AssertLog $pj @('[t] ASSERT Requirement-PreUpdate = FAIL (x)')
    if ((Wait-Win32ToolkitUpdateAssertion -ProjectPath $pj -TimeoutMinutes 0.04 -PollSeconds 1 6>$null 3>$null) -eq $false) { Ok 'partial run with FAIL -> $false (failures are conclusive)' } else { Bad 'partial FAIL not conclusive' }

    # Hyper-V speed-up PR 1 (D24): a Hyper-V run's log came back with the copy-out and cannot change: one read, no sleep.
    Write-Host "`n[3b] Wait-Win32ToolkitUpdateAssertion -SinglePass: one read, no polling, the same verdict rules" -ForegroundColor Cyan
    $script:sleeps3b = 0
    function Start-Sleep { param($Seconds, $Milliseconds) $script:sleeps3b++ }
    try {
        foreach ($case in @(
                @{ Tag = 'a complete PASS log'; P = $pp; Want = $true }
                @{ Tag = 'a partial log with a FAIL'; P = $pj; Want = $false }
                @{ Tag = 'a partial PASS log (no RESULT COMPLETE)'; P = $pi; Want = $null }
                @{ Tag = 'a SKIP-only log'; P = $ps; Want = $null })) {
            $script:sleeps3b = 0
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $v = Wait-Win32ToolkitUpdateAssertion -ProjectPath $case.P -Backend HyperV -SinglePass 6>$null 3>$null
            $sw.Stop()
            if ($v -eq $case.Want -and ($null -ne $case.Want -or $null -eq $v) -and $script:sleeps3b -eq 0 -and $sw.Elapsed.TotalSeconds -lt 1) { Ok "$($case.Tag): $(if ($null -eq $v) { '$null' } else { "`$$v" }) at once (0 sleeps, $([int]$sw.Elapsed.TotalMilliseconds) ms)" } else { Bad "$($case.Tag): verdict=$v sleeps=$($script:sleeps3b) ms=$($sw.Elapsed.TotalMilliseconds)" }
        }
        $script:sleeps3b = 0
        $w3b = $null
        $v = Wait-Win32ToolkitUpdateAssertion -ProjectPath $pt -Backend HyperV -SinglePass -WarningVariable w3b 6>$null 3>$null
        if ($null -eq $v -and $script:sleeps3b -eq 0 -and @($w3b).Count -eq 1 -and "$($w3b[0])" -like 'No assertion results came back from the Hyper-V run*' -and "$($w3b[0])" -notmatch 'minutes') {
            Ok 'no log: $null at once, the "came back from the Hyper-V run" wording (no minutes)'
        } else { Bad "missing log: verdict=$v sleeps=$($script:sleeps3b) warnings=$(@($w3b) -join ' | ')" }
        $script:sleeps3b = 0
        $v = Wait-Win32ToolkitUpdateAssertion -ProjectPath $pi -TimeoutMinutes 0.001 -PollSeconds 1 6>$null 3>$null
        if ($null -eq $v -and $script:sleeps3b -ge 1) { Ok 'without -SinglePass the waiter still polls (Sandbox: unchanged)' } else { Bad "polling: verdict=$v sleeps=$($script:sleeps3b)" }
    }
    finally { Remove-Item Function:\Start-Sleep }

    Write-Host "`n[4] Get-Win32ToolkitBaselineInstallCommand" -ForegroundColor Cyan
    # Every form ends in the same FIXED suffix that records the exit code (test campaign 2026-10-21, H6-F7).
    $blSuffix = '; $w32tCls = ''Failed''; if ($w32tRc -eq 0 -or $w32tRc -eq 1707) { $w32tCls = ''Success'' } elseif ($w32tRc -eq 3010) { $w32tCls = ''SoftReboot'' } elseif ($w32tRc -eq 1641) { $w32tCls = ''HardReboot'' }; (''[{0}] baseline Install parent=vendor exit={1} result={2}'' -f ([DateTime]::UtcNow.ToString(''yyyy-MM-dd HH:mm:ss'', [Globalization.CultureInfo]::InvariantCulture) + ''Z''), $w32tRc, $w32tCls) | Add-Content -LiteralPath ''C:\PSADT\Sandbox\Logs\PsadtExitCodes.log'' -Encoding UTF8 -ErrorAction SilentlyContinue; $global:LASTEXITCODE = $w32tRc'
    if (-not $blSuffix.Contains('"') -and $blSuffix -notmatch '\bexit\b\s*\$') { Ok 'the recording suffix has no double quote and no exit' } else { Bad 'suffix shape' }
    $c = Get-Win32ToolkitBaselineInstallCommand -InstallerSandboxPath 'C:\PSADT\Sandbox\OldVersion\app.exe' -InstallerType exe -SilentArgs '/S'
    if ($c -eq ('$w32tBl = Start-Process ''C:\PSADT\Sandbox\OldVersion\app.exe'' -ArgumentList ''/S'' -Wait -PassThru; $w32tRc = [int]$w32tBl.ExitCode' + $blSuffix)) { Ok 'exe + args -> Start-Process -ArgumentList -Wait -PassThru, exit code recorded' } else { Bad "exe: [$c]" }
    $c = Get-Win32ToolkitBaselineInstallCommand -InstallerSandboxPath 'C:\PSADT\Sandbox\OldVersion\app.exe' -InstallerType exe
    if ($c -eq ('$w32tBl = Start-Process ''C:\PSADT\Sandbox\OldVersion\app.exe'' -Wait -PassThru; $w32tRc = [int]$w32tBl.ExitCode' + $blSuffix)) { Ok 'exe no args -> no -ArgumentList' } else { Bad "exe-noargs: [$c]" }
    $c = Get-Win32ToolkitBaselineInstallCommand -InstallerSandboxPath 'C:\PSADT\Sandbox\OldVersion\app.msix' -InstallerType msix -SilentArgs '/qn'
    if ($c -eq ('try { Add-AppxPackage -Path ''C:\PSADT\Sandbox\OldVersion\app.msix'' -ErrorAction Stop; $w32tRc = 0 } catch { $w32tRc = 1 }' + $blSuffix)) { Ok 'msix -> Add-AppxPackage (no Start-Process, args ignored), 0/1 recorded' } else { Bad "msix: [$c]" }
    # Behaviour under Windows PowerShell 5.1: the vendor exit code becomes $LASTEXITCODE and one log line (H6-F7).
    $ps51b = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps51b) {
        $blDir = Join-Path ([System.IO.Path]::GetTempPath()) ('w32bl_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $blDir -Force | Out-Null
        $blLog = Join-Path $blDir 'PsadtExitCodes.log'
        $cmdB = (Get-Win32ToolkitBaselineInstallCommand -InstallerSandboxPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -InstallerType exe -SilentArgs '/c exit 3010').Replace('C:\PSADT\Sandbox\Logs\PsadtExitCodes.log', $blLog)
        & $ps51b -NoProfile -ExecutionPolicy Bypass -Command ('& { ' + $cmdB.Replace('\"', '"') + ' }; exit $LASTEXITCODE') | Out-Null
        $rcB = $LASTEXITCODE
        $lineB = @(if (Test-Path -LiteralPath $blLog) { Get-Content -LiteralPath $blLog })
        if ($rcB -eq 3010 -and $lineB.Count -eq 1 -and $lineB[0] -match '^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\dZ\] baseline Install parent=vendor exit=3010 result=SoftReboot$') { Ok "5.1: vendor exit 3010 -> `$LASTEXITCODE 3010 and '$($lineB[0])'" } else { Bad "5.1 baseline: rc=$rcB log=$($lineB -join ' | ')" }
        Remove-Item -LiteralPath $blDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Hostile values: apostrophes doubled, double quotes argv-escaped as \"
    $c = Get-Win32ToolkitBaselineInstallCommand -InstallerSandboxPath "C:\PSADT\Sandbox\OldVersion\O'Brien.exe" -InstallerType exe -SilentArgs 'INSTALLDIR="C:\Program Files\App"'
    if ($c -match [regex]::Escape("O''Brien.exe") -and $c -match [regex]::Escape('INSTALLDIR=\"C:\Program Files\App\"')) { Ok 'apostrophes doubled + double quotes argv-escaped' } else { Bad "hostile: [$c]" }
    # The command (with argv \" collapsed back to ") must parse as PowerShell
    $errsC = $null; [System.Management.Automation.Language.Parser]::ParseInput($c.Replace('\"', '"'), [ref]$null, [ref]$errsC) | Out-Null
    if (-not ($errsC -and $errsC.Count)) { Ok 'decoded command parses as PowerShell' } else { Bad "cmd parse: $($errsC[0].Message)" }

    # CRT argv rule: a backslash BEFORE an embedded quote must be doubled (INSTALLDIR="C:\App\" /qn),
    # or the quote toggles early and /qn is swallowed. Verify against a real argv decoder.
    $c2 = Get-Win32ToolkitBaselineInstallCommand -InstallerSandboxPath 'C:\PSADT\Sandbox\OldVersion\a.msi' -InstallerType msi -SilentArgs 'INSTALLDIR="C:\App\" /qn'
    if ($c2 -match [regex]::Escape('C:\App\\\"')) { Ok 'backslash-before-quote doubled per CRT rule' } else { Bad "crt: [$c2]" }
    Add-Type -AssemblyName System.Runtime.InteropServices -ErrorAction SilentlyContinue
    $sig = '[DllImport("shell32.dll", SetLastError = true)] public static extern IntPtr CommandLineToArgvW([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);'
    $w32 = Add-Type -MemberDefinition $sig -Name 'ArgvProbe' -Namespace 'W32T' -PassThru
    $numArgs = 0
    $argvPtr = $w32::CommandLineToArgvW("powershell.exe -Command `"$c2`"", [ref]$numArgs)
    $args2 = for ($ai = 0; $ai -lt $numArgs; $ai++) { [System.Runtime.InteropServices.Marshal]::PtrToStringUni([System.Runtime.InteropServices.Marshal]::ReadIntPtr($argvPtr, $ai * [IntPtr]::Size)) }
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($argvPtr) 2>$null
    $decoded = $args2[2]
    if ($decoded -match [regex]::Escape('INSTALLDIR="C:\App\" /qn')) { Ok 'CommandLineToArgvW round-trip preserves quote + /qn' } else { Bad "argv decode: [$decoded]" }
    # XML layer: encodes cleanly and round-trips
    $xml = "<Command>powershell.exe -Command &quot;&amp; { $(ConvertTo-XmlEncoded $c) }&quot;</Command>"
    try { [xml]("<root>$xml</root>") | Out-Null; Ok 'XML-encoded command yields valid XML' } catch { Bad "xml: $($_.Exception.Message)" }
    if ((ConvertTo-XmlEncoded 'C:\Win32 Apps & Co\X') -eq 'C:\Win32 Apps &amp; Co\X') { Ok 'HostFolder path encoding (& -> &amp;)' } else { Bad 'xml-encode path' }

    Write-Host "`n[5] Stale capture selection" -ForegroundColor Cyan
    . (Join-Path $repo 'Private\Get-LatestInstallationCapture.ps1')
    . (Join-Path $repo 'Private\Get-Win32DetectionRules.ps1')
    . (Join-Path $repo 'Private\New-TargetedDocumentation.ps1')
    # New-TargetedDocumentation now stages declared dependencies; this project declares none, so 0.
    function Initialize-Win32ToolkitDependencyStaging { param($ProjectPath) return 0 }
    . (Join-Path $repo 'Private\New-LogCollectorScript.ps1')
    . (Join-Path $repo 'Private\New-Win32ToolkitSandboxConfig.ps1')   # .wsb builder used by New-TargetedDocumentation

    # (a) newest-by-LastWriteTime wins even when NAME order disagrees
    $sp = Join-Path $base 'stale-proj'
    New-Item -ItemType Directory -Path (Join-Path $sp 'Documentation') -Force | Out-Null
    $nameNewest = Join-Path $sp 'Documentation\InstallationChanges_20991231_235959.json'
    $timeNewest = Join-Path $sp 'Documentation\InstallationChanges_20200101_000000.json'
    Set-Content $nameNewest '{"NewRegistryKeys":[]}'; Set-Content $timeNewest '{"NewRegistryKeys":[]}'
    (Get-Item $nameNewest).LastWriteTime = (Get-Date).AddHours(-2)
    (Get-Item $timeNewest).LastWriteTime = (Get-Date)
    $sel = Get-LatestInstallationCapture -ProjectPath $sp
    if ($sel.Name -eq 'InstallationChanges_20200101_000000.json') { Ok 'newest-by-LastWriteTime wins over name order' } else { Bad "selector picked $($sel.Name)" }
    $tie = Get-Date; (Get-Item $nameNewest).LastWriteTime = $tie; (Get-Item $timeNewest).LastWriteTime = $tie
    $sel2 = Get-LatestInstallationCapture -ProjectPath $sp
    if ($sel2.Name -eq 'InstallationChanges_20991231_235959.json') { Ok 'equal timestamps -> name-descending tie-break' } else { Bad "tie-break picked $($sel2.Name)" }

    # (b) detection-rule fallback keys off the FRESH capture (regression for the old -First 1 pick)
    $dp = Join-Path $base 'det-recency'
    New-Item -ItemType Directory -Path (Join-Path $dp 'Documentation') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dp 'SupportFiles') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dp 'SupportFiles\AppConfig.json'), '{"SchemaVersion":"1.0"}', (New-Object System.Text.UTF8Encoding($false)))
    $staleCap = Join-Path $dp 'Documentation\InstallationChanges_11111111_111111.json'
    $freshCap = Join-Path $dp 'Documentation\InstallationChanges_00000000_000000.json'   # name-order would pick this LAST
    ([pscustomobject]@{ NewRegistryKeys = @([pscustomobject]@{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{STALE}'; Values = @{} }) } | ConvertTo-Json -Depth 6) | Set-Content $staleCap
    ([pscustomobject]@{ NewRegistryKeys = @([pscustomobject]@{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{FRESH}'; Values = @{} }) } | ConvertTo-Json -Depth 6) | Set-Content $freshCap
    (Get-Item $staleCap).LastWriteTime = (Get-Date).AddDays(-1)
    (Get-Item $freshCap).LastWriteTime = (Get-Date)
    $rules = @(Get-Win32DetectionRules -ProjectPath $dp 6>$null)
    if ($rules.Count -eq 1 -and $rules[0]['keyPath'] -match 'FRESH') { Ok 'detection rule built from the FRESH capture' } else { Bad "detection keyPath: $($rules[0]['keyPath'])" }

    # (c) New-TargetedDocumentation -SkipLaunch: clears stale patterns, keeps user notes, returns expected path
    $tp = Join-Path $base 'doc-proj'
    New-Item -ItemType Directory -Path (Join-Path $tp 'Documentation') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tp 'Files') -Force | Out-Null
    Set-Content (Join-Path $tp 'Documentation\InstallationChanges_stale.json') '{}'
    Set-Content (Join-Path $tp 'Documentation\Targeted_Documentation_Log_stale.txt') 'x'
    Set-Content (Join-Path $tp 'Documentation\notes.md') 'keep me'
    $ret = New-TargetedDocumentation -ProjectPath $tp -ProjectName 'DocTest' -AppInfo ([pscustomobject]@{ Name = 'X'; Version = '1'; Id = 'X' }) -SkipLaunch 6>$null 3>$null
    if ($ret -is [string] -and $ret -match 'InstallationChanges_\d{8}_\d{6}\.json$') { Ok 'returns the expected capture path (truthy string)' } else { Bad "returned [$ret]" }
    if (-not (Test-Path (Join-Path $tp 'Documentation\InstallationChanges_stale.json'))) { Ok 'stale capture JSON cleared before launch' } else { Bad 'stale JSON survived' }
    if (-not (Test-Path (Join-Path $tp 'Documentation\Targeted_Documentation_Log_stale.txt'))) { Ok 'stale capture log cleared' } else { Bad 'stale log survived' }
    if (Test-Path (Join-Path $tp 'Documentation\notes.md')) { Ok 'user notes in Documentation\ survive' } else { Bad 'user notes deleted!' }

    Write-Host "`n[7] Resolve-Win32ToolkitBaselineSilentArgs (unknown/portable baseline types)" -ForegroundColor Cyan
    foreach ($t in 'portable', 'zip', 'pwa') {
        $threwT = $false
        try { Resolve-Win32ToolkitBaselineSilentArgs -InstallerTypeName $t -YamlSilentArgs '/S' | Out-Null }
        catch { $threwT = $_.Exception.Message -match 'no silent installer' }
        if ($threwT) { Ok "'$t' throws (even with YAML args) — no silent path" } else { Bad "'$t' did not throw" }
    }
    $r = Resolve-Win32ToolkitBaselineSilentArgs -InstallerTypeName 'nullsoft'
    if ($r.SilentArgs -eq '/S' -and -not $r.Guessed) { Ok 'known type nsis -> /S, Guessed=$false' } else { Bad "nsis: $($r | ConvertTo-Json -Compress)" }
    $r = Resolve-Win32ToolkitBaselineSilentArgs -InstallerTypeName 'msix'
    if ($r.SilentArgs -eq '' -and -not $r.Guessed) { Ok 'anchored msix -> empty (not /qn)' } else { Bad "msix: $($r | ConvertTo-Json -Compress)" }
    $r = Resolve-Win32ToolkitBaselineSilentArgs -InstallerTypeName 'randomtool'
    if ($r.SilentArgs -eq '/S' -and $r.Guessed) { Ok 'unknown type -> /S, Guessed=$true' } else { Bad "unknown: $($r | ConvertTo-Json -Compress)" }
    $r = Resolve-Win32ToolkitBaselineSilentArgs -Extension '.exe'
    if ($r.SilentArgs -eq '/S' -and $r.Guessed) { Ok 'typeless .exe -> /S, Guessed=$true' } else { Bad "exe: $($r | ConvertTo-Json -Compress)" }
    $r = Resolve-Win32ToolkitBaselineSilentArgs -InstallerTypeName 'inno' -YamlSilentArgs '/CUSTOM'
    if ($r.SilentArgs -eq '/CUSTOM' -and -not $r.Guessed) { Ok 'YAML args win over the type map' } else { Bad "yaml-win: $($r | ConvertTo-Json -Compress)" }

    # Download-OldVersionInstaller fails fast on a portable pin — BEFORE touching winget
    $dlThrew = $false
    try { Download-OldVersionInstaller -AppId 'X.Y' -Version '1.0' -ProjectPath $base -InstallerType 'portable' | Out-Null }
    catch { $dlThrew = $_.Exception.Message -match 'no silent installer' }
    if ($dlThrew) { Ok 'Download-OldVersionInstaller portable pin -> throws pre-download' } else { Bad 'portable pin did not throw early' }

    Write-Host "`n[6] Capture script: Win32_Product removed, NewPrograms derived from registry diff" -ForegroundColor Cyan
    $ntdRaw = Get-Content (Join-Path $repo 'Private\New-TargetedDocumentation.ps1') -Raw
    if ($ntdRaw -notmatch 'Win32_Product' -and $ntdRaw -notmatch 'Get-WmiObject') { Ok 'no Win32_Product / Get-WmiObject anywhere (regression guard)' } else { Bad 'WMI product enumeration still present' }

    # The embedded 5.1 sandbox script must still parse after the edits
    $hsMatch = [regex]::Match($ntdRaw, "(?s)\`$documentationScript = @'\r?\n(.*?)\r?\n'@")
    if ($hsMatch.Success) {
        $errsHS = $null
        [System.Management.Automation.Language.Parser]::ParseInput($hsMatch.Groups[1].Value, [ref]$null, [ref]$errsHS) | Out-Null
        if (-not ($errsHS -and $errsHS.Count)) { Ok 'embedded capture script parses (5.1 sandbox safety)' } else { Bad "capture script parse: $($errsHS[0].Message)" }
    } else { Bad 'could not extract the capture here-string' }

    Write-Host "`n[8] OldArpGone assertion + Test-LooseVersionEqual + baseline tattoo" -ForegroundColor Cyan
    $ap = Join-Path $base 'arp-proj'
    New-Item -ItemType Directory -Path (Join-Path $ap 'SupportFiles') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ap 'SupportFiles\AppConfig.json'),
        '{"App":{"DisplayName":"Git","Name":"","Vendor":"Git Dev","Version":"2.55.0","ScriptAuthor":"Contoso IT"},"Uninstall":{"AppName":"Git version 2.55.0"}}',
        (New-Object System.Text.UTF8Encoding($false)))
    # hostile old-version apostrophe
    $ag = Get-Content -LiteralPath (New-UpdateAssertionScript -ProjectPath $ap -OldVersion "2.53'0") -Raw
    $agErr = $null; [System.Management.Automation.Language.Parser]::ParseInput($ag, [ref]$null, [ref]$agErr) | Out-Null
    if (-not ($agErr -and $agErr.Count)) { Ok 'assertion script with -OldVersion parses' } else { Bad "parse: $($agErr[0].Message)" }
    if ($ag -match "'PreBaseline', 'PreUpdate', 'PostUpdate'") { Ok 'ValidateSet includes PreBaseline' } else { Bad 'PreBaseline phase missing' }
    if ($ag -match 'ASSERT OldArpGone-PostUpdate' -and $ag -match 'PreUpdateArpBaseline.json' -and $ag -match 'HKCU:\\SOFTWARE' -and $ag -match 'WOW6432Node') { Ok 'OldArpGone block: 3 hives + identified-file' } else { Bad 'OldArpGone block incomplete' }
    if ($ag -match [regex]::Escape("'2.53''0'")) { Ok 'OldVersion escaped as data' } else { Bad 'OldVersion not escaped' }
    if ($ag -match [regex]::Escape("'Git version 2.55.0'")) { Ok 'captured Uninstall.AppName in candidate names' } else { Bad 'candidate name missing' }
    # WITHOUT -OldVersion still parses + OldArpGone present (name-only identification)
    $agNo = Get-Content -LiteralPath (New-UpdateAssertionScript -ProjectPath $ap) -Raw
    $agNoErr = $null; [System.Management.Automation.Language.Parser]::ParseInput($agNo, [ref]$null, [ref]$agNoErr) | Out-Null
    if (-not ($agNoErr -and $agNoErr.Count) -and $agNo -match 'ASSERT OldArpGone-PostUpdate') { Ok 'no -OldVersion: still parses + OldArpGone present' } else { Bad 'no-OldVersion generation broken' }
    # 'Unknown App' sentinel must be filtered from candidates
    [System.IO.File]::WriteAllText((Join-Path $ap 'SupportFiles\AppConfig.json'),
        '{"App":{"DisplayName":"Git","Vendor":"V","Version":"2.55.0","ScriptAuthor":"A"},"Uninstall":{"AppName":"Unknown App"}}',
        (New-Object System.Text.UTF8Encoding($false)))
    $agUnk = Get-Content -LiteralPath (New-UpdateAssertionScript -ProjectPath $ap -OldVersion '2.53.0') -Raw
    if ($agUnk -notmatch "'Unknown App'") { Ok "'Unknown App' sentinel filtered from candidate names" } else { Bad "sentinel leaked into candidates" }
    # -ExpectBaselineTattoo adds the PreUpdate baseline-tattoo assertion
    $agBt = Get-Content -LiteralPath (New-UpdateAssertionScript -ProjectPath $ap -OldVersion '2.53.0' -ExpectBaselineTattoo) -Raw
    if ($agBt -match 'ASSERT TattooBaseline-PreUpdate') { Ok '-ExpectBaselineTattoo adds TattooBaseline-PreUpdate' } else { Bad 'baseline tattoo assertion missing' }
    if ($agNo -notmatch 'ASSERT TattooBaseline') { Ok 'no baseline tattoo assertion without the switch' } else { Bad 'baseline tattoo present unexpectedly' }
    # Extract Test-LooseVersionEqual and verify its rules
    $lvFn = [regex]::Match($ag, '(?s)function Test-LooseVersionEqual.*?\n\}').Value
    Invoke-Expression $lvFn
    if ((Test-LooseVersionEqual '2.53.0' 'v2.53.0') -and (Test-LooseVersionEqual '2.5' '2.5.0') -and (Test-LooseVersionEqual '2.53.0' '2.53.0.windows.1') -and -not (Test-LooseVersionEqual '2.53.0' '2.54.0') -and -not (Test-LooseVersionEqual 'x' 'y')) { Ok 'Test-LooseVersionEqual: v-prefix, padding, suffix, mismatch, garbage' } else { Bad 'loose-version rules wrong' }
    # Test-VersionUnchanged: strict — 2.5==2.5.0 (unchanged) but 2.5.1 != 2.5 (bumped -> NOT a false FAIL)
    $vuFn = [regex]::Match($ag, '(?s)function Test-VersionUnchanged.*?\n\}').Value
    Invoke-Expression $vuFn
    if ((Test-VersionUnchanged '2.5.0' '2.5') -and (Test-VersionUnchanged '2.53.0' '2.53.0') -and -not (Test-VersionUnchanged '2.5.1' '2.5') -and -not (Test-VersionUnchanged '2.54.0' '2.53.0')) { Ok 'Test-VersionUnchanged: trailing-zero drift equal, prefix bump 2.5->2.5.1 NOT unchanged' } else { Bad 'version-unchanged rules wrong (prefix false-FAIL risk)' }
    if ($ag -match [regex]::Escape('Test-VersionUnchanged "$($p.DisplayVersion)" $expectedOldVersion')) { Ok 'PostUpdate bump-decision uses strict Test-VersionUnchanged' } else { Bad 'PostUpdate still uses loose match for bump' }
    if ($ag -match [regex]::Escape('$identified = @(Read-JsonArray $identifiedFile | Where-Object { $_ -and $_.KeyPath })')) { Ok 'identified-set read element by element, filtering the empty-array artifact (SKIP not false-PASS)' } else { Bad 'identified-set read is not element by element' }
    # Live run OP-OWN (2026-10-27): under Windows PowerShell 5.1 ConvertFrom-Json writes a JSON array as ONE object, so the
    # PreBaseline exclusion never worked and two surviving old entries were read back as one (their versions joined into
    # '8.9.8.1 8.9.8.1', judged "upgraded": a false OldArpGone PASS). The generated script, run under 5.1 with its ARP
    # reads stubbed and C:\PSADT pointed at a temp folder.
    $ps51j = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps51j) {
        $jRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('w32arp_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $jProj = Join-Path $jRoot 'proj'
        New-Item -ItemType Directory -Path (Join-Path $jProj 'SupportFiles'), (Join-Path $jRoot 'guest\Sandbox\Logs'), (Join-Path $jRoot 'guest\SupportFiles') -Force | Out-Null
        $jCfg = '{"App":{"DisplayName":"Notepad++","Name":"","Vendor":"Notepad++ Team","Version":"8.9.8.2","ScriptAuthor":"Contoso IT"},"Uninstall":{"AppName":"Notepad++ (64-bit x64)"}}'
        [System.IO.File]::WriteAllText((Join-Path $jProj 'SupportFiles\AppConfig.json'), $jCfg, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $jRoot 'guest\SupportFiles\AppConfig.json'), $jCfg, (New-Object System.Text.UTF8Encoding($false)))
        $jText = Get-Content -LiteralPath (New-UpdateAssertionScript -ProjectPath $jProj -OldVersion '8.9.8.1' -SkipRequirement) -Raw
        $jStub = @'
$identifiedFile  = Join-Path $logDir 'PreUpdateArpBaseline.json'
function Get-ArpEntries { $s = Get-Content -LiteralPath $env:W32T_T_ARP -Raw | ConvertFrom-Json; foreach ($x in @($s)) { if ($x) { [pscustomobject]@{ KeyPath = [string]$x.KeyPath; DisplayName = [string]$x.DisplayName; DisplayVersion = [string]$x.DisplayVersion } } } }
function Get-ItemProperty { param([string]$LiteralPath, $Name, $ErrorAction) $s = Get-Content -LiteralPath $env:W32T_T_ARP -Raw | ConvertFrom-Json; foreach ($x in @($s)) { if ($x -and [string]$x.KeyPath -eq $LiteralPath) { return [pscustomobject]@{ DisplayName = [string]$x.DisplayName; DisplayVersion = [string]$x.DisplayVersion; UninstallString = '' } } }; throw 'absent' }
'@
        $jText = $jText.Replace("`$identifiedFile  = Join-Path `$logDir 'PreUpdateArpBaseline.json'", $jStub.TrimEnd()).Replace('C:\PSADT\', (Join-Path $jRoot 'guest') + '\')
        $jScript = Join-Path $jRoot 'UpdateAssertions.ps1'
        [System.IO.File]::WriteAllText($jScript, $jText, (New-Object System.Text.UTF8Encoding($true)))
        $jKey = { param($n) "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$n" }
        $jRun = {
            param([object[]]$Before, [object[]]$Baseline)
            $log = Join-Path $jRoot 'guest\Sandbox\Logs\UpdateAssertions.log'
            Get-ChildItem -LiteralPath (Join-Path $jRoot 'guest\Sandbox\Logs') -File | Remove-Item -Force
            $state = Join-Path $jRoot 'arp.json'
            foreach ($step in @(@('PreBaseline', $Before), @('PreUpdate', $Baseline), @('PostUpdate', $Baseline))) {
                [System.IO.File]::WriteAllText($state, (ConvertTo-Json -InputObject @($step[1]) -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
                $env:W32T_T_ARP = $state
                try { & $ps51j -NoProfile -ExecutionPolicy Bypass -File $jScript -Phase $step[0] *> $null } finally { Remove-Item Env:\W32T_T_ARP -ErrorAction SilentlyContinue }
            }
            @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
        }
        try {
            # The vendor NSIS install was there before the baseline (a declared dependency); the baseline adds the MSI.
            $nsis = [pscustomobject]@{ KeyPath = (& $jKey 'Notepad++'); DisplayName = 'Notepad++ (64-bit x64)'; DisplayVersion = '8.9.8.1' }
            $msi = [pscustomobject]@{ KeyPath = (& $jKey '{5C6F0000-0000-0000-0000-000000000001}'); DisplayName = 'Notepad++ (64-bit x64)'; DisplayVersion = '8.9.8.1' }
            $other = [pscustomobject]@{ KeyPath = (& $jKey 'Other'); DisplayName = 'Other'; DisplayVersion = '1.0' }
            $lines = & $jRun @($nsis, $other) @($nsis, $other, $msi)
            $idLine = @($lines | Where-Object { $_ -match 'PreUpdate: identified' })
            $failLine = @($lines | Where-Object { $_ -match 'ASSERT OldArpGone-PostUpdate = FAIL' })
            if ($idLine.Count -eq 1 -and $idLine[0] -match 'identified 1 ARP entry' -and $failLine.Count -eq 1 -and $failLine[0] -match [regex]::Escape('{5C6F0000') -and $failLine[0] -notmatch 'Uninstall\\Notepad\+\+\]') {
                Ok '5.1: an entry present before the baseline is not the old app; the surviving baseline entry FAILs OldArpGone'
            } else { Bad "5.1 PreBaseline exclusion: $($lines -join ' | ')" }
            # Two old entries the baseline installed, both still registered at the old version after the update.
            $a = [pscustomobject]@{ KeyPath = (& $jKey 'AppA'); DisplayName = 'Notepad++'; DisplayVersion = '8.9.8.1' }
            $b = [pscustomobject]@{ KeyPath = (& $jKey 'AppB'); DisplayName = 'Notepad++ (64-bit x64)'; DisplayVersion = '8.9.8.1' }
            $lines = & $jRun @() @($a, $b)
            $failLine = @($lines | Where-Object { $_ -match 'ASSERT OldArpGone-PostUpdate = FAIL' })
            if (@($lines | Where-Object { $_ -match 'identified 2 ARP entry' }).Count -eq 1 -and $failLine.Count -eq 1 -and $failLine[0] -match 'AppA' -and $failLine[0] -match 'AppB' -and @($lines | Where-Object { $_ -match 'OldArpGone-PostUpdate = PASS' }).Count -eq 0) {
                Ok '5.1: two surviving old entries stay two (OldArpGone FAIL names both, never a PASS)'
            } else { Bad "5.1 two survivors: $($lines -join ' | ')" }
            # Read-JsonArray itself: 0, 1 and 2 elements, as 5.1 writes them.
            $rjFn = [regex]::Match($jText, '(?s)function Read-JsonArray.*?\r?\n\}').Value
            $rjScript = Join-Path $jRoot 'rj.ps1'
            [System.IO.File]::WriteAllText($rjScript, ($rjFn + "`r`n" + @'
$f = Join-Path $env:TEMP ('w32rj_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
foreach ($case in @(@(), @(@{ Path = 'p1' }), @(@{ Path = 'p1' }, @{ Path = 'p2' }))) {
    ConvertTo-Json -InputObject @($case) | Set-Content -LiteralPath $f -Encoding UTF8
    'n=' + @(Read-JsonArray $f | Where-Object { $_ -and $_.Path }).Count
}
Remove-Item -LiteralPath $f -Force
'n=' + @(Read-JsonArray (Join-Path $env:TEMP 'w32rj-missing.json')).Count
'@), (New-Object System.Text.UTF8Encoding($true)))
            $rj = @(& $ps51j -NoProfile -ExecutionPolicy Bypass -File $rjScript 2>&1 | ForEach-Object { "$_" })
            if (($rj -join ',') -eq 'n=0,n=1,n=2,n=0') { Ok '5.1: Read-JsonArray gives 0, 1 and 2 elements (and nothing for a missing file)' } else { Bad "Read-JsonArray: $($rj -join ',')" }
            # Live run SB-ENFORCE (2026-10-27): the host polls the mapped UpdateAssertions.log while the Windows Sandbox guest
            # appends to it; 5.1 Add-Content fails on a file another process holds open and dropped 7 PostUpdate lines (a
            # lost FAIL would turn a failed update into a pass). The generated writer under 5.1, behind a held read handle.
            $wLog = Join-Path $jRoot 'held.log'
            $wFn = [regex]::Match($jText, '(?s)function Write-AssertLine.*?\r?\n\}').Value
            [System.IO.File]::WriteAllText((Join-Path $jRoot 'w.ps1'), ("param([string]`$Log)`r`n`$assertLog = `$Log`r`n" + $wFn + "`r`nfor (`$i = 1; `$i -le 20; `$i++) { Write-AssertLine ('ASSERT Line' + `$i + ' = PASS') }`r`n"), (New-Object System.Text.UTF8Encoding($true)))
            $held = [System.IO.File]::Open($wLog, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try { $null = & $ps51j -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $jRoot 'w.ps1') -Log $wLog 2>&1 }
            finally { $held.Dispose() }
            $wLines = @(Get-Content -LiteralPath $wLog -Encoding UTF8 | Where-Object { $_ -match '^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\dZ\] ASSERT Line\d+ = PASS$' })
            if ($wLines.Count -eq 20) { Ok '5.1: every assertion line is written while the host holds the log open for reading' } else { Bad "5.1 writer under a held reader: $($wLines.Count) of 20 lines" }
        }
        finally { Remove-Item -LiteralPath $jRoot -Recurse -Force -ErrorAction SilentlyContinue }
    } else { Bad 'Windows PowerShell 5.1 is not available for the OldArpGone guest test' }
    # Single-entry ConvertTo-Json round-trip (the 5.1 array-collapse trap the PreBaseline/identified files hit)
    $one = @([pscustomobject]@{ KeyPath = 'k'; DisplayName = 'n'; DisplayVersion = 'v' })
    $rtOne = @(ConvertTo-Json -InputObject @($one) | ConvertFrom-Json)
    if ($rtOne.Count -eq 1 -and $rtOne[0].KeyPath -eq 'k') { Ok 'single-entry JSON round-trips as an array (-InputObject @())' } else { Bad "json array trap: count=$($rtOne.Count)" }

    Write-Host "`n[9] -BaselineProjectPath validation (throws before any sandbox work)" -ForegroundColor Cyan
    # Real project-under-test dir (must exist + have the deploy script) so resolution passes and we
    # reach the baseline validation, which throws deterministically BEFORE the sandbox pre-flight.
    $put = Join-Path $base 'put'; New-Item -ItemType Directory -Path $put -Force | Out-Null
    Set-Content (Join-Path $put 'Invoke-AppDeployToolkit.ps1') '# stub'
    function Test-BaselineErr($splat, $pattern) {
        $ev = $null
        try { Test-Win32ToolkitProject @splat -ErrorVariable ev -ErrorAction SilentlyContinue | Out-Null } catch { $ev = $_ }
        return (@($ev) -match $pattern).Count -gt 0
    }
    if (Test-BaselineErr @{ ProjectPath = $put; Scenario = 'Update'; BaselineProjectPath = $put; VersionsBack = 1 } 'mutually exclusive') { Ok '-BaselineProjectPath + -VersionsBack -> error' } else { Bad 'mutual-exclusion not enforced' }
    if (Test-BaselineErr @{ ProjectPath = $put; Scenario = 'Update'; BaselineProjectPath = (Join-Path $base 'does-not-exist') } 'not found') { Ok 'missing baseline path -> error' } else { Bad 'missing-path not caught' }
    $noScript = Join-Path $base 'noscript'; New-Item -ItemType Directory -Path $noScript -Force | Out-Null
    if (Test-BaselineErr @{ ProjectPath = $put; Scenario = 'Update'; BaselineProjectPath = $noScript } 'Not a PSADT project') { Ok 'baseline without Invoke-AppDeployToolkit.ps1 -> error' } else { Bad 'non-PSADT baseline not caught' }
    $noVer = Join-Path $base 'nover'; New-Item -ItemType Directory -Path $noVer -Force | Out-Null
    Set-Content (Join-Path $noVer 'Invoke-AppDeployToolkit.ps1') '# stub'   # exists, differs from $put, but no AppConfig App.Version
    if (Test-BaselineErr @{ ProjectPath = $put; Scenario = 'Update'; BaselineProjectPath = $noVer } 'no App.Version') { Ok 'baseline without App.Version -> clear regenerate error' } else { Bad 'no-App.Version not caught' }

    # Execute the derivation block (between its BEGIN/END markers) against a fixture
    $derMatch = [regex]::Match($ntdRaw, '(?s)# BEGIN NewPrograms derivation.*?# END NewPrograms derivation')
    if ($derMatch.Success) {
        function Write-Log { param($m, $l) }   # stub — defined only inside the sandbox script
        $jsonData = @{
            NewPrograms = @()
            NewRegistryKeys = @(
                @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\EvilApp'
                   Values = @{ DisplayName = "Evil'App"; DisplayVersion = '1.2.3'; Publisher = "O'Reilly"
                               UninstallString = '"C:\Program Files\EvilApp\unins000.exe" /SILENT'; InstallLocation = 'C:\Program Files\EvilApp' } }
                @{ Path = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\EvilApp'
                   Values = @{ DisplayName = "Evil'App"; DisplayVersion = '1.2.3' } }   # dup in 2nd hive -> deduped
                @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\evil.exe'; Values = @{ DisplayName = 'NotAProgram' } }
                @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\NoName'; Values = @{} }
            )
        }
        & ([scriptblock]::Create($derMatch.Value))
        if (@($jsonData.NewPrograms).Count -eq 1) { Ok 'exactly 1 derived program (dedupe + filters work)' } else { Bad "derived count: $(@($jsonData.NewPrograms).Count)" }
        $np = @($jsonData.NewPrograms)[0]
        if ($np.Name -eq "Evil'App" -and $np.DisplayName -eq $np.Name -and $np.DisplayVersion -eq '1.2.3' -and $np.Path -eq 'C:\Program Files\EvilApp' -and $np.ContainsKey('UninstallString')) { Ok 'derived shape: Name/DisplayName/DisplayVersion/Publisher/UninstallString/Path' } else { Bad "shape: $($np | ConvertTo-Json -Compress)" }
        $rt = ($jsonData | ConvertTo-Json -Depth 8) | ConvertFrom-Json
        if (@($rt.NewPrograms).Count -eq 1 -and $rt.NewPrograms[0].DisplayName -eq "Evil'App") { Ok 'derived data round-trips through JSON' } else { Bad 'JSON round-trip failed' }
    } else { Bad 'derivation block markers not found' }

    Write-Host "`n[10] Baseline technology (installer-identity PR 1): Auto, fallback, unavailable, Both, the Git scope case" -ForegroundColor Cyan
    # C-9: the Update arm now resolves the baseline technology (the real resolver and the WP-3 family table) and
    # reads the source facts, the identity delta and the technology-switch finding (shadowed). The guest run is
    # shadowed (Hyper-V, unattended); nothing is downloaded, installed or started.
    . (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
    . (Join-Path $repo 'Private\Get-Win32ToolkitInstallerFamily.ps1')
    . (Join-Path $repo 'Private\Test-Win32ToolkitWingetNoApplicableInstaller.ps1')
    . (Join-Path $repo 'Private\Resolve-Win32ToolkitBaselineFamily.ps1')
    . (Join-Path $repo 'Private\Get-WingetManifestFile.ps1')
    . (Join-Path $repo 'Private\Get-YAMLInstallerInfo.ps1')
    . (Join-Path $repo 'Private\Get-WingetIdFromProject.ps1')

    # Shadows declare only the parameters they read (the rest arrive in $args); state-changing verbs are defined through
    # the function: drive, like a plain test double.
    $script:testBackend = 'HyperV'; $script:testModeCfg = 'Unattended'
    function Get-Win32ToolkitTestBackend { $script:testBackend }
    function Get-Win32ToolkitConfigValue { $script:testModeCfg }
    function Get-Win32ToolkitHyperVTarget { param([switch]$NoThrow) [pscustomobject]@{ VMName = 'win32tk-golden'; CheckpointName = 'clean-base'; Source = 'Default'; CheckpointSource = 'Default'; Pinned = $false; Problem = $null } }   # C-9: menu selectors D13 resolves once per call
    ${function:New-Win32ToolkitPackageRunnerScript} = { 'runner' }
    function Initialize-Win32ToolkitDependencyStaging { 0 }
    ${function:New-LogCollectorScript} = { 'collector' }
    function Get-Win32ToolkitRequirementRule { 'rule' }
    ${function:New-UpdateAssertionScript} = { 'assert.ps1' }
    $script:hvRuns = 0
    $script:hvHints = [System.Collections.Generic.List[string]]::new()   # each run's 'Update (Intune parity)' ParityHint
    function Invoke-Win32ToolkitHyperVRun {
        param($ProjectPath, $Phase, $Output, $BaselineProjectPath)
        $script:hvRuns++
        $script:lastHvPhase = $Phase
        $upd = @($Phase | Where-Object { $_.Label -eq 'Update (Intune parity)' })
        if ($upd.Count) { $script:hvHints.Add([string]$upd[0].ParityHint) }
        $ld = Join-Path $ProjectPath 'Sandbox\Logs'
        New-Item -ItemType Directory -Path $ld -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ld 'UpdateAssertions.log') -Value "[t] ASSERT Tattoo-PostUpdate = PASS (guest run $script:hvRuns)" -Encoding UTF8
        Add-Content -LiteralPath (Join-Path $ld 'PsadtExitCodes.log') -Value "[t] update Install parent=x86-cmd exit=0 result=Success (guest run $script:hvRuns)" -Encoding UTF8
        $true
    }
    $script:verdictQueue = [System.Collections.Generic.Queue[object]]::new()
    function Wait-Win32ToolkitUpdateAssertion { if ($script:verdictQueue.Count) { $script:verdictQueue.Dequeue() } else { $true } }
    ${function:Get-WingetVersions} = { @('8.8.9', '8.8.8') }
    $script:pickerCalls = 0
    function Show-VersionSelection { param($Versions) $script:pickerCalls++; Write-Host 'PICKER-CALLED'; $Versions[0] }
    $script:outcomes = [System.Collections.Generic.List[object]]::new()
    function Write-Win32ToolkitTestOutcome { param($Scenario, $Verdict, $Baseline, $LogFolder) $script:outcomes.Add([pscustomobject]@{ Scenario = $Scenario; Verdict = $Verdict; Baseline = $Baseline; LogFolder = $LogFolder }) }
    $script:records = [System.Collections.Generic.List[object]]::new()
    function Add-Win32ToolkitTestResult { param($Scenario, $Backend, $Verdict, $Mode, $Assertions, $Notes, $Baseline, [hashtable]$NotRun) $script:records.Add([pscustomobject]@{ Scenario = $Scenario; Backend = $Backend; Verdict = $Verdict; Mode = $Mode; Assertions = @($Assertions); Notes = $Notes; Baseline = $Baseline; NotRun = $NotRun }) }
    # C-9 (installer-identity PR 2): an unattended Hyper-V Update asks the Intune-parity pre-check before Step 1. Not
    # blocked by default, PSADT 4.1 dialog risk found (no processes to close; the update phase's 1460 hint is then
    # 'Dialog41'); (j) blocks it, or clears the risk.
    $script:preCalls = [System.Collections.Generic.List[string]]::new()
    $script:preBlocked = $false
    $script:preAtRisk = $true
    $script:preProcessCount = 0
    function Invoke-Win32ToolkitParityPrecheck {
        param($ProjectPath, $Scenario)
        $script:preCalls.Add([string]$Scenario)
        [pscustomobject]@{
            Blocked = $script:preBlocked; Risk = @{ AtRisk = $script:preAtRisk; Shape = 'Psadt41'; ProcessCount = $script:preProcessCount }; Guest = $null
            Message = $(if ($script:preBlocked) { 'PRECHECK-MESSAGE' } else { '' }); Notes = $(if ($script:preBlocked) { 'Not run (Intune-parity pre-check): x' } else { '' })
            NotRun  = $(if ($script:preBlocked) { @{ Code = 'PARITY-DIALOG-WAIT'; Shape = 'Psadt41'; ProcessesToClose = 0; Welcome = 'OrgUi'; SignedInSessions = 1 } } else { $null })
        }
    }
    $script:switchCalls = 0
    function Get-Win32ToolkitTechnologySwitch { $script:switchCalls++; [pscustomobject]@{ Code = 'ID-TECH-SWITCH'; Message = 'Technology switch: TEST' } }
    $script:source = [pscustomobject]@{ InstallerType = 'wix'; Family = 'msi'; Scope = 'machine' }
    function Get-Win32ToolkitProjectSource { $script:source }
    $script:deltaWrites = 0
    function Write-Win32ToolkitIdentityDelta { $script:deltaWrites++ }

    # The old-version download, shadowed: records each call; $script:dlAnswer decides ('ok' | 'ivu' | 'boom').
    $script:dlCalls = [System.Collections.Generic.List[hashtable]]::new()
    $script:dlAnswer = { 'ok' }
    ${function:New-IvuError} = {
        param([string]$Message)
        [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($Message), 'W32T.InstallerVariantUnavailable',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound, 'x')
    }
    $dlShadow = {
        param($AppId, $Version, $ProjectPath, $DestinationDir, $Architecture, $Scope, $InstallerType, $Locale, [switch]$FamilyPin)
        $h = @{}; foreach ($k in $PSBoundParameters.Keys) { $h[$k] = $PSBoundParameters[$k] }
        $script:dlCalls.Add($h)
        $answer = & $script:dlAnswer $InstallerType
        if ($answer -eq 'ivu') { throw (New-IvuError "winget offers no $InstallerType installer for $AppId v$Version.") }
        if ($answer -eq 'boom') { throw "network down while downloading $InstallerType" }
        [pscustomobject]@{
            InstallerPath = 'C:\x\old.exe'; InstallerName = 'old.exe'; InstallerType = $(if ($InstallerType -in 'msi', 'wix') { 'msi' } else { 'exe' }); SilentArgs = '/S'
            UsedFallback = $false; RequestedInstallerType = $InstallerType; ManifestInstallerType = $InstallerType; ManifestProductCode = ''; Scope = 'machine'; Locale = 'en-US'
            Family = (Get-Win32ToolkitInstallerFamily -Type $InstallerType).Family; TriedTypes = @($InstallerType); ScopeRelaxed = $false
        }
    }
    ${function:Download-OldVersionInstaller} = $dlShadow

    # A Notepad++ 8.9.8.1 x64 project (the fixture manifest) whose IdentityDelta.json lists the nullsoft sibling.
    $np = Join-Path $base 'npp'
    New-Item -ItemType Directory -Path (Join-Path $np 'Files'), (Join-Path $np 'Documentation'), (Join-Path $np 'SupportFiles') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'Tests\Fixtures\winget-manifests\Notepad++.Notepad++\8.9.8.1.installer.yaml') -Destination (Join-Path $np 'Files\Notepad++.Notepad++.installer.yaml')
    Set-Content -LiteralPath (Join-Path $np 'Invoke-AppDeployToolkit.ps1') -Value '# stub'
    $nppDelta = [pscustomobject]@{ SchemaVersion = '1.0'; Siblings = @([pscustomobject]@{
                EffectiveType = 'nullsoft'; RegisteredType = ''; Family = 'exe'; InstallerType = 'nullsoft'; NestedInstallerType = ''; Scope = 'machine'; ProductCode = 'Notepad++'
                ZipWrapped = $false; Registers = $true; Testable = $true; PinValue = 'nullsoft'; Precedence = 7; Label = 'nullsoft (vendor EXE, NSIS)' }) }
    [System.IO.File]::WriteAllText((Join-Path $np 'Documentation\IdentityDelta.json'), ($nppDelta | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    function Clear-RunState {
        $script:dlCalls.Clear(); $script:outcomes.Clear(); $script:records.Clear(); $script:verdictQueue.Clear()
        $script:switchCalls = 0; $script:pickerCalls = 0; $script:W32TUpdateLegContext = $null; $script:dlAnswer = { 'ok' }
        $script:preCalls.Clear(); $script:hvHints.Clear(); $script:preBlocked = $false; $script:preAtRisk = $true; $script:preProcessCount = 0
        $script:cleanupCalls = 0; $script:cleanupFindings = @()
    }
    function Split-Out($Items) {
        [pscustomobject]@{
            Warnings = @($Items | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { "$_" })
            Info     = @($Items | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
            Values   = @($Items | Where-Object { $null -ne $_ -and $_ -isnot [System.Management.Automation.WarningRecord] -and $_ -isnot [System.Management.Automation.InformationRecord] })
        }
    }

    # (a) default Auto -> the sibling technology, printed before the version picker (an interactive run on an interactive host)
    Clear-RunState
    $script:testModeCfg = 'Interactive'
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update 6>&1 3>&1)
    $script:testModeCfg = 'Unattended'
    $iTech = [array]::FindIndex([string[]]$o.Info, [Predicate[string]] { param($l) $l -like 'Baseline technology : nullsoft (vendor EXE, NSIS) (other technology winget ships for this app)' })
    $iPick = [array]::IndexOf([string[]]$o.Info, 'PICKER-CALLED')
    if ($iTech -ge 0 -and $iPick -gt $iTech -and $script:pickerCalls -eq 1) { Ok "'Baseline technology : <label>' is printed before the version picker is called (Dv5)" } else { Bad "order: tech=$iTech pick=$iPick" }
    $c0 = if ($script:dlCalls.Count) { $script:dlCalls[0] } else { @{} }
    if ($script:dlCalls.Count -eq 1 -and $c0['FamilyPin'] -and $c0['InstallerType'] -eq 'nullsoft' -and $c0['Scope'] -eq 'machine' -and $c0['Version'] -eq '8.8.9' -and -not $c0.ContainsKey('Locale')) { Ok 'default Auto: Download-OldVersionInstaller gets -FamilyPin -InstallerType nullsoft (the sibling) -Scope machine, no -Locale' }
    else { Bad "auto call: $($script:dlCalls | ConvertTo-Json -Compress)" }
    $b0 = if ($script:outcomes.Count) { $script:outcomes[0].Baseline } else { $null }
    if ($script:outcomes.Count -eq 1 -and $b0 -and $b0.Mode -eq 'Auto' -and $b0.Origin -eq 'Sibling' -and $b0.InstallerType -eq 'nullsoft' -and $b0.Family -eq 'exe' -and
        $b0.Version -eq '8.8.9' -and $b0.UsedFallback -eq $false -and $b0.Source -eq 'winget' -and $b0.Unavailable -eq $false) { Ok 'the outcome is recorded with -Baseline (Mode Auto, Origin Sibling, nullsoft/exe, v8.8.9)' }
    else { Bad "baseline: $($b0 | ConvertTo-Json -Compress)" }
    if (@($o.Values) -contains $true -and $script:switchCalls -eq 0) { Ok 'a PASS returns $true and runs no technology-switch check' } else { Bad "values=$($o.Values -join ',') switch=$script:switchCalls" }
    # The vendor baseline phase ends with its exact exit code and is judged like a package (H6-F7).
    $blPh = @($script:lastHvPhase | Where-Object { $_.Label -like 'Install baseline*' })[0]
    if ($blPh -and ([string]$blPh.Command).EndsWith('$global:LASTEXITCODE = $w32tRc; exit $LASTEXITCODE') -and (@($blPh.SuccessExitCodes) -join ',') -eq '0,1707,3010,1641') { Ok 'Hyper-V vendor baseline phase: exit $LASTEXITCODE + SuccessExitCodes 0/1707/3010/1641 (a failed baseline is warned)' } else { Bad "baseline phase: $($blPh | ConvertTo-Json -Compress)" }
    $f5Warn = 'No baseline version was given (-VersionsBack or -SpecificVersion) and this run cannot ask for one (an unattended run or a non-interactive host): the Update test uses the previous version (-VersionsBack 1). Pass -VersionsBack or -SpecificVersion to test from another version.'
    if (@($o.Warnings) -notcontains $f5Warn) { Ok 'an interactive run on an interactive host still shows the picker (no default, no warning)' } else { Bad 'interactive run got the F5 default' }

    # (a1) Test campaign F5: no version given and nobody to ask -> the previous version with one warning, never the picker
    # (its Read-Host threw under -NonInteractive: no verdict, and packaging went on untested).
    foreach ($case in @(
            @{ Label = 'HyperVTestMode=Unattended'; Cfg = 'Unattended'; NonInteractiveHost = $false; Extra = @{} }
            @{ Label = '-Unattended'; Cfg = 'Interactive'; NonInteractiveHost = $false; Extra = @{ Unattended = $true } }
            @{ Label = 'a non-interactive host'; Cfg = 'Interactive'; NonInteractiveHost = $true; Extra = @{} }
            @{ Label = 'a console started with pwsh -NonInteractive'; Cfg = 'Interactive'; NonInteractiveHost = $false; NoniSwitch = $true; Extra = @{} }
            @{ Label = '-TestMode Unattended'; Cfg = 'Interactive'; NonInteractiveHost = $false; Extra = @{ TestMode = 'Unattended' } })) {
        Clear-RunState
        $script:testModeCfg = $case.Cfg; $script:hostNonInteractive = $case.NonInteractiveHost; $script:noniSwitch = [bool]$case.NoniSwitch
        $extra = $case.Extra
        $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update @extra 6>&1 3>&1)
        $c0 = if ($script:dlCalls.Count) { $script:dlCalls[0] } else { @{} }
        if ($script:pickerCalls -eq 0 -and @($o.Warnings | Where-Object { $_ -eq $f5Warn }).Count -eq 1 -and $script:dlCalls.Count -eq 1 -and $c0['Version'] -eq '8.8.9' -and @($o.Values) -contains $true) {
            Ok "F5, $($case.Label): no picker; the previous version (8.8.9) with one warning; a verdict"
        } else { Bad "F5 $($case.Label): picker=$($script:pickerCalls) version=$($c0['Version']) values=$($o.Values -join ',') warnings=$($o.Warnings -join ' | ')" }
    }
    $script:testModeCfg = 'Unattended'; $script:hostNonInteractive = $false; $script:noniSwitch = $false
    # TUI audit G3: -TestMode Interactive is this run's choice over HyperVTestMode=Unattended, so the run can ask: the
    # version picker is called once and the F5 default (previous version + warning) does not apply.
    Clear-RunState
    $script:testModeCfg = 'Unattended'
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -TestMode Interactive 6>&1 3>&1)
    if ($script:pickerCalls -eq 1 -and @($o.Warnings | Where-Object { $_ -eq $f5Warn }).Count -eq 0) { Ok 'HyperVTestMode=Unattended + -TestMode Interactive: the version picker is asked once, no F5 warning' }
    else { Bad "-TestMode Interactive: picker=$($script:pickerCalls) warnings=$($o.Warnings -join ' | ')" }
    # A prompt the host still refuses (pwsh -NonInteractive under a host the predicates do not recognise): Read-Host's own
    # InvalidOperation from the picker -> the same warning and the previous version, with a verdict. Any other picker error
    # is not swallowed (no verdict, as before).
    $script:testModeCfg = 'Interactive'
    $pickerShadow = ${function:Show-VersionSelection}
    ${function:Show-VersionSelection} = {
        $script:pickerCalls++
        throw ([System.Management.Automation.ErrorRecord]::new([System.Management.Automation.PSInvalidOperationException]::new('PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.'),
                'InvalidOperation,Microsoft.PowerShell.Commands.ReadHostCommand', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null))
    }
    Clear-RunState
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update 6>&1 3>&1)
    $c0 = if ($script:dlCalls.Count) { $script:dlCalls[0] } else { @{} }
    if ($script:pickerCalls -eq 1 -and @($o.Warnings | Where-Object { $_ -eq $f5Warn }).Count -eq 1 -and $c0['Version'] -eq '8.8.9' -and @($o.Values) -contains $true) { Ok 'F5, the picker''s Read-Host refused (NonInteractive mode): one warning, the previous version (8.8.9), a verdict' }
    else { Bad "F5 refused prompt: picker=$($script:pickerCalls) version=$($c0['Version']) values=$($o.Values -join ',') warnings=$($o.Warnings -join ' | ')" }
    ${function:Show-VersionSelection} = { $script:pickerCalls++; throw 'picker exploded' }
    Clear-RunState
    $errs = @(); $threw = $null
    try { $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -ErrorVariable errs 6>$null 3>$null 2>$null } catch { $threw = $_ }
    $errText = (@($errs) + @($threw) | Where-Object { $_ } | ForEach-Object { "$_" }) -join ' | '
    if ($script:dlCalls.Count -eq 0 -and $errText -match 'picker exploded') { Ok 'F5, any other picker error is not swallowed (no download, the error is reported)' } else { Bad "F5 other picker error: calls=$($script:dlCalls.Count) err=$errText" }
    ${function:Show-VersionSelection} = $pickerShadow
    $script:testModeCfg = 'Unattended'
    # Both, unattended, no version: the outer run picks the previous version once; each leg gets it as -SpecificVersion.
    Clear-RunState
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both 6>&1 3>&1)
    if ($script:pickerCalls -eq 0 -and @($o.Warnings | Where-Object { $_ -eq $f5Warn }).Count -eq 1 -and $script:dlCalls.Count -eq 2 -and
        @($script:dlCalls | Where-Object { $_['Version'] -eq '8.8.9' }).Count -eq 2) { Ok 'F5, Both: one warning, both runs from the previous version (8.8.9)' }
    else { Bad "F5 Both: picker=$($script:pickerCalls) calls=$($script:dlCalls | ConvertTo-Json -Compress) warnings=$($o.Warnings -join ' | ')" }
    # No older version at all: the -VersionsBack 1 error, before any download (never the picker).
    Clear-RunState
    ${function:Get-WingetVersions} = { @() }
    $errs = @(); $threw = $null
    try { $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -ErrorVariable errs 6>$null 3>$null 2>$null } catch { $threw = $_ }
    $errText = (@($errs) + @($threw) | Where-Object { $_ } | ForEach-Object { "$_" }) -join ' | '
    if ($script:pickerCalls -eq 0 -and $script:dlCalls.Count -eq 0 -and $errText -match "Requested 1 version\(s\) back but only 0 older version\(s\) are available for 'Notepad\+\+\.Notepad\+\+'") { Ok 'F5, no older version: the -VersionsBack 1 error, no download, no picker' }
    else { Bad "F5 none: picker=$($script:pickerCalls) calls=$($script:dlCalls.Count) err=$errText" }
    ${function:Get-WingetVersions} = { @('8.8.9', '8.8.8') }
    # (a2) the sibling lookup could not run (stored Probe Unavailable, e.g. HTTP 429): Auto uses the packaged technology
    # and says so under 'Baseline technology', after one retry of the lookup (never a silent packaged-over-packaged pass).
    $npu = Join-Path $base 'npp-unavailable'
    New-Item -ItemType Directory -Path (Join-Path $npu 'Files'), (Join-Path $npu 'Documentation') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $np 'Files\Notepad++.Notepad++.installer.yaml') -Destination (Join-Path $npu 'Files')
    Set-Content -LiteralPath (Join-Path $npu 'Invoke-AppDeployToolkit.ps1') -Value '# stub'
    [System.IO.File]::WriteAllText((Join-Path $npu 'Documentation\IdentityDelta.json'), '{"SchemaVersion":"1.0","Probe":{"Status":"Unavailable","Reason":"Network"},"Siblings":[]}', (New-Object System.Text.UTF8Encoding($false)))
    Clear-RunState; $script:deltaWrites = 0
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $npu -Scenario Update -SpecificVersion '8.8.9' 6>&1 3>&1)
    $iTech = [array]::IndexOf([string[]]$o.Info, 'Baseline technology : wix (MSI) (packaged technology)')
    $noteLine = '  Other installer technologies could not be checked (Network), so the packaged technology is used; pass -BaselineInstallerType <type> to choose one.'
    if ($iTech -ge 0 -and $o.Info[$iTech + 1] -eq $noteLine) { Ok "probe Unavailable: 'Baseline technology : wix (MSI) (packaged technology)' followed by the 'could not be checked (Network)' note" }
    else { Bad "probe note: $(@($o.Info | Where-Object { $_ -like 'Baseline technology*' -or $_ -like '  Other*' }) -join ' | ')" }
    if ($script:deltaWrites -eq 1 -and $script:dlCalls.Count -eq 1 -and $script:dlCalls[0]['InstallerType'] -eq 'wix' -and $script:outcomes.Count -eq 1 -and $script:outcomes[0].Baseline.Origin -eq 'Packaged') { Ok 'the lookup is retried once; the run uses the packaged wix (Origin Packaged)' }
    else { Bad "probe retry: writes=$script:deltaWrites calls=$($script:dlCalls | ConvertTo-Json -Compress)" }

    # (b) the sibling is not offered at the baseline version -> pinned fallback to the packaged technology (L2)
    Clear-RunState
    $script:dlAnswer = { param($Type) if ($Type -eq 'nullsoft') { 'ivu' } else { 'ok' } }
    $script:verdictQueue.Enqueue($false)
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' 6>$null 3>&1)
    if ($script:dlCalls.Count -eq 2 -and $script:dlCalls[1]['InstallerType'] -eq 'wix' -and $script:dlCalls[1]['FamilyPin'] -and $script:dlCalls[1]['Scope'] -eq 'machine') { Ok 'sibling unavailable -> a second, pinned call with the packaged type (wix, machine)' }
    else { Bad "fallback calls: $($script:dlCalls | ConvertTo-Json -Compress)" }
    $fbWarn = @($o.Warnings | Where-Object { $_ -like 'v8.8.9 has no vendor EXE installer for x64; this Update test falls back to the packaged technology (wix (MSI)) and cannot show a technology switch.*-BaselineInstallerType nullsoft.' })
    if ($fbWarn.Count -eq 1) { Ok 'the L2 fallback warning (spec text)' } else { Bad "warnings: $($o.Warnings -join ' | ')" }
    $b1 = if ($script:outcomes.Count) { $script:outcomes[0].Baseline } else { $null }
    if ($b1 -and $b1.UsedFallback -eq $true -and $b1.FallbackReason -eq 'SiblingFamilyNotOfferedAtBaselineVersion' -and $b1.Origin -eq 'Sibling' -and $b1.InstallerType -eq 'wix' -and $b1.Family -eq 'msi') { Ok 'recorded: UsedFallback, FallbackReason, Origin Sibling, the packaged wix/msi' }
    else { Bad "fallback baseline: $($b1 | ConvertTo-Json -Compress)" }
    if ($script:switchCalls -eq 1 -and @($o.Warnings) -contains 'Technology switch: TEST' -and @($o.Values) -contains $false) { Ok 'a FAIL checks for a technology switch and prints each finding as a warning' } else { Bad "switch=$script:switchCalls" }

    # (c) an explicit type that the version does not ship -> no verdict, one Unavailable record (L21)
    foreach ($variant in 'preference', 'parameter') {
        Clear-RunState
        $script:dlAnswer = { 'ivu' }
        $threw = $null; $items = @()
        try {
            $items = if ($variant -eq 'parameter') { @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' -BaselineInstallerType nullsoft -ErrorAction Stop 6>$null 3>&1) }
                     else { @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' -BaselineInstallerType nullsoft 6>$null 3>&1) }
        } catch { $threw = $_ }
        $o = Split-Out $items
        $label = if ($variant -eq 'parameter') { '-ErrorAction Stop' } else { "`$ErrorActionPreference = 'Stop'" }
        $r = if ($script:records.Count) { $script:records[0] } else { $null }
        if (-not $threw -and $script:dlCalls.Count -eq 1 -and $o.Values.Count -eq 0 -and $o.Warnings.Count -eq 1 -and $o.Warnings[0] -eq 'winget offers no nullsoft installer for Notepad++.Notepad++ v8.8.9.' -and $script:outcomes.Count -eq 0) {
            Ok "explicit type unavailable ($label): no second call, one warning, returns `$null, no terminating error"
        } else { Bad "unavailable ($label): threw=$($threw.Exception.Message) calls=$($script:dlCalls.Count) values=$($o.Values.Count) warnings=$($o.Warnings -join ' | ')" }
        if ($script:records.Count -eq 1 -and $r.Scenario -eq 'Update' -and $r.Backend -eq 'HyperV' -and $r.Verdict -eq 'Inconclusive' -and $r.Mode -eq 'Unattended' -and $r.Assertions.Count -eq 0 -and
            $r.Notes -like 'Baseline unavailable: winget offers no nullsoft installer*' -and $r.Baseline.Unavailable -eq $true -and $r.Baseline.InstallerType -eq '' -and
            $r.Baseline.RequestedInstallerType -eq 'nullsoft' -and $r.Baseline.Family -eq 'exe' -and $r.Baseline.Origin -eq 'Explicit' -and $r.Baseline.Mode -eq 'nullsoft') {
            Ok "($label) one Inconclusive record via Add-Win32ToolkitTestResult, Baseline.Unavailable, the leg's type and family"
        } else { Bad "record ($label): $($script:records | ConvertTo-Json -Compress -Depth 5)" }
    }
    Clear-RunState
    $script:dlAnswer = { 'ivu' }
    $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' -BaselineInstallerType Packaged 6>$null 3>$null
    if ($script:dlCalls.Count -eq 1 -and $script:dlCalls[0]['InstallerType'] -eq 'wix' -and $script:records.Count -eq 1 -and $script:records[0].Baseline.Origin -eq 'Packaged') { Ok '-BaselineInstallerType Packaged unavailable -> no fallback, Unavailable record' } else { Bad "packaged unavailable: $($script:records.Count)" }
    Clear-RunState
    $script:dlAnswer = { 'ivu' }
    $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' 6>$null 3>$null
    if ($script:dlCalls.Count -eq 2 -and $script:records.Count -eq 1 -and $script:records[0].Baseline.UsedFallback -eq $true -and $script:records[0].Baseline.RequestedInstallerType -eq 'nullsoft') { Ok 'Auto: the fallback unavailable too -> one Unavailable record (UsedFallback recorded)' } else { Bad "fallback unavailable: calls $($script:dlCalls.Count) records $($script:records.Count)" }
    # TUI audit G3: the Unavailable record's Mode is the run's own mode, -TestMode over HyperVTestMode, both ways.
    foreach ($case in @(@{ Cfg = 'Unattended'; TestMode = 'Interactive'; Pre = 0 }, @{ Cfg = 'Interactive'; TestMode = 'Unattended'; Pre = 1 })) {
        Clear-RunState
        $script:testModeCfg = $case.Cfg
        $script:dlAnswer = { 'ivu' }
        $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' -BaselineInstallerType nullsoft -TestMode $case.TestMode 6>$null 3>$null
        $r = if ($script:records.Count) { $script:records[0] } else { $null }
        if ($script:records.Count -eq 1 -and $r.Baseline.Unavailable -eq $true -and $r.Mode -eq $case.TestMode -and $script:preCalls.Count -eq $case.Pre) {
            Ok "HyperVTestMode=$($case.Cfg) + -TestMode $($case.TestMode), baseline unavailable: the record says Mode $($case.TestMode) ($($case.Pre) pre-check call)"
        } else { Bad "unavailable -TestMode $($case.TestMode): records=$($script:records.Count) mode=$($r.Mode) pre=$($script:preCalls.Count)" }
    }
    $script:testModeCfg = 'Unattended'
    Clear-RunState
    $script:dlAnswer = { 'boom' }
    $threw = $null
    try { $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' 6>$null 3>$null } catch { $threw = $_ }
    if ($threw -and $threw.Exception.Message -match 'network down' -and $script:dlCalls.Count -eq 1 -and $script:records.Count -eq 0) { Ok 'any other download error keeps the old path (outer catch), no fallback, no record' } else { Bad "other error: $($threw.Exception.Message) calls $($script:dlCalls.Count)" }

    # (d) the Git worked case: user-scope inno package, the 2.33.0 baseline ships machine scope only (the REAL download)
    $gp = Join-Path $base 'git'
    New-Item -ItemType Directory -Path (Join-Path $gp 'Files'), (Join-Path $gp 'Documentation') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $gp 'Invoke-AppDeployToolkit.ps1') -Value '# stub'
    Set-Content -LiteralPath (Join-Path $gp 'Files\Git.Git.installer.yaml') -Encoding UTF8 -Value @(
        'PackageIdentifier: Git.Git', 'PackageVersion: 2.55.0.5', 'Installers:', '- Architecture: x64', '  InstallerType: inno', '  Scope: user',
        '  InstallerUrl: https://example.invalid/Git-2.55.0.5-64-bit.exe', '  InstallerSha256: 0000000000000000000000000000000000000000000000000000000000000001', 'ManifestType: installer')
    [System.IO.File]::WriteAllText((Join-Path $gp 'Documentation\IdentityDelta.json'), '{"SchemaVersion":"1.0","Siblings":[]}', (New-Object System.Text.UTF8Encoding($false)))
    $script:source = [pscustomobject]@{ InstallerType = 'inno'; Family = 'exe'; Scope = 'user' }
    . (Join-Path $repo 'Private\Download-OldVersionInstaller.ps1')   # the real one, with winget shadowed below
    function Get-Win32ToolkitPipelineCacheRoot { $null }
    $script:wingetCalls = [System.Collections.Generic.List[object]]::new()
    function winget {
        $a = [string[]]$args
        $script:wingetCalls.Add($a)
        if ([array]::IndexOf($a, 'user') -ge 0 -and [array]::IndexOf($a, '--scope') -ge 0) { $global:LASTEXITCODE = -1978335216; return }   # 0x8A150010
        $dir = $a[[array]::IndexOf($a, '--download-directory') + 1]
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'Git-2.33.0-64-bit.exe'), [byte[]](1..32))
        Set-Content -LiteralPath (Join-Path $dir 'Git.Git.installer.yaml') -Encoding UTF8 -Value @(
            'PackageIdentifier: Git.Git', 'PackageVersion: 2.33.0', 'Installers:', '- Architecture: x64', '  InstallerType: inno', '  Scope: machine',
            '  InstallerSwitches:', '    Silent: /VERYSILENT /NORESTART')
        $global:LASTEXITCODE = 0
    }
    Clear-RunState
    $threw = $null; $gv = $null
    try { $gv = Test-Win32ToolkitProject -ProjectPath $gp -Scenario Update -SpecificVersion '2.33.0' 6>$null 3>$null } catch { $threw = $_ }
    $gb = if ($script:outcomes.Count) { $script:outcomes[0].Baseline } else { $null }
    $scopes = @($script:wingetCalls | ForEach-Object { $i = [array]::IndexOf([string[]]$_, '--scope'); if ($i -ge 0) { $_[$i + 1] } else { '-' } })
    if (-not $threw -and $gv -eq $true -and $script:records.Count -eq 0 -and ($scopes -join ',') -eq 'user,-') { Ok 'Git worked case: --scope user no-applicable -> inno without --scope -> a verdict (not W32T, no Unavailable record)' }
    else { Bad "git: threw=$($threw.Exception.Message) verdict=$gv scopes=$($scopes -join ',') records=$($script:records.Count)" }
    if ($gb -and $gb.ScopeRelaxed -eq $true -and $gb.RequestedScope -eq 'user' -and $gb.Scope -eq 'machine' -and $gb.InstallerType -eq 'inno' -and $gb.Family -eq 'exe' -and $gb.Origin -eq 'Packaged' -and $gb.UsedFallback -eq $false) { Ok 'recorded: ScopeRelaxed, RequestedScope user, Scope machine, inno/exe, Origin Packaged' }
    else { Bad "git baseline: $($gb | ConvertTo-Json -Compress)" }

    # (d2) the REAL download, every type unavailable: no verdict, and Sandbox\OldVersion keeps the previous baseline (the
    # 2.33.0 download above), still paired with the last UpdateAssertions.ps1, so an older FAIL stays judgeable (L21).
    $gOv = Join-Path $gp 'Sandbox\OldVersion'
    $gBefore = @(Get-ChildItem -LiteralPath $gOv -Force -File | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ';'
    function winget { $script:wingetCalls.Add([string[]]$args); $global:LASTEXITCODE = -1978335216 }   # 0x8A150010 for every type and scope
    Clear-RunState; $script:wingetCalls.Clear()
    $threw = $null; $uv = 'unset'
    try { $uv = Test-Win32ToolkitProject -ProjectPath $gp -Scenario Update -SpecificVersion '2.30.0' -BaselineInstallerType Packaged 6>$null 3>$null } catch { $threw = $_ }
    $gAfter = @(Get-ChildItem -LiteralPath $gOv -Force -File | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join ';'
    if (-not $threw -and $null -eq $uv -and $script:records.Count -eq 1 -and $script:records[0].Baseline.Unavailable -eq $true -and $script:wingetCalls.Count -eq 8 -and $script:outcomes.Count -eq 0) { Ok 'real download, every type unavailable -> $null, one Unavailable record (8 attempts)' }
    else { Bad "real unavailable: threw=$($threw.Exception.Message) v=$uv records=$($script:records.Count) calls=$($script:wingetCalls.Count)" }
    if ($gBefore -match 'Git\.Git\.installer\.yaml=' -and $gAfter -eq $gBefore -and -not (Test-Path -LiteralPath "$gOv.attempt")) { Ok 'Sandbox\OldVersion still holds the previous baseline, byte for byte; no staging folder is left' }
    else { Bad "OldVersion changed: before='$gBefore' after='$gAfter'" }
    ${function:Download-OldVersionInstaller} = $dlShadow
    $script:source = [pscustomobject]@{ InstallerType = 'wix'; Family = 'msi'; Scope = 'machine' }

    # (e) Both -> one inner run per technology, at the picked version, recorded separately (L13)
    Clear-RunState
    $script:versionCalls = 0
    $versionsShadowE = ${function:Get-WingetVersions}
    ${function:Get-WingetVersions} = { $script:versionCalls++; @('8.8.9', '8.8.8') }
    $script:verdictQueue.Enqueue($true); $script:verdictQueue.Enqueue($false)
    $script:cleanupFindings = @([pscustomobject]@{ Kind = 'CleanupPath'; Message = 'UNSAFE-BOTH' })
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -VersionsBack 1 6>&1 3>&1)
    # F7 (installer-identity PR 2 follow-up): the outer call checks the cleanup paths Export refuses once, for both legs.
    $cw = @($o.Warnings | Where-Object { $_ -like 'Export refuses this project*' })
    if ($script:cleanupCalls -eq 1 -and $cw.Count -eq 1 -and $cw[0].StartsWith('Export refuses this project (1 uninstall cleanup-path finding(s)); the test runs anyway. UNSAFE-BOTH ')) { Ok 'Both: one cleanup-path check and one warning for the whole run (the legs do not repeat it)' }
    else { Bad "Both cleanup check: calls=$($script:cleanupCalls) warnings=$($cw -join ' | ')" }
    if ($script:dlCalls.Count -eq 2 -and $script:dlCalls[0]['InstallerType'] -eq 'wix' -and $script:dlCalls[1]['InstallerType'] -eq 'nullsoft' -and
        $script:dlCalls[0]['Version'] -eq '8.8.9' -and $script:dlCalls[1]['Version'] -eq '8.8.9' -and $script:pickerCalls -eq 0) { Ok 'Both: two inner runs at the same version (-SpecificVersion 8.8.9, VersionsBack dropped): wix, then nullsoft' }
    else { Bad "both calls: $($script:dlCalls | ConvertTo-Json -Compress)" }
    # The inner leg keeps the outer list's label for its technology (H6-F2): never 'requested with -BaselineInstallerType',
    # which the operator did not do (the pin value itself is proven by the download calls above).
    if (@($o.Info | Where-Object { $_ -eq 'Baseline technology : wix (MSI) (packaged technology)' }).Count -ge 2 -and
        @($o.Info | Where-Object { $_ -eq 'Baseline technology : nullsoft (vendor EXE, NSIS) (other technology winget ships for this app)' }).Count -eq 2 -and
        @($o.Info | Where-Object { "$_" -match 'requested with -BaselineInstallerType' }).Count -eq 0) { Ok 'each leg shows the label the Both list gave it (the sibling leg stays "other technology winget ships for this app")' }
    else { Bad "inner labels: $(@($o.Info | Where-Object { $_ -like 'Baseline technology*' }) -join ' | ')" }
    if ($script:outcomes.Count -eq 2 -and $script:outcomes[0].Baseline.Mode -eq 'Both' -and $script:outcomes[0].Baseline.Origin -eq 'Packaged' -and
        $script:outcomes[1].Baseline.Mode -eq 'Both' -and $script:outcomes[1].Baseline.Origin -eq 'Sibling' -and $script:outcomes[1].Baseline.Family -eq 'exe') { Ok 'one record per leg, Baseline.Mode Both with its own Origin (Packaged, Sibling)' }
    else { Bad "both records: $($script:outcomes | ConvertTo-Json -Compress -Depth 5)" }
    if ($null -eq $script:W32TUpdateLegContext) { Ok 'the leg context is cleared afterwards' } else { Bad 'leg context left set' }
    # One winget version query for the whole Both run: the legs do not repeat the advisory lookup (H6-F3).
    if ($script:versionCalls -eq 1) { Ok 'Both: one Get-WingetVersions call for two legs (no advisory re-query per leg)' } else { Bad "Get-WingetVersions calls: $($script:versionCalls)" }
    ${function:Get-WingetVersions} = $versionsShadowE
    if (@($o.Values).Count -eq 1 -and $o.Values[0] -eq $false -and $script:switchCalls -eq 1) { Ok 'combined verdict: a failed leg -> $false (and its technology switch is checked)' } else { Bad "combined: $($o.Values -join ',')" }
    if (@($o.Info | Where-Object { $_ -like '  1. wix (MSI) (packaged technology): PASSED' }).Count -eq 1 -and @($o.Info | Where-Object { $_ -like '  2. nullsoft*: FAILED' }).Count -eq 1) { Ok 'one summary line per leg' } else { Bad 'summary lines missing' }
    # The scenario header is mode-neutral and printed once, not once per leg (test campaign 2026-10-21).
    $scE = @($o.Info | Where-Object { "$_" -like '*Scenario:*' })
    if ($scE.Count -eq 1 -and "$($scE[0])".Trim() -eq 'Scenario: Install Old Version → Run PSADT Update') { Ok 'Both: one mode-neutral scenario header (no countdown claimed, not repeated per leg)' } else { Bad "scenario headers: $($scE -join ' | ')" }
    # Test campaign F2: each leg keeps its own logs (Sandbox\Logs\Runs\<run>_Update_<family>); the top-level exit-code log
    # is cleared once (by the outer call) and holds both legs.
    $lf = @($script:outcomes | ForEach-Object { [string]$_.LogFolder })
    $legLog = { param($i, $name) $f = Join-Path $np "$($lf[$i])\$name"; if ($lf[$i] -and (Test-Path -LiteralPath $f)) { Get-Content -LiteralPath $f -Raw } else { '' } }
    $g1 = [regex]::Match((& $legLog 0 'UpdateAssertions.log'), 'guest run (\d+)').Groups[1].Value
    $g2 = [regex]::Match((& $legLog 1 'UpdateAssertions.log'), 'guest run (\d+)').Groups[1].Value
    if ($lf.Count -eq 2 -and $lf[0] -match '^Sandbox\\Logs\\Runs\\\d{8}-\d{6}_Update_msi(-\d+)?$' -and $lf[1] -match '^Sandbox\\Logs\\Runs\\\d{8}-\d{6}_Update_exe(-\d+)?$' -and $g1 -and $g2 -and [int]$g2 -eq [int]$g1 + 1) {
        Ok "each leg's record names its own run folder ($($lf -join ', ')), which keeps that leg's UpdateAssertions.log"
    } else { Bad "leg folders: $($lf -join ' | ') runs=$g1/$g2" }
    $c1 = & $legLog 0 'PsadtExitCodes.log'; $c2 = & $legLog 1 'PsadtExitCodes.log'
    if ($c1 -match "guest run $g1\b" -and $c1 -notmatch "guest run $g2\b" -and $c2 -match "guest run $g2\b" -and $c2 -notmatch "guest run $g1\b") { Ok "each leg's folder keeps only its own exit-code line" } else { Bad "leg codes: [$c1] [$c2]" }
    $topCodes = @(Get-Content -LiteralPath (Join-Path $np 'Sandbox\Logs\PsadtExitCodes.log'))
    if ($topCodes.Count -eq 4 -and $topCodes[1] -match "guest run $g1\b" -and $topCodes[3] -match "guest run $g2\b" -and @($topCodes -match ' -- test run ').Count -eq 2) { Ok 'the top-level PsadtExitCodes.log holds both legs (cleared once by the outer call)' } else { Bad "top codes: $($topCodes -join ' | ')" }
    Clear-RunState
    $script:verdictQueue.Enqueue($true); $script:verdictQueue.Enqueue($true)
    $v = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -SpecificVersion '8.8.9' 6>$null 3>$null
    $script:verdictQueue.Enqueue($true); $script:verdictQueue.Enqueue($null)
    $script:outcomes.Clear()
    $v2 = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -SpecificVersion '8.8.9' 6>$null 3>$null
    if ($v -eq $true -and $null -eq $v2 -and $script:outcomes.Count -eq 2) { Ok 'combined verdict: all passed -> $true; a leg without a verdict -> $null' } else { Bad "combined: v=$v v2=$v2" }

    # (f) a leg that throws: warned, no verdict, the other leg still runs, the context is cleared
    foreach ($eaMode in 'Stop', 'Continue') {
        Clear-RunState
        $script:dlAnswer = { param($Type) if ($Type -eq 'wix') { 'boom' } else { 'ok' } }
        $script:verdictQueue.Enqueue($true)
        $threw = $null; $items = @()
        try { $items = @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -SpecificVersion '8.8.9' -ErrorAction $eaMode 6>$null 3>&1 2>$null) } catch { $threw = $_ }
        $o = Split-Out $items
        if (-not $threw -and $null -eq $script:W32TUpdateLegContext -and $script:dlCalls.Count -eq 2 -and $script:outcomes.Count -eq 1 -and $o.Values.Count -eq 0) {
            Ok "Both, the first leg throws (-ErrorAction $eaMode): the second leg still runs, combined verdict `$null, context cleared"
        } else { Bad "leg throws ($eaMode): threw=$($threw.Exception.Message) ctx=$($script:W32TUpdateLegContext) calls=$($script:dlCalls.Count) outcomes=$($script:outcomes.Count) values=$($o.Values -join ',')" }
    }

    # (f2) Test campaign F2 on the Sandbox backend (the campaign's S3 path: SandboxTestMode=Unattended, Both): each leg
    #      keeps its own evidence. The sandbox launch is shadowed and writes what the guest would: the leg's
    #      UpdateAssertions.log and one exit-code line. The collector wait (60 s max) follows only a launched leg.
    $script:testBackend = 'Sandbox'; $script:testModeCfg = 'Unattended'
    # Records the own-sandbox wait each completed unattended leg makes before it returns (F10); a plain function, so
    # -OwnRun arrives in $args.
    $script:ownRuns = [System.Collections.Generic.List[int]]::new()
    function Wait-Win32ToolkitSandboxFree { param($TimeoutSeconds) if ($args -contains '-OwnRun') { $script:ownRuns.Add([int]$TimeoutSeconds) }; $true }
    ${function:New-Win32ToolkitSandboxConfig} = { '<Configuration/>' }
    $script:sbRuns = 0
    $script:sbLaunch = { $true }
    function Invoke-Win32ToolkitTestRun {
        param($Backend, $SandboxConfigPath)
        $null = $Backend
        $script:sbRuns++
        if (-not (& $script:sbLaunch $script:sbRuns)) { return [pscustomobject]@{ Launched = $false } }
        $ld = Join-Path (Split-Path -Parent (Split-Path -Parent $SandboxConfigPath)) 'Sandbox\Logs'
        New-Item -ItemType Directory -Path $ld -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ld 'UpdateAssertions.log') -Value "[t] ASSERT Tattoo-PostUpdate = PASS (sandbox run $script:sbRuns)" -Encoding UTF8
        Add-Content -LiteralPath (Join-Path $ld 'PsadtExitCodes.log') -Value "[t] update Install parent=x64-direct exit=0 result=Success (sandbox run $script:sbRuns)" -Encoding UTF8
        [pscustomobject]@{ Launched = $true }
    }
    Clear-RunState; $script:collectWaits = @(); $script:ownRuns.Clear()
    $script:verdictQueue.Enqueue($true); $script:verdictQueue.Enqueue($false)
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -SpecificVersion '8.8.9' 6>&1 3>&1)
    if (($script:ownRuns -join ',') -eq '90,90') { Ok 'Sandbox Both (F10): each launched leg with a verdict waits for its own sandbox (-TimeoutSeconds 90 -OwnRun) before it returns' }
    else { Bad "own-sandbox waits: $($script:ownRuns -join ',')" }
    $lf = @($script:outcomes | ForEach-Object { [string]$_.LogFolder })
    $sbLeg = { param($i, $name) $f = Join-Path $np "$($lf[$i])\$name"; if ($lf[$i] -and (Test-Path -LiteralPath $f)) { Get-Content -LiteralPath $f -Raw } else { '' } }
    $s1 = [regex]::Match((& $sbLeg 0 'UpdateAssertions.log'), 'sandbox run (\d+)').Groups[1].Value
    $s2 = [regex]::Match((& $sbLeg 1 'UpdateAssertions.log'), 'sandbox run (\d+)').Groups[1].Value
    if ($script:dlCalls.Count -eq 2 -and $lf.Count -eq 2 -and $lf[0] -match '^Sandbox\\Logs\\Runs\\\d{8}-\d{6}_Update_msi(-\d+)?$' -and $lf[1] -match '^Sandbox\\Logs\\Runs\\\d{8}-\d{6}_Update_exe(-\d+)?$' -and
        $s1 -and $s2 -and [int]$s2 -eq [int]$s1 + 1) { Ok "Sandbox Both: each leg's record names its own run folder ($($lf -join ', ')), with that leg's UpdateAssertions.log" }
    else { Bad "sandbox leg folders: $($lf -join ' | ') runs=$s1/$s2 downloads=$($script:dlCalls.Count)" }
    $k1 = & $sbLeg 0 'PsadtExitCodes.log'; $k2 = & $sbLeg 1 'PsadtExitCodes.log'
    if ($k1 -match "sandbox run $s1\b" -and $k1 -notmatch "sandbox run $s2\b" -and $k2 -match "sandbox run $s2\b" -and $k2 -notmatch "sandbox run $s1\b") { Ok "Sandbox Both: each leg's folder keeps only its own exit-code line" } else { Bad "sandbox leg codes: [$k1] [$k2]" }
    if (($script:collectWaits -join ',') -eq '60,60') { Ok 'Sandbox Both: one collector wait of 60 s after each launched leg' } else { Bad "collector waits: $($script:collectWaits -join ',')" }
    if (@($o.Values).Count -eq 1 -and $o.Values[0] -eq $false) { Ok 'Sandbox Both: the failed leg fails the combined verdict' } else { Bad "sandbox combined: $($o.Values -join ',')" }
    # A leg whose sandbox did not launch: no collector wait for it, and no folder of the other leg's logs.
    Clear-RunState; $script:collectWaits = @(); $script:sbRuns = 0; $script:ownRuns.Clear()
    $script:sbLaunch = { param($n) $n -ne 2 }
    $script:verdictQueue.Enqueue($true); $script:verdictQueue.Enqueue($null)
    $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -SpecificVersion '8.8.9' 6>$null 3>$null
    $lf = @($script:outcomes | ForEach-Object { [string]$_.LogFolder })
    if (($script:collectWaits -join ',') -eq '60' -and $lf.Count -eq 2 -and $lf[0] -match '_Update_msi' -and -not $lf[1]) { Ok 'a leg that did not launch: no collector wait, no run folder (nothing of the other leg is filed under it)' }
    else { Bad "not launched: waits=$($script:collectWaits -join ',') folders=$($lf -join ' | ')" }
    if (($script:ownRuns -join ',') -eq '90') { Ok 'F10: only the launched leg waits for its own sandbox' } else { Bad "own-sandbox waits (one leg not launched): $($script:ownRuns -join ',')" }
    # F10 never follows a leg whose sandbox did not launch (even with a verdict) or a leg without a verdict (the assertion
    # wait timed out: that sandbox is usually still running).
    Clear-RunState; $script:sbRuns = 0; $script:ownRuns.Clear()
    $script:verdictQueue.Enqueue($true); $script:verdictQueue.Enqueue($true)
    $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -SpecificVersion '8.8.9' 6>$null 3>$null
    if (($script:ownRuns -join ',') -eq '90' -and $script:outcomes.Count -eq 2) { Ok 'F10: a leg that did not launch makes no own-sandbox wait, whatever its verdict' } else { Bad "not launched, verdict: own=$($script:ownRuns -join ',') outcomes=$($script:outcomes.Count)" }
    $script:sbLaunch = { $true }
    Clear-RunState; $script:sbRuns = 0; $script:ownRuns.Clear()
    $script:verdictQueue.Enqueue($null); $script:verdictQueue.Enqueue($false)
    $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -SpecificVersion '8.8.9' 6>$null 3>$null
    if (($script:ownRuns -join ',') -eq '90' -and $script:outcomes.Count -eq 2) { Ok 'F10: a launched leg without a verdict makes no own-sandbox wait; the next leg with one does' } else { Bad "no verdict: own=$($script:ownRuns -join ',') outcomes=$($script:outcomes.Count)" }
    # A single (not Both) unattended Sandbox Update: one own-sandbox wait.
    Clear-RunState; $script:sbRuns = 0; $script:ownRuns.Clear()
    $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' 6>$null 3>$null
    if (($script:ownRuns -join ',') -eq '90') { Ok 'F10: a single unattended Sandbox Update with a verdict waits for its own sandbox once' } else { Bad "single: own=$($script:ownRuns -join ',')" }
    $script:testBackend = 'HyperV'

    # (g) Both on watched Sandbox: close the previous leg's sandbox first (up to 600 s), else that leg has no verdict
    $script:testBackend = 'Sandbox'; $script:testModeCfg = 'Interactive'
    $script:freeCalls = [System.Collections.Generic.List[int]]::new()
    # The own-sandbox wait (F10, -OwnRun in $args) is filed apart from the start-up and leg-2 waits: a watched run never
    # makes it (the user is still checking that sandbox).
    $script:watchedOwnRuns = [System.Collections.Generic.List[int]]::new()
    function Wait-Win32ToolkitSandboxFree {
        param($TimeoutSeconds)
        if ($args -contains '-OwnRun') { $script:watchedOwnRuns.Add([int]$TimeoutSeconds); return $true }
        $script:freeCalls.Add([int]$TimeoutSeconds); [int]$TimeoutSeconds -ne 600
    }
    ${function:New-CountdownScript} = { 'countdown.ps1' }
    ${function:New-Win32ToolkitSandboxConfig} = { '<Configuration/>' }
    function Invoke-Win32ToolkitTestRun { [pscustomobject]@{ Launched = $true } }
    Clear-RunState; $script:watchedOwnRuns.Clear()
    $script:verdictQueue.Enqueue($true)   # leg 1 launched with a verdict
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -SpecificVersion '8.8.9' 6>&1 3>&1)
    if ($script:freeCalls -contains 600 -and @($o.Info | Where-Object { $_ -eq 'Close the Windows Sandbox of the previous leg to start the exe leg' }).Count -eq 1) { Ok 'watched Sandbox: asks to close the previous sandbox and waits up to 600 s before leg 2' }
    else { Bad "sandbox wait: $($script:freeCalls -join ',') info=$(@($o.Info | Where-Object { $_ -like 'Close*' }) -join '|')" }
    if ($script:dlCalls.Count -eq 1 -and $script:outcomes.Count -eq 1 -and $o.Values.Count -eq 0 -and @($o.Warnings | Where-Object { $_ -like '*still open after 10 minutes*' }).Count -eq 1) { Ok 'still busy -> that leg did not run (warning), combined verdict $null' }
    else { Bad "busy: calls=$($script:dlCalls.Count) outcomes=$($script:outcomes.Count) values=$($o.Values -join ',')" }
    if ($script:watchedOwnRuns.Count -eq 0 -and $script:outcomes.Count -eq 1 -and $true -eq $script:outcomes[0].Verdict) { Ok 'watched Sandbox Both (F10): the launched leg with a verdict makes no own-sandbox wait (-OwnRun)' }
    else { Bad "watched Both own-sandbox waits: $($script:watchedOwnRuns -join ',') outcomes=$($script:outcomes.Count)" }
    # A single watched Sandbox Update, launched, with a verdict: no own-sandbox wait either (no 90 s wait and no 'still
    # open' line at the end while the user checks the sandbox).
    Clear-RunState; $script:watchedOwnRuns.Clear()
    $script:verdictQueue.Enqueue($true)
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' 6>&1 3>&1)
    if ($script:watchedOwnRuns.Count -eq 0 -and $script:outcomes.Count -eq 1 -and @($o.Values) -contains $true) { Ok 'watched Sandbox Update (F10): launched with a verdict, no own-sandbox wait (-OwnRun)' }
    else { Bad "watched single own-sandbox waits: $($script:watchedOwnRuns -join ',') outcomes=$($script:outcomes.Count) values=$($o.Values -join ',')" }
    # TUI audit G3: the Both run's watched check follows the run's -TestMode too. SandboxTestMode=Unattended + -TestMode
    # Interactive = watched legs: close the previous leg's sandbox first (up to 600 s); no own-sandbox wait after leg 1.
    $script:testModeCfg = 'Unattended'
    Clear-RunState; $script:freeCalls.Clear(); $script:watchedOwnRuns.Clear()
    $script:verdictQueue.Enqueue($true)   # leg 1 launched with a verdict
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -SpecificVersion '8.8.9' -TestMode Interactive 6>&1 3>&1)
    if ($script:freeCalls -contains 600 -and @($o.Info | Where-Object { $_ -eq 'Close the Windows Sandbox of the previous leg to start the exe leg' }).Count -eq 1 -and
        $script:dlCalls.Count -eq 1 -and $script:outcomes.Count -eq 1 -and $script:watchedOwnRuns.Count -eq 0) {
        Ok 'SandboxTestMode=Unattended + -TestMode Interactive, Both: the watched path (close the previous sandbox, 600 s), no own-sandbox wait'
    } else { Bad "-TestMode Interactive Both: waits=$($script:freeCalls -join ',') downloads=$($script:dlCalls.Count) outcomes=$($script:outcomes.Count) own=$($script:watchedOwnRuns -join ',')" }
    $script:testModeCfg = 'Interactive'
    # F5 on the Sandbox backend with SandboxTestMode=Unattended (the campaign's configuration): no version given ->
    # the previous version with one warning, never the picker, and a verdict.
    $script:testModeCfg = 'Unattended'
    Clear-RunState
    $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update 6>&1 3>&1)
    $c0 = if ($script:dlCalls.Count) { $script:dlCalls[0] } else { @{} }
    if ($script:pickerCalls -eq 0 -and @($o.Warnings | Where-Object { $_ -eq $f5Warn }).Count -eq 1 -and $script:dlCalls.Count -eq 1 -and $c0['Version'] -eq '8.8.9' -and @($o.Values) -contains $true -and $script:outcomes.Count -eq 1) {
        Ok 'F5, Sandbox + SandboxTestMode=Unattended: no picker; the previous version (8.8.9) with one warning; a verdict'
    } else { Bad "F5 Sandbox: picker=$($script:pickerCalls) version=$($c0['Version']) values=$($o.Values -join ',') warnings=$($o.Warnings -join ' | ')" }
    $script:testBackend = 'HyperV'; $script:testModeCfg = 'Unattended'

    # (h) parameter rules
    if (Test-BaselineErr @{ ProjectPath = $put; Scenario = 'InstallUninstall'; BaselineInstallerType = 'Both' } 'BaselineInstallerType applies only to -Scenario Update') { Ok '-BaselineInstallerType with -Scenario InstallUninstall -> the Update-only error' } else { Bad 'InstallUninstall accepted -BaselineInstallerType' }
    $bp = Join-Path $base 'bp'; New-Item -ItemType Directory -Path $bp -Force | Out-Null; Set-Content (Join-Path $bp 'Invoke-AppDeployToolkit.ps1') '# stub'
    if (Test-BaselineErr @{ ProjectPath = $put; Scenario = 'Update'; BaselineProjectPath = $bp; BaselineInstallerType = 'nullsoft' } 'applies to a winget baseline; the baseline project has its own technology') { Ok '-BaselineInstallerType with -BaselineProjectPath -> the new error' } else { Bad 'baseline project accepted a technology' }

    # (j) Intune-parity pre-check (installer-identity PR 2, A1 hv r1.2): an unattended Hyper-V Update that would only wait on
    #     a PSADT 4.1 dialog is not started - before any download; one record with NotRun and no Baseline; once per outer call.
    Write-Host "`n[10j] Intune-parity pre-check before the Update baseline (installer-identity PR 2)" -ForegroundColor Cyan
    $script:testBackend = 'HyperV'; $script:testModeCfg = 'Unattended'
    foreach ($case in @(@{ Label = 'single run'; Extra = @{ SpecificVersion = '8.8.9' } }, @{ Label = '-BaselineInstallerType Both'; Extra = @{ BaselineInstallerType = 'Both'; VersionsBack = 1 } })) {
        Clear-RunState
        $script:preBlocked = $true
        $hv0 = $script:hvRuns
        $extra = $case.Extra
        $o = Split-Out @(Test-Win32ToolkitProject -ProjectPath $np -Scenario Update @extra 6>&1 3>&1)
        $r = if ($script:records.Count) { $script:records[0] } else { $null }
        if (($script:preCalls -join ',') -eq 'Update' -and $script:dlCalls.Count -eq 0 -and $script:hvRuns -eq $hv0 -and $script:outcomes.Count -eq 0 -and $o.Values.Count -eq 0 -and
            @($o.Info | Where-Object { $_ -like '=== Update test leg*' }).Count -eq 0) {
            Ok "blocked ($($case.Label)): the pre-check is asked once; no download, no guest run, no leg, no outcome; returns `$null"
        } else { Bad "blocked ($($case.Label)): pre=$($script:preCalls -join ',') downloads=$($script:dlCalls.Count) outcomes=$($script:outcomes.Count) values=$($o.Values -join ',')" }
        if ($script:records.Count -eq 1 -and $r.Scenario -eq 'Update' -and $r.Backend -eq 'HyperV' -and $r.Mode -eq 'Unattended' -and $r.Verdict -eq 'Inconclusive' -and
            $r.Assertions.Count -eq 0 -and $r.NotRun.Code -eq 'PARITY-DIALOG-WAIT' -and $null -eq $r.Baseline -and $r.Notes -like 'Not run (Intune-parity pre-check)*') {
            Ok "blocked ($($case.Label)): one Update record with NotRun and no Baseline"
        } else { Bad "blocked ($($case.Label)) record: $($script:records | ConvertTo-Json -Compress -Depth 5)" }
        $wAt = [array]::IndexOf([string[]]$o.Warnings, 'PRECHECK-MESSAGE')
        if ($wAt -ge 0 -and @($o.Info | Where-Object { $_ -eq 'Update test: NOT RUN (Intune-parity pre-check).' }).Count -eq 1 -and @($o.Info | Where-Object { $_ -like 'Baseline technology*' }).Count -eq 0) {
            Ok "blocked ($($case.Label)): the warning and 'NOT RUN' are printed before any baseline step"
        } else { Bad "blocked ($($case.Label)) output: warnings=$($o.Warnings -join ' | ') info=$($o.Info -join ' | ')" }
    }
    $hvBefore = $script:hvRuns
    Clear-RunState
    $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' 6>$null 3>$null
    if ($script:preCalls.Count -eq 1 -and $script:hvRuns -eq $hvBefore + 1 -and ($script:hvHints -join ',') -eq 'Dialog41' -and $script:dlCalls.Count -eq 1) { Ok "not blocked, single run: today's flow; the Update (Intune parity) phase carries ParityHint 'Dialog41'" }
    else { Bad "not blocked single: pre=$($script:preCalls.Count) runs=$($script:hvRuns - $hvBefore) hints=$($script:hvHints -join ',')" }
    # A PSADT 4.1 project that lists a process to close is not at risk: its 1460 hint is the generic 'Dialog' (a listed
    # process still running), never the 4.1 welcome text, although its shape is Psadt41 (L16).
    $hvBefore = $script:hvRuns
    Clear-RunState
    $script:preAtRisk = $false; $script:preProcessCount = 1
    $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' 6>$null 3>$null
    if ($script:preCalls.Count -eq 1 -and $script:hvRuns -eq $hvBefore + 1 -and ($script:hvHints -join ',') -eq 'Dialog') { Ok "not blocked, PSADT 4.1 with a process to close (not at risk): the Update (Intune parity) phase carries the generic 'Dialog' hint" }
    else { Bad "not at risk: pre=$($script:preCalls.Count) runs=$($script:hvRuns - $hvBefore) hints=$($script:hvHints -join ',')" }
    Clear-RunState
    $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -BaselineInstallerType Both -SpecificVersion '8.8.9' 6>$null 3>$null
    if ($script:preCalls.Count -eq 1 -and ($script:hvHints -join ',') -eq 'Dialog,Dialog' -and $script:dlCalls.Count -eq 2) { Ok "not blocked, Both: the outer call asks once; each leg's update phase carries the generic 'Dialog' hint (legs never re-check)" }
    else { Bad "not blocked Both: pre=$($script:preCalls -join ',') hints=$($script:hvHints -join ',') downloads=$($script:dlCalls.Count)" }
    Clear-RunState
    $script:testModeCfg = 'Interactive'
    $null = Test-Win32ToolkitProject -ProjectPath $np -Scenario Update -SpecificVersion '8.8.9' 6>$null 3>$null
    if ($script:preCalls.Count -eq 0) { Ok 'a watched Hyper-V Update never asks the pre-check' } else { Bad "watched: pre=$($script:preCalls.Count)" }
    $script:testModeCfg = 'Unattended'

    # (i) K5/K6: the two catches around the baseline download start with the IVU line; the download is family-pinned
    $tpFile = Join-Path $repo 'Public\Test-Win32ToolkitProject.ps1'
    $tpAst = [System.Management.Automation.Language.Parser]::ParseFile($tpFile, [ref]$null, [ref]$null)
    # The try statement whose BODY directly encloses a command (not the outer try of the whole function).
    $enclosingTry = {
        param($Node)
        $child = $Node; $p = $Node.Parent
        while ($p) {
            if ($p -is [System.Management.Automation.Language.TryStatementAst] -and [object]::ReferenceEquals($p.Body, $child)) { return $p }
            if ($p -is [System.Management.Automation.Language.CatchClauseAst]) { return $null }
            $child = $p; $p = $p.Parent
        }
        $null
    }
    $triesOf = {
        param([string[]]$Names)
        $seen = @{}
        $wanted = $Names
        foreach ($cmd in $tpAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $wanted }, $true)) {
            $try = & $enclosingTry $cmd
            if ($try -and -not $seen.ContainsKey($try.Extent.StartOffset)) { $seen[$try.Extent.StartOffset] = $true; $try }
        }
    }
    $dlTries = @(& $triesOf @('Download-OldVersionInstaller'))
    $ivu = "if (`$_.FullyQualifiedErrorId -ne 'W32T.InstallerVariantUnavailable') { throw }"
    $dlCatches = @($dlTries | ForEach-Object { $_.CatchClauses })
    if ($dlCatches.Count -eq 2 -and @($dlCatches | Where-Object { ($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -eq $ivu }).Count -eq 2) { Ok 'K5/K6: both catches around Download-OldVersionInstaller start with the IVU line' }
    else { Bad "K5/K6: $($dlCatches.Count) catch(es)" }
    $c2 = "if (`$_.FullyQualifiedErrorId -like 'W32T.*') { throw }"
    $newCatches = @(& $triesOf @('Get-Win32ToolkitTechnologySwitch', 'Add-Win32ToolkitTestResult', 'Test-Win32ToolkitProject') | ForEach-Object { $_.CatchClauses })
    # Five since installer-identity PR 3b (X3): the -SiblingProof FloorAndNewest floor leg runs inside the command's outer try.
    if ($newCatches.Count -eq 5 -and @($newCatches | Where-Object { ($_.Body.Statements[0].Extent.Text -replace '\s+', ' ') -eq $c2 }).Count -eq 5) { Ok 'the five other new catches (technology switch, Unavailable record, Both leg, not-run record, the outer catch around the X3 floor leg) start with the C-2 line' }
    else { Bad "new catches: $($newCatches.Count)" }
    $tpSrc = Get-Content -LiteralPath $tpFile -Raw -Encoding UTF8
    if ($tpSrc -match '(?s)\$dl = @\{[^}]*FamilyPin\s*=\s*\$true' -and $tpSrc -notmatch "\`$dl\['Locale'\]") { Ok 'the baseline download is always family-pinned and never passes -Locale' } else { Bad 'download hashtable not family-pinned' }
}
finally { Remove-Item -Path $base -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'Update-test unit tests PASSED' -ForegroundColor Green }
else             { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 }
