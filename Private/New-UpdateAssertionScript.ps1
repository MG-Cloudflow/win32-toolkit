function New-UpdateAssertionScript {
    <#
    .SYNOPSIS
        Generates Sandbox\UpdateAssertions.ps1 — the in-sandbox pass/fail checks for the Update test.
    .DESCRIPTION
        The Update test scenario runs this script twice inside Windows Sandbox (Windows PowerShell 5.1):

          -Phase PreUpdate   after the old-baseline vendor install: runs
                             SupportFiles\UpdateRequirement.ps1 (the update app's Intune requirement
                             rule) and asserts it exits 0 — i.e. the requirement correctly detects a
                             REAL old install with no tattoo. This is the only environment where that
                             signal can be validated before rollout. A failed/hung baseline install
                             also surfaces here (the requirement won't find the app).
          -Phase PostUpdate  after the PSADT update: re-runs the requirement script (still 0) and
                             asserts the install tattoo holds the NEW version — exactly what the
                             update app's Intune detection rule evaluates.

        Results are appended as 'ASSERT <name> = PASS|FAIL|SKIP' lines to
        C:\PSADT\Sandbox\Logs\UpdateAssertions.log (the mapped project folder, so they land on the
        host live); 'RESULT COMPLETE' marks the end. Wait-Win32ToolkitUpdateAssertion parses them
        host-side.

        Tattoo expectations are read from AppConfig.json with the same DisplayName||Name fallback the
        deploy script and Get-Win32DetectionRules use, and are spliced into the generated script as
        escaped single-quoted literals (ConvertTo-PSSingleQuoted) — data, never code.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder.
          -Phase PreBaseline is run FIRST (before the old install) to snapshot existing ARP keys, so the
          old app's entry can be identified as "new since baseline" (avoids matching the Sandbox base
          image's preinstalled apps). PostUpdate then asserts OldArpGone (no duplicate install).
    .PARAMETER SkipRequirement
        Do not run SupportFiles\UpdateRequirement.ps1 in either phase — the requirement assertions are
        emitted as explicit SKIPs (even if a stale UpdateRequirement.ps1 exists from a previous
        packaging). The tattoo/detection assertion still runs. Used by
        Test-Win32ToolkitProject -SkipRequirementCheck.
    .PARAMETER OldVersion
        The baseline (old) version string. Used to identify the old app's ARP entry by DisplayVersion
        (loose match) and to assert it is gone/updated after the update.
    .PARAMETER ExpectBaselineTattoo
        The baseline was installed by a PREVIOUS toolkit package (Test-Win32ToolkitProject
        -BaselineProjectPath), so it wrote the install tattoo. Adds a PreUpdate assertion that the
        tattoo holds the OLD version, and PostUpdate then proves the old→new overwrite.
    .OUTPUTS
        [string] the path of the generated script.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [switch]$SkipRequirement,

        [string]$OldVersion,

        [switch]$ExpectBaselineTattoo
    )

    $sandboxPath = Join-Path $ProjectPath 'Sandbox'
    if (-not (Test-Path -LiteralPath $sandboxPath)) {
        New-Item -ItemType Directory -Path $sandboxPath -Force | Out-Null
    }

    # Tattoo expectation — same source and fallback as the deploy script / detection rule.
    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $app = if ($cfg.PSObject.Properties.Name -contains 'App') { $cfg.App } else { $null }
    $uninstall = if ($cfg.PSObject.Properties.Name -contains 'Uninstall') { $cfg.Uninstall } else { $null }
    $tattooName = if ($app -and ($app.PSObject.Properties.Name -contains 'DisplayName') -and $app.DisplayName) { $app.DisplayName }
                  elseif ($app -and $app.Name) { $app.Name }
                  else { $null }
    $hasTattoo = [bool]($app -and $app.ScriptAuthor -and $app.Vendor -and $tattooName -and $app.Version)

    # ARP DisplayName candidates for identifying the old app (exact match): the clean name and the
    # captured uninstall DisplayName — but NOT the 'Unknown App' sentinel (Update-PSADTUninstallLogic).
    $candNames = @()
    if ($tattooName) { $candNames += $tattooName }
    if ($uninstall -and $uninstall.AppName -and $uninstall.AppName -ne 'Unknown App') { $candNames += $uninstall.AppName }
    $candNames = @($candNames | Select-Object -Unique)
    $candLiteral = if ($candNames.Count) { '@(' + (($candNames | ForEach-Object { "'" + (ConvertTo-PSSingleQuoted $_) + "'" }) -join ', ') + ')' } else { '@()' }

    # ---- Fixed body (single-quoted here-strings: device-side $ stays literal) ----
    $header = @'
param([Parameter(Mandatory = $true)][ValidateSet('PreBaseline', 'PreUpdate', 'PostUpdate')][string]$Phase)
# win32-toolkit update-test assertions (Windows PowerShell 5.1-safe; runs inside Windows Sandbox).
$logDir = 'C:\PSADT\Sandbox\Logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$assertLog = Join-Path $logDir 'UpdateAssertions.log'
function Write-AssertLine([string]$Message) {
    ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) | Add-Content -Path $assertLog -Encoding UTF8
}

