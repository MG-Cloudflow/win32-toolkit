function Export-Win32ToolkitDocumentation {
    <#
    .SYNOPSIS
        Writes a clean, customer-facing one-page Documentation.md summarising a packaged project.
    .DESCRIPTION
        Gathers the read-only facts about a packaged PSADT/Intune project - its AppConfig, the Intune
        detection method, declared dependencies, the newest install-change capture, and any recorded
        automated test results - and renders them as a tight, skimmable Markdown one-pager aimed at a
        human reviewer (an IT admin signing off on the package, or an end-customer deliverable).

        Every gather is guarded: a missing piece degrades gracefully to a sensible line, never throws.

        By default NO tenant or app ids are read or printed, and the capture JSON's raw sandbox host paths
        are summarised to COUNTS and program names only, never surfaced. Pass -IncludeIntuneIds to add an
        Intune section with the published app id and portal link (only do this for internal documentation).

        The rendered Markdown is deliberately ASCII-only (typographic characters use HTML entities), so the
        file cannot mojibake regardless of how a viewer decodes it.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder (the folder that contains Invoke-AppDeployToolkit.ps1).
    .PARAMETER OutputPath
        Where to write the Markdown. Defaults to <ProjectPath>\Documentation.md.
    .PARAMETER IncludeIntuneIds
        Also read <ProjectPath>\Intune\Publications.json and add an "Intune" section with the app id and a
        portal deep-link. Omitted by default so the one-pager carries no tenant-specific identifiers.
    .OUTPUTS
        [string] - the full path of the Markdown file that was written.
    .EXAMPLE
        Export-Win32ToolkitDocumentation -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'

        Writes Documentation.md next to the project with no Intune ids.
    .EXAMPLE
        Export-Win32ToolkitDocumentation -ProjectPath $proj -OutputPath 'C:\temp\Git.md' -IncludeIntuneIds

        Writes an internal copy that also lists the published Intune app id and a portal link.
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
    $app = $null; $installer = $null; $uninstall = $null
    try {
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        if ($cfg) {
            if ($cfg.PSObject.Properties.Name -contains 'App')       { $app       = $cfg.App }
            if ($cfg.PSObject.Properties.Name -contains 'Installer') { $installer = $cfg.Installer }
            if ($cfg.PSObject.Properties.Name -contains 'Uninstall') { $uninstall = $cfg.Uninstall }
        }
    }
    catch { Write-Warning "Could not read AppConfig: $($_.Exception.Message)" }

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
    else { $null = $sb.AppendLine("$displayName packaged for silent deployment via Microsoft Intune.") }
    if ($infoUrl) { $null = $sb.AppendLine(); $null = $sb.AppendLine("More information: <$infoUrl>") }
    $null = $sb.AppendLine()

    $null = $sb.AppendLine('## Deployment')
    $null = $sb.AppendLine("- **Installer type:** $installType")
    $null = $sb.AppendLine('- Runs **silently, as SYSTEM** (no user interaction required).')
    $null = $sb.AppendLine('- **Install command:**')
    $null = $sb.AppendLine('  ```')
    $null = $sb.AppendLine('  powershell.exe -ExecutionPolicy Bypass -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install')
    $null = $sb.AppendLine('  ```')
    $null = $sb.AppendLine('- **Uninstall command:**')
    $null = $sb.AppendLine('  ```')
    $null = $sb.AppendLine('  powershell.exe -ExecutionPolicy Bypass -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Uninstall')
    $null = $sb.AppendLine('  ```')
    $null = $sb.AppendLine("- **Detection:** $detectionText")
    $null = $sb.AppendLine('- **Minimum OS:** Windows 10 1607 (build 14393) or later.')
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
            $sc = & $cell (& $prop $t 'Scenario' '')
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
            $vd = & $cell (& $prop $t 'Verdict' '')
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
    $null = $sb.AppendLine("_Generated by win32-toolkit on ${genDate}_")

    # -- Write (UTF-8) and return the path ----------------------------------------------
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $sb.ToString() -Encoding UTF8
    Write-Verbose "Documentation written to $OutputPath"
    return $OutputPath
}
