<#
    P1 — two defects in the generator code.

      ITEM A  Every file this module generates for CONSUMPTION BY WINDOWS POWERSHELL 5.1 (Intune's
              powershell.exe on the device, or the 5.1 host inside Windows Sandbox) was written with
              `Set-Content -Encoding UTF8`. On the PS7 host that writes NO BOM, and 5.1 decodes a
              BOM-less file as ANSI — so any non-ASCII character (an app called "Café", a publisher
              "Nagüi", branding text) mojibakes ON THE DEVICE, silently.
              Six write sites now emit UTF-8 WITH BOM via [System.IO.File]::WriteAllText:
                Set-PSADTDataDrivenScript (Invoke-AppDeployToolkit.ps1)
                Apply-OrgTemplate         (config.psd1, strings.psd1, Invoke-AppDeployToolkit.ps1)
                New-CountdownScript       (Sandbox\Countdown.ps1)
                New-LogCollectorScript    (Sandbox\CollectLogs.ps1)
                New-IntuneRequirementScript (SupportFiles\RequirementScript.ps1)
              …and the generated AppConfig.json loader now reads with -Encoding UTF8 (the JSON is
              written BOM-less on purpose, so 5.1 needs to be told).

      ITEM B  The generated RequirementScript.ps1 matched Add/Remove-Programs by the FIRST TOKEN of
              the DisplayName (`$appName.Split(' ')[0]` -> `-like "*Microsoft*"`). "Microsoft Teams"
              therefore reported ITSELF as installed on any device that merely had Microsoft Edge.
              It now matches the FULL DisplayName exactly (and the MSI product code), like
              Get-Win32ToolkitRequirementRule already did.

    Nothing here touches the network, the registry, or a real PSADT install: the PSADT project is a
    hand-rolled fixture, and the generated requirement script is executed against an in-memory
    Add/Remove-Programs fixture with Get-ItemProperty shadowed.

    Run:  pwsh -File Tests\P1_GeneratedFileEncoding.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-PSSingleQuoted.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitProductCode.ps1')
. (Join-Path $repo 'Private\Set-PSADTDataDrivenScript.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitTextBlock.ps1')   # Set-TextBlock, promoted out of Apply-OrgTemplate
. (Join-Path $repo 'Private\New-Win32ToolkitSparseConfig.ps1') # sparse config.psd1 generator (F1) — Apply-OrgTemplate dep
. (Join-Path $repo 'Private\Apply-OrgTemplate.ps1')
. (Join-Path $repo 'Private\New-CountdownScript.ps1')
. (Join-Path $repo 'Private\New-LogCollectorScript.ps1')
. (Join-Path $repo 'Private\New-IntuneRequirementScript.ps1')

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────
# Read the RAW BYTES — never trust the -Encoding parameter that was passed to the writer.
function Test-Bom([string]$Path) {
    $b = [System.IO.File]::ReadAllBytes($Path)
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

# Decode the raw bytes as UTF-8 (dropping a leading BOM char) and look for $Needle. Combined with
# Test-Bom this is the byte-level proof that a non-ASCII value survives to a 5.1 reader intact.
function Test-Utf8Contains([string]$Path, [string]$Needle) {
    $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path)).TrimStart([char]0xFEFF)
    return $text.Contains($Needle)
}

# The generated files run on Windows PowerShell 5.1: they must parse, and must not use PS7-only
# syntax (ternary / ?? / ?. ), which 5.1's parser rejects outright.
function Get-Ps51Problem([string]$Path) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count) { return "parse error: $($errs[0].Message)" }
    $tern = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true)
    if ($tern.Count -gt 0) { return 'PS7-only ternary operator' }
    $ps7Kinds = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket')
    foreach ($t in @($tokens)) {
        if ($ps7Kinds -contains $t.Kind.ToString()) { return "PS7-only operator token: $($t.Kind)" }
    }
    return $null
}

# Non-ASCII fixtures: precisely the characters that turn into mojibake when UTF-8 bytes are decoded
# as ANSI on the device.
$NONASCII_COMPANY = 'Café Nagüi Ünïcøde ehf.'
$NONASCII_AUTHOR  = 'Nagüi — Café IT'
$NONASCII_APP     = 'Café Nagüi Player'

# ── PSADT-shaped fixture project (no PSAppDeployToolkit dependency) ──────────────────────────────
function New-FixtureProject([string]$Author = 'PSAppDeployToolkit') {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32enc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $p 'Config')  -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $p 'Strings') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $p 'Files')   -Force | Out-Null

    $cfg = @'
