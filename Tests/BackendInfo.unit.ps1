<#
    Unit tests for Get-Win32ToolkitBackendInfo — the single source the TUI renders the backend from.
    Config + resolver + readiness are shadowed; no registry, no Hyper-V.

    Run:  pwsh -File Tests\BackendInfo.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitBackendInfo.ps1')

$script:cfg      = @{ TestBackend = 'Sandbox'; HyperVVMName = 'win32tk-golden' }
$script:resolved = 'Sandbox'
$script:reasons  = @()
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
function Get-Win32ToolkitTestBackend { param($Backend, $WarningAction) return $script:resolved }
function Test-Win32ToolkitHyperVReady { return $script:reasons }

Write-Host '[1] Sandbox configured -> Sandbox, friendly label, no fallback' -ForegroundColor Cyan
$script:cfg['TestBackend'] = 'Sandbox'; $script:resolved = 'Sandbox'; $script:reasons = @()
$i = Get-Win32ToolkitBackendInfo
if ($i.Resolved -eq 'Sandbox' -and $i.Label -eq 'Windows Sandbox' -and -not $i.FellBack) { Ok 'Sandbox label, FellBack=false' } else { Bad "$($i.Label) fellBack=$($i.FellBack)" }

Write-Host '[2] HyperV configured + ready -> HyperV, label names the VM' -ForegroundColor Cyan
$script:cfg['TestBackend'] = 'HyperV'; $script:resolved = 'HyperV'; $script:reasons = @()
$i = Get-Win32ToolkitBackendInfo
if ($i.Resolved -eq 'HyperV' -and $i.Label -eq 'Hyper-V VM (win32tk-golden)' -and -not $i.FellBack) { Ok 'HyperV label includes the VM name' } else { Bad "$($i.Label) fellBack=$($i.FellBack)" }

Write-Host '[3] HyperV configured but NOT ready -> falls back, surfaces why' -ForegroundColor Cyan
$script:cfg['TestBackend'] = 'HyperV'; $script:resolved = 'Sandbox'; $script:reasons = @('VM not found', 'not elevated')
$i = Get-Win32ToolkitBackendInfo
if ($i.FellBack -and $i.Resolved -eq 'Sandbox' -and $i.Label -eq 'Windows Sandbox' -and $i.Reasons.Count -eq 2) {
    Ok 'FellBack=true, label reflects what ACTUALLY runs, reasons surfaced'
} else { Bad "fellBack=$($i.FellBack) label=$($i.Label) reasons=$($i.Reasons -join ';')" }

Write-Host '[4] custom VM name flows into the label' -ForegroundColor Cyan
$script:cfg['TestBackend'] = 'HyperV'; $script:cfg['HyperVVMName'] = 'lab-vm'; $script:resolved = 'HyperV'; $script:reasons = @()
$i = Get-Win32ToolkitBackendInfo
if ($i.Label -eq 'Hyper-V VM (lab-vm)') { Ok 'label uses the configured VM name' } else { Bad "label=$($i.Label)" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All BackendInfo tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail BackendInfo test(s) FAILED." -ForegroundColor Red; exit 1 }
