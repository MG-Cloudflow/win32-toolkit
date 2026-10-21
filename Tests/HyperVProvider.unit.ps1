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

. (Join-Path $repo 'Private\Invoke-Win32ToolkitGuestScheduledTask.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitGuestPhase.ps1')
. (Join-Path $repo 'Private\Copy-Win32ToolkitResultsFromGuest.ps1')
. (Join-Path $repo 'Private\New-Win32ToolkitHyperVSession.ps1')
. (Join-Path $repo 'Private\Copy-Win32ToolkitProjectToGuest.ps1')
. (Join-Path $repo 'Private\Remove-Win32ToolkitHyperVSession.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitHyperVRun.ps1')

Write-Host '[1] Invoke-Win32ToolkitGuestPhase runs as SYSTEM and returns ONLY the exit code' -ForegroundColor Cyan
# Simulate a guest that emits output lines followed by the exit code (the shape that broke the [int] cast).
# The scheduled-task runner passes -ArgumentList $Command,$RunAs,$Timeout, so ArgumentList[1] is the context.
$script:runAs = $null
function Invoke-Command { param($Session, [scriptblock]$ScriptBlock, $ArgumentList) $script:runAs = $ArgumentList[1]; return @('install output line', 'more output', 5) }
$rc = Invoke-Win32ToolkitGuestPhase -Session 'S' -Command 'x' -Label 'test'
if ($rc -eq 5) { Ok 'extracts the exit code even when output is present' } else { Bad "rc=$rc" }
if ($script:runAs -eq 'System') { Ok 'silent phase runs as SYSTEM (Intune-faithful context)' } else { Bad "runAs=$($script:runAs)" }
Remove-Item Function:\Invoke-Command

