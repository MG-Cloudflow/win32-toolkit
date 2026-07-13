<#
    Unit tests for the Hyper-V provider (Phase 3). No Hyper-V / no VM — the Hyper-V + PowerShell Direct
    cmdlets and the provider primitives are shadowed in-scope. Verifies exit-code passthrough, copy-out
    path mapping, the session revert/connect sequence, orchestration order, always-revert teardown, and
    the credential requirement.

    Run:  pwsh -File Tests\HyperVProvider.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Invoke-Win32ToolkitGuestPhase.ps1')
. (Join-Path $repo 'Private\Copy-Win32ToolkitResultsFromGuest.ps1')
. (Join-Path $repo 'Private\New-Win32ToolkitHyperVSession.ps1')
. (Join-Path $repo 'Private\Copy-Win32ToolkitProjectToGuest.ps1')
. (Join-Path $repo 'Private\Remove-Win32ToolkitHyperVSession.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitHyperVRun.ps1')

Write-Host '[1] Invoke-Win32ToolkitGuestPhase returns ONLY the exit code (not the output stream)' -ForegroundColor Cyan
# Simulate a guest that emits output lines followed by the exit code (the shape that broke the [int] cast).
function Invoke-Command { param($Session, [scriptblock]$ScriptBlock, $ArgumentList) return @('install output line', 'more output', 5) }
$rc = Invoke-Win32ToolkitGuestPhase -Session 'S' -Command 'x' -Label 'test'
if ($rc -eq 5) { Ok 'extracts the exit code even when output is present' } else { Bad "rc=$rc" }
Remove-Item Function:\Invoke-Command

