<#
    Unit tests for the backend-aware documentation/capture generator (Phase 4, Step 4.1).
    New-LogCollectorScript / Start-Process / Get-WindowsOptionalFeature are shadowed; nothing launches a
    sandbox or a VM. Verifies the emitted guest script is UTF-8 WITH BOM, parses, bakes the backend, guards
    the Sandbox-only blocks, and that the HyperV path writes no .wsb and never launches.

    Run:  pwsh -File Tests\TargetedDocumentation.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-XmlEncoded.ps1')
. (Join-Path $repo 'Private\New-Win32ToolkitSandboxConfig.ps1')   # Sandbox .wsb built via the shared seam helper
. (Join-Path $repo 'Private\Get-Win32ToolkitConfigValue.ps1')     # the generator reads SandboxTestMode (auto-close)
. (Join-Path $repo 'Private\New-TargetedDocumentation.ps1')

# Shadows so nothing external runs.
function New-LogCollectorScript { param($ProjectPath) return 'fake-collector' }
# Declared dependencies are staged into Sandbox\Dependencies\ before the run; these fixtures declare none.
function Initialize-Win32ToolkitDependencyStaging { param($ProjectPath) return 0 }
function Get-WindowsOptionalFeature { param($Online, $FeatureName, $ErrorAction) return $null }
$script:started = 0
function Start-Process { param($FilePath, $ArgumentList, $ErrorAction, [switch]$PassThru, [switch]$Wait) $script:started++ }

function New-Proj {
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('w32doc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $p 'Files') -Force | Out-Null
    $p
}
$sandGuard = 'if ($backend -eq ''Sandbox'')'
$hvGuard   = 'if ($backend -eq ''HyperV'')'
function GuardCount([string]$text, [string]$needle) { ([regex]::Matches($text, [regex]::Escape($needle))).Count }

# --- Sandbox generation -----------------------------------------------------------------------------
Write-Host '[1] Backend=Sandbox: builds the .wsb; script is BOM+parses+baked+guarded' -ForegroundColor Cyan
$projS = New-Proj
$script:started = 0
$jsonS = New-TargetedDocumentation -ProjectPath $projS -ProjectName 'Test_x64_1.0' -Backend Sandbox -SkipLaunch
$docS  = Join-Path $projS 'SupportFiles\TargetedDocumentationScript.ps1'
$wsbS  = Join-Path $projS 'Test_x64_1.0_TargetedDocumentation.wsb'

$bytes = [System.IO.File]::ReadAllBytes($docS)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$text  = [System.IO.File]::ReadAllText($docS)
$perr = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$perr)