Write-Host '[2] Copy-Win32ToolkitResultsFromGuest maps guest files to project-relative paths (zip transfer)' -ForegroundColor Cyan
# The copy-out is now ONE zip (see CopyOutBatch.unit.ps1 for the full matrix). Here: the guest scriptblock
# runs LOCALLY against a fixture tree standing in for C:\PSADT, and the relative mapping is verified.
function Invoke-Command { [CmdletBinding()] param($Session, [scriptblock]$ScriptBlock, $ArgumentList, [Parameter(ValueFromRemainingArguments)]$Rest) & $ScriptBlock @ArgumentList }
function Copy-Item { [CmdletBinding()] param($FromSession, $Path, $Destination, [switch]$Force, [Parameter(ValueFromRemainingArguments)]$Rest) Microsoft.PowerShell.Management\Copy-Item -Path $Path -Destination $Destination -Force }
$guestRoot = Join-Path ([IO.Path]::GetTempPath()) ('hvpg_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$dest      = Join-Path ([IO.Path]::GetTempPath()) ('hvp_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path (Join-Path $guestRoot 'Documentation'), (Join-Path $guestRoot 'Sandbox\Logs'), $dest -Force | Out-Null
Set-Content -LiteralPath (Join-Path $guestRoot 'Documentation\InstallationChanges_1.json') '{}'
Set-Content -LiteralPath (Join-Path $guestRoot 'Sandbox\Logs\a.log') 'log'
Copy-Win32ToolkitResultsFromGuest -Session 'S' -GuestPath @((Join-Path $guestRoot 'Documentation\*'), (Join-Path $guestRoot 'Sandbox\Logs\*')) -Destination $dest -GuestRoot $guestRoot 3>$null
if ((Test-Path (Join-Path $dest 'Documentation\InstallationChanges_1.json')) -and (Test-Path (Join-Path $dest 'Sandbox\Logs\a.log'))) { Ok 'relative structure preserved under the project (single-zip transfer)' } else { Bad "copied: $(@(Get-ChildItem $dest -Recurse -File | ForEach-Object FullName) -join '|')" }
Remove-Item Function:\Invoke-Command, Function:\Copy-Item
Remove-Item -LiteralPath $dest, $guestRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '[3] New-Win32ToolkitHyperVSession: revert -> (running) -> connect (the proving session IS the run session)' -ForegroundColor Cyan
$script:seq = @()
$script:HyperVCleanMarker = $null   # no prior teardown in this process -> the open-revert must run
function Restore-VMCheckpoint { param($VMName, $Name, [switch]$Confirm, $ErrorAction) $script:seq += 'restore' }
function Get-VM   { param($Name, $ErrorAction) $script:seq += 'get-vm'; [pscustomobject]@{ State = 'Running' } }
function Start-VM { param($Name, $ErrorAction) $script:seq += 'start' }
function Wait-Win32ToolkitVMReady { param($VMName, $Credential, [switch]$SkipPrep, [switch]$ReturnSession)
    if ($ReturnSession) { $script:seq += 'session'; 'SESS' } else { $script:seq += 'wait'; $true }
}
$cred = [pscredential]::new('w32admin', (New-Object System.Security.SecureString))
$s = New-Win32ToolkitHyperVSession -VMName vm -Credential $cred
if ($s -eq 'SESS' -and (($script:seq -join '>') -eq 'restore>get-vm>session')) { Ok 'warm revert then ONE connection (no throwaway probe; Start-VM skipped when Running)' } else { Bad "seq=$($script:seq -join '>') s=$s" }
Remove-Item Function:\Restore-VMCheckpoint, Function:\Get-VM, Function:\Start-VM, Function:\Wait-Win32ToolkitVMReady

Write-Host '[4] Invoke-Win32ToolkitHyperVRun orchestration order + always-revert' -ForegroundColor Cyan
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Get-Win32ToolkitGuestCredential { [pscredential]::new('w32admin', (New-Object System.Security.SecureString)) }
$script:log = @()
function New-Win32ToolkitHyperVSession    { param($VMName, $Credential, $CheckpointName, [switch]$SkipRevert, [switch]$EnsureDesktop) $script:log += 'session'; 'SESS' }
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

Write-Host '[6] Invoke-Win32ToolkitHyperVRun routes interactive / pause / silent phases + opens vmconnect' -ForegroundColor Cyan
. (Join-Path $repo 'Private\Invoke-Win32ToolkitHyperVRun.ps1')
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Get-Win32ToolkitGuestCredential { [pscredential]::new('.\w32admin', (New-Object System.Security.SecureString)) }
$script:log2 = @()
function New-Win32ToolkitHyperVSession     { param($VMName, $Credential, $CheckpointName, [switch]$SkipRevert, [switch]$EnsureDesktop) $script:ensureDesktop = $EnsureDesktop.IsPresent; 'SESS' }
function Copy-Win32ToolkitProjectToGuest   { param($Session, $ProjectPath, $GuestPath) }
function Copy-Win32ToolkitResultsFromGuest { param($Session, $GuestPath, $Destination, $GuestRoot) }
function Remove-Win32ToolkitHyperVSession  { param($Session, $VMName, $CheckpointName, [switch]$Revert) }
function Invoke-Win32ToolkitGuestPhase { param($Session, $Command, $Label) $script:log2 += "phase:$Label"; 0 }
function Read-Host { param($Prompt) $script:log2 += 'pause' }
$script:vmconnect = $false
function Start-Process { param($FilePath, $ArgumentList, $ErrorAction) if ($FilePath -eq 'vmconnect.exe') { $script:vmconnect = $true } }

$iphases = @(
    @{ Label = 'Install (GUI)';   Command = 'x'; Interactive = $true }
    @{ Label = 'Test';            Pause = $true }
    @{ Label = 'Uninstall (GUI)'; Command = 'y'; Interactive = $true }
    @{ Label = 'CollectLogs';     Command = 'z'; IgnoreExit = $true }
)
Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase $iphases 6>$null | Out-Null
if ($script:vmconnect) { Ok 'vmconnect opened for the interactive run' } else { Bad 'vmconnect not opened' }
if ($script:ensureDesktop) { Ok 'interactive run requests -EnsureDesktop (login-screen safety net)' } else { Bad 'EnsureDesktop not requested for interactive run' }
if (($script:log2 -join ' > ') -eq 'phase:Install (GUI) > pause > phase:Uninstall (GUI) > phase:CollectLogs') { Ok 'every phase runs via the SYSTEM Phase; pause blocks on the host' } else { Bad "log: $($script:log2 -join ' > ')" }
Write-Host '[7] Invoke-Win32ToolkitHyperVRun warns only for an exit code outside a phase''s SuccessExitCodes' -ForegroundColor Cyan
# Reuses the [6] doubles; only the phase runner changes: its Command carries the exit code to return.
${function:Invoke-Win32ToolkitGuestPhase} = { param($Session, $Command, $Label) $script:log2 += "phase:$Label@$Session"; [int]$Command }
$ok7 = @(0, 1707, 3010, 1641)
$warn7 = @()
$script:log2 = @()
$null = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(
    @{ Label = 'parity-3010';  Command = '3010';  SuccessExitCodes = $ok7 }
    @{ Label = 'parity-1641';  Command = '1641';  SuccessExitCodes = $ok7 }
    @{ Label = 'parity-60008'; Command = '60008'; SuccessExitCodes = $ok7 }
    @{ Label = 'plain-3010';   Command = '3010' }
    @{ Label = 'ignored-5';    Command = '5'; IgnoreExit = $true }
) -WarningVariable warn7 3>$null 6>$null
$w7 = @($warn7 | ForEach-Object { "$_" })
if ($script:log2.Count -eq 5) { Ok 'all five phases ran' } else { Bad "log: $($script:log2 -join ' > ')" }
if (-not ($w7 -match 'parity-3010') -and -not ($w7 -match 'parity-1641')) { Ok '3010 / 1641 inside SuccessExitCodes -> no warning' } else { Bad "warnings: $($w7 -join ' | ')" }
if ($w7 -match "'parity-60008' exited with code 60008") { Ok '60008 outside SuccessExitCodes -> warned with the exact code' } else { Bad "warnings: $($w7 -join ' | ')" }
if ($w7 -match "'plain-3010' exited with code 3010") { Ok 'no SuccessExitCodes -> only 0 is success (as before)' } else { Bad "warnings: $($w7 -join ' | ')" }
if (-not ($w7 -match 'ignored-5')) { Ok 'IgnoreExit still silences the warning' } else { Bad "warnings: $($w7 -join ' | ')" }
Remove-Item Function:\New-Win32ToolkitHyperVSession, Function:\Copy-Win32ToolkitProjectToGuest, Function:\Copy-Win32ToolkitResultsFromGuest, Function:\Remove-Win32ToolkitHyperVSession, Function:\Invoke-Win32ToolkitGuestPhase, Function:\Read-Host, Function:\Start-Process, Function:\Get-Win32ToolkitConfigValue, Function:\Get-Win32ToolkitGuestCredential

Write-Host '[8] the scheduled-task primitive is SYSTEM-only (dead Interactive principal removed, GAP1-01)' -ForegroundColor Cyan
$stSrc = Get-Content -LiteralPath (Join-Path $repo 'Private\Invoke-Win32ToolkitGuestScheduledTask.ps1') -Raw
if ($stSrc -notmatch 'LogonType Interactive' -and $stSrc -notmatch 'SAM username') { Ok 'no Interactive principal / SAM-user RunAs left' } else { Bad 'Interactive principal text still present' }
if ($stSrc -match [regex]::Escape("New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest")) { Ok 'the only principal: NT AUTHORITY\SYSTEM, ServiceAccount, Highest' } else { Bad 'SYSTEM principal missing' }
$rp = (Get-Command Invoke-Win32ToolkitGuestScheduledTask).Parameters['RunAs']
$vs = @($rp.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
if ($vs.Count -eq 1 -and (@($vs[0].ValidValues) -join ',') -eq 'System') { Ok '-RunAs kept as [ValidateSet(''System'')] (caller unchanged)' } else { Bad "RunAs attributes: $(@($rp.Attributes | ForEach-Object { $_.GetType().Name }) -join ',')" }
if ($stSrc -match '-ArgumentList \$Command, \$RunAs, \$TimeoutMinutes') { Ok 'remoting -ArgumentList $Command, $RunAs, $TimeoutMinutes unchanged ([1] reads ArgumentList[1])' } else { Bad 'argument list changed' }
if ($stSrc -match 'NOT full Intune parity') { Ok 'the "same context as Intune" claim is corrected (SYSTEM yes; bitness/launcher no)' } else { Bad 'parity claim not corrected' }
$threw = $false
try { $null = Invoke-Win32ToolkitGuestScheduledTask -Session 'S' -Command 'x' -RunAs 'w32admin' } catch { $threw = $true }
if ($threw) { Ok 'a user RunAs is rejected at binding (no interactive-user principal any more)' } else { Bad 'RunAs w32admin accepted' }

Write-Host '[9] a phase that did not finish (267009 stopped at its timeout / 267011 never started) ends the run' -ForegroundColor Cyan
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Get-Win32ToolkitGuestCredential { [pscredential]::new('w32admin', (New-Object System.Security.SecureString)) }
function New-Win32ToolkitHyperVSession    { param($VMName, $Credential, $CheckpointName, [switch]$SkipRevert, [switch]$EnsureDesktop) 'SESS' }
function Copy-Win32ToolkitProjectToGuest  { param($Session, $ProjectPath, $GuestPath) }
function Copy-Win32ToolkitResultsFromGuest{ param($Session, $GuestPath, $Destination, $GuestRoot) $script:log9 += "copyout:$(@($GuestPath) -join ',')" }
function Remove-Win32ToolkitHyperVSession { param($Session, $VMName, $CheckpointName, [switch]$Revert) $script:log9 += "teardown:revert=$($Revert.IsPresent)" }
function Invoke-Win32ToolkitGuestPhase    { param($Session, $Command, $Label) $script:log9 += "phase:$Label"; [int]$Command }
foreach ($case in @(
        @{ Code = 267009; At = 'Install'; Ignore = $false; Why = 'still running at its timeout' }
        @{ Code = 267011; At = 'Install'; Ignore = $false; Why = 'never started' }
        @{ Code = 267009; At = 'Assert';  Ignore = $true;  Why = 'still running at its timeout' })) {
    $script:log9 = @()
    $warn9 = @()
    $ph9 = @(
        @{ Label = 'Install';     Command = $(if ($case.At -eq 'Install') { "$($case.Code)" } else { '0' }); SuccessExitCodes = @(0, 3010) }
        @{ Label = 'Assert';      Command = $(if ($case.At -eq 'Assert') { "$($case.Code)" } else { '0' }); IgnoreExit = $case.Ignore }
        @{ Label = 'Uninstall';   Command = '0' }
        @{ Label = 'CollectLogs'; Command = '0'; IgnoreExit = $true }
    )
    $r9 = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase $ph9 -Output @('Documentation\InstallationChanges_*.json', 'Sandbox\Logs\*') -WarningVariable warn9 3>$null 6>$null
    $tag = "$($case.Code) in '$($case.At)'$(if ($case.Ignore) { ' (IgnoreExit)' })"
    if ($r9 -eq $false) { Ok "${tag}: the run returns `$false" } else { Bad "${tag}: returned $r9" }
    $ran9 = @($script:log9 | Where-Object { $_ -like 'phase:*' })
    $expect = if ($case.At -eq 'Install') { 'phase:Install' } else { 'phase:Install phase:Assert' }
    if (($ran9 -join ' ') -eq $expect) { Ok "${tag}: the later phases are skipped" } else { Bad "${tag}: phases ran: $($ran9 -join ' > ')" }
    $co = @($script:log9 | Where-Object { $_ -like 'copyout:*' })
    if ($co.Count -eq 1 -and $co[0] -match 'Sandbox\\Logs' -and $co[0] -notmatch 'InstallationChanges') { Ok "${tag}: logs still copied back, the install capture is not" } else { Bad "${tag}: copy-out: $($co -join ' | ')" }
    if ($script:log9[-1] -eq 'teardown:revert=True') { Ok "${tag}: the VM is still reverted" } else { Bad "${tag}: log: $($script:log9 -join ' > ')" }
    $w9 = @($warn9 | ForEach-Object { "$_" } | Where-Object { $_ -match "Guest phase '$($case.At)' did not finish" -and $_ -match $case.Why -and $_ -match 'remaining phases are skipped' })
    if ($w9.Count -eq 1) { Ok "${tag}: one warning names the phase and why" } else { Bad "${tag}: warnings: $(@($warn9) -join ' | ')" }
}
Remove-Item Function:\New-Win32ToolkitHyperVSession, Function:\Copy-Win32ToolkitProjectToGuest, Function:\Copy-Win32ToolkitResultsFromGuest, Function:\Remove-Win32ToolkitHyperVSession, Function:\Invoke-Win32ToolkitGuestPhase, Function:\Get-Win32ToolkitConfigValue, Function:\Get-Win32ToolkitGuestCredential

if ($fail -eq 0) {
    Write-Host "`nAll HyperVProvider tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$fail HyperVProvider test(s) failed." -ForegroundColor Red
    exit 1
}
