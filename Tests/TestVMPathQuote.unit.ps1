<#
    Regression test for issue #66: pasting an ISO path wrapped in double quotes (Explorer's
    "Copy as path" produces "C:\iso\Win11.iso" INCLUDING the quotes) made Hyper-V provisioning fail —
    the quoted string flowed into Test-Path / New-Win32ToolkitGoldenVhdx, which threw a confusing
    'ISO not found: "C:\iso\Win11.iso"' (a literal " is illegal in a Windows path, so nothing matched).

    New-Win32ToolkitTestVM now strips surrounding whitespace + double quotes from -IsoPath and
    -VhdxPath BEFORE its guards (the same .Trim().Trim('"') the manual-app prompts already use), and
    the TUI's ISO prompt does the same. Every Hyper-V cmdlet + helper is shadowed; no VM, no host
    mutation.

    Run:  pwsh -File Tests\TestVMPathQuote.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Public\New-Win32ToolkitTestVM.ps1')

# --- shadows: everything New-Win32ToolkitTestVM touches, logging the paths it hands downstream -----
$script:calls    = @()
$script:isoSeen  = $null
$script:vhdSeen  = $null
$script:byoVhdx  = 'C:\vm\base.vhdx'   # the only path the shadowed Test-Path says exists

function Log($s) { $script:calls += $s }

function Test-Win32ToolkitElevated { $true }
function Get-Module { param($Name, [switch]$ListAvailable) [pscustomobject]@{ Name = 'Hyper-V' } }
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Set-Win32ToolkitConfigValue { param($Name, $Value) }
function Set-Win32ToolkitGuestCredential { param($Credential) }
function Clear-Win32ToolkitHyperVStateCache { }
function Get-Win32ToolkitBasePath { param([Parameter(ValueFromRemainingArguments)]$a) 'C:\Win32Apps' }
function Get-Win32ToolkitHyperVPaths { param($BasePath) [pscustomobject]@{ Golden = 'C:\hv\golden'; VMs = 'C:\hv\vms' } }
function Test-Path { param($LiteralPath, $Path, $PathType) if ($LiteralPath -eq $script:byoVhdx) { $true } elseif ($LiteralPath -like 'C:\hv\*') { $true } else { $false } }
function New-Item { param([Parameter(ValueFromRemainingArguments)]$a) }

function Get-VM { param($Name, $ErrorAction) $null }
function New-Win32ToolkitGoldenVhdx { param($IsoPath, $VhdxPath, $AdminCredential, $Force, $ImageIndex, $Edition) $script:isoSeen = $IsoPath; Log 'BuildVhdx' }
function New-VM { param($Name, $Generation, $MemoryStartupBytes, $VHDPath, $Path, $SwitchName, $ErrorAction) $script:vhdSeen = $VHDPath; Log 'New-VM' }
function Set-VMFirmware { param([Parameter(ValueFromRemainingArguments)]$a) }
function Set-VMProcessor { param([Parameter(ValueFromRemainingArguments)]$a) }
function Set-VMMemory { param([Parameter(ValueFromRemainingArguments)]$a) }
function Set-VMKeyProtector { param([Parameter(ValueFromRemainingArguments)]$a) }
function Enable-VMTPM { param([Parameter(ValueFromRemainingArguments)]$a) }
function Disconnect-VMNetworkAdapter { param([Parameter(ValueFromRemainingArguments)]$a) }
function Connect-VMNetworkAdapter { param([Parameter(ValueFromRemainingArguments)]$a) }
function Start-VM { param($Name, $ErrorAction) }
function Wait-Win32ToolkitVMReady { param($VMName, $Credential) $true }
function Invoke-Command { param($VMName, $Credential, $ScriptBlock, $ErrorAction) $true }   # explorer up -> settle loop exits fast
function Start-Sleep { param($Seconds) }
function Set-Win32ToolkitGuestAutoLogon { param($VMName, $Credential) }
function Set-VM { param($Name, $CheckpointType) }
function Checkpoint-VM { param($VMName, $SnapshotName) Log 'Checkpoint-VM' }

$cred = [pscredential]::new('w32admin', (ConvertTo-SecureString 'p' -AsPlainText -Force))
function Run { param([hashtable]$P) $script:calls = @(); $script:isoSeen = $null; $script:vhdSeen = $null; $script:err = $null
    try { New-Win32ToolkitTestVM @P *>$null } catch { $script:err = $_.Exception.Message } }

# ══ [1] THE FIELD BUG: quoted -IsoPath reaches the VHDX builder UNQUOTED ═══════════════════════════
Write-Host '[1] "Copy as path" quoted -IsoPath is unwrapped before use' -ForegroundColor Cyan
Run @{ IsoPath = '"C:\iso\Win11_x64.iso"'; Credential = $cred; Unattended = $true }
if (-not $script:err) { Ok 'provisioning proceeds (no confusing not-found throw)' } else { Bad "threw: $script:err" }
if ($script:isoSeen -eq 'C:\iso\Win11_x64.iso') { Ok "New-Win32ToolkitGoldenVhdx received the CLEAN path ('$script:isoSeen')" } else { Bad "builder saw: '$script:isoSeen'" }
if ($script:calls -contains 'Checkpoint-VM') { Ok 'run completed through the checkpoint' } else { Bad "stopped early: $($script:calls -join ',')" }

# ══ [2] quoted + padded -VhdxPath (BYO) passes the existence AND .vhdx-extension guards ════════════
Write-Host '[2] quoted/padded -VhdxPath: exists-check and extension check see the real path' -ForegroundColor Cyan
Run @{ VhdxPath = ' "C:\vm\base.vhdx" '; Credential = $cred; Unattended = $true }
if (-not $script:err) { Ok 'BYO flow proceeds (extension/not-found guards satisfied)' } else { Bad "threw: $script:err" }
if ($script:vhdSeen -eq 'C:\vm\base.vhdx') { Ok "New-VM received the CLEAN -VHDPath ('$script:vhdSeen')" } else { Bad "New-VM saw: '$script:vhdSeen'" }

# ══ [3] a paste of just quotes counts as "not supplied" (trim runs BEFORE the guards) ══════════════
Write-Host '[3] quoted-blank paste hits the "Supply -IsoPath" guard, not a broken build' -ForegroundColor Cyan
Run @{ IsoPath = '""'; Credential = $cred; Unattended = $true }
if ($script:err -like '*Supply -IsoPath*') { Ok 'clear guidance instead of a quoted-empty build attempt' } else { Bad "err='$script:err'" }

# ══ [4] no regression: unquoted paths flow through unchanged ═══════════════════════════════════════
Write-Host '[4] plain unquoted -IsoPath unchanged' -ForegroundColor Cyan
Run @{ IsoPath = 'C:\iso\Win11_x64.iso'; Credential = $cred; Unattended = $true }
if (-not $script:err -and $script:isoSeen -eq 'C:\iso\Win11_x64.iso') { Ok 'clean input passes through verbatim' } else { Bad "err='$script:err' iso='$script:isoSeen'" }

# ══ [5] the TUI ISO prompt strips quotes too (source-pinned) ═══════════════════════════════════════
Write-Host '[5] Show-Win32ToolkitTestVM trims the pasted ISO path' -ForegroundColor Cyan
$tui = Get-Content -Raw (Join-Path $repo 'Private\Show-Win32ToolkitTestVM.ps1')
if ($tui -match '\$iso\s*=\s*\$iso\.Trim\(\)\.Trim\(''"''\)') { Ok 'TUI provision branch normalizes the pasted path' } else { Bad 'TUI trim missing from the provision branch' }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestVMPathQuote tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestVMPathQuote test(s) FAILED." -ForegroundColor Red; exit 1 }
