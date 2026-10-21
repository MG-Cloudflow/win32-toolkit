<#
    Unit tests for Invoke-Win32ToolkitFinalize backend routing (Phase 4, Step 4.2).
    Everything the finalize tail calls is shadowed in-scope; no sandbox, no VM, no packaging.

    Run:  pwsh -File Tests\DocumentationDispatch.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Invoke-Win32ToolkitFinalize.ps1')

# --- shadows --------------------------------------------------------------------------------------
$script:backend = 'Sandbox'
$script:log     = @()
$script:genBackend = $null
$script:hvPhase = $null
$script:hvOutput = $null
$script:hvReturn = $true

function Get-Win32ToolkitTestBackend { return $script:backend }
function New-TargetedDocumentation {
    param($ProjectPath, $ProjectName, $AppInfo, $Backend, [switch]$SkipLaunch, $BasePath)
    $script:genBackend = $Backend; $script:genBase = $BasePath; $script:log += "gen:$Backend"
    return 'C:\proj\Documentation\InstallationChanges_x.json'
}
function Invoke-Win32ToolkitHyperVRun {
    param($ProjectPath, $Phase, $Output)
    $script:log += 'hv:run'; $script:hvPhase = $Phase; $script:hvOutput = $Output
    return $script:hvReturn
}
function Wait-ForDocumentationAndProcess { param($ProjectPath, $InstallerType, $ExpectedJsonPath) $script:log += 'wait'; return $true }
# C-9: the capture keeps its logs in Sandbox\Logs\Runs\<ts>_Capture (test campaign 2026-10-21, H5-F5/H7-F1). Shadows
# that touch no disk ('C:\proj' is fake) and stay out of $script:log, so the exact-order assertions hold.
$script:cap = @{ Scenario = $null; Waits = 0; Saves = 0 }
function Initialize-Win32ToolkitTestRunLog { param($ProjectPath, $Scenario, $Family) $script:cap.Scenario = $Scenario; [pscustomobject]@{ ProjectPath = $ProjectPath; RunName = 'x_Capture'; RelativePath = 'Sandbox\Logs\Runs\x_Capture'; Marker = $null; Snapshot = @{} } }
function Save-Win32ToolkitTestRunLog { param($Run) $script:cap.Saves++; [string]$Run.RelativePath }
function Wait-Win32ToolkitCollectedLog { param($ProjectPath, $TimeoutSeconds) $script:cap.Waits++; $true }
function Import-Win32ToolkitCapturedIcon { param($ProjectPath) }
function Get-InstallerFileInfo { param($FilesPath) [pscustomobject]@{ Type = 'exe' } }
function Export-Win32ToolkitIntuneWin { param($ProjectPath, [switch]$PublishIntune, [switch]$PublishUpdate, [switch]$AllowLegacyScript) $script:exportAllowLegacy = [bool]$AllowLegacyScript }
# Finalize pre-flight (WP-C contract, spec 2.11): passes unless the case says otherwise.
$script:assertFails = $false
function Assert-Win32ToolkitPackageReady {
    param($ProjectPath, $Stage, [switch]$AllowLegacyScript)
    $script:log += "assert:$Stage"
    $script:assertAllowLegacy = [bool]$AllowLegacyScript
    if ($script:assertFails) {
        throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('not ready'), 'W32T.PackageNotReady',
            [System.Management.Automation.ErrorCategory]::InvalidData, $ProjectPath)
    }
    [pscustomobject]@{ Ready = $true; Shape = 'Psadt41'; VersionText = '4.1.8'; Warnings = @() }
}