# Loose version equality: tolerate 'v' prefix, component-count drift (2.5 == 2.5.0), and a decorated
# suffix ('2.53.0' ~ '2.53.0.windows.1') — old-version ARP DisplayVersions vary a lot.
function Test-LooseVersionEqual([string]$a, [string]$b) {
    if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return $false }
    $ta = $a.Trim() -replace '^[vV]', ''
    $tb = $b.Trim() -replace '^[vV]', ''
    if ($ta -ieq $tb) { return $true }
    $pa = $null; $pb = $null
    if ([version]::TryParse($ta, [ref]$pa) -and [version]::TryParse($tb, [ref]$pb) -and $pa -eq $pb) { return $true }
    if ($ta.StartsWith("$tb.") -or $tb.StartsWith("$ta.")) { return $true }
    return $false
}
# STRICT equality (only trailing-zero drift, 2.5 == 2.5.0) — for deciding whether a surviving ARP
# entry's version changed. Test-LooseVersionEqual's prefix tolerance is WRONG here: it would treat a
# 2.5 -> 2.5.1 in-place upgrade as "unchanged" and false-FAIL a successful update.
function Test-VersionUnchanged([string]$actual, [string]$old) {
    if ([string]::IsNullOrWhiteSpace($actual) -or [string]::IsNullOrWhiteSpace($old)) { return $false }
    $na = $actual.Trim() -replace '^[vV]', ''
    $no = $old.Trim() -replace '^[vV]', ''
    if ($na -ieq $no) { return $true }
    $pa = $null; $po = $null
    if ([version]::TryParse($na, [ref]$pa) -and [version]::TryParse($no, [ref]$po)) {
        $sa = '{0}.{1}.{2}.{3}' -f [Math]::Max($pa.Major,0), [Math]::Max($pa.Minor,0), [Math]::Max($pa.Build,0), [Math]::Max($pa.Revision,0)
        $so = '{0}.{1}.{2}.{3}' -f [Math]::Max($po.Major,0), [Math]::Max($po.Minor,0), [Math]::Max($po.Build,0), [Math]::Max($po.Revision,0)
        return ($sa -eq $so)
    }
    return $false
}

$arpPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)
function Get-ArpEntries {
    $out = @()
    foreach ($p in $arpPaths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $p -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            $out += [pscustomobject]@{ KeyPath = "$($k.PSPath)"; DisplayName = "$($props.DisplayName)"; DisplayVersion = "$($props.DisplayVersion)" }
        }
    }
    $out
}
$preBaselineFile = Join-Path $logDir 'PreBaselineArp.json'
$identifiedFile  = Join-Path $logDir 'PreUpdateArpBaseline.json'

Write-AssertLine "=== Phase: $Phase ==="

