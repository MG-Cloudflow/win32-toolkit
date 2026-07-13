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
    param($ProjectPath, $ProjectName, $AppInfo, $Backend, [switch]$SkipLaunch)
    $script:genBackend = $Backend; $script:log += "gen:$Backend"
    return 'C:\proj\Documentation\InstallationChanges_x.json'
}
function Invoke-Win32ToolkitHyperVRun {
    param($ProjectPath, $Phase, $Output)
    $script:log += 'hv:run'; $script:hvPhase = $Phase; $script:hvOutput = $Output
    return $script:hvReturn
}
function Wait-ForDocumentationAndProcess { param($ProjectPath, $InstallerType, $ExpectedJsonPath) $script:log += 'wait'; return $true }
function Get-InstallerFileInfo { param($FilesPath) [pscustomobject]@{ Type = 'exe' } }
function Export-Win32ToolkitIntuneWin { param($ProjectPath, [switch]$PublishIntune, [switch]$PublishUpdate) }

# --- Sandbox --------------------------------------------------------------------------------------
Write-Host '[1] Backend=Sandbox: no Hyper-V run; generator gets -Backend Sandbox; waiter runs' -ForegroundColor Cyan
$script:backend = 'Sandbox'; $script:log = @()
Invoke-Win32ToolkitFinalize -ProjectPath 'C:\proj' -ProjectName 'P' 3>$null
if ($script:genBackend -eq 'Sandbox') { Ok 'New-TargetedDocumentation -Backend Sandbox' } else { Bad "genBackend=$script:genBackend" }
if ('hv:run' -notin $script:log) { Ok 'Invoke-Win32ToolkitHyperVRun NOT called for Sandbox' } else { Bad 'HyperV run called on Sandbox' }
if (($script:log -join '>') -eq 'gen:Sandbox>wait') { Ok 'order: generate -> wait' } else { Bad "log=$($script:log -join '>')" }

# --- HyperV ---------------------------------------------------------------------------------------
Write-Host '[2] Backend=HyperV: runs the capture in the VM, then the same waiter' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:log = @(); $script:hvReturn = $true
Invoke-Win32ToolkitFinalize -ProjectPath 'C:\proj' -ProjectName 'P' 3>$null
if ($script:genBackend -eq 'HyperV') { Ok 'New-TargetedDocumentation -Backend HyperV' } else { Bad "genBackend=$script:genBackend" }
if (($script:log -join '>') -eq 'gen:HyperV>hv:run>wait') { Ok 'order: generate -> hyperv run -> wait' } else { Bad "log=$($script:log -join '>')" }
if ($script:hvPhase -and $script:hvPhase[0].Command -like '*TargetedDocumentationScript.ps1*') { Ok 'phase runs the generated doc script' } else { Bad "phase=$($script:hvPhase | Out-String)" }
if ($script:hvOutput -contains 'Documentation\InstallationChanges_*.json' -and $script:hvOutput -contains 'Sandbox\Logs\*') { Ok 'copies capture + logs back' } else { Bad "output=$($script:hvOutput -join ',')" }

# --- HyperV run fails -----------------------------------------------------------------------------
Write-Host '[3] Backend=HyperV but the VM run fails: skip processing (no 30-min wait hang)' -ForegroundColor Cyan
$script:backend = 'HyperV'; $script:log = @(); $script:hvReturn = $false
Invoke-Win32ToolkitFinalize -ProjectPath 'C:\proj' -ProjectName 'P' 3>$null
if ('wait' -notin $script:log) { Ok 'waiter skipped when the Hyper-V capture fails' } else { Bad 'waiter ran despite failed capture' }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All DocumentationDispatch tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail DocumentationDispatch test(s) FAILED." -ForegroundColor Red; exit 1 }