# --- Sandbox --------------------------------------------------------------------------------------
Write-Host '[1] Backend=Sandbox: no Hyper-V run; generator gets -Backend Sandbox; waiter runs' -ForegroundColor Cyan
$script:backend = 'Sandbox'; $script:log = @()
Invoke-Win32ToolkitFinalize -ProjectPath 'C:\proj' -ProjectName 'P' 3>$null
if ($script:genBackend -eq 'Sandbox') { Ok 'New-TargetedDocumentation -Backend Sandbox' } else { Bad "genBackend=$script:genBackend" }
if ('hv:run' -notin $script:log) { Ok 'Invoke-Win32ToolkitHyperVRun NOT called for Sandbox' } else { Bad 'HyperV run called on Sandbox' }
if (($script:log -join '>') -eq 'assert:Finalize>gen:Sandbox>wait') { Ok 'order: pre-flight -> generate -> wait' } else { Bad "log=$($script:log -join '>')" }
if ($script:cap.Scenario -eq 'Capture' -and $script:cap.Waits -eq 1 -and $script:cap.Saves -eq 1) { Ok 'Sandbox: the capture run keeps its logs (Capture run folder; waits for the guest collector first)' } else { Bad "capture logs: $($script:cap | ConvertTo-Json -Compress)" }

# --- HyperV ---------------------------------------------------------------------------------------
Write-Host '[2] Backend=HyperV: runs the capture in the VM, then the same waiter' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:log = @(); $script:hvReturn = $true
$script:cap = @{ Scenario = $null; Waits = 0; Saves = 0 }
Invoke-Win32ToolkitFinalize -ProjectPath 'C:\proj' -ProjectName 'P' 3>$null
if ($script:cap.Scenario -eq 'Capture' -and $script:cap.Waits -eq 0 -and $script:cap.Saves -eq 1) { Ok 'HyperV: the capture logs are kept without a collector wait (they came back with the copy-out)' } else { Bad "capture logs: $($script:cap | ConvertTo-Json -Compress)" }
if ($script:genBackend -eq 'HyperV') { Ok 'New-TargetedDocumentation -Backend HyperV' } else { Bad "genBackend=$script:genBackend" }
if (($script:log -join '>') -eq 'assert:Finalize>gen:HyperV>hv:run>wait') { Ok 'order: pre-flight -> generate -> hyperv run -> wait' } else { Bad "log=$($script:log -join '>')" }
if ($script:hvPhase -and $script:hvPhase[0].Command -like '*TargetedDocumentationScript.ps1*') { Ok 'phase runs the generated doc script' } else { Bad "phase=$($script:hvPhase | Out-String)" }
if ($script:hvOutput -contains 'Documentation\InstallationChanges_*.json' -and $script:hvOutput -contains 'Sandbox\Logs\*') { Ok 'copies capture + logs back' } else { Bad "output=$($script:hvOutput -join ',')" }

# --- HyperV run fails -----------------------------------------------------------------------------
Write-Host '[3] Backend=HyperV but the VM run fails: skip processing (no 30-min wait hang)' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:log = @(); $script:hvReturn = $false
Invoke-Win32ToolkitFinalize -ProjectPath 'C:\proj' -ProjectName 'P' 3>$null
if ('wait' -notin $script:log) { Ok 'waiter skipped when the Hyper-V capture fails' } else { Bad 'waiter ran despite failed capture' }

# --- pre-flight fails -----------------------------------------------------------------------------
Write-Host '[4] the Finalize pre-flight (Assert-Win32ToolkitPackageReady) fails: nothing is documented' -ForegroundColor Cyan
$script:backend = 'Sandbox'; $script:log = @(); $script:assertFails = $true
$threw = $null
try { Invoke-Win32ToolkitFinalize -ProjectPath 'C:\proj' -ProjectName 'P' 3>$null } catch { $threw = $_.FullyQualifiedErrorId }
$script:assertFails = $false
if ($threw -eq 'W32T.PackageNotReady' -and ($script:log -join '>') -eq 'assert:Finalize') { Ok 'W32T.PackageNotReady propagates before any documentation run' } else { Bad "threw='$threw' log=$($script:log -join '>')" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All DocumentationDispatch tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail DocumentationDispatch test(s) FAILED." -ForegroundColor Red; exit 1 }
