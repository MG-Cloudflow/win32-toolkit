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

        Every Update run gets the prior-install text (the catalog's PriorPredicate and PriorEvaluate, verbatim, then a
        fixed assertion text) between the tattoo block and the footer, and the data file Sandbox\UpdateAssertionData.json
        (BOM-less: ProofEntryIds, OtherEntryIds, NewAppFiles, OwnProductCode, OwnAppxName, SeedUserData, Sibling) - lists
        and identities are never spliced into the script. NewAppIntact-PostUpdate checks up to 10 program files of the
        newest install capture (or the provisioned MSIX package) after the update, and the package's own MSI product.
        The guest writes Sandbox\Logs\PriorObservations.json (the versions it observed).
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
    .PARAMETER ProofEntryIds
        Installer-identity PR 3 (spec 2.10, L27): the Enforce prior-install entries (one proof group) this run checks:
        PreUpdate asserts PriorPresent-PreUpdate.<id> (the deploy script's own evaluation plans their removal) and, for
        capture lineage, SiblingIdentityStable-PreUpdate.<id>; PostUpdate asserts PriorAbsent-PostUpdate.<id> and
        PriorResidue-PostUpdate.<id>, and writes 'DATA UserDataKept-PostUpdate.<id> = KEPT|LOST' (data, never an
        assertion, L14) for a user file seeded in the prior's folder. PostUpdate also writes the device markers the deploy
        script left (HKLM\SOFTWARE\<ScriptAuthor>\win32-toolkit: LastRefusal; PriorInstalls\<View>\<Key>: Removed, Version,
        LastSeen) as 'NOTE PriorMarker ...' lines: evidence only, never a verdict.
    .PARAMETER OtherEntryIds
        Prior-install entries of another uninstaller technology or registry view: asserted absent before and after.
    .PARAMETER SiblingData
        Capture lineage: per entry id, @{ ObservedVersion; Services; Shortcuts; Tasks } from its floor capture record.
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

        [switch]$ExpectBaselineTattoo,

        [string[]]$ProofEntryIds = @(),

        [string[]]$OtherEntryIds = @(),

        [hashtable]$SiblingData
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
    # Appended with read sharing: the host reads this log while the guest writes it (Windows Sandbox maps the folder),
    # and Windows PowerShell 5.1's Add-Content fails on a file another process holds open, which dropped the line.
    # A short retry covers any other transient lock. UTF-8 with a BOM on a new file, as Add-Content wrote it.
    $assertText = ('[{0}] {1}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'), $Message) + "`r`n"
    $assertBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($assertText)
    for ($assertTry = 1; $assertTry -le 100; $assertTry++) {
        $assertStream = $null
        try {
            $assertStream = [System.IO.File]::Open($assertLog, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            if ($assertStream.Length -eq 0) { $assertStream.Write([byte[]](0xEF, 0xBB, 0xBF), 0, 3) }
            $assertStream.Write($assertBytes, 0, $assertBytes.Length)
            return
        }
        catch { Start-Sleep -Milliseconds 100 }
        finally { if ($null -ne $assertStream) { $assertStream.Dispose() } }
    }
}
# The elements of a JSON array file this script wrote. Windows PowerShell 5.1 writes a parsed JSON array to the
# pipeline as ONE object, so a filter right after ConvertFrom-Json would see the whole array as one item: the value is
# read into a variable first and enumerated here (an empty array, also 5.1's '[ ]' artifact, gives nothing).
function Read-JsonArray([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $jsonValue = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($jsonItem in @($jsonValue)) { if ($null -ne $jsonItem) { $jsonItem } }
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
    elseif ($Phase -eq 'PreUpdate') { Write-AssertLine "ASSERT Requirement-$Phase = FAIL (rule did not detect the installed old version - the update app would be NOT APPLICABLE on devices like this one: an install of the app it has no signal for<<W32T-PREUPDATE-CAUSES>>)" }
    else                { Write-AssertLine "ASSERT Requirement-$Phase = FAIL (rule did not detect the app AFTER the update - the update did not install the app (see the exit code of the update), or its presence signals are broken)" }
}
else {
    Write-AssertLine "ASSERT Requirement-$Phase = SKIP (SupportFiles\UpdateRequirement.ps1 not present)"
}
'@
    }
    # The causes the PreUpdate failure names follow the project's prior-install rules: one of two CONSTANT texts per mode, chosen
    # on the host (no rule data reaches the script). Live rows OP-CONTROL (a project without rules was told about "its rule's
    # VersionMax") and RC2-BLOCK (a Block rule's prior, left out of the update requirement by design, D28, was not named).
    $ruleModes = @()
    if ($cfg.PSObject.Properties.Name -contains 'PriorInstalls' -and $cfg.PriorInstalls -and $cfg.PriorInstalls.PSObject.Properties.Name -contains 'Entries') {
        $ruleModes = @(@($cfg.PriorInstalls.Entries) | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'Mode' } | ForEach-Object { [string]$_.Mode })
    }
    $preCauses = ''
    if ($ruleModes -ccontains 'Enforce') { $preCauses += ", or a prior install above its Enforce rule's VersionMax, which is not applicable by design" }
    if ($ruleModes -ccontains 'Block' -or $ruleModes -ccontains 'Report') { $preCauses += ', or a prior install only a Block or Report rule names, which the update requirement leaves out by design (it holds Enforce rules only)' }
    $requirementBlock = $requirementBlock.Replace('<<W32T-PREUPDATE-CAUSES>>', $preCauses)
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
    foreach ($k in @(Read-JsonArray $preBaselineFile | Where-Object { $_ })) { $preSet["$k"] = $true }
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
    # Element by element (Read-JsonArray): a zero-identified run SKIPs (not false-PASS), and two or more entries stay two.
    $identified = @(Read-JsonArray $identifiedFile | Where-Object { $_ -and $_.KeyPath })
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

    # ---- Prior installs (installer-identity PR 3, spec 2.10, L6, L14, L15) ----------------------------------------------
    # The data the guest needs travels in a BOM-less data file (lists and identities are never spliced); the predicate
    # and the evaluation are the deploy script's own catalog texts, verbatim, so the test checks what the device runs.
    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $guidRule = '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$'
    $newAppFiles = [string[]]@()
    $capFile = @(Get-ChildItem -LiteralPath (Join-Path $ProjectPath 'Documentation') -Filter 'InstallationChanges_*.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending) | Select-Object -First 1
    if ($capFile) {
        try {
            $capture = Get-Content -LiteralPath $capFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $paths = [string[]]@(@(& $prop $capture 'NewFiles') | Where-Object { $null -ne $_ -and [string](& $prop $_ 'Type') -eq 'File' } | ForEach-Object { [string](& $prop $_ 'Path') } |
                    Where-Object { $_ -match '^C:\\Program Files( \(x86\))?\\' -and $_ -match '\.(exe|dll)$' -and $_ -notmatch '\\(Microsoft|Common Files|WindowsApps|Package Cache)\\|EdgeUpdate|EdgeCore|EdgeWebView' -and $_ -notmatch '[\p{Cc}\p{Cf}]' -and $_.Length -le 260 } |
                    Select-Object -Unique)
            [Array]::Sort($paths, [System.StringComparer]::Ordinal)
            $newAppFiles = [string[]]@($paths | Select-Object -First 10)
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "The install capture was not read for NewAppIntact: $($_.Exception.Message)"
        }
    }
    $ownId = & $prop $cfg 'OwnIdentity'
    $ownProductCode = [string](& $prop $ownId 'ProductCode')
    if ($ownProductCode -notmatch $guidRule) { $ownProductCode = '' }
    $ownAppxName = ''
    foreach ($u in @(& $prop $uninstall 'Uninstallers')) { if ([string](& $prop $u 'Type') -eq 'msix' -and (& $prop $u 'PackageName')) { $ownAppxName = [string](& $prop $u 'PackageName'); break } }
    $sibling = [ordered]@{}
    if ($SiblingData) {
        foreach ($k in @($SiblingData.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -cmatch '^[a-z0-9-]{1,40}$' } | Sort-Object)) {
            $sd = $SiblingData[$k]
            $sibling[$k] = [ordered]@{
                ObservedVersion = [string]$sd['ObservedVersion']
                Services        = [string[]]@($sd['Services'] | Where-Object { $_ })
                Shortcuts       = [string[]]@($sd['Shortcuts'] | Where-Object { $_ })
                Tasks           = [string[]]@($sd['Tasks'] | Where-Object { $_ })
            }
        }
    }
    $proofIds = [string[]]@($ProofEntryIds | Where-Object { $_ -cmatch '^[a-z0-9-]{1,40}$' })
    $otherIds = [string[]]@($OtherEntryIds | Where-Object { $_ -cmatch '^[a-z0-9-]{1,40}$' })
    $assertionData = [ordered]@{
        SchemaVersion  = '1.0'
        ProofEntryIds  = $proofIds
        OtherEntryIds  = $otherIds
        NewAppFiles    = $newAppFiles
        OwnProductCode = $ownProductCode
        OwnAppxName    = $ownAppxName
        SeedUserData   = ($proofIds.Count -gt 0)
        Sibling        = $sibling
    }
    [System.IO.File]::WriteAllText((Join-Path $sandboxPath 'UpdateAssertionData.json'), (ConvertTo-Json -InputObject $assertionData -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    $priorAssertions = @'
## ---- win32-toolkit prior-install assertions (installer-identity PR 3). Data: Sandbox\UpdateAssertionData.json and the
## ---- package's own SupportFiles\AppConfig.json (data files, never spliced). The predicate above is the deploy script's.
$w32tPrAD = $null
$w32tPrCfg = $null
try { $w32tPrAD = Get-Content -LiteralPath 'C:\PSADT\Sandbox\UpdateAssertionData.json' -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $w32tPrAD = $null }
try { $w32tPrCfg = Get-Content -LiteralPath 'C:\PSADT\SupportFiles\AppConfig.json' -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $w32tPrCfg = $null }
$w32tPrAll = @()
if ($w32tPrCfg -and $w32tPrCfg.PSObject.Properties['PriorInstalls'] -and $w32tPrCfg.PriorInstalls) { $w32tPrAll = @(@($w32tPrCfg.PriorInstalls.Entries) | Where-Object { $_ }) }
$w32tPrProof = @()
$w32tPrOther = @()
if ($w32tPrAD) { $w32tPrProof = @(@($w32tPrAD.ProofEntryIds) | Where-Object { $_ }); $w32tPrOther = @(@($w32tPrAD.OtherEntryIds) | Where-Object { $_ }) }
$w32tPrSeedFile = Join-Path $logDir 'PriorSeeds.json'
if ($Phase -eq 'PreUpdate') {
    $w32tPrObs = @()
    $w32tPrSeeds = @()
    foreach ($w32tPrE in $w32tPrAll) {
        $w32tPrId = [string]$w32tPrE.Id
        if ($w32tPrProof -contains $w32tPrId) {
            $w32tPrR = & $w32tPrEvaluate $w32tPrE $w32tPrCfg
            $w32tPrObs += [pscustomobject]@{ Id = $w32tPrId; Outcome = [string]$w32tPrR.Outcome; Version = [string]$w32tPrR.VersionText }
            if ($w32tPrR.Outcome -eq 'Plan') { Write-AssertLine "ASSERT PriorPresent-PreUpdate.$w32tPrId = PASS" }
            else { Write-AssertLine ("ASSERT PriorPresent-PreUpdate.$w32tPrId = FAIL (" + (& $w32tPrShow ([string]$w32tPrR.Text)) + ')') }
            $w32tPrSib = $null
            if ($w32tPrAD.Sibling -and $w32tPrAD.Sibling.PSObject.Properties[$w32tPrId]) { $w32tPrSib = $w32tPrAD.Sibling.$w32tPrId }
            if ($w32tPrSib) {
                if ($w32tPrR.Outcome -eq 'Plan' -and [string]$w32tPrR.VersionText -ceq [string]$w32tPrSib.ObservedVersion) { Write-AssertLine "ASSERT SiblingIdentityStable-PreUpdate.$w32tPrId = PASS" }
                else { Write-AssertLine ("ASSERT SiblingIdentityStable-PreUpdate.$w32tPrId = FAIL (observed version " + (& $w32tPrShow ([string]$w32tPrR.VersionText)) + ', captured ' + (& $w32tPrShow ([string]$w32tPrSib.ObservedVersion)) + ')') }
            }
            if ($w32tPrAD.SeedUserData -and $w32tPrR.Outcome -eq 'Plan') {
                $w32tPrSeed = Join-Path $w32tPrR.Dir ('w32t-userdata-' + $w32tPrId + '.ini')
                try { Set-Content -LiteralPath $w32tPrSeed -Value 'win32-toolkit user data marker' -Encoding ASCII -ErrorAction Stop; $w32tPrSeeds += [pscustomobject]@{ Id = $w32tPrId; Path = $w32tPrSeed } } catch { }
            }
        }
        elseif ($w32tPrOther -contains $w32tPrId) {
            if ((& $w32tPrState $w32tPrE).State -eq 'Absent') { Write-AssertLine "ASSERT OtherPriorAbsent-PreUpdate.$w32tPrId = PASS" }
            else { Write-AssertLine "ASSERT OtherPriorAbsent-PreUpdate.$w32tPrId = FAIL (present before the update although this baseline should not produce it)" }
        }
    }
    ConvertTo-Json -InputObject @($w32tPrObs) -Depth 3 | Set-Content -LiteralPath (Join-Path $logDir 'PriorObservations.json') -Encoding UTF8
    ConvertTo-Json -InputObject @($w32tPrSeeds) -Depth 3 | Set-Content -LiteralPath $w32tPrSeedFile -Encoding UTF8
}
if ($Phase -eq 'PostUpdate') {
    $w32tPrSeeds = @(Read-JsonArray $w32tPrSeedFile | Where-Object { $_ -and $_.Path })
    foreach ($w32tPrE in $w32tPrAll) {
        $w32tPrId = [string]$w32tPrE.Id
        $w32tPrS = & $w32tPrState $w32tPrE
        if ($w32tPrProof -contains $w32tPrId) {
            if ($w32tPrS.State -eq 'Absent') { Write-AssertLine "ASSERT PriorAbsent-PostUpdate.$w32tPrId = PASS" }
            else { Write-AssertLine ("ASSERT PriorAbsent-PostUpdate.$w32tPrId = FAIL (still registered: " + (& $w32tPrShow ([string]$w32tPrS.KeyPath)) + ')') }
            ## User data is DATA, not an assertion (L14): the verdict ignores it, the host records LOST as Proof.DataLoss.
            foreach ($w32tPrSd in @($w32tPrSeeds | Where-Object { $_.Id -eq $w32tPrId })) {
                if (Test-Path -LiteralPath ([string]$w32tPrSd.Path)) { Write-AssertLine "DATA UserDataKept-PostUpdate.$w32tPrId = KEPT" }
                else { Write-AssertLine "DATA UserDataKept-PostUpdate.$w32tPrId = LOST (a user file in the prior's install folder was deleted by its uninstaller)" }
            }
            $w32tPrSib = $null
            if ($w32tPrAD -and $w32tPrAD.Sibling -and $w32tPrAD.Sibling.PSObject.Properties[$w32tPrId]) { $w32tPrSib = $w32tPrAD.Sibling.$w32tPrId }
            if ($w32tPrSib) {
                $w32tPrLeft = @(@($w32tPrSib.Services) | Where-Object { $_ -and (Get-Service -Name ([string]$_) -ErrorAction SilentlyContinue) })
                foreach ($w32tPrL in @(@($w32tPrSib.Shortcuts) + @($w32tPrSib.Tasks) | Where-Object { $_ })) { Write-AssertLine ('NOTE PriorResidue ' + $w32tPrId + ': listed residue ' + (& $w32tPrShow ([string]$w32tPrL))) }
                if ($w32tPrLeft.Count -eq 0) { Write-AssertLine "ASSERT PriorResidue-PostUpdate.$w32tPrId = PASS" }
                else { Write-AssertLine ("ASSERT PriorResidue-PostUpdate.$w32tPrId = FAIL (service(s) of the prior still installed: " + (& $w32tPrShow (@($w32tPrLeft) -join ', ')) + ')') }
            }
        }
        elseif ($w32tPrOther -contains $w32tPrId) {
            if ($w32tPrS.State -eq 'Absent') { Write-AssertLine "ASSERT OtherPriorAbsent-PostUpdate.$w32tPrId = PASS" }
            else { Write-AssertLine "ASSERT OtherPriorAbsent-PostUpdate.$w32tPrId = FAIL (present after the update)" }
        }
    }
    ## The device markers the deploy script wrote (NOTE lines: evidence only, never a verdict). Live rows OP-BLOCK,
    ## RC2-BLOCK, APP-RUNNING and OP-PROOF found LastRefusal and Removed/Version/LastSeen in no run artefact.
    $w32tPrMAuthor = ''
    if ($w32tPrCfg -and $w32tPrCfg.PSObject.Properties['App'] -and $w32tPrCfg.App) { $w32tPrMAuthor = [string]$w32tPrCfg.App.ScriptAuthor }
    if ($w32tPrMAuthor -match '\S' -and $w32tPrMAuthor -notmatch '[\\/*?\[\]\p{Cc}\p{Cf}]') {
        $w32tPrMRoot = 'HKLM:\SOFTWARE\' + $w32tPrMAuthor + '\win32-toolkit'
        $w32tPrMV = ''
        try { $w32tPrMV = [string](Get-ItemProperty -LiteralPath $w32tPrMRoot -Name 'LastRefusal' -ErrorAction Stop).LastRefusal } catch { $w32tPrMV = '' }
        if ($w32tPrMV) { Write-AssertLine ('NOTE PriorMarker LastRefusal: ' + (& $w32tPrShow $w32tPrMV)) }
        foreach ($w32tPrE in $w32tPrAll) {
            $w32tPrMKey = $w32tPrMRoot + '\PriorInstalls\' + [string]$w32tPrE.View + '\' + [string]$w32tPrE.Key
            $w32tPrMParts = @()
            foreach ($w32tPrMN in @('Removed', 'Version', 'LastSeen')) {
                $w32tPrMV = ''
                try { $w32tPrMV = [string](Get-ItemProperty -LiteralPath $w32tPrMKey -Name $w32tPrMN -ErrorAction Stop).$w32tPrMN } catch { $w32tPrMV = '' }
                if ($w32tPrMV) { $w32tPrMParts += ($w32tPrMN + '=' + (& $w32tPrShow $w32tPrMV)) }
            }
            if ($w32tPrMParts.Count -gt 0) { Write-AssertLine ('NOTE PriorMarker ' + (& $w32tPrShow ([string]$w32tPrE.Id)) + ': ' + ($w32tPrMParts -join '; ')) }
        }
    }
    $w32tPrFiles = @()
    if ($w32tPrAD) { $w32tPrFiles = @(@($w32tPrAD.NewAppFiles) | Where-Object { $_ }) }
    if ($w32tPrFiles.Count -eq 0 -and $w32tPrAD -and [string]$w32tPrAD.OwnAppxName) {
        $w32tPrProv = @()
        try { $w32tPrProv = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq [string]$w32tPrAD.OwnAppxName }) } catch { $w32tPrProv = @() }
        if ($w32tPrProv.Count -gt 0) { Write-AssertLine 'ASSERT NewAppIntact-PostUpdate = PASS' }
        else { Write-AssertLine 'ASSERT NewAppIntact-PostUpdate = FAIL (the package is not provisioned)' }
    }
    elseif ($w32tPrFiles.Count -eq 0) { Write-AssertLine 'ASSERT NewAppIntact-PostUpdate = SKIP (no install capture lists the new files)' }
    else {
        $w32tPrMissing = @($w32tPrFiles | Where-Object { -not (Test-Path -LiteralPath ([string]$_) -PathType Leaf) })
        $w32tPrMsiOk = $true
        if ($w32tPrAD.OwnProductCode -and [string]$w32tPrAD.OwnProductCode -match $w32tPrGuid) {
            try { $w32tPrMsiOk = [int](New-Object -ComObject WindowsInstaller.Installer).ProductState([string]$w32tPrAD.OwnProductCode) -eq 5 } catch { $w32tPrMsiOk = $false }
        }
        if ($w32tPrMissing.Count -eq 0 -and $w32tPrMsiOk) { Write-AssertLine 'ASSERT NewAppIntact-PostUpdate = PASS' }
        else {
            # Only the parts that failed (live row OP-NEWER: an empty 'missing:' list when only the MSI was not registered).
            $w32tPrWhy = @()
            if ($w32tPrMissing.Count -gt 0) { $w32tPrWhy += ('missing: ' + (& $w32tPrShow (@($w32tPrMissing) -join ', '))) }
            if (-not $w32tPrMsiOk) { $w32tPrWhy += 'own MSI not registered' }
            Write-AssertLine ('ASSERT NewAppIntact-PostUpdate = FAIL (' + ($w32tPrWhy -join '; ') + ')')
        }
    }
}
'@
    $priorBlock = "`n" + (Get-Win32ToolkitDeployScriptBlock -Name PriorPredicate) + "`n" + (Get-Win32ToolkitDeployScriptBlock -Name PriorEvaluate) + "`n" + $priorAssertions + "`n"

    $footer = @'

Write-AssertLine "=== End $Phase ==="
if ($Phase -eq 'PostUpdate') { Write-AssertLine 'RESULT COMPLETE' }
'@

    $scriptPath = Join-Path $sandboxPath 'UpdateAssertions.ps1'
    # UTF-8 WITH BOM: the script runs under Windows PowerShell 5.1 in the sandbox, which decodes
    # BOM-less files as ANSI — non-ASCII app metadata (vendor/product names) would mojibake and
    # produce false assertion FAILs. (PS7's Set-Content -Encoding UTF8 writes no BOM.)
    # Line endings normalised to CRLF: the catalog texts are LF, the here-strings follow this file's checkout.
    $scriptText = ($body + $tattooBlock + $priorBlock + $footer) -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($scriptPath, $scriptText, (New-Object System.Text.UTF8Encoding($true)))

    # Sanity: the generated script must parse (it runs unattended on 5.1 in the sandbox).
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs) | Out-Null
    if ($errs -and $errs.Count) {
        throw "Generated UpdateAssertions.ps1 has parse errors: $($errs[0].Message)"
    }
    return $scriptPath
}