@{
    Toolkit = @{
        CompanyName = 'PSAppDeployToolkit'
        # Log path used for Toolkit logging.
        LogPath = 'C:\Windows\Logs\Software'
    }
    UI = @{
        DialogStyle = 'Classic'
        FluentAccentColor = $null
    }
}
'@
    $str = @'
@{
    BalloonTip = @{
        # Text displayed in the balloon tip for successful completion of a deployment type.
        Complete = @{
            Install = 'Installation complete.'
            Repair = 'Repair complete.'
            Uninstall = 'Uninstallation complete.'
        }
    }

    ProgressPrompt = @{
        # Default message displayed in the progress bar.
        Message = @{
            Install = 'Installation in progress.'
            Repair = 'Repair in progress.'
            Uninstall = 'Uninstallation in progress.'
        }
    }

    RestartPrompt = @{
        Message = 'Please restart.'
    }
}
'@
    $deploy = @"
[CmdletBinding()]
param()

`$adtSession = @{
    AppVendor = ''
    AppName = ''
    AppVersion = ''
    AppArch = ''
    AppScriptDate = '2026-01-01'
    AppScriptAuthor = '$($Author -replace "'", "''")'
    AppProcessesToClose = @()
}

function Install-ADTDeployment
{
    ## Show Welcome Message, close processes if specified.
    `$saiwParams = @{
        AllowDefer = `$true
    }
    if (`$adtSession.AppProcessesToClose.Count -gt 0)
    {
        `$saiwParams.Add('CloseProcesses', `$adtSession.AppProcessesToClose)
    }
    Show-ADTInstallationWelcome @saiwParams

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    ## <Perform Installation tasks here>

    ## <Perform Post-Installation tasks here>

    ## Display a message at the end of the install.
    if (!`$adtSession.UseDefaultMsi)
    {
        Show-ADTInstallationPrompt -Message 'Complete.' -ButtonRightText 'OK' -NoWait
    }
}

function Uninstall-ADTDeployment
{
    ## If there are processes to close, show Welcome Message before uninstalling.
    if (`$adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses `$adtSession.AppProcessesToClose
    }

    ## Show Progress Message (with the default message).
    Show-ADTInstallationProgress

    ## <Perform Uninstallation tasks here>

    ## <Perform Post-Uninstallation tasks here>
}
"@
    $bom = New-Object System.Text.UTF8Encoding($true)
    foreach ($f in @(
        @{ P = (Join-Path $p 'Config\config.psd1');           T = $cfg },
        @{ P = (Join-Path $p 'Strings\strings.psd1');         T = $str },
        @{ P = (Join-Path $p 'Invoke-AppDeployToolkit.ps1');  T = $deploy })) {
        [System.IO.File]::WriteAllText($f.P, (($f.T -replace "`r?`n", "`r`n") + "`r`n"), $bom)
    }
    return $p
}

# Writes SupportFiles\RequirementScript.ps1 for $DisplayName / $Version, returns its path.
function New-FixtureRequirement([string]$DisplayName, [string]$Version) {
    $p = New-FixtureProject
    $capture = Join-Path $p 'InstallationChanges_test.json'
    $prog = @{ DisplayName = $DisplayName; DisplayVersion = $Version; Publisher = 'Contoso' }
    (@{ NewPrograms = @($prog) } | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath $capture -Encoding UTF8
    $r = New-IntuneRequirementScript -ProjectPath $p -JsonFilePath $capture 6>$null
    if (-not $r) { throw "New-IntuneRequirementScript failed for '$DisplayName'" }
    return (Join-Path $p 'SupportFiles\RequirementScript.ps1')
}

# Runs the GENERATED requirement script for real, in a child pwsh, with Get-ItemProperty shadowed so
# it sees $Arp as the machine's Add/Remove-Programs. Returns the process exit code
# (0 = "app is installed / requirement met", 1 = "not met").
function Invoke-GeneratedRequirement([string]$ScriptPath, [object[]]$Arp) {
    $arpLiteral = ($Arp | ForEach-Object {
        "    [pscustomobject]@{ DisplayName = '$($_.DisplayName -replace "'", "''")'; DisplayVersion = '$($_.DisplayVersion)' }"
    }) -join "`r`n"

    # NOTE: invoke with & (call operator), NOT dot-sourcing — `exit N` inside a DOT-SOURCED script does
    # not set the process exit code (the parent just runs on and exits 0), which would make every
    # assertion below vacuously "met". With & the script runs in a child scope (so the shadowed
    # functions below are still visible) and its `exit` lands in $LASTEXITCODE, which we re-raise.
    $wrapper = @"
`$global:Arp = @(
$arpLiteral
)
# Shadow the registry read: the generated script must decide purely from these ARP entries.
function Get-ItemProperty { [CmdletBinding()] param([string]`$Path, [string]`$LiteralPath) `$global:Arp }
function Test-Path        { [CmdletBinding()] param([string]`$Path, [string]`$LiteralPath) `$false }
& '$($ScriptPath -replace "'", "''")'
exit `$LASTEXITCODE
"@
    $wp = Join-Path ([System.IO.Path]::GetTempPath()) ('w32req_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    [System.IO.File]::WriteAllText($wp, $wrapper, (New-Object System.Text.UTF8Encoding($true)))
    & (Get-Process -Id $PID).Path -NoProfile -File $wp *>$null
    return $LASTEXITCODE
}

# ══ ITEM A ═══════════════════════════════════════════════════════════════════════════════════════
Write-Host '[A] Every file destined for Windows PowerShell 5.1 is written UTF-8 WITH BOM' -ForegroundColor Cyan

$generated = @{}   # label -> path, collected for the parse/5.1-safety sweep below

# 1. Set-PSADTDataDrivenScript -> Invoke-AppDeployToolkit.ps1 (non-ASCII author must survive)
$pA = New-FixtureProject -Author $NONASCII_AUTHOR
$depA = Join-Path $pA 'Invoke-AppDeployToolkit.ps1'
$null = Set-PSADTDataDrivenScript -ScriptPath $depA -WarningAction SilentlyContinue
$generated['Set-PSADTDataDrivenScript: Invoke-AppDeployToolkit.ps1'] = $depA
if (Test-Bom $depA) { Ok 'Set-PSADTDataDrivenScript writes Invoke-AppDeployToolkit.ps1 with a BOM' }
else { Bad 'Set-PSADTDataDrivenScript wrote a BOM-LESS Invoke-AppDeployToolkit.ps1' }
if (Test-Utf8Contains $depA $NONASCII_AUTHOR) { Ok "non-ASCII AppScriptAuthor round-trips byte-correctly ('$NONASCII_AUTHOR')" }
else { Bad 'non-ASCII AppScriptAuthor did not survive the data-driven patch' }

# …and the loader it emits must tell 5.1 how to decode the (deliberately BOM-less) AppConfig.json.
$depAText = Get-Content -LiteralPath $depA -Raw
if ($depAText -match 'AppConfig\.json"\s+-Raw\s+-Encoding\s+UTF8') { Ok 'generated AppConfig.json loader reads with -Encoding UTF8 (5.1 would use ANSI otherwise)' }
else { Bad 'generated AppConfig.json loader still uses Get-Content with no -Encoding' }

# 2-4. Apply-OrgTemplate -> config.psd1, strings.psd1, Invoke-AppDeployToolkit.ps1
$pB = New-FixtureProject
$tmpl = [pscustomobject]@{
    TemplateName           = 'EncTest'
    CompanyName            = $NONASCII_COMPANY
    AppScriptAuthor        = $NONASCII_AUTHOR
    DialogStyle            = 'Fluent'
    FluentAccentColor      = ''
    LogPath                = 'C:\Windows\Logs\Software'
    BalloonComplete        = [pscustomobject]@{ Install = "Installé"; Repair = 'Repair complete.'; Uninstall = 'Uninstallation complete.' }
    ProgressMessage        = [pscustomobject]@{ Install = "Installation en cours…"; Repair = 'Repairing…'; Uninstall = 'Removing…' }
    ProgressMessageDetail  = [pscustomobject]@{ Install = "Veuillez patienter"; Repair = 'Please wait'; Uninstall = 'Please wait' }
    WelcomeDialog          = [pscustomobject]@{ Enabled = $false }
    UninstallWelcomeDialog = [pscustomobject]@{ Enabled = $false }
    ProgressDialog         = [pscustomobject]@{ Enabled = $true; StatusMessage = ''; StatusMessageDetail = '' }
    CompletionPrompt       = [pscustomobject]@{ Enabled = $false }
}
$null = Apply-OrgTemplate -ProjectPath $pB -Template $tmpl -WarningAction SilentlyContinue 6>$null
$cfgB = Join-Path $pB 'Config\config.psd1'
$strB = Join-Path $pB 'Strings\strings.psd1'
$depB = Join-Path $pB 'Invoke-AppDeployToolkit.ps1'
$generated['Apply-OrgTemplate: Invoke-AppDeployToolkit.ps1'] = $depB

if (Test-Bom $cfgB) { Ok 'Apply-OrgTemplate writes config.psd1 with a BOM' }   else { Bad 'config.psd1 written BOM-LESS' }
if (Test-Bom $strB) { Ok 'Apply-OrgTemplate writes strings.psd1 with a BOM' }  else { Bad 'strings.psd1 written BOM-LESS' }
if (Test-Bom $depB) { Ok 'Apply-OrgTemplate writes Invoke-AppDeployToolkit.ps1 with a BOM' } else { Bad 'org-templated deploy script written BOM-LESS' }

if (Test-Utf8Contains $cfgB $NONASCII_COMPANY) { Ok "non-ASCII CompanyName round-trips byte-correctly ('$NONASCII_COMPANY')" }
else { Bad 'non-ASCII CompanyName mangled in config.psd1' }
if (Test-Utf8Contains $strB 'Installation en cours…') { Ok 'non-ASCII dialog strings round-trip byte-correctly' }
else { Bad 'non-ASCII strings mangled in strings.psd1' }
if (Test-Utf8Contains $depB $NONASCII_AUTHOR) { Ok 'non-ASCII AppScriptAuthor round-trips byte-correctly (org template)' }
else { Bad 'non-ASCII AppScriptAuthor mangled in the deploy script' }

# The BOM must not break the .psd1 consumers (PSADT / Import-PowerShellDataFile tolerate it).
try {
    $cfgData = Import-PowerShellDataFile -LiteralPath $cfgB
    $strData = Import-PowerShellDataFile -LiteralPath $strB
    if ($cfgData.Toolkit.CompanyName -eq $NONASCII_COMPANY -and $strData.ProgressPrompt.Message.Install -eq 'Installation en cours…') {
        Ok 'BOM-prefixed .psd1 files still Import-PowerShellDataFile with values intact'
    } else { Bad "psd1 values did not round-trip: [$($cfgData.Toolkit.CompanyName)]" }
} catch { Bad "BOM broke Import-PowerShellDataFile: $($_.Exception.Message)" }

# 5. New-CountdownScript -> Sandbox\Countdown.ps1
$pC = New-FixtureProject
$cd = New-CountdownScript -ProjectPath $pC
$generated['New-CountdownScript: Countdown.ps1'] = $cd
if (Test-Bom $cd) { Ok 'New-CountdownScript writes Countdown.ps1 with a BOM' } else { Bad 'Countdown.ps1 written BOM-LESS' }

# 6. New-LogCollectorScript -> Sandbox\CollectLogs.ps1
$lc = New-LogCollectorScript -ProjectPath $pC
$generated['New-LogCollectorScript: CollectLogs.ps1'] = $lc
if (Test-Bom $lc) { Ok 'New-LogCollectorScript writes CollectLogs.ps1 with a BOM' } else { Bad 'CollectLogs.ps1 written BOM-LESS' }

# 7. New-IntuneRequirementScript -> SupportFiles\RequirementScript.ps1 (non-ASCII DisplayName)
$reqNonAscii = New-FixtureRequirement -DisplayName $NONASCII_APP -Version '2.1.0'
$generated['New-IntuneRequirementScript: RequirementScript.ps1'] = $reqNonAscii
if (Test-Bom $reqNonAscii) { Ok 'New-IntuneRequirementScript writes RequirementScript.ps1 with a BOM' }
else { Bad 'RequirementScript.ps1 written BOM-LESS (Intune runs it on 5.1 -> ANSI -> the name never matches)' }
if (Test-Utf8Contains $reqNonAscii $NONASCII_APP) { Ok "non-ASCII DisplayName round-trips byte-correctly ('$NONASCII_APP')" }
else { Bad 'non-ASCII DisplayName mangled in RequirementScript.ps1' }

Write-Host ''
Write-Host '[A] …and every generated script still parses and stays 5.1-safe (no ternary / ?? / ?.)' -ForegroundColor Cyan
foreach ($k in $generated.Keys | Sort-Object) {
    $problem = Get-Ps51Problem $generated[$k]
    if (-not $problem) { Ok "$k -> parses, 5.1-safe" } else { Bad "$k -> $problem" }
}

# ══ ITEM B ═══════════════════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '[B] RequirementScript.ps1 matches the FULL DisplayName, not its first token' -ForegroundColor Cyan

$reqTeams = New-FixtureRequirement -DisplayName 'Microsoft Teams' -Version '1.6.0.0'
$reqText  = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($reqTeams))

# Content: the first-token wildcard is gone, the full name is compared with -eq.
if ($reqText -notmatch 'DisplayName\s+-like') { Ok 'no `DisplayName -like "*token*"` match remains' }
else { Bad 'the generated script still does a substring DisplayName match' }
if ($reqText -notmatch "\*Microsoft\*") { Ok 'the first token ("Microsoft") is not used as a wildcard pattern' }
else { Bad 'the generated script still wildcard-matches on "*Microsoft*"' }
if ($reqText -match [regex]::Escape("`$_.DisplayName -eq 'Microsoft Teams'")) { Ok 'the FULL DisplayName is compared with -eq' }
else { Bad 'the full DisplayName equality match is missing' }

# Behaviour: run the generated script for real against a fixture Add/Remove-Programs.
# THE BUG: a device with only "Microsoft Edge" reported "Microsoft Teams" as installed (exit 0).
$decoy = @([pscustomobject]@{ DisplayName = 'Microsoft Edge'; DisplayVersion = '120.0.0.0' })
$rc = Invoke-GeneratedRequirement -ScriptPath $reqTeams -Arp $decoy
if ($rc -eq 1) { Ok 'ARP = {Microsoft Edge} -> NOT met (exit 1). The false positive is gone.' }
else { Bad "ARP = {Microsoft Edge} -> exit $rc (expected 1): 'Microsoft Teams' still matches any 'Microsoft *' product" }

$decoyPlusMore = @(
    [pscustomobject]@{ DisplayName = 'Microsoft Edge';                DisplayVersion = '120.0.0.0' }
    [pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2015-2022 Redistributable (x64)'; DisplayVersion = '14.38.33135' }
    [pscustomobject]@{ DisplayName = 'Microsoft Teams Classic';       DisplayVersion = '1.5.0.0' }
)
$rc = Invoke-GeneratedRequirement -ScriptPath $reqTeams -Arp $decoyPlusMore
if ($rc -eq 1) { Ok 'ARP = {Edge, VC++ Redist, Teams *Classic*} -> still NOT met (near-miss names do not match)' }
else { Bad "near-miss ARP -> exit $rc (expected 1)" }

# …and the real thing IS still detected (the fix must not under-match).
$real = @(
    [pscustomobject]@{ DisplayName = 'Microsoft Edge';   DisplayVersion = '120.0.0.0' }
    [pscustomobject]@{ DisplayName = 'Microsoft Teams';  DisplayVersion = '1.6.0.0' }
)
$rc = Invoke-GeneratedRequirement -ScriptPath $reqTeams -Arp $real
if ($rc -eq 0) { Ok 'ARP contains the real "Microsoft Teams" -> requirement MET (exit 0)' }
else { Bad "the genuine app is no longer detected -> exit $rc (expected 0)" }

# An older installed version must still fail the version gate (unchanged behaviour).
$older = @([pscustomobject]@{ DisplayName = 'Microsoft Teams'; DisplayVersion = '1.0.0.0' })
$rc = Invoke-GeneratedRequirement -ScriptPath $reqTeams -Arp $older
if ($rc -eq 1) { Ok 'an OLDER installed version still fails the version comparison (exit 1)' }
else { Bad "older version -> exit $rc (expected 1)" }

Write-Host ''
Write-Host '[B] …and the untrusted DisplayName is still escaped as DATA (ConvertTo-PSSingleQuoted)' -ForegroundColor Cyan
$reqEvil = New-FixtureRequirement -DisplayName "Evil'App `$(calc)" -Version '1.2.3'
$evilText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($reqEvil))
if ($evilText -match [regex]::Escape("-eq 'Evil''App `$(calc)'")) { Ok "the apostrophe is doubled and `$(...) stays inside the literal" }
else { Bad 'the DisplayName is no longer escaped into a single-quoted literal' }
$problem = Get-Ps51Problem $reqEvil
if (-not $problem) { Ok 'the hostile-name requirement script still parses (no injection, no breakage)' } else { Bad "hostile name broke the script: $problem" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
Write-Host "$fail FAILURE(S)" -ForegroundColor Red
exit 1
