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

        Presence uses EXACT/LITERAL signals only, so it never matches unrelated products and never
        misses due to wildcard characters in the name:
          1. the install tattoo key (Test-Path -LiteralPath; version-agnostic, the primary signal),
          2. any captured MSI product code (Test-Path -LiteralPath), and
          3. an exact Add/Remove-Programs DisplayName -eq the clean App.Name.
        A first-word substring "-like" match is deliberately NOT used (it matched e.g. every
        "Microsoft *" product). If neither a tattoo key nor an App.Name is available (e.g. MSI
        Zero-Config), no reliable cross-version signal exists and the function returns $null so the
        caller aborts rather than shipping an over- or under-matching update app.

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
    $tattooKey = $null
    if ($app -and $app.ScriptAuthor -and $app.Vendor -and $app.Name) {
        $tattooKey = "HKLM:\SOFTWARE\$($app.ScriptAuthor)\$($app.Vendor)\$($app.Name)"
    }

    # Version-independent product name for an EXACT (safe) Add/Remove-Programs match. Deliberately the
    # clean App.Name (NOT the captured, version-decorated Uninstall DisplayName), matched with -eq and
    # never a substring wildcard, so it cannot match unrelated products (e.g. 'Microsoft *').
    $cleanName = if ($app -and $app.Name) { $app.Name } else { $null }

    $productCodes = @()
    if ($uninstall) {
        foreach ($pc in @($uninstall.ProductCodes)) { if ($pc) { $productCodes += $pc } }
        foreach ($u  in @($uninstall.Uninstallers)) { if ($u.ProductCode) { $productCodes += $u.ProductCode } }
    }
    $productCodes = @($productCodes | Where-Object { Test-Win32ToolkitProductCode $_ } | Select-Object -Unique)

    # Require a signal that can identify the app across versions: the tattoo key (version-agnostic) or a
    # clean app name for an exact ARP match. Product codes alone are per-version, so they never gate the
    # rule on their own (an MSI Zero-Config app has neither a tattoo nor an App.Name -> abort).
    if (-not $tattooKey -and -not $cleanName) {
        Write-Warning 'Cannot build a reliable update requirement rule (no install tattoo key and no app name — e.g. MSI Zero-Config). Use the install app, or supersedence.'
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
    if ($cleanName) {
        # Exact DisplayName equality (no wildcard) — matches the app at any version whose ARP name equals
        # App.Name, and cannot match unrelated products.
        $lines.Add('if (-not $found) {')
        $lines.Add("    `$target = '$(ConvertTo-PSSingleQuoted $cleanName)'")
        $lines.Add('    foreach ($p in @(')
        $lines.Add("        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',")
        $lines.Add("        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'")
        $lines.Add('    )) {')
        $lines.Add('        if (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $target }) { $found = $true; break }')
        $lines.Add('    }')
        $lines.Add('}')
    }
    $lines.Add('if ($found) { Write-Output 1; exit 0 } else { exit 1 }')
    $scriptText = ($lines -join "`r`n") + "`r`n"

    # Save a plaintext copy for transparency (does not affect the upload, which uses base64 below).
    try {
        $supportFiles = Join-Path $ProjectPath 'SupportFiles'
        if (-not (Test-Path -LiteralPath $supportFiles)) { New-Item -ItemType Directory -Path $supportFiles -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $supportFiles 'UpdateRequirement.ps1') -Value $scriptText -Encoding UTF8
    } catch { Write-Verbose "Could not write UpdateRequirement.ps1: $($_.Exception.Message)" }

    # UTF-8 with BOM (Intune-recommended for Win32 requirement/detection scripts), then base64.
    $enc   = New-Object System.Text.UTF8Encoding($true)
    $bytes = $enc.GetPreamble() + $enc.GetBytes($scriptText)
    $b64   = [System.Convert]::ToBase64String($bytes)

    return @{
        '@odata.type'           = '#microsoft.graph.win32LobAppPowerShellScriptRequirement'
        'displayName'           = if ($app -and $app.Name) { "$($app.Name) is installed" } else { 'App is installed' }
        'enforceSignatureCheck' = $false
        'runAs32Bit'            = [bool]$RunAs32Bit
        'runAsAccount'          = $RunAsAccount
        'scriptContent'         = $b64
        'detectionType'         = 'integer'
        'operator'              = 'equal'
        'detectionValue'        = '1'
    }
}
