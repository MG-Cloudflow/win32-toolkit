function New-InstallAssertionScript {
    <#
    .SYNOPSIS
        Generates Sandbox\InstallAssertions.ps1 — the in-sandbox pass/fail checks for the
        InstallUninstall test scenario (which, until now, produced no real PASS/FAIL signal).
    .DESCRIPTION
        The InstallUninstall test runs the generated script twice inside Windows Sandbox
        (Windows PowerShell 5.1):

          -Phase PostInstall    after the PSADT install: asserts the app is DETECTED exactly the way
                                Intune would detect it — the install tattoo
                                (HKLM:\SOFTWARE\<ScriptAuthor>\<Vendor>\<DisplayName>, value 'Version')
                                holds App.Version. If the project has no tattoo (e.g. MSI Zero-Config
                                with no org template), it falls back to an Add/Remove Programs scan for
                                a DisplayName equal to App.DisplayName.
          -Phase PostUninstall  after the PSADT uninstall: asserts the same signal is GONE (tattoo key
                                removed / ARP entry absent), then emits 'RESULT COMPLETE'.

        Results are appended as 'ASSERT <name> = PASS|FAIL|SKIP' lines to
        C:\PSADT\Sandbox\Logs\InstallAssertions.log (the mapped project folder, so the host sees them
        live), in the shared assertion-log format ('=== Phase: <X> ===', timestamped lines,
        'RESULT COMPLETE' at the end of PostUninstall).

        IMPORTANT: the generated script is entirely VALUE-FREE. No app metadata is spliced into the
        script text; the script reads C:\PSADT\SupportFiles\AppConfig.json at RUNTIME and computes the
        tattoo key / DisplayName from that DATA. This keeps untrusted app metadata (vendor/product
        names) out of the code that runs as SYSTEM in the guest.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder.
    .OUTPUTS
        [string] the path of the generated script, or [bool] $false on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    try {
        $sandboxPath = Join-Path $ProjectPath 'Sandbox'
        if (-not (Test-Path -LiteralPath $sandboxPath)) {
            New-Item -ItemType Directory -Path $sandboxPath -Force | Out-Null
        }

        # ── Generated body: ONE single-quoted here-string. Device-side $ stays literal; NO app value is
        #    spliced — everything is read from AppConfig.json at runtime as DATA. 5.1-safe (no ternary,
        #    no ??, no ?.). ────────────────────────────────────────────────────────────────────────────
        $script = @'
param([Parameter(Mandatory = $true)][ValidateSet('PostInstall', 'PostUninstall')][string]$Phase)
# win32-toolkit install/uninstall-test assertions (Windows PowerShell 5.1-safe; runs inside Windows
# Sandbox). Fully value-free: reads AppConfig.json at runtime and computes detection from that DATA.
$ErrorActionPreference = 'Continue'

$logDir = 'C:\PSADT\Sandbox\Logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$assertLog = Join-Path $logDir 'InstallAssertions.log'
function Write-AssertLine([string]$Message) {
    ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) | Add-Content -Path $assertLog -Encoding UTF8
}

Write-AssertLine ('=== Phase: {0} ===' -f $Phase)

if ($Phase -eq 'PostInstall') { $assertName = 'InstallDetected-PostInstall' }
else                          { $assertName = 'UninstallClean-PostUninstall' }

# ── Read the app config as DATA (never spliced into this script). ──────────────────────────────────
$cfgPath = 'C:\PSADT\SupportFiles\AppConfig.json'
$app = $null
try {
    if (Test-Path -LiteralPath $cfgPath) {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'App')) { $app = $cfg.App }
    }
} catch {
    Write-AssertLine ('Failed to read AppConfig.json: {0}' -f $_.Exception.Message)
}

function Get-AppText($obj, [string]$name) {
    if ($obj -and ($obj.PSObject.Properties.Name -contains $name) -and $null -ne $obj.$name) {
        return ("$($obj.$name)").Trim()
    }
    return ''
}

$scriptAuthor = Get-AppText $app 'ScriptAuthor'
$vendor       = Get-AppText $app 'Vendor'
$displayName  = Get-AppText $app 'DisplayName'
$version      = Get-AppText $app 'Version'

$hasTattoo = ($scriptAuthor -ne '' -and $vendor -ne '' -and $displayName -ne '' -and $version -ne '')

