function Get-Win32ToolkitRequirementRule {
    <#
    .SYNOPSIS
        Builds an Intune Win32 "requirement rule" (PowerShell script) that is met only when the app is
        ALREADY installed — used by the update app so it targets only devices that already have it.
    .DESCRIPTION
        Returns a #microsoft.graph.win32LobAppPowerShellScriptRequirement object for the app described
        by SupportFiles\AppConfig.json. The embedded (base64) script is a presence check: it writes 1
        to STDOUT and exits 0 when the app is found, otherwise it exits 1. Intune treats "exit 0 +
        STDOUT = 1" (detectionType integer, operator equal, value 1) as "requirement met", and a
        non-zero exit as "not met" — so the update app is applicable only where the app already exists.

        Presence uses EXACT/LITERAL, version-agnostic signals only, so it never matches unrelated
        products and never misses due to wildcard characters in the name:
          1. the install tattoo key (Test-Path -LiteralPath; the primary signal for EXE apps),
          2. the MSI UpgradeCode (version-stable) via WindowsInstaller RelatedProducts — read from the
             MSI in Files\ so MSI Zero-Config apps (empty App.Name, no tattoo) are covered,
          3. any captured MSI product code (Test-Path -LiteralPath), and
          4. an exact Add/Remove-Programs DisplayName -eq the clean App.Name (or the MSI ProductName).
        A first-word substring "-like" match is deliberately NOT used (it matched e.g. every
        "Microsoft *" product). If none of a tattoo key, an UpgradeCode, or a name is available, no
        reliable cross-version signal exists and the function returns $null so the caller aborts rather
        than shipping an over- or under-matching update app.

        Presence (not version >=) is deliberate: the update app's detection rule already checks the
        exact version, so the requirement only needs to gate on "the app is here to be updated". A
        version-based requirement would make the update never apply (it would only be applicable once
        already up to date).

        Untrusted values (app name, product codes) are escaped (ConvertTo-PSSingleQuoted /
        Test-Win32ToolkitProductCode) before being spliced into the generated script, so they are data
        and never a code position — same discipline as New-IntuneRequirementScript. The plaintext script
        is also written to SupportFiles\UpdateRequirement.ps1 for transparency.

        See knowledge-base/06-intune-packaging-and-publishing.md.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder (reads SupportFiles\AppConfig.json).
    .PARAMETER RunAsAccount
        Execution context for the requirement script on the device: 'system' (default) or 'user'.
    .PARAMETER RunAs32Bit
        Run the requirement script in a 32-bit process on 64-bit clients. Default: 64-bit (matches the
        install tattoo, which is written to the native 64-bit hive).
    .OUTPUTS
        [hashtable] the requirement rule, or $null if no reliable presence signal is available.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [ValidateSet('system', 'user')]
        [string]$RunAsAccount = 'system',

        [switch]$RunAs32Bit
    )

    $cfg       = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $app       = if ($cfg.PSObject.Properties.Name -contains 'App')       { $cfg.App }       else { $null }
    $uninstall = if ($cfg.PSObject.Properties.Name -contains 'Uninstall') { $cfg.Uninstall } else { $null }

    # ── Collect presence signals (all optional; need at least one) ────────────────
    # DisplayName is the tattoo name (populated even for MSI Zero-Config, where Name is empty); fall back
    # to Name for projects generated before DisplayName existed.
    $appName = if ($app) { if ($app.PSObject.Properties['DisplayName'] -and $app.DisplayName) { $app.DisplayName } else { $app.Name } } else { $null }
    $tattooKey = $null
    if ($app -and $app.ScriptAuthor -and $app.Vendor -and $appName) {
        $tattooKey = "HKLM:\SOFTWARE\$($app.ScriptAuthor)\$($app.Vendor)\$appName"
    }

    $productCodes = @()
    if ($uninstall) {
        foreach ($pc in @($uninstall.ProductCodes)) { if ($pc) { $productCodes += $pc } }
        foreach ($u  in @($uninstall.Uninstallers)) { if ($u.ProductCode) { $productCodes += $u.ProductCode } }
    }
    $productCodes = @($productCodes | Where-Object { Test-Win32ToolkitProductCode $_ } | Select-Object -Unique)

    # MSI: the version-STABLE identity is the UpgradeCode. Read it (and the ProductName) from the MSI in
    # Files\, so an MSI Zero-Config app (empty App.Name, no tattoo) still gets a reliable, version-agnostic
    # presence signal (checked on-device via WindowsInstaller RelatedProducts).
    $upgradeCode = $null
    $msiName     = $null
    $installerType = if (($cfg.PSObject.Properties.Name -contains 'Installer') -and $cfg.Installer) { $cfg.Installer.Type } else { $null }
    if ($installerType -eq 'msi' -or -not ($app -and $app.Name)) {
        $msiFile = Get-ChildItem -Path (Join-Path $ProjectPath 'Files') -Filter '*.msi' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($msiFile) {
            $uc = Get-Win32ToolkitMsiProperty -Path $msiFile.FullName -Property 'UpgradeCode'
            if (Test-Win32ToolkitProductCode $uc) { $upgradeCode = $uc }
            $pn = Get-Win32ToolkitMsiProperty -Path $msiFile.FullName -Property 'ProductName'
            if ($pn) { $msiName = $pn }
        }
    }

    # Version-independent product names for an EXACT (safe) Add/Remove-Programs match: App.DisplayName/Name
    # AND, for MSI, the MSI ProductName (authoritative — Windows Installer writes it verbatim as the ARP
    # DisplayName, and it often differs from the winget name, e.g. 'Notepad++' vs 'Notepad++ (64-bit x64)').
    # Matched with exact equality and never a substring wildcard, so it cannot match unrelated products.
    $cleanNames = @(@($appName; $msiName) | Where-Object { $_ } | Select-Object -Unique)
    $cleanName  = if ($cleanNames.Count) { $cleanNames[0] } else { $null }   # display/reporting name

    # Require a signal that can identify the app across versions: the tattoo key, the MSI UpgradeCode, or a
    # clean name for an exact ARP match. Product codes alone are per-version, so they never gate the rule on
    # their own. If none exist (e.g. an MSI with no UpgradeCode), abort rather than ship a bad rule.
    if (-not $tattooKey -and -not $cleanName -and -not $upgradeCode) {
        Write-Warning 'Cannot build a reliable update requirement rule (no install tattoo, MSI UpgradeCode, or app name). Use the install app, or supersedence.'
        return $null
    }

    # ── Build the presence-check script (untrusted values escaped as data; exact/literal matches only) ──
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# win32-toolkit update requirement: MET (exit 0 + STDOUT 1) when the app is already installed.')
    # Suppress non-terminating registry errors so nothing reaches STDERR — Intune treats ANY STDERR as
    # "requirement not met", which would wrongly reject a device that actually has the app.
    $lines.Add('$ErrorActionPreference = ''SilentlyContinue''')
    $lines.Add('$found = $false')
    if ($tattooKey) {
        # -LiteralPath so a name with [ ] * ? (e.g. "App [x64]") is matched literally, not as a wildcard.
        $lines.Add("if (-not `$found -and (Test-Path -LiteralPath '$(ConvertTo-PSSingleQuoted $tattooKey)')) { `$found = `$true }")
    }
    if ($upgradeCode) {
        # MSI UpgradeCode is stable across versions; RelatedProducts lists installed products sharing it.
        $lines.Add('if (-not $found) {')
        $lines.Add('    try {')
        $lines.Add('        $wi = New-Object -ComObject WindowsInstaller.Installer')
        $lines.Add("        if (@(`$wi.RelatedProducts('$(ConvertTo-PSSingleQuoted $upgradeCode)')).Count -gt 0) { `$found = `$true }")
        $lines.Add('    } catch { }')
        $lines.Add('}')
    }
    if ($productCodes.Count -gt 0) {
        $lines.Add('if (-not $found) {')
        $lines.Add('    foreach ($c in @(')
        foreach ($pc in $productCodes) { $lines.Add("        '$(ConvertTo-PSSingleQuoted $pc)'") }
        $lines.Add('    )) {')
        $lines.Add('        if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$c") { $found = $true; break }')
        $lines.Add('        if (Test-Path -LiteralPath "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$c") { $found = $true; break }')
        $lines.Add('    }')
        $lines.Add('}')
    }
    if ($cleanNames.Count -gt 0) {
        # Exact DisplayName equality (no wildcard) against each candidate name (App.DisplayName and, for
        # MSI, the authoritative MSI ProductName) — matches the app at any version, and cannot match
        # unrelated products.
        $lines.Add('if (-not $found) {')
        $lines.Add('    $targets = @(')
        foreach ($n in $cleanNames) { $lines.Add("        '$(ConvertTo-PSSingleQuoted $n)'") }
        $lines.Add('    )')
        $lines.Add('    foreach ($p in @(')
        $lines.Add("        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',")
        $lines.Add("        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'")
        $lines.Add('    )) {')
        $lines.Add('        if (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | Where-Object { $targets -contains $_.DisplayName }) { $found = $true; break }')
        $lines.Add('    }')
        $lines.Add('}')
    }
    $lines.Add('if ($found) { Write-Output 1; exit 0 } else { exit 1 }')
    $scriptText = ($lines -join "`r`n") + "`r`n"

    # Save a plaintext copy for transparency and for the sandbox Update test (which runs it under
    # Windows PowerShell 5.1 — write UTF-8 WITH BOM so non-ASCII names don't mojibake; PS7's
    # Set-Content -Encoding UTF8 writes no BOM).
    try {
        $supportFiles = Join-Path $ProjectPath 'SupportFiles'
        if (-not (Test-Path -LiteralPath $supportFiles)) { New-Item -ItemType Directory -Path $supportFiles -Force | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $supportFiles 'UpdateRequirement.ps1'), $scriptText, (New-Object System.Text.UTF8Encoding($true)))
    } catch { Write-Verbose "Could not write UpdateRequirement.ps1: $($_.Exception.Message)" }

    # UTF-8 with BOM (Intune-recommended for Win32 requirement/detection scripts), then base64.
    $enc   = New-Object System.Text.UTF8Encoding($true)
    $bytes = $enc.GetPreamble() + $enc.GetBytes($scriptText)
    $b64   = [System.Convert]::ToBase64String($bytes)

    return @{
        '@odata.type'           = '#microsoft.graph.win32LobAppPowerShellScriptRequirement'
        'displayName'           = if ($cleanName) { "$cleanName is installed" } else { 'App is installed' }
        'enforceSignatureCheck' = $false
        'runAs32Bit'            = [bool]$RunAs32Bit
        'runAsAccount'          = $RunAsAccount
        'scriptContent'         = $b64
        'detectionType'         = 'integer'
        'operator'              = 'equal'
        'detectionValue'        = '1'
    }
}