# PreBaseline: snapshot existing ARP keys BEFORE the old install, then stop (no assertions).
if ($Phase -eq 'PreBaseline') {
    $keys = @(Get-ArpEntries | ForEach-Object { $_.KeyPath })
    ConvertTo-Json -InputObject @($keys) | Set-Content -LiteralPath $preBaselineFile -Encoding UTF8
    Write-AssertLine "PreBaseline ARP snapshot: $($keys.Count) keys"
    Write-AssertLine "=== End PreBaseline ==="
    return
}
'@

    $requirementBlock = if ($SkipRequirement) {
        @'

Write-AssertLine "ASSERT Requirement-$Phase = SKIP (requirement check disabled with -SkipRequirementCheck)"
'@
    }
    else {
        @'

# Update-app requirement rule: exit 0 + STDOUT means Intune would consider the requirement MET.
$reqScript = 'C:\PSADT\SupportFiles\UpdateRequirement.ps1'
if (Test-Path -LiteralPath $reqScript) {
    $reqOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reqScript 2>&1
    $reqCode = $LASTEXITCODE
    Write-AssertLine ('Requirement script exit code: {0}; output: [{1}]' -f $reqCode, (@($reqOutput | ForEach-Object { "$_" }) -join ' '))
    if ($reqCode -eq 0) { Write-AssertLine "ASSERT Requirement-$Phase = PASS" }
    elseif ($Phase -eq 'PreUpdate') { Write-AssertLine "ASSERT Requirement-$Phase = FAIL (rule did not detect the vendor-installed old version - the update app would be NOT APPLICABLE on machines that got the app outside this toolkit; the update itself may still work)" }
    else                { Write-AssertLine "ASSERT Requirement-$Phase = FAIL (rule did not detect the app AFTER the update - presence signals are broken)" }
}
else {
    Write-AssertLine "ASSERT Requirement-$Phase = SKIP (SupportFiles\UpdateRequirement.ps1 not present)"
}
'@
    }
    # ---- OldArpGone: old app's ARP entry must be gone/updated after the update (data spliced) ----
    $arpData = @"

# Old-app identification data (spliced from AppConfig; DATA, never code).
`$candidateNames = $candLiteral
`$expectedOldVersion = '$(ConvertTo-PSSingleQuoted $OldVersion)'
"@

    $arpBlock = @'