Write-Host '[2] Copy-Win32ToolkitResultsFromGuest maps guest files to project-relative paths' -ForegroundColor Cyan
function Invoke-Command { param($Session, [scriptblock]$ScriptBlock, $ArgumentList) return @('C:\PSADT\Documentation\InstallationChanges_1.json', 'C:\PSADT\Sandbox\Logs\a.log') }
$script:copied = @()
function Copy-Item { param($FromSession, $LiteralPath, $Destination, [switch]$Force, $ErrorAction) $script:copied += $Destination }
$dest = Join-Path ([IO.Path]::GetTempPath()) ('hvp_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath @('C:\PSADT\Documentation\*', 'C:\PSADT\Sandbox\Logs\*') -Destination $dest
if (($script:copied -contains (Join-Path $dest 'Documentation\InstallationChanges_1.json')) -and ($script:copied -contains (Join-Path $dest 'Sandbox\Logs\a.log'))) { Ok 'C:\PSADT-relative structure preserved under the project' } else { Bad "copied: $($script:copied -join '|')" }
Remove-Item Function:\Invoke-Command, Function:\Copy-Item
Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '[3] New-Win32ToolkitHyperVSession: revert -> (running) -> wait -> session' -ForegroundColor Cyan
$script:seq = @()
function Restore-VMCheckpoint { param($VMName, $Name, [switch]$Confirm, $ErrorAction) $script:seq += 'restore' }
function Get-VM   { param($Name, $ErrorAction) $script:seq += 'get-vm'; [pscustomobject]@{ State = 'Running' } }
function Start-VM { param($Name, $ErrorAction) $script:seq += 'start' }
function Wait-Win32ToolkitVMReady { param($VMName, $Credential, [switch]$SkipPrep) $script:seq += 'wait'; $true }
function New-PSSession { param($VMName, $Credential, $ErrorAction) $script:seq += 'session'; 'SESS' }
$cred = [pscredential]::new('w32admin', (ConvertTo-SecureString 'p' -AsPlainText -Force))
$s = New-Win32ToolkitHyperVSession -VMName vm -Credential $cred
if ($s -eq 'SESS' -and (($script:seq -join '>') -eq 'restore>get-vm>wait>session')) { Ok 'warm revert then connect (Start-VM skipped when already Running)' } else { Bad "seq=$($script:seq -join '>') s=$s" }
Remove-Item Function:\Restore-VMCheckpoint, Function:\Get-VM, Function:\Start-VM, Function:\Wait-Win32ToolkitVMReady, Function:\New-PSSession

Write-Host '[4] Invoke-Win32ToolkitHyperVRun orchestration order + always-revert' -ForegroundColor Cyan
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Get-Win32ToolkitGuestCredential { [pscredential]::new('w32admin', (ConvertTo-SecureString 'p' -AsPlainText -Force)) }
$script:log = @()
function New-Win32ToolkitHyperVSession    { param($VMName, $Credential, $CheckpointName, [switch]$SkipRevert) $script:log += 'session'; 'SESS' }
function Copy-Win32ToolkitProjectToGuest  { param($Session, $ProjectPath, $GuestPath) $script:log += "copyin:$GuestPath" }
function Invoke-Win32ToolkitGuestPhase    { param($Session, $Command, $Label) $script:log += "phase:$Label"; 0 }
function Copy-Win32ToolkitResultsFromGuest{ param($Session, $GuestPath, $Destination, $GuestRoot) $script:log += 'copyout' }
function Remove-Win32ToolkitHyperVSession { param($Session, $VMName, $CheckpointName, [switch]$Revert) $script:log += "teardown:revert=$($Revert.IsPresent)" }

$phases = @(
    @{ Label = 'Install';   Command = '& C:\PSADT\Invoke-AppDeployToolkit.ps1' },
    @{ Label = 'Uninstall'; Command = '& C:\PSADT\Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall' }
)
$ok = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase $phases -Output @('Sandbox\Logs\*') 6>$null
if ($ok) { Ok 'returns $true on completion' } else { Bad 'did not return true' }
if (($script:log -join ' > ') -eq 'session > copyin:C:\PSADT > phase:Install > phase:Uninstall > copyout > teardown:revert=True') { Ok 'order: session -> copy-in -> phases -> copy-out -> teardown(revert)' } else { Bad "order: $($script:log -join ' > ')" }

$script:log = @()
Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -BaselineProjectPath 'C:\old' -Phase @(@{ Label = 'X'; Command = 'x' }) 6>$null | Out-Null
if (($script:log -join ' ') -match 'copyin:C:\\PSADT .*copyin:C:\\PSADTOld') { Ok 'baseline project copied to C:\PSADTOld' } else { Bad "baseline: $($script:log -join ' ')" }

$script:log = @()
function Copy-Win32ToolkitProjectToGuest { param($Session, $ProjectPath, $GuestPath) throw 'copy failed' }
$ok2 = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(@{ Label = 'X'; Command = 'x' }) 6>$null 3>$null
if ((-not $ok2) -and (($script:log -join ' ') -match 'teardown:revert=True')) { Ok 'reverts even when a step throws (finally)' } else { Bad "fail path: ok=$ok2 log=$($script:log -join ' ')" }
Remove-Item Function:\New-Win32ToolkitHyperVSession, Function:\Copy-Win32ToolkitProjectToGuest, Function:\Invoke-Win32ToolkitGuestPhase, Function:\Copy-Win32ToolkitResultsFromGuest, Function:\Remove-Win32ToolkitHyperVSession

Write-Host '[5] Missing guest credential throws a clear error' -ForegroundColor Cyan
function Get-Win32ToolkitGuestCredential { $null }
try { Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(@{ Label = 'X'; Command = 'x' }) 6>$null | Out-Null; Bad 'no throw on missing credential' }
catch { if ("$_" -match 'guest credential') { Ok 'missing credential -> clear throw' } else { Bad "$_" } }
Remove-Item Function:\Get-Win32ToolkitConfigValue, Function:\Get-Win32ToolkitGuestCredential

if ($fail -eq 0) {
    Write-Host "`nAll HyperVProvider tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$fail HyperVProvider test(s) failed." -ForegroundColor Red
    exit 1
}