if ($hasTattoo) {
    # ── Tattoo detection — exactly what Intune's registry-version rule evaluates. ──────────────────
    $tattooKey = 'HKLM:\SOFTWARE\' + $scriptAuthor + '\' + $vendor + '\' + $displayName
    $keyPresent = $false
    $actual = $null
    try {
        $item = Get-ItemProperty -LiteralPath $tattooKey -ErrorAction Stop
        $keyPresent = $true
        if ($item -and ($item.PSObject.Properties.Name -contains 'Version')) { $actual = "$($item.Version)" }
    } catch {
        $keyPresent = $false   # a missing key is 'not installed', not an error
    }
    if ($Phase -eq 'PostInstall') {
        Write-AssertLine ('Tattoo [{0}] Version actual=[{1}] expected=[{2}]' -f $tattooKey, $actual, $version)
        if ($keyPresent -and $actual -eq $version) {
            Write-AssertLine ('ASSERT {0} = PASS' -f $assertName)
        } else {
            Write-AssertLine ('ASSERT {0} = FAIL (tattoo key absent or Version mismatch after install)' -f $assertName)
        }
    } else {
        if (-not $keyPresent) {
            Write-AssertLine ('ASSERT {0} = PASS' -f $assertName)
        } else {
            Write-AssertLine ('ASSERT {0} = FAIL (tattoo key still present after uninstall: {1})' -f $assertName, $tattooKey)
        }
    }
}
elseif ($displayName -ne '') {
    # ── Fallback: no tattoo (e.g. MSI Zero-Config, no org template). Detect via Add/Remove Programs. ─
    $arpPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $found = $false
    foreach ($p in $arpPaths) {
        if ($found) { break }
        try {
            if (-not (Test-Path -LiteralPath $p)) { continue }
            foreach ($k in @(Get-ChildItem -LiteralPath $p -ErrorAction SilentlyContinue)) {
                $props = $null
                try { $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { $props = $null }
                if ($props -and ($props.PSObject.Properties.Name -contains 'DisplayName') -and ("$($props.DisplayName)").Trim() -eq $displayName) {
                    $found = $true
                    break
                }
            }
        } catch {
            # unreadable hive -> treat as no match, not an error
        }
    }
    Write-AssertLine ('ARP scan DisplayName=[{0}] found=[{1}]' -f $displayName, $found)
    if ($Phase -eq 'PostInstall') {
        if ($found) { Write-AssertLine ('ASSERT {0} = PASS' -f $assertName) }
        else        { Write-AssertLine ('ASSERT {0} = FAIL (app not found in Add/Remove Programs after install)' -f $assertName) }
    } else {
        if (-not $found) { Write-AssertLine ('ASSERT {0} = PASS' -f $assertName) }
        else             { Write-AssertLine ('ASSERT {0} = FAIL (app still in Add/Remove Programs after uninstall)' -f $assertName) }
    }
}
else {
    # ── Nothing checkable: no tattoo fields AND no DisplayName. ────────────────────────────────────
    Write-AssertLine ('ASSERT {0} = SKIP (AppConfig.json has no tattoo fields and no DisplayName - nothing to detect against)' -f $assertName)
}

Write-AssertLine ('=== End {0} ===' -f $Phase)
if ($Phase -eq 'PostUninstall') { Write-AssertLine 'RESULT COMPLETE' }
'@

        $scriptPath = Join-Path $sandboxPath 'InstallAssertions.ps1'
        # UTF-8 WITH BOM: the script runs under Windows PowerShell 5.1 in the sandbox, which decodes a
        # BOM-less file as ANSI — non-ASCII text would mojibake. (PS7's Set-Content -Encoding UTF8
        # writes no BOM, so use the .NET writer explicitly.)
        [System.IO.File]::WriteAllText($scriptPath, $script, (New-Object System.Text.UTF8Encoding($true)))

        # Sanity: the generated script must parse (it runs unattended on 5.1 in the sandbox).
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs) | Out-Null
        if ($errs -and $errs.Count) {
            throw "Generated InstallAssertions.ps1 has parse errors: $($errs[0].Message)"
        }
        return $scriptPath
    }
    catch {
        Write-Error "New-InstallAssertionScript failed: $($_.Exception.Message)"
        return $false
    }
}