if ($Phase -eq 'PreUpdate') {
    # Identify the old app's ARP entries = keys NEW since PreBaseline that match a candidate name or
    # the old version (intersection kills the Sandbox base image's preinstalled Edge/WebView2/etc.).
    $preSet = @{}
    if (Test-Path -LiteralPath $preBaselineFile) {
        # Where-Object filters the empty-array artifact: PS 5.1 ConvertTo-Json @() -> "[\n\n]", which
        # ConvertFrom-Json reads back as one empty Object[] element (not zero).
        foreach ($k in @(Get-Content -LiteralPath $preBaselineFile -Raw | ConvertFrom-Json | Where-Object { $_ })) { $preSet["$k"] = $true }
    }
    $identified = @()
    foreach ($e in @(Get-ArpEntries)) {
        if ($preSet.ContainsKey($e.KeyPath)) { continue }
        $nameMatch = $e.DisplayName -and ($candidateNames -contains $e.DisplayName)
        $verMatch  = $expectedOldVersion -and $e.DisplayName -and (Test-LooseVersionEqual $e.DisplayVersion $expectedOldVersion)
        if ($nameMatch -or $verMatch) {
            $identified += [pscustomobject]@{ KeyPath = $e.KeyPath; DisplayName = $e.DisplayName; DisplayVersion = $e.DisplayVersion }
        }
    }
    ConvertTo-Json -InputObject @($identified) | Set-Content -LiteralPath $identifiedFile -Encoding UTF8
    Write-AssertLine "PreUpdate: identified $($identified.Count) ARP entry(ies) as the old app"
}
if ($Phase -eq 'PostUpdate') {
    # Where-Object drops the PS 5.1 empty-array artifact so a zero-identified run SKIPs (not false-PASS).
    $identified = @()
    if (Test-Path -LiteralPath $identifiedFile) { $identified = @(Get-Content -LiteralPath $identifiedFile -Raw | ConvertFrom-Json | Where-Object { $_ -and $_.KeyPath }) }
    if ($identified.Count -eq 0) {
        Write-AssertLine "ASSERT OldArpGone-PostUpdate = SKIP (no old-app ARP entry identified after the baseline install - MSIX baseline or unrecognizable DisplayName/DisplayVersion)"
    } else {
        $stillOld = @()
        foreach ($e in $identified) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $e.KeyPath -ErrorAction Stop } catch { }
            if (-not $p) { continue }                                                                 # key gone -> updated in place or removed
            if ($expectedOldVersion -and -not (Test-VersionUnchanged "$($p.DisplayVersion)" $expectedOldVersion)) { continue }   # version bumped -> upgraded (strict, not prefix-loose)
            $stillOld += "$($e.DisplayName) [$($e.KeyPath)]"
        }
        if ($stillOld.Count -gt 0) {
            Write-AssertLine "ASSERT OldArpGone-PostUpdate = FAIL (old version still registered: $($stillOld -join '; '))"
        } else {
            Write-AssertLine "ASSERT OldArpGone-PostUpdate = PASS"
        }
    }
}
'@

    # ---- Baseline tattoo (PreUpdate only; baseline was a previous TOOLKIT package) ----
    $baselineTattooBlock = ''
    if ($ExpectBaselineTattoo -and $hasTattoo) {
        $baselineTattooBlock = @"

if (`$Phase -eq 'PreUpdate') {
    # The baseline was installed by a previous toolkit package - it must have written its own tattoo
    # at the OLD version (PostUpdate then proves the old->new overwrite).
    `$btKey = 'HKLM:\SOFTWARE\$(ConvertTo-PSSingleQuoted $app.ScriptAuthor)\$(ConvertTo-PSSingleQuoted $app.Vendor)\$(ConvertTo-PSSingleQuoted $tattooName)'
    `$btActual = `$null
    try { `$btActual = (Get-ItemProperty -LiteralPath `$btKey -ErrorAction Stop).Version } catch { }
    Write-AssertLine ('TattooBaseline [{0}] actual=[{1}] expected(old)=[{2}]' -f `$btKey, `$btActual, `$expectedOldVersion)
    if (Test-LooseVersionEqual "`$btActual" `$expectedOldVersion) { Write-AssertLine 'ASSERT TattooBaseline-PreUpdate = PASS' }
    else { Write-AssertLine 'ASSERT TattooBaseline-PreUpdate = FAIL (baseline toolkit package did not write its tattoo at the old version - baseline install failed?)' }
}
"@
    }

    $body = $header + $requirementBlock + $arpData + $arpBlock + $baselineTattooBlock

    # ---- Tattoo check (PostUpdate only; expectations spliced as escaped data) ----
    if ($hasTattoo) {
        $tattooBlock = @"

if (`$Phase -eq 'PostUpdate') {
    # The update app's Intune detection rule: tattoo key holds the NEW version after the update.
    `$tattooKey = 'HKLM:\SOFTWARE\$(ConvertTo-PSSingleQuoted $app.ScriptAuthor)\$(ConvertTo-PSSingleQuoted $app.Vendor)\$(ConvertTo-PSSingleQuoted $tattooName)'
    `$expectedVersion = '$(ConvertTo-PSSingleQuoted $app.Version)'
    `$actualVersion = `$null
    try { `$actualVersion = (Get-ItemProperty -LiteralPath `$tattooKey -ErrorAction Stop).Version } catch { }
    Write-AssertLine ('Tattoo [{0}] Version: actual=[{1}] expected=[{2}]' -f `$tattooKey, `$actualVersion, `$expectedVersion)
    if (`$actualVersion -eq `$expectedVersion) { Write-AssertLine 'ASSERT Tattoo-PostUpdate = PASS' }
    else                                       { Write-AssertLine 'ASSERT Tattoo-PostUpdate = FAIL' }
}
"@
    }
    else {
        $tattooBlock = @'

if ($Phase -eq 'PostUpdate') {
    Write-AssertLine 'ASSERT Tattoo-PostUpdate = SKIP (AppConfig.json has no complete tattoo values - regenerate the project)'
}
'@
    }

    $footer = @'

Write-AssertLine "=== End $Phase ==="
if ($Phase -eq 'PostUpdate') { Write-AssertLine 'RESULT COMPLETE' }
'@

    $scriptPath = Join-Path $sandboxPath 'UpdateAssertions.ps1'
    # UTF-8 WITH BOM: the script runs under Windows PowerShell 5.1 in the sandbox, which decodes
    # BOM-less files as ANSI — non-ASCII app metadata (vendor/product names) would mojibake and
    # produce false assertion FAILs. (PS7's Set-Content -Encoding UTF8 writes no BOM.)
    [System.IO.File]::WriteAllText($scriptPath, ($body + $tattooBlock + $footer), (New-Object System.Text.UTF8Encoding($true)))

    # Sanity: the generated script must parse (it runs unattended on 5.1 in the sandbox).
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs) | Out-Null
    if ($errs -and $errs.Count) {
        throw "Generated UpdateAssertions.ps1 has parse errors: $($errs[0].Message)"
    }
    return $scriptPath
}
