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

        MSI projects additionally assert Windows Installer's own record: the host reads the MSI's
        ProductCode (validated GUID) into Sandbox\InstallAssertionData.json (DATA), and the guest checks
        the Uninstall\<ProductCode> key in either registry view ('MsiProductInstalled-PostInstall' /
        'MsiProductRemoved-PostUninstall') - a tattoo alone can be written by a run whose MSI step never ran.

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
    # UTC with a 'Z' (invariant culture), like PsadtExitCodes.log: in order whatever the guest's time zone.
    ('[{0}] {1}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'), $Message) | Add-Content -Path $assertLog -Encoding UTF8
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

# ── MSI: Windows Installer's own record (DATA from Sandbox\InstallAssertionData.json, written by the host
#    from the MSI's ProductCode). The tattoo alone can be written by a deploy script whose MSI step never
#    ran, so an MSI project also asserts its Uninstall key: present after install, gone after uninstall. ──
$msiCode = ''
$assertDataPath = 'C:\PSADT\Sandbox\InstallAssertionData.json'
try {
    if (Test-Path -LiteralPath $assertDataPath) {
        $assertData = Get-Content -LiteralPath $assertDataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($assertData -and ($assertData.PSObject.Properties.Name -contains 'MsiProductCode') -and $null -ne $assertData.MsiProductCode) {
            $msiCode = ("$($assertData.MsiProductCode)").Trim()
        }
    }
} catch {
    Write-AssertLine ('Failed to read InstallAssertionData.json: {0}' -f $_.Exception.Message)
}
if ($msiCode -ne '' -and $msiCode -notmatch '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$') {
    Write-AssertLine 'InstallAssertionData.json MsiProductCode is not a GUID - MSI assertion skipped'
    $msiCode = ''
}
if ($msiCode -ne '') {
    $msiKeys = @(
        ('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\' + $msiCode),
        ('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\' + $msiCode)
    )
    $msiPresent = $false
    foreach ($mk in $msiKeys) {
        # Same probe as the tattoo check: a missing key throws ('not installed'), an existing one does not.
        try { $null = Get-ItemProperty -LiteralPath $mk -ErrorAction Stop; $msiPresent = $true } catch { }
    }
    Write-AssertLine ('MSI ProductCode {0} Uninstall key present=[{1}]' -f $msiCode, $msiPresent)
    if ($Phase -eq 'PostInstall') {
        if ($msiPresent) { Write-AssertLine 'ASSERT MsiProductInstalled-PostInstall = PASS' }
        else             { Write-AssertLine 'ASSERT MsiProductInstalled-PostInstall = FAIL (MSI ProductCode not registered after install)' }
    } else {
        if (-not $msiPresent) { Write-AssertLine 'ASSERT MsiProductRemoved-PostUninstall = PASS' }
        else                  { Write-AssertLine 'ASSERT MsiProductRemoved-PostUninstall = FAIL (MSI ProductCode still registered after uninstall)' }
    }
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

        # MSI projects: hand the guest the MSI's ProductCode as DATA (Sandbox\InstallAssertionData.json) so
        # it can also assert Windows Installer's own Uninstall key. Validated as a strict GUID; any other
        # project (or an unreadable MSI) gets no data file and no MSI assertion. Best-effort: never fails
        # the tattoo assertions.
        $dataPath = Join-Path $sandboxPath 'InstallAssertionData.json'
        if (Test-Path -LiteralPath $dataPath) { Remove-Item -LiteralPath $dataPath -Force -ErrorAction SilentlyContinue }
        try {
            $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
            $inst = if ($cfg.PSObject.Properties.Name -contains 'Installer') { $cfg.Installer } else { $null }
            if ($inst -and "$($inst.Type)" -eq 'msi') {
                $msi = $null
                if ($inst.PSObject.Properties.Name -contains 'FileName' -and $inst.FileName) {
                    $named = Join-Path (Join-Path $ProjectPath 'Files') ([string]$inst.FileName)
                    if ($named -like '*.msi' -and (Test-Path -LiteralPath $named -PathType Leaf)) { $msi = $named }
                }
                if (-not $msi) {
                    $first = Get-ChildItem -LiteralPath (Join-Path $ProjectPath 'Files') -Filter '*.msi' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($first) { $msi = $first.FullName }
                }
                $productCode = if ($msi) { Get-Win32ToolkitMsiProperty -Path $msi -Property 'ProductCode' } else { '' }
                if (Test-Win32ToolkitProductCode $productCode) {
                    $dataJson = ConvertTo-Json -InputObject ([ordered]@{ MsiProductCode = $productCode })
                    [System.IO.File]::WriteAllText($dataPath, $dataJson, (New-Object System.Text.UTF8Encoding($false)))
                }
                else {
                    Write-Verbose 'MSI project without a readable ProductCode - the MSI install assertion is skipped.'
                }
            }
        }
        catch {
            Write-Verbose "MSI install-assertion data skipped: $($_.Exception.Message)"
        }
        return $scriptPath
    }
    catch {
        Write-Error "New-InstallAssertionScript failed: $($_.Exception.Message)"
        return $false
    }
}