if ($hasBom) { Ok 'script written UTF-8 with BOM' } else { Bad 'no UTF-8 BOM on generated script' }
if (-not $perr) { Ok 'generated script parses (5.1-safe syntax)' } else { Bad "parse errors: $($perr[0].Message)" }
if ($text.Contains("`$backend = 'Sandbox'")) { Ok 'backend literal baked = Sandbox' } else { Bad 'backend not baked to Sandbox' }
if ((GuardCount $text $sandGuard) -eq 3) { Ok 'three Sandbox-only guards (init wait + its capture-log line + auto-close/Stop-Computer)' } else { Bad "sandbox guards = $(GuardCount $text $sandGuard)" }
if ((GuardCount $text $hvGuard) -eq 1) { Ok 'one HyperV guard (ProgressPreference)' } else { Bad "hyperv guards = $(GuardCount $text $hvGuard)" }
# Test campaign F1: a bare Stop-Computer left the Windows Sandbox 0.8 client window open after the capture.
$stops = @([System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null).FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Stop-Computer' }, $true))
if ($stops.Count -eq 1 -and @($stops[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Force' }).Count -eq 1) { Ok 'one Stop-Computer (guarded), with -Force like the test guests' } else { Bad "Stop-Computer calls: $(@($stops | ForEach-Object { $_.Extent.Text }) -join ' | ')" }

# THE most important ordering rule in the capture: declared dependencies must be installed BEFORE the
# pre-install baseline. If they went in afterwards, the dependency's own files/registry/services would show
# up in the diff as changes made by the app under test — poisoning the detection rule and uninstall logic.
$depIdx  = $text.IndexOf('InstallDependencies.ps1')
$baseIdx = $text.IndexOf('Capturing PRE-INSTALLATION baseline')
if ($depIdx -ge 0 -and $baseIdx -gt $depIdx) {
    Ok 'dependencies install BEFORE the pre-install baseline snapshot'
} else { Bad "dep block at $depIdx, baseline at $baseIdx — the dependency must come FIRST" }
if (Test-Path -LiteralPath $wsbS) { Ok 'Sandbox: .wsb built' } else { Bad 'Sandbox: .wsb missing' }
if ($jsonS -like '*Documentation\InstallationChanges_*.json') { Ok 'returns expected capture path' } else { Bad "returned: $jsonS" }

# --- HyperV generation ------------------------------------------------------------------------------
Write-Host '[2] Backend=HyperV: NO .wsb, never launches, script baked HyperV' -ForegroundColor Cyan
$projH = New-Proj
$script:started = 0
$jsonH = New-TargetedDocumentation -ProjectPath $projH -ProjectName 'Test_x64_1.0' -Backend HyperV
$docH  = Join-Path $projH 'SupportFiles\TargetedDocumentationScript.ps1'
$wsbH  = Join-Path $projH 'Test_x64_1.0_TargetedDocumentation.wsb'
$textH = [System.IO.File]::ReadAllText($docH)
$perrH = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($textH, [ref]$null, [ref]$perrH)

if ($textH.Contains("`$backend = 'HyperV'")) { Ok 'backend literal baked = HyperV' } else { Bad 'backend not baked to HyperV' }
if (-not $perrH) { Ok 'HyperV script parses' } else { Bad "parse errors: $($perrH[0].Message)" }
if (-not (Test-Path -LiteralPath $wsbH)) { Ok 'HyperV: no .wsb built' } else { Bad 'HyperV: .wsb should NOT exist' }
if ($script:started -eq 0) { Ok 'HyperV: WindowsSandbox.exe never launched' } else { Bad "Start-Process called $script:started time(s)" }
if ($jsonH -like '*Documentation\InstallationChanges_*.json') { Ok 'HyperV returns expected capture path' } else { Bad "returned: $jsonH" }

# --- single-instance guard before the capture launch (test campaign 2026-10-21, S8-F4) ----------------
Write-Host '[2b] Sandbox launch waits for a free Sandbox; still busy after 90 s -> $false, no launch' -ForegroundColor Cyan
$projW = New-Proj
$script:waitArgs = $null; $script:launches = 0
function Wait-Win32ToolkitSandboxFree { param([int]$TimeoutSeconds) $script:waitArgs = $TimeoutSeconds; $script:sandboxFree }
function Invoke-Win32ToolkitTestRun { param($Backend, $SandboxConfigPath) $script:launches++; [pscustomobject]@{ Launched = $true } }
$script:sandboxFree = $false
$wW = $null

$retW = New-TargetedDocumentation -ProjectPath $projW -ProjectName 'Busy_x64_1.0' -Backend Sandbox -WarningVariable wW -WarningAction SilentlyContinue 6>$null
if ($retW -eq $false -and $script:launches -eq 0 -and $script:waitArgs -eq 90 -and @($wW | Where-Object { "$_" -match 'Another Windows Sandbox is still running after waiting 90 s' -and "$_" -match 'NOT launched' }).Count -eq 1) { Ok 'busy Sandbox: waited 90 s, never launched, warned, returned $false (no 30-min wait)' } else { Bad "busy: ret=$retW launches=$($script:launches) wait=$($script:waitArgs) warn=$($wW -join ' | ')" }
$script:sandboxFree = $true
$retF = New-TargetedDocumentation -ProjectPath $projW -ProjectName 'Busy_x64_1.0' -Backend Sandbox -WarningAction SilentlyContinue 6>$null
if ($retF -like '*Documentation\InstallationChanges_*.json' -and $script:launches -eq 1) { Ok 'free Sandbox: launched once, returns the expected capture path' } else { Bad "free: ret=$retF launches=$($script:launches)" }
Remove-Item Function:\Wait-Win32ToolkitSandboxFree, Function:\Invoke-Win32ToolkitTestRun
Remove-Item -LiteralPath $projW -Recurse -Force -ErrorAction SilentlyContinue

# --- capture noise (test campaign 2026-10-21, S7-F7) --------------------------------------------------
Write-Host '[3] the file snapshots leave out the PSADT run''s own .NET/PowerShell noise (both snapshots alike)' -ForegroundColor Cyan
if ($text.Contains("Join-Path `$env:ProgramData 'Microsoft\NetFramework\BreadcrumbStore'") -and $text.Contains("Join-Path `$env:LOCALAPPDATA 'Microsoft\Windows\PowerShell'")) { Ok 'the guest script lists the BreadcrumbStore and PowerShell-cache noise (static literals)' } else { Bad 'noise list missing' }
# Behaviour: run the generated noise list + snapshot function against a fake ProgramData/LOCALAPPDATA tree.
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
$snapFn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-TargetedDirectorySnapshot' }, $true))[0]
$noiseStmts = @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text -match '^\s*(\$snapshotNoise\s*=|if \(\$env:(ProgramData|LOCALAPPDATA)\)\s*\{\s*\$snapshotNoise)' })
$fake = Join-Path ([System.IO.Path]::GetTempPath()) ('w32noise_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$pd = Join-Path $fake 'ProgramData'; $la = Join-Path $fake 'LocalAppData'
foreach ($d in "$pd\Microsoft\NetFramework\BreadcrumbStore", "$pd\Vendor\App", "$la\Microsoft\Windows\PowerShell", "$la\Vendor") { New-Item -ItemType Directory -Path $d -Force | Out-Null }
foreach ($f in "$pd\Microsoft\NetFramework\BreadcrumbStore\a.crumb", "$pd\Vendor\App\app.exe", "$la\Microsoft\Windows\PowerShell\StartupProfileData-NonInteractive", "$la\Vendor\settings.json") { Set-Content -LiteralPath $f -Value 'x' }
$savedPd = $env:ProgramData; $savedLa = $env:LOCALAPPDATA
try {
    $env:ProgramData = $pd; $env:LOCALAPPDATA = $la
    function Write-Log { param($Message, $Level) }
    . ([scriptblock]::Create((@($noiseStmts | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n" + $snapFn.Extent.Text))
    $snap = @(Get-TargetedDirectorySnapshot -Description 'probe' -Paths @($pd, $la) -Depth 5 6>$null | ForEach-Object { $_.FullName })
    $hasNoise = @($snap | Where-Object { $_ -like '*BreadcrumbStore*' -or $_ -like '*\Microsoft\Windows\PowerShell*' }).Count
    if ($noiseStmts.Count -ge 3 -and $hasNoise -eq 0 -and ($snap -contains "$pd\Vendor\App\app.exe") -and ($snap -contains "$la\Vendor\settings.json")) { Ok 'BreadcrumbStore and PowerShell-cache entries are left out; C:\ProgramData\Vendor and LOCALAPPDATA\Vendor files are kept' }
    else { Bad "snapshot (noise stmts $($noiseStmts.Count)): $($snap -join ' | ')" }
}
finally {
    $env:ProgramData = $savedPd; $env:LOCALAPPDATA = $savedLa
    Remove-Item -LiteralPath $fake -Recurse -Force -ErrorAction SilentlyContinue
}
if ($textH.Contains("Join-Path `$env:ProgramData 'Microsoft\NetFramework\BreadcrumbStore'")) { Ok 'the same filter in the Hyper-V capture script' } else { Bad 'Hyper-V script lacks the noise filter' }

# best-effort cleanup
Remove-Item -LiteralPath $projS, $projH -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TargetedDocumentation tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TargetedDocumentation test(s) FAILED." -ForegroundColor Red; exit 1 }
