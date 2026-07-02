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
    .PARAMETER SkipRequirement
        Do not run SupportFiles\UpdateRequirement.ps1 in either phase — the requirement assertions are
        emitted as explicit SKIPs (even if a stale UpdateRequirement.ps1 exists from a previous
        packaging). The tattoo/detection assertion still runs. Used by
        Test-Win32ToolkitProject -SkipRequirementCheck.
    .OUTPUTS
        [string] the path of the generated script.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [switch]$SkipRequirement
    )

    $sandboxPath = Join-Path $ProjectPath 'Sandbox'
    if (-not (Test-Path -LiteralPath $sandboxPath)) {
        New-Item -ItemType Directory -Path $sandboxPath -Force | Out-Null
    }

    # Tattoo expectation — same source and fallback as the deploy script / detection rule.
    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $app = if ($cfg.PSObject.Properties.Name -contains 'App') { $cfg.App } else { $null }
    $tattooName = if ($app -and ($app.PSObject.Properties.Name -contains 'DisplayName') -and $app.DisplayName) { $app.DisplayName }
                  elseif ($app -and $app.Name) { $app.Name }
                  else { $null }
    $hasTattoo = [bool]($app -and $app.ScriptAuthor -and $app.Vendor -and $tattooName -and $app.Version)

    # ---- Fixed body (single-quoted here-strings: device-side $ stays literal) ----
    $header = @'
param([Parameter(Mandatory = $true)][ValidateSet('PreUpdate', 'PostUpdate')][string]$Phase)
# win32-toolkit update-test assertions (Windows PowerShell 5.1-safe; runs inside Windows Sandbox).
$logDir = 'C:\PSADT\Sandbox\Logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$assertLog = Join-Path $logDir 'UpdateAssertions.log'
function Write-AssertLine([string]$Message) {
    ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) | Add-Content -Path $assertLog -Encoding UTF8
}

Write-AssertLine "=== Phase: $Phase ==="
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
    $body = $header + $requirementBlock

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
