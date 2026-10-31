function Export-Win32ToolkitDocumentation {
    <#
    .SYNOPSIS
        Writes a one-page summary of a packaged app for your customer.
    .DESCRIPTION
        Export-Win32ToolkitDocumentation writes a one-page summary of a project in a Markdown file.
        It describes the app, how Intune installs and detects it, what it installs, the tests that
        were run and the uninstall. If a part is missing, for example when no test was run, the
        summary says so and the command continues.

        Use it when you give a package to your customer. In the menu: Work with an existing
        project > Generate customer documentation. The menu then asks "Include the Intune app id +
        portal link? (only if the customer owns the tenant)". The default is No.

        By default, the summary holds no tenant ID and no Intune app ID. From the install capture
        (the record of what the installer changed), it shows only counts and the program name,
        never file paths.

        The command writes one file and replaces an older one. By default, this is Documentation.md
        in the project folder. Documentation.md never goes into the package: the build leaves it
        out.
    .PARAMETER ProjectPath
        The project folder: <base folder>\Projects\<template>\<project>.
    .PARAMETER OutputPath
        The file to write. Default: Documentation.md in the project folder. The command creates the
        folder if it does not exist. Use it to keep an internal copy apart from the customer's copy.
    .PARAMETER IncludeIntuneIds
        Adds an Intune section with the app ID and the link to the app in the Intune admin center.
        It lists the app of every tenant that this project was published to. Use it only for your
        own copy, or when the customer owns the tenant. A project that was never published gets no
        Intune section.
    .EXAMPLE
        Export-Win32ToolkitDocumentation -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'

        This writes Documentation.md in the project folder, without Intune IDs.
    .EXAMPLE
        $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
        Export-Win32ToolkitDocumentation -ProjectPath $project -IncludeIntuneIds

        This adds the Intune app ID and the link to the app. Do this only when the customer owns
        the tenant.
    .EXAMPLE
        $project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
        $copy = 'C:\Temp\Git_x64_2.53.0_internal.md'
        Export-Win32ToolkitDocumentation -ProjectPath $project -OutputPath $copy -IncludeIntuneIds

        This writes an internal copy with the Intune IDs to C:\Temp. The Documentation.md in the
        project does not change.
    .OUTPUTS
        The full path of the file that was written.
    .NOTES
        Time: seconds. The command needs no sign-in and no network.
    .LINK
        https://win32toolkit.com/reference/Export-Win32ToolkitDocumentation/
    .LINK
        https://win32toolkit.com/publishing/
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [string]$OutputPath,

        [switch]$IncludeIntuneIds
    )

    if (-not (Test-Path -LiteralPath $ProjectPath)) {
        throw "Project path not found: $ProjectPath"
    }
    if (-not $OutputPath) {
        $OutputPath = Join-Path $ProjectPath 'Documentation.md'
    }

    # -- Small helpers ------------------------------------------------------------------
    # Markdown table cells: a literal pipe would break the column, and newlines collapse the row.
    $cell = {
        param($v)
        if ($null -eq $v) { return '' }
        ([string]$v) -replace '\|', '\|' -replace '\r?\n', ' '
    }

    # Reads a named member off either a PSCustomObject (AppConfig / test results, from ConvertFrom-Json)
    # or an IDictionary (the detection rule is an ordered hashtable). Returns $default when absent/empty.
    $prop = {
        param($obj, $name, $default = '')
        if ($null -eq $obj) { return $default }
        $val = $null
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($name)) { $val = $obj[$name] }
        }
        elseif ($obj.PSObject.Properties.Name -contains $name) {
            $val = $obj.$name
        }
        if ($null -ne $val -and "$val" -ne '') { return [string]$val }
        return $default
    }

    # -- Gather: AppConfig (App / Installer / Uninstall / ProcessesToClose) --------------
    $app = $null; $installer = $null; $uninstall = $null; $intuneDefaults = $null; $branding = $null
    try {
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        if ($cfg) {
            if ($cfg.PSObject.Properties.Name -contains 'App')            { $app            = $cfg.App }
            if ($cfg.PSObject.Properties.Name -contains 'Installer')      { $installer      = $cfg.Installer }
            if ($cfg.PSObject.Properties.Name -contains 'Uninstall')      { $uninstall      = $cfg.Uninstall }
            if ($cfg.PSObject.Properties.Name -contains 'IntuneDefaults') { $intuneDefaults = $cfg.IntuneDefaults }
            if ($cfg.PSObject.Properties.Name -contains 'Branding')       { $branding       = $cfg.Branding }
        }
    }
    catch { Write-Warning "Could not read AppConfig: $($_.Exception.Message)" }

    # Min-OS shown here must match what Publish actually sends (D3) — read the org default, fall back to
    # the same '1607' Publish uses, so the doc never drifts from the app body.
    $docMinRelease = & $prop $intuneDefaults 'MinimumWindowsRelease' '1607'
    $docCompany    = & $prop $branding 'CompanyName' ''
    $docFooter     = & $prop $branding 'DocFooter' ''

    $displayName = & $prop $app 'DisplayName' (& $prop $app 'Name' 'Application')
    $version     = & $prop $app 'Version' ''
    $vendor      = & $prop $app 'Vendor' ''
    $arch        = & $prop $app 'Arch' ''
    $author      = & $prop $app 'ScriptAuthor' ''
    $packDate    = & $prop $app 'ScriptDate' ''
    $description = & $prop $app 'Description' ''
    $infoUrl     = & $prop $app 'InformationUrl' ''
    $installType = & $prop $installer 'Type' 'unknown'

    # -- Gather: detection method, in plain English -------------------------------------
    $detectionText = 'No detection rule generated yet (capture or publish the app first).'
    try {
        $rules = @(Get-Win32DetectionRules -ProjectPath $ProjectPath)
        $rule  = $rules | Select-Object -First 1
        if ($rule) {
            $odata = & $prop $rule '@odata.type' ''
            $dtype = & $prop $rule 'detectionType' ''
            if ($odata -match 'RegistryDetection') {
                if ($dtype -eq 'version') {
                    $keyPath  = (& $prop $rule 'keyPath' '') -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM\'
                    $valName  = & $prop $rule 'valueName' 'Version'
                    $detVal   = & $prop $rule 'detectionValue' $version
                    $detectionText = "Detected by a version marker in the registry ($keyPath\$valName = $detVal)."
                }
                else {
                    $keyPath = (& $prop $rule 'keyPath' '') -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM\'
                    $detectionText = "Detected by a registry key ($keyPath)."
                }
            }
            elseif ($odata -match 'FileSystemDetection') {
                $leaf = & $prop $rule 'fileOrFolderName' ''
                $detectionText = if ($leaf) { "Detected by a file on disk ($leaf)." } else { 'Detected by a file on disk.' }
            }
        }
    }
    catch { Write-Warning "Could not read detection rules: $($_.Exception.Message)" }

    # -- Gather: dependencies -----------------------------------------------------------
    $dependencies = @()
    try { $dependencies = @(Get-Win32ToolkitDependencies -ProjectPath $ProjectPath) }
    catch { Write-Warning "Could not read dependencies: $($_.Exception.Message)" }

    # -- Gather: install-change capture -> COUNTS + names only (never raw paths) ---------
    $captureText = 'Installed changes were not captured for this package.'
    $arpText     = ''
    try {
        $capFile = Get-LatestInstallationCapture -ProjectPath $ProjectPath
        if ($capFile) {
            $cap = Get-Content -LiteralPath $capFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $nFiles = @($cap.NewFiles).Count
            $nReg   = @($cap.NewRegistryKeys).Count
            $nSvc   = @($cap.NewServices).Count
            $captureText = "Registers $nFiles files, $nReg registry keys, $nSvc service(s)."
            $programs = @($cap.NewPrograms)
            if ($programs.Count -gt 0 -and $programs[0]) {
                $arpName = & $prop $programs[0] 'DisplayName' ''
                $arpVer  = & $prop $programs[0] 'DisplayVersion' ''
                if ($arpName) { $arpText = "Appears in Add/Remove Programs as **$arpName $arpVer**".TrimEnd() + '.' }
            }
        }
    }
    catch { Write-Warning "Could not read installation capture: $($_.Exception.Message)" }

    # -- Gather: test results (own reader if present, else the shared JSON directly) -----
    # The reader returns a comma-wrapped array to survive assignment; bind it BARE first, then normalise
    # with @() (wrapping the function call directly would leave the array nested one level deep).
    $testResults = @()
    try {
        if (Get-Command -Name 'Get-Win32ToolkitTestResult' -ErrorAction SilentlyContinue) {
            $tr = Get-Win32ToolkitTestResult -ProjectPath $ProjectPath
            $testResults = @($tr)
        }
        else {
            $trPath = Join-Path $ProjectPath 'Documentation\TestResults.json'
            if (Test-Path -LiteralPath $trPath) {
                $testResults = @(Get-Content -LiteralPath $trPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            }
        }
    }
    catch { Write-Warning "Could not read test results: $($_.Exception.Message)" }

    # -- Build the Markdown (ASCII only) ------------------------------------------------
    $sep = ' &nbsp;&middot;&nbsp; '   # HTML entity => renders as a mid-dot, but the source stays pure ASCII
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("# $displayName $version".TrimEnd())
    $null = $sb.AppendLine()

    $introBits = @()
    if ($vendor)   { $introBits += "**Publisher:** $vendor" }
    if ($arch)     { $introBits += "**Architecture:** $arch" }
    if ($packDate) { $introBits += "**Packaged:** $packDate" }
    if ($author)   { $introBits += "**Prepared by:** $author" }
    if ($introBits.Count -gt 0) {
        $null = $sb.AppendLine(($introBits -join $sep))
        $null = $sb.AppendLine()
    }

    $null = $sb.AppendLine('## Overview')
    if ($description) { $null = $sb.AppendLine($description) }
    else { $null = $sb.AppendLine("$displayName packaged for deployment via Microsoft Intune.") }
    if ($infoUrl) { $null = $sb.AppendLine(); $null = $sb.AppendLine("More information: <$infoUrl>") }
    $null = $sb.AppendLine()

    # The command lines are exactly what Publish sends to Intune (one helper, so the two never drift).
    # The interaction sentence is deliberately version-neutral: whether a user sees dialogs depends on the
    # org template's welcome/progress settings and on whether the app is running, and the exact rules
    # differ between PSADT 4.1 and 4.2 (it is no longer claimed to be silent).
    $intuneCommandLine = Get-Win32ToolkitIntuneCommandLine
    $null = $sb.AppendLine('## Deployment')
    $null = $sb.AppendLine("- **Installer type:** $installType")
    $null = $sb.AppendLine(('- Runs **as SYSTEM** via `{0}` (64-bit PowerShell). Whether the signed-in user sees dialogs (close the app, defer, progress) depends on the organisation template and on whether the app is running at install time.' -f $intuneCommandLine.Launcher))
    $null = $sb.AppendLine('- **Install command:**')
    $null = $sb.AppendLine('  ```')
    $null = $sb.AppendLine("  $($intuneCommandLine.Install)")
    $null = $sb.AppendLine('  ```')
    $null = $sb.AppendLine('- **Uninstall command:**')
    $null = $sb.AppendLine('  ```')
    $null = $sb.AppendLine("  $($intuneCommandLine.Uninstall)")
    $null = $sb.AppendLine('  ```')
    $null = $sb.AppendLine("- **Detection:** $detectionText")
    $minReleaseText = if ($docMinRelease -eq '1607') { 'Windows 10 1607 (build 14393) or later' } else { "Windows release $docMinRelease or later" }
    $null = $sb.AppendLine("- **Minimum OS:** $minReleaseText.")
    if ($arch) { $null = $sb.AppendLine("- **Supported architecture:** $arch") }
    if ($dependencies.Count -gt 0) {
        $null = $sb.AppendLine('- **Dependencies (installed first):**')
        foreach ($d in $dependencies) {
            $src = & $prop $d 'Source' ''
            $ref = & $prop $d 'Ref' ''
            $null = $sb.AppendLine("  - ${src}:$ref")
        }
    }
    $null = $sb.AppendLine()

    $null = $sb.AppendLine('## What it installs')
    $null = $sb.AppendLine($captureText)
    if ($arpText) { $null = $sb.AppendLine(); $null = $sb.AppendLine($arpText) }
    $null = $sb.AppendLine()

    $null = $sb.AppendLine('## Testing')
    if ($testResults.Count -gt 0) {
        $null = $sb.AppendLine('| Scenario | Backend | Date | Result |')
        $null = $sb.AppendLine('| --- | --- | --- | --- |')
        $failNotes = @()
        foreach ($t in $testResults) {
            $scenario = & $prop $t 'Scenario' ''
            # An Update record names the baseline technology it upgraded FROM (D1/D5), so the two rows of a
            # 'Both' run (one per technology) can be told apart. Older records (no Baseline) keep 'Update'.
            $baseline = if ($t -is [System.Collections.IDictionary]) { $t['Baseline'] } elseif ($t.PSObject.Properties.Name -contains 'Baseline') { $t.Baseline } else { $null }
            if ($scenario -eq 'Update' -and $null -ne $baseline) {
                if ((& $prop $baseline 'Unavailable' '') -eq 'True') {
                    $scenario = "Update (baseline unavailable: $(& $prop $baseline 'RequestedInstallerType' 'unknown'))"
                }
                else {
                    $tech = ('{0} {1}' -f (& $prop $baseline 'InstallerType' ''), (& $prop $baseline 'Family' '')).Trim()
                    if (-not $tech) { $tech = 'unknown technology' }
                    $baseVer = & $prop $baseline 'Version' ''
                    $scenario = if ($baseVer) { "Update (baseline: $tech, v$baseVer)" } else { "Update (baseline: $tech)" }
                }
            }
            $sc = & $cell $scenario
            $bk = & $cell (& $prop $t 'Backend' '')
            # Render the timestamp as a clean, culture-invariant UTC date (ConvertFrom-Json coerces the ISO
            # string to a [datetime] whose default [string] form is the host's locale, e.g. 07/15/2026).
            $dtVal = if ($t -is [System.Collections.IDictionary]) { $t['TimestampUtc'] } elseif ($t.PSObject.Properties.Name -contains 'TimestampUtc') { $t.TimestampUtc } else { $null }
            $dt = ''
            if ($dtVal -is [datetime]) {
                $dt = $dtVal.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + ' UTC'
            }
            elseif ($dtVal) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse([string]$dtVal, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
                    $dt = $parsed.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) + ' UTC'
                }
                else { $dt = & $cell $dtVal }
            }
            # A test the Intune-parity pre-check did not start (NotRun) is named as such, never as a bare
            # 'Inconclusive', which would read as a test that ran without a verdict (installer-identity PR 2, L17).
            $notRun = if ($t -is [System.Collections.IDictionary]) { $t.Contains('NotRun') } else { $t.PSObject.Properties.Name -contains 'NotRun' }
            $vd = if ($notRun) { 'Not run (Intune-parity pre-check)' } else { & $cell (& $prop $t 'Verdict' '') }
            $null = $sb.AppendLine("| $sc | $bk | $dt | $vd |")
            # Only genuine FAILs are "issues". A SKIP means "not checkable" (e.g. no tattoo/DisplayName to
            # detect against), not a failure — listing it as an issue would misread as a fault to the customer.
            if ($vd -ne 'Passed') {
                $bad = @($t.Assertions | Where-Object { $_ -and $_.Result -eq 'FAIL' } | ForEach-Object { "$($_.Name) ($($_.Result))" })
                if ($bad.Count -gt 0) { $failNotes += "**$sc / $bk** - issues: $($bad -join ', ')" }
            }
        }
        if ($failNotes.Count -gt 0) {
            $null = $sb.AppendLine()
            foreach ($n in $failNotes) { $null = $sb.AppendLine("- $n") }
        }
    }
    else {
        $null = $sb.AppendLine('No automated tests recorded yet.')
    }
    $null = $sb.AppendLine()

    $null = $sb.AppendLine('## Uninstall')
    $hasProductCodes = $uninstall -and ($uninstall.PSObject.Properties.Name -contains 'ProductCodes') -and @($uninstall.ProductCodes).Count -gt 0
    if ($uninstall) {
        if ($hasProductCodes) {
            $null = $sb.AppendLine("Supported - uninstall is driven by $(@($uninstall.ProductCodes).Count) known product code(s) plus the toolkit's uninstall logic.")
        }
        else {
            $null = $sb.AppendLine('Supported - uninstall logic was captured for this package.')
        }
    }
    else {
        $null = $sb.AppendLine('Supported via the Uninstall command above (no dedicated uninstall metadata was captured).')
    }
    $null = $sb.AppendLine()

    # -- Intune section (only with the switch; only then read publication ids) -----------
    if ($IncludeIntuneIds) {
        try {
            $pubs = @(Get-Win32ToolkitPublication -ProjectPath $ProjectPath)
            if ($pubs.Count -gt 0) {
                $null = $sb.AppendLine('## Intune')
                foreach ($p in $pubs) {
                    $appId = & $prop $p 'AppId' ''
                    if ($appId) {
                        $portal = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$appId"
                        $null = $sb.AppendLine("- **App ID:** $appId")
                        $null = $sb.AppendLine("- **Portal:** <$portal>")
                    }
                }
                $null = $sb.AppendLine()
            }
        }
        catch { Write-Warning "Could not read publication cache: $($_.Exception.Message)" }
    }

    $genDate = (Get-Date).ToString('yyyy-MM-dd')
    # B8 — org documentation branding: a custom footer line and/or "prepared by <company>".
    if (-not [string]::IsNullOrWhiteSpace($docFooter)) {
        $null = $sb.AppendLine($docFooter)
        $null = $sb.AppendLine()
    }
    $genLine = if (-not [string]::IsNullOrWhiteSpace($docCompany)) {
        "_Prepared by $docCompany · Generated by win32-toolkit on ${genDate}_"
    } else {
        "_Generated by win32-toolkit on ${genDate}_"
    }
    $null = $sb.AppendLine($genLine)

    # -- Write (UTF-8) and return the path ----------------------------------------------
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $sb.ToString() -Encoding UTF8
    Write-Verbose "Documentation written to $OutputPath"
    return $OutputPath
}
