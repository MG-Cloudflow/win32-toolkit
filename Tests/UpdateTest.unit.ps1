<#
    Unit tests for the Update test scenario plumbing (no winget / no sandbox needed):
    - Select-Win32ToolkitOlderVersion: strictly-older filtering, numeric fallback, array-safe returns,
      refusal (throw) when no safe comparison exists.
    - New-UpdateAssertionScript: generated 5.1-safe script, escaped tattoo values, ASSERT markers.
    - Wait-Win32ToolkitUpdateAssertion: PASS/FAIL/timeout verdicts from a pre-written log.

    Run:  pwsh -File Tests\UpdateTest.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Select-Win32ToolkitOlderVersion.ps1')
. (Join-Path $repo 'Private\New-UpdateAssertionScript.ps1')
. (Join-Path $repo 'Private\Wait-Win32ToolkitUpdateAssertion.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitAppConfig.ps1')
. (Join-Path $repo 'Private\ConvertTo-PSSingleQuoted.ps1')
. (Join-Path $repo 'Private\ConvertTo-XmlEncoded.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitBaselineInstallCommand.ps1')

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

    Write-Host "`n[4] Get-Win32ToolkitBaselineInstallCommand" -ForegroundColor Cyan
    $c = Get-Win32ToolkitBaselineInstallCommand -InstallerSandboxPath 'C:\PSADT\Sandbox\OldVersion\app.exe' -InstallerType exe -SilentArgs '/S'
    if ($c -eq "Start-Process 'C:\PSADT\Sandbox\OldVersion\app.exe' -ArgumentList '/S' -Wait") { Ok 'exe + args -> Start-Process -ArgumentList' } else { Bad "exe: [$c]" }
    $c = Get-Win32ToolkitBaselineInstallCommand -InstallerSandboxPath 'C:\PSADT\Sandbox\OldVersion\app.exe' -InstallerType exe
    if ($c -eq "Start-Process 'C:\PSADT\Sandbox\OldVersion\app.exe' -Wait") { Ok 'exe no args -> no -ArgumentList' } else { Bad "exe-noargs: [$c]" }
    $c = Get-Win32ToolkitBaselineInstallCommand -InstallerSandboxPath 'C:\PSADT\Sandbox\OldVersion\app.msix' -InstallerType msix -SilentArgs '/qn'
    if ($c -eq "Add-AppxPackage -Path 'C:\PSADT\Sandbox\OldVersion\app.msix'") { Ok 'msix -> Add-AppxPackage (no Start-Process, args ignored)' } else { Bad "msix: [$c]" }
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
    . (Join-Path $repo 'Private\New-LogCollectorScript.ps1')

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
}
finally { Remove-Item -Path $base -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'Update-test unit tests PASSED' -ForegroundColor Green }
else             { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 }
