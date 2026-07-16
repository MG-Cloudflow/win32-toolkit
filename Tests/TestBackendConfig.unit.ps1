<#
    Unit tests for the test-backend config plumbing (Phase 1). No registry writes, no Hyper-V needed —
    the registry/Hyper-V layers are shadowed with in-scope stubs.

    Run:  pwsh -File Tests\TestBackendConfig.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitConfigValue.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitConfigValue.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitElevated.ps1')
. (Join-Path $repo 'Private\Set-Win32ToolkitGuestCredential.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitGuestCredential.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitHyperVReady.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitTestBackend.ps1')

Write-Host '[1] Get-Win32ToolkitTestBackend resolution' -ForegroundColor Cyan
# Shadow the config read + readiness so resolution is deterministic.
$script:cfgBackend = 'Sandbox'
function Get-Win32ToolkitConfigValue { param([string]$Name, [string]$Default) if ($Name -eq 'TestBackend') { return $script:cfgBackend } return $Default }
$script:hvReasons = @()
function Test-Win32ToolkitHyperVReady { return $script:hvReasons }

$script:cfgBackend = 'Sandbox'; $script:hvReasons = @()
if ((Get-Win32ToolkitTestBackend) -eq 'Sandbox') { Ok 'config Sandbox -> Sandbox' } else { Bad 'default not Sandbox' }

$script:cfgBackend = 'HyperV'; $script:hvReasons = @()
if ((Get-Win32ToolkitTestBackend) -eq 'HyperV') { Ok 'config HyperV + ready -> HyperV' } else { Bad 'ready HyperV not resolved' }

$script:cfgBackend = 'HyperV'; $script:hvReasons = @('VM not found')
if ((Get-Win32ToolkitTestBackend -WarningAction SilentlyContinue) -eq 'Sandbox') { Ok 'config HyperV + NOT ready -> Sandbox fallback' } else { Bad 'no fallback on unready HyperV' }

$script:cfgBackend = 'HyperV'; $script:hvReasons = @()
if ((Get-Win32ToolkitTestBackend -Backend Sandbox) -eq 'Sandbox') { Ok '-Backend Sandbox overrides config' } else { Bad 'override ignored' }

$script:cfgBackend = 'Sandbox'; $script:hvReasons = @()
if ((Get-Win32ToolkitTestBackend -Backend HyperV) -eq 'HyperV') { Ok '-Backend HyperV + ready -> HyperV' } else { Bad 'override HyperV not honored' }

Write-Host '[2] Guest credential DPAPI round-trip' -ForegroundColor Cyan
# Shadow the registry layer with an in-memory store.
$script:store = @{}
function Get-Win32ToolkitConfigValue { param([string]$Name, [string]$Default) if ($script:store.ContainsKey($Name)) { return $script:store[$Name] } return $Default }
function Set-Win32ToolkitConfigValue { param([string]$Name, [string]$Value) $script:store[$Name] = $Value }

if ($null -eq (Get-Win32ToolkitGuestCredential)) { Ok 'nothing stored -> $null' } else { Bad 'phantom credential' }

$pw   = 'P@ss w0rd''s!'
$cred = [pscredential]::new('.\w32admin', (ConvertTo-SecureString $pw -AsPlainText -Force))
Set-Win32ToolkitGuestCredential -Credential $cred
$got  = Get-Win32ToolkitGuestCredential
if ($got -and $got.UserName -eq '.\w32admin') { Ok 'username round-trips' } else { Bad "username: $($got.UserName)" }
$plain = [System.Net.NetworkCredential]::new('', $got.Password).Password
if ($plain -eq $pw) { Ok 'DPAPI password round-trips' } else { Bad "password mismatch: [$plain]" }
if ($script:store['HyperVGuestSecret'] -and $script:store['HyperVGuestSecret'] -notmatch 'P@ss') { Ok 'secret stored DPAPI-encrypted (not cleartext)' } else { Bad 'secret stored in cleartext' }

Write-Host '[3] Test-Win32ToolkitHyperVReady reasons' -ForegroundColor Cyan
. (Join-Path $repo 'Private\Test-Win32ToolkitHyperVReady.ps1')   # restore real impl (section [1] shadowed it)
function Test-Win32ToolkitElevated { $true }
function Get-Module { param([switch]$ListAvailable, [string]$Name) [pscustomobject]@{ Name = 'Hyper-V' } }
function Get-VM { param([string]$Name, $ErrorAction) [pscustomobject]@{ Name = $Name } }
function Get-VMCheckpoint { param([string]$VMName, [string]$Name, $ErrorAction) [pscustomobject]@{ Name = $Name } }
function Get-Win32ToolkitGuestCredential { [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
function Get-Win32ToolkitConfigValue { param([string]$Name, [string]$Default) $Default }

if (@(Test-Win32ToolkitHyperVReady -Force).Count -eq 0) { Ok 'all prereqs present -> ready (no reasons)' } else { Bad "unexpected reasons: $(@(Test-Win32ToolkitHyperVReady -Force) -join '; ')" }

function Test-Win32ToolkitElevated { $false }
if (@(Test-Win32ToolkitHyperVReady -Force) -match 'elevated') { Ok 'not elevated -> reason' } else { Bad 'elevation not flagged' }
function Test-Win32ToolkitElevated { $true }

function Get-Module { param([switch]$ListAvailable, [string]$Name) $null }
if (@(Test-Win32ToolkitHyperVReady -Force) -match 'module') { Ok 'Hyper-V module missing -> reason' } else { Bad 'module not flagged' }
function Get-Module { param([switch]$ListAvailable, [string]$Name) [pscustomobject]@{ Name = 'Hyper-V' } }

function Get-VM { param([string]$Name, $ErrorAction) $null }
if (@(Test-Win32ToolkitHyperVReady -Force) -match 'not found') { Ok 'missing VM -> reason' } else { Bad 'missing VM not flagged' }
function Get-VM { param([string]$Name, $ErrorAction) [pscustomobject]@{ Name = $Name } }

function Get-VMCheckpoint { param([string]$VMName, [string]$Name, $ErrorAction) $null }
if (@(Test-Win32ToolkitHyperVReady -Force) -match 'checkpoint') { Ok 'missing checkpoint -> reason' } else { Bad 'missing checkpoint not flagged' }
function Get-VMCheckpoint { param([string]$VMName, [string]$Name, $ErrorAction) [pscustomobject]@{ Name = $Name } }

function Get-Win32ToolkitGuestCredential { $null }
if (@(Test-Win32ToolkitHyperVReady -Force) -match 'credential') { Ok 'no guest credential -> reason' } else { Bad 'missing credential not flagged' }

if ($fail -eq 0) {
    Write-Host "`nAll TestBackendConfig tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$fail TestBackendConfig test(s) failed." -ForegroundColor Red
    exit 1
}
