<#
    Unit tests for the Hyper-V provider (Phase 3). No Hyper-V / no VM — the Hyper-V + PowerShell Direct
    cmdlets and the provider primitives are shadowed in-scope. Verifies exit-code passthrough, copy-out
    path mapping, the session revert/connect sequence, orchestration order, always-revert teardown, and
    the credential requirement.

    Run:  pwsh -File Tests\HyperVProvider.unit.ps1
    Exits non-zero on any failure.
#>
# Test shadows keep the real command names and signatures (C-4: no PSScriptAnalyzer warning in the suites).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'test shadows mirror the real signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'test shadows keep the real command names')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'test shadows take a fake credential')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUsePSCredentialType', '', Justification = 'test shadows take a fake credential')]
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
# C-9 (Hyper-V speed-up PR 1): the provider's new record helpers, inert by default ([14]/[15] replace them). The lane
# double returns nothing (the run's Lane stays $null) and the hash double emits nothing (no CopyInSha256).
function Get-Win32ToolkitHyperVLane { param($VMName, $CheckpointName, $VM) }
function Get-Win32ToolkitZipContentHash { param($ZipPath) }

Write-Host '[1] Invoke-Win32ToolkitGuestPhase runs as SYSTEM and returns ONLY the exit code' -ForegroundColor Cyan
# Simulate a guest that emits output lines followed by the exit code (the shape that broke the [int] cast).
# The scheduled-task runner passes -ArgumentList $Command,$RunAs,$Timeout, so ArgumentList[1] is the context.
$script:runAs = $null
$script:taskTimeout = $null
function Invoke-Command { param($Session, [scriptblock]$ScriptBlock, $ArgumentList) $script:runAs = $ArgumentList[1]; $script:taskTimeout = $ArgumentList[2]; return @('install output line', 'more output', 5) }
$rc = Invoke-Win32ToolkitGuestPhase -Session 'S' -Command 'x' -Label 'test'
if ($rc -eq 5) { Ok 'extracts the exit code even when output is present' } else { Bad "rc=$rc" }
if ($script:runAs -eq 'System') { Ok 'silent phase runs as SYSTEM (Intune-faithful context)' } else { Bad "runAs=$($script:runAs)" }
if ($script:taskTimeout -eq 30) { Ok 'no -TimeoutMinutes: the scheduled task keeps its 30-minute timeout' } else { Bad "timeout without -TimeoutMinutes: $($script:taskTimeout)" }
# Installer-identity PR 2 follow-up F2: a phase may raise its own timeout (the Intune-parity uninstall's backstop, 40).
$script:taskTimeout = $null
try {
    $null = Invoke-Win32ToolkitGuestPhase -Session 'S' -Command 'x' -Label 'test' -TimeoutMinutes 40
    if ($script:taskTimeout -eq 40) { Ok '-TimeoutMinutes 40 reaches the scheduled task (ArgumentList[2] = 40)' } else { Bad "timeout with -TimeoutMinutes 40: $($script:taskTimeout)" }
}
catch { Bad "-TimeoutMinutes 40: $($_.Exception.Message)" }
foreach ($badTimeout in 0, 241) {
    $bindErr = $null
    $bindId = ''
    try { $null = Invoke-Win32ToolkitGuestPhase -Session 'S' -Command 'x' -Label 'test' -TimeoutMinutes $badTimeout } catch { $bindErr = $_.Exception; $bindId = $_.FullyQualifiedErrorId }
    # ParameterBindingValidationException is not a public type: match its name and the validation error id.
    if ($bindErr -is [System.Management.Automation.ParameterBindingException] -and $bindErr.GetType().Name -eq 'ParameterBindingValidationException' -and $bindId -like 'ParameterArgumentValidationError*') { Ok "-TimeoutMinutes $badTimeout is refused at binding (1-240)" } else { Bad "-TimeoutMinutes ${badTimeout}: $(if ($bindErr) { $bindErr.GetType().FullName + ' (' + $bindId + '): ' + $bindErr.Message } else { 'accepted' })" }
}
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
# Exit code 1460 = the guest runner's 25-minute limit: an Intune-parity phase names its likely cause through the
# host constant ParityHint (installer-identity PR 2, L16); other phases and other codes keep the plain line.
$warn7b = @()
$script:log2 = @()
$null = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(
    @{ Label = 'p-dialog41';    Command = '1460'; SuccessExitCodes = $ok7; ParityHint = 'Dialog41' }
    @{ Label = 'p-dialog';      Command = '1460'; SuccessExitCodes = $ok7; ParityHint = 'Dialog' }
    @{ Label = 'p-uninstaller'; Command = '1460'; SuccessExitCodes = $ok7; ParityHint = 'Uninstaller' }
    @{ Label = 'p-nokey';       Command = '1460'; SuccessExitCodes = $ok7 }
    @{ Label = 'p-unknown';     Command = '1460'; SuccessExitCodes = $ok7; ParityHint = 'Something' }
    @{ Label = 'p-exit0';       Command = '0';    SuccessExitCodes = $ok7; ParityHint = 'Dialog41' }
    @{ Label = 'p-exit5';       Command = '5';    SuccessExitCodes = $ok7; ParityHint = 'Uninstaller' }
) -WarningVariable warn7b 3>$null 6>$null
$w7b = @($warn7b | ForEach-Object { "$_" })
$for7 = { param($label) @($w7b | Where-Object { $_ -like "Guest phase '$label' *" }) }
$d41 = @(& $for7 'p-dialog41')
if ($d41.Count -eq 1 -and $d41[0] -match '25-minute limit' -and $d41[0] -match 'signed in' -and $d41[0] -match 'PSADT 4\.1' -and $d41[0] -match 'watched' -and $d41[0] -match 'ProcessesToClose') { Ok '1460 + Dialog41: names the 25-minute limit, the signed-in user, PSADT 4.1, a watched run and ProcessesToClose' } else { Bad "Dialog41: $($d41 -join ' | ')" }
$dlg = @(& $for7 'p-dialog')
if ($dlg.Count -eq 1 -and $dlg[0] -match '25-minute limit' -and $dlg[0] -match 'watched' -and $dlg[0] -notmatch 'PSADT 4\.1') { Ok '1460 + Dialog: the 25-minute limit and a watched run, no PSADT version claimed' } else { Bad "Dialog: $($dlg -join ' | ')" }
# Live P5 r2: "without -Unattended" alone did not make a watched run when HyperVTestMode=Unattended is configured.
# TUI audit G3: -TestMode Interactive overrides HyperVTestMode for one run; the advice names it and the menu's run mode.
$needs7 = ' (Test-Win32ToolkitProject -TestMode Interactive, or Interactive as the Hyper-V run mode under Run a test in the menu, from an interactive console)'
if ($d41.Count -eq 1 -and $dlg.Count -eq 1 -and $d41[0].Contains($needs7) -and $dlg[0].Contains($needs7) -and $d41[0] -notmatch 'all three' -and $dlg[0] -notmatch 'all three' -and
    -not ($d41[0] -match 'watched \(without -Unattended\)') -and -not ($dlg[0] -match 'watched \(without -Unattended\)')) {
    Ok '1460 + Dialog41 / Dialog: the watched-run advice names -TestMode Interactive and the menu''s Hyper-V run mode (no "all three")'
} else { Bad "watched advice: $($d41 -join ' | ') || $($dlg -join ' | ')" }
$uni = @(& $for7 'p-uninstaller')
if ($uni.Count -eq 1 -and $uni[0] -match 'uninstaller' -and $uni[0] -match '30 minutes' -and $uni[0] -match '69113' -and $uni[0] -notmatch 'dialog') { Ok '1460 + Uninstaller: names the uninstaller, the 30-minute device limit and 69113, no dialog' } else { Bad "Uninstaller: $($uni -join ' | ')" }
# Dv2 override (2026-10-22): only an uninstaller still running at 30 minutes ends with 69113; a child process still
# running then is stopped and the uninstaller's own exit code counts, so "stops it at 30 minutes" is no longer true.
if ($uni.Count -eq 1 -and $uni[0].Contains("the uninstaller's own exit code counts") -and -not $uni[0].Contains('stops it at 30 minutes')) { Ok '1460 + Uninstaller: a child process outliving the limit is stopped and the uninstaller''s own exit code counts (Dv2)' } else { Bad "Uninstaller (Dv2 wording): $($uni -join ' | ')" }
foreach ($plain in 'p-nokey', 'p-unknown') {
    $pl = @(& $for7 $plain)
    if ($pl.Count -eq 1 -and $pl[0] -eq "Guest phase '$plain' exited with code 1460.") { Ok "1460 ($plain): the plain 'exited with code 1460' line" } else { Bad "${plain}: $($pl -join ' | ')" }
}
if (@(& $for7 'p-exit0').Count -eq 0) { Ok 'a ParityHint with exit code 0 -> no warning' } else { Bad "exit0: $((& $for7 'p-exit0') -join ' | ')" }
$e5 = @(& $for7 'p-exit5')
if ($e5.Count -eq 1 -and $e5[0] -eq "Guest phase 'p-exit5' exited with code 5.") { Ok 'a ParityHint with exit code 5 -> the plain line (the hint is for 1460 only)' } else { Bad "exit5: $($e5 -join ' | ')" }
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

Write-Host '[10] a failed dependency phase skips the app phases; Always phases (log collection) still run (S11-F1)' -ForegroundColor Cyan
$script:log9 = @()
$warn10 = @()
$r10 = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(
    @{ Label = 'Install dependencies'; Command = '60001'; DepPhase = $true }
    @{ Label = 'Install';     Command = '0'; SuccessExitCodes = @(0, 3010) }
    @{ Label = 'Assert';      Command = '0'; IgnoreExit = $true }
    @{ Label = 'Test pause';  Pause = $true }
    @{ Label = 'CollectLogs'; Command = '0'; IgnoreExit = $true; Always = $true }
) -Output @('Sandbox\Logs\*') -WarningVariable warn10 3>$null 6>$null
$ran10 = @($script:log9 | Where-Object { $_ -like 'phase:*' })
if (($ran10 -join ' ') -eq 'phase:Install dependencies phase:CollectLogs') { Ok 'only the dependency phase and CollectLogs ran (no install, assert or pause)' } else { Bad "phases: $($ran10 -join ' > ')" }
if ($r10 -eq $true -and @($script:log9 | Where-Object { $_ -like 'copyout:*' }).Count -eq 1 -and $script:log9[-1] -eq 'teardown:revert=True') { Ok 'the run still completes: logs copied back, VM reverted, $true (the verdict comes from the FAIL line in the log)' } else { Bad "log: $($script:log9 -join ' > ') r=$r10" }
if (@($warn10 | Where-Object { "$_" -match 'dependency failed to install: the app phases are skipped' }).Count -eq 1) { Ok 'one warning says the app phases were skipped' } else { Bad "warnings: $($warn10 -join ' | ')" }
$script:log9 = @()
$null = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(
    @{ Label = 'Install dependencies'; Command = '0'; DepPhase = $true }
    @{ Label = 'Install'; Command = '0' }
    @{ Label = 'CollectLogs'; Command = '0'; IgnoreExit = $true; Always = $true }
) -Output @('Sandbox\Logs\*') 3>$null 6>$null
if ((@($script:log9 | Where-Object { $_ -like 'phase:*' }) -join ' ') -eq 'phase:Install dependencies phase:Install phase:CollectLogs') { Ok 'a successful dependency phase changes nothing' } else { Bad "phases: $($script:log9 -join ' > ')" }
Remove-Item Function:\New-Win32ToolkitHyperVSession, Function:\Copy-Win32ToolkitProjectToGuest, Function:\Copy-Win32ToolkitResultsFromGuest, Function:\Remove-Win32ToolkitHyperVSession, Function:\Invoke-Win32ToolkitGuestPhase, Function:\Get-Win32ToolkitConfigValue, Function:\Get-Win32ToolkitGuestCredential

Write-Host '[11] the run reverts the configured HyperVCheckpoint (installer-identity PR 2, L18)' -ForegroundColor Cyan
# The parameter has no default any more: an omitted -CheckpointName is the HyperVCheckpoint config value (default
# 'clean-base'), the checkpoint New-/Set-Win32ToolkitTestVM* maintain; an explicit one still wins.
$script:cfg11 = @{}
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg11.ContainsKey($Name)) { $script:cfg11[$Name] } else { $Default } }
function Get-Win32ToolkitGuestCredential { [pscredential]::new('w32admin', (New-Object System.Security.SecureString)) }
function New-Win32ToolkitHyperVSession    { param($VMName, $Credential, $CheckpointName, [switch]$SkipRevert, [switch]$EnsureDesktop) $script:log11 += "open:$CheckpointName"; 'SESS' }
function Copy-Win32ToolkitProjectToGuest  { param($Session, $ProjectPath, $GuestPath) }
function Copy-Win32ToolkitResultsFromGuest{ param($Session, $GuestPath, $Destination, $GuestRoot) }
function Remove-Win32ToolkitHyperVSession { param($Session, $VMName, $CheckpointName, [switch]$Revert) $script:log11 += "revert:$CheckpointName" }
function Invoke-Win32ToolkitGuestPhase    { param($Session, $Command, $Label) 0 }
foreach ($case in @(
        @{ Label = 'HyperVCheckpoint warm-x, no -CheckpointName'; Cfg = @{ HyperVCheckpoint = 'warm-x' }; Arg = @{}; Want = 'warm-x' }
        @{ Label = 'HyperVCheckpoint warm-x, -CheckpointName clean-base'; Cfg = @{ HyperVCheckpoint = 'warm-x' }; Arg = @{ CheckpointName = 'clean-base' }; Want = 'clean-base' }
        @{ Label = 'nothing configured (the default)'; Cfg = @{}; Arg = @{}; Want = 'clean-base' })) {
    $script:cfg11 = $case.Cfg; $script:log11 = @()
    $arg11 = $case.Arg
    $null = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(@{ Label = 'x'; Command = 'y' }) @arg11 3>$null 6>$null
    if (($script:log11 -join ' ') -eq "open:$($case.Want) revert:$($case.Want)") { Ok "$($case.Label): opens and reverts '$($case.Want)'" } else { Bad "$($case.Label): $($script:log11 -join ' ')" }
}
Remove-Item Function:\New-Win32ToolkitHyperVSession, Function:\Copy-Win32ToolkitProjectToGuest, Function:\Copy-Win32ToolkitResultsFromGuest, Function:\Remove-Win32ToolkitHyperVSession, Function:\Invoke-Win32ToolkitGuestPhase, Function:\Get-Win32ToolkitConfigValue, Function:\Get-Win32ToolkitGuestCredential

Write-Host '[12] a phase may raise its guest-runner limit (RunnerTimeoutMinutes): backstop +5, 1460/69113 texts per limit (F2)' -ForegroundColor Cyan
# Installer-identity PR 2 follow-up F2: the Intune-parity uninstall's runner may run 35 minutes, longer than the device's
# 30-minute EXE uninstaller limit, so a test can show 69113; its phase backstop is then 40 (runner + 5).
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Get-Win32ToolkitGuestCredential { [pscredential]::new('w32admin', (New-Object System.Security.SecureString)) }
function New-Win32ToolkitHyperVSession    { param($VMName, $Credential, $CheckpointName, [switch]$SkipRevert, [switch]$EnsureDesktop) 'SESS' }
function Copy-Win32ToolkitProjectToGuest  { param($Session, $ProjectPath, $GuestPath) }
function Copy-Win32ToolkitResultsFromGuest{ param($Session, $GuestPath, $Destination, $GuestRoot) }
function Remove-Win32ToolkitHyperVSession { param($Session, $VMName, $CheckpointName, [switch]$Revert) }
# Records whether the run bound -TimeoutMinutes, and to what; the Command carries the exit code to return.
$script:tm12 = @{}
function Invoke-Win32ToolkitGuestPhase { param($Session, $Command, $Label, $TimeoutMinutes)
    $script:tm12[$Label] = if ($PSBoundParameters.ContainsKey('TimeoutMinutes')) { "bound:$TimeoutMinutes" } else { 'unbound' }
    [int]$Command
}
$out12 = @(Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(
        @{ Label = 'k35';   Command = '0'; RunnerTimeoutMinutes = 35 }
        @{ Label = 'k235';  Command = '0'; RunnerTimeoutMinutes = 235 }
        @{ Label = 'nokey'; Command = '0' }
        @{ Label = 'k0';    Command = '0'; RunnerTimeoutMinutes = 0 }
        @{ Label = 'k236';  Command = '0'; RunnerTimeoutMinutes = 236 }
        @{ Label = 'kx';    Command = '0'; RunnerTimeoutMinutes = 'x' }
    ) -Verbose 4>&1 3>$null 6>$null)
if ($script:tm12['k35'] -eq 'bound:40') { Ok 'RunnerTimeoutMinutes 35 -> the phase backstop is 40 (-TimeoutMinutes bound)' } else { Bad "k35: $($script:tm12['k35'])" }
if ($script:tm12['k235'] -eq 'bound:240') { Ok 'RunnerTimeoutMinutes 235 -> 240 (the scheduled task''s maximum)' } else { Bad "k235: $($script:tm12['k235'])" }
if ($script:tm12['nokey'] -eq 'unbound') { Ok 'no RunnerTimeoutMinutes -> -TimeoutMinutes not bound (the 30-minute default, existing shadows keep working)' } else { Bad "nokey: $($script:tm12['nokey'])" }
$verb12 = @($out12 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message } | Where-Object { $_ -match 'RunnerTimeoutMinutes' })
foreach ($badKey in @(@{ L = 'k0'; V = '0' }, @{ L = 'k236'; V = '236' }, @{ L = 'kx'; V = 'x' })) {
    $vl = @($verb12 | Where-Object { $_ -like "*Phase '$($badKey.L)': RunnerTimeoutMinutes '$($badKey.V)' is not 1-235; the default limits apply." })
    if ($script:tm12[$badKey.L] -eq 'unbound' -and $vl.Count -eq 1) { Ok "RunnerTimeoutMinutes '$($badKey.V)' -> not bound, one verbose line" } else { Bad "$($badKey.L): $($script:tm12[$badKey.L]) verbose: $($verb12 -join ' | ')" }
}
if ($verb12.Count -eq 3) { Ok 'no verbose line for a valid key or no key' } else { Bad "verbose lines: $($verb12 -join ' | ')" }
if ((@($out12 | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }) -join ',') -eq 'True') { Ok 'the run still completes ($true)' } else { Bad "result: $(@($out12 | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }) -join ',')" }

$warn12 = @()
$null = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(
    @{ Label = 'u35';      Command = '1460';  SuccessExitCodes = $ok7; ParityHint = 'Uninstaller'; RunnerTimeoutMinutes = 35 }
    @{ Label = 'u25';      Command = '1460';  SuccessExitCodes = $ok7; ParityHint = 'Uninstaller' }
    @{ Label = 'd35';      Command = '1460';  SuccessExitCodes = $ok7; ParityHint = 'Dialog'; RunnerTimeoutMinutes = 35 }
    @{ Label = 'x69113';   Command = '69113'; SuccessExitCodes = $ok7; ParityHint = 'Uninstaller'; RunnerTimeoutMinutes = 35 }
    @{ Label = 'x69113nk'; Command = '69113'; SuccessExitCodes = $ok7; ParityHint = 'Uninstaller' }
    @{ Label = 'n69113';   Command = '69113'; SuccessExitCodes = $ok7 }
    @{ Label = 'dl69113';  Command = '69113'; SuccessExitCodes = $ok7; ParityHint = 'Dialog' }
) -WarningVariable warn12 3>$null 6>$null
$w12 = @($warn12 | ForEach-Object { "$_" })
$for12 = { param($label) @($w12 | Where-Object { $_ -like "Guest phase '$label' *" }) }
$u35 = @(& $for12 'u35')
if ($u35.Count -eq 1 -and $u35[0].StartsWith("Guest phase 'u35' exited with code 1460: the guest runner stopped the package at its 35-minute limit.") -and
    $u35[0].Contains('after 35 minutes') -and $u35[0].Contains('30-minute uninstaller limit') -and $u35[0].Contains('69113') -and $u35[0] -notmatch 'dialog') {
    Ok '1460 + Uninstaller + RunnerTimeoutMinutes 35: the 35-minute limit, longer than the 30-minute device limit, 69113, no dialog'
} else { Bad "u35: $($u35 -join ' | ')" }
$want25 = "Guest phase 'u25' exited with code 1460: the guest runner stopped the package at its 25-minute limit. The uninstaller, or a child process it waits for, was still running at the test runner's 25-minute limit; on devices, a project created with this win32-toolkit version stops the uninstaller at 30 minutes (exit code 69113 when the uninstaller itself is still running; a child process still running then is stopped and the uninstaller's own exit code counts). The PSADT log under Sandbox\Logs shows the command it was running."
$u25 = @(& $for12 'u25')
if ($u25.Count -eq 1 -and $u25[0] -ceq $want25) { Ok '1460 + Uninstaller without the key: exactly the reworded 25-minute text (Dv2)' } else { Bad "u25: $($u25 -join ' | ')" }
$d35 = @(& $for12 'd35')
if ($d35.Count -eq 1 -and $d35[0].StartsWith("Guest phase 'd35' exited with code 1460: the guest runner stopped the package at its 35-minute limit.") -and $d35[0] -match 'dialog') { Ok '1460 + Dialog + RunnerTimeoutMinutes 35: the preamble names the 35-minute limit' } else { Bad "d35: $($d35 -join ' | ')" }
foreach ($lbl in 'x69113', 'x69113nk') {
    $want69 = "Guest phase '$lbl' exited with code 69113: the package stopped the app's EXE uninstaller at the device's 30-minute limit, as a device would. The detection tattoo stays, so Intune would keep reporting the app as installed. The PSADT log under Sandbox\Logs names the uninstaller."
    $x69 = @(& $for12 $lbl)
    if ($x69.Count -eq 1 -and $x69[0] -ceq $want69) { Ok "69113 + Uninstaller ($lbl): says the package stopped the EXE uninstaller at the device's 30-minute limit" } else { Bad "${lbl}: $($x69 -join ' | ')" }
}
foreach ($lbl in 'n69113', 'dl69113') {
    $p69 = @(& $for12 $lbl)
    if ($p69.Count -eq 1 -and $p69[0] -ceq "Guest phase '$lbl' exited with code 69113.") { Ok "69113 ($lbl): the plain line (the explanation needs ParityHint 'Uninstaller')" } else { Bad "${lbl}: $($p69 -join ' | ')" }
}

Write-Host '[13] -ParityExitNote: one record sentence per Intune-parity phase that failed (69113 vs 1460, R6 #3)' -ForegroundColor Cyan
# Installer-identity PR 2 follow-up R6 #3: a parity uninstall that ended with 69113 (the device's limit) and one that hit the
# test's own limit (1460) looked alike in TestResults.json. The caller's list gets one sentence per failed parity phase, in
# phase order; success codes, IgnoreExit, phases without ParityHint and a phase that did not finish add nothing.
$notes13 = [System.Collections.Generic.List[string]]::new()
$r13 = $null
$err13 = $null
try {
    $r13 = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(
        @{ Label = 'Install (Intune parity)';   Command = '3010';  SuccessExitCodes = $ok7; ParityHint = 'Dialog41' }
        @{ Label = 'Assert: installed';         Command = '1';     IgnoreExit = $true }
        @{ Label = 'Uninstall (Intune parity)'; Command = '69113'; SuccessExitCodes = $ok7; ParityHint = 'Uninstaller'; RunnerTimeoutMinutes = 35 }
        @{ Label = 'u1460-35';                  Command = '1460';  SuccessExitCodes = $ok7; ParityHint = 'Uninstaller'; RunnerTimeoutMinutes = 35 }
        @{ Label = 'd1460-25';                  Command = '1460';  SuccessExitCodes = $ok7; ParityHint = 'Dialog' }
        @{ Label = 'd60008';                    Command = '60008'; SuccessExitCodes = $ok7; ParityHint = 'Dialog' }
        @{ Label = 'dl69113';                   Command = '69113'; SuccessExitCodes = $ok7; ParityHint = 'Dialog' }
        @{ Label = 'plain-1460';                Command = '1460';  SuccessExitCodes = $ok7 }
        @{ Label = 'ignored-parity';            Command = '1460';  SuccessExitCodes = $ok7; ParityHint = 'Uninstaller'; IgnoreExit = $true }
        @{ Label = 'ok-parity';                 Command = '0';     SuccessExitCodes = $ok7; ParityHint = 'Uninstaller' }
    ) -ParityExitNote $notes13 3>$null 6>$null
}
catch { $err13 = $_ }
if ($null -eq $err13 -and $r13 -eq $true) { Ok '-ParityExitNote is accepted and the run completes ($true)' } else { Bad "run: $(if ($err13) { $err13.Exception.Message } else { "returned $r13" })" }
$want13 = @(
    "Intune-parity phase 'Uninstall (Intune parity)' exited with code 69113: the app's own uninstaller was still running at the device's 30-minute limit and was stopped."
    "Intune-parity phase 'u1460-35' exited with code 1460: the test's own 35-minute limit for this phase was reached and the package was stopped."
    "Intune-parity phase 'd1460-25' exited with code 1460: the test's own 25-minute limit for this phase was reached and the package was stopped."
    "Intune-parity phase 'd60008' exited with code 60008."
    "Intune-parity phase 'dl69113' exited with code 69113."
)
if ($notes13.Count -ge 1 -and $notes13[0] -ceq $want13[0]) { Ok '69113 + Uninstaller: the app''s own uninstaller was still running at the device''s 30-minute limit and was stopped' } else { Bad "69113 note: $($notes13 -join ' | ')" }
if ($notes13.Count -ge 3 -and $notes13[1] -ceq $want13[1] -and $notes13[2] -ceq $want13[2]) { Ok '1460: the test''s own limit for the phase (35 with the key, 25 without), not the device''s' } else { Bad "1460 notes: $($notes13 -join ' | ')" }
if ($notes13.Count -ge 5 -and $notes13[3] -ceq $want13[3] -and $notes13[4] -ceq $want13[4]) { Ok 'any other code (and 69113 without ParityHint ''Uninstaller''): the code only' } else { Bad "other notes: $($notes13 -join ' | ')" }
if ((@($notes13) -join "`n") -ceq ($want13 -join "`n")) { Ok 'exactly five sentences, in phase order: none for 3010 (success), IgnoreExit, no ParityHint or exit 0' } else { Bad "notes: $($notes13 -join ' | ')" }
# A phase that did not finish did not exit: the run stops there and adds no sentence.
$notes13b = [System.Collections.Generic.List[string]]::new()
try {
    $null = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(
        @{ Label = 'Uninstall (Intune parity)'; Command = '267009'; SuccessExitCodes = $ok7; ParityHint = 'Uninstaller'; RunnerTimeoutMinutes = 35 }
    ) -ParityExitNote $notes13b 3>$null 6>$null
    if ($notes13b.Count -eq 0) { Ok '267009 (did not finish): no sentence' } else { Bad "267009 notes: $($notes13b -join ' | ')" }
}
catch { Bad "267009: $($_.Exception.Message)" }
# Without the list the run is unchanged (every existing caller and shadow).
$r13c = Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(@{ Label = 'x'; Command = '69113'; SuccessExitCodes = $ok7; ParityHint = 'Uninstaller' }) 3>$null 6>$null
if ($r13c -eq $true) { Ok 'no -ParityExitNote: the run completes as before' } else { Bad "no list: returned $r13c" }
Remove-Item Function:\New-Win32ToolkitHyperVSession, Function:\Copy-Win32ToolkitProjectToGuest, Function:\Copy-Win32ToolkitResultsFromGuest, Function:\Remove-Win32ToolkitHyperVSession, Function:\Invoke-Win32ToolkitGuestPhase, Function:\Get-Win32ToolkitConfigValue, Function:\Get-Win32ToolkitGuestCredential

# ── Hyper-V speed-up PR 1 ────────────────────────────────────────────────────────────────────────────────────────────
# C-12 static check (V-1): in the files below, every call of a helper this round added or changed is assigned or used
# as an if/elseif condition within its own statement, so nothing it returns can join a caller's [bool] or session.
$c12Files = @('Private\Invoke-Win32ToolkitHyperVRun.ps1', 'Private\New-Win32ToolkitHyperVSession.ps1', 'Private\Remove-Win32ToolkitHyperVSession.ps1')
$c12Names = @('Get-Win32ToolkitHyperVLane', 'Get-Win32ToolkitZipContentHash', 'New-Win32ToolkitHyperVSession', 'Remove-Win32ToolkitHyperVSession')
$c12Check = {
    param([string[]]$Files, [string[]]$Names)
    $bad = [System.Collections.Generic.List[string]]::new()
    $seen = 0
    foreach ($rel in $Files) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $rel), [ref]$null, [ref]$null)
        foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $Names }, $true)) {
            $seen++
            $ok = $false
            $child = $cmd; $p = $cmd.Parent
            while ($p) {
                if ($p -is [System.Management.Automation.Language.AssignmentStatementAst]) { $ok = $true; break }
                if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
                    $ok = @($p.Clauses | Where-Object { [object]::ReferenceEquals($_.Item1, $child) }).Count -gt 0
                    break
                }
                if ($p -is [System.Management.Automation.Language.StatementBlockAst] -or $p -is [System.Management.Automation.Language.NamedBlockAst]) { break }
                $child = $p; $p = $p.Parent
            }
            if (-not $ok) { $bad.Add("$(Split-Path -Leaf $rel):$($cmd.Extent.StartLineNumber) $($cmd.GetCommandName())") }
        }
    }
    [pscustomobject]@{ Seen = $seen; Bad = @($bad) }
}

Write-Host '[14] -RunInfo: Timing and Lane for the record; the output stays exactly one [bool] (speed-up PR 1, C-12)' -ForegroundColor Cyan
function Get-Win32ToolkitConfigValue { param($Name, $Default) $Default }
function Get-Win32ToolkitGuestCredential { [pscredential]::new('w32admin', (New-Object System.Security.SecureString)) }
$script:skip14 = $false; $script:since14 = $null
$vmId14 = '0e5f9e66-1111-2222-3333-444455556666'
function New-Win32ToolkitHyperVSession {
    param($VMName, $Credential, $CheckpointName, [switch]$SkipRevert, [switch]$EnsureDesktop, [hashtable]$Info)
    if ($null -ne $Info) { $Info['RevertSkipped'] = $script:skip14; $Info['SecondsSinceTeardown'] = $script:since14; $Info['VM'] = [pscustomobject]@{ Name = $VMName; Id = $vmId14 }; $Info['VMId'] = $vmId14; $Info['Warm'] = $true }
    'SESS'
}
function Copy-Win32ToolkitProjectToGuest  { param($Session, $ProjectPath, $GuestPath, [switch]$ReadOnly, $PrebuiltZip) }
function Copy-Win32ToolkitResultsFromGuest { param($Session, $GuestPath, $Destination, $GuestRoot) }
function Invoke-Win32ToolkitGuestPhase    { param($Session, $Command, $Label) [int]$Command }
function Read-Host { param($Prompt) }
# The teardown double fills -Info and RETURNS AN OBJECT: an unassigned call would add it to the run's output.
function Remove-Win32ToolkitHyperVSession { param($Session, $VMName, $CheckpointName, [switch]$Revert, [hashtable]$Info)
    if ($null -ne $Info) { $Info['Restored'] = $true; $Info['RevertMode'] = 'Legacy' }
    [pscustomobject]@{ Leak = 'teardown' }
}
$script:laneThrows = $false
$script:laneVm = $null
function Get-Win32ToolkitHyperVLane { param($VMName, $CheckpointName, $VM)
    if ($script:laneThrows) { throw 'the checkpoint could not be read' }
    $script:laneVm = $VM
    @{ VMName = $VMName; VMId = $vmId14; CheckpointName = $CheckpointName; CheckpointId = '29613cba-d62f-4998-a421-df2e124a2b4f'; ConcurrentLanes = 1 }
}
$ri14 = @{}
$out14 = @(Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(
        @{ Label = 'Install'; Command = '0' }
        @{ Label = 'Test the app'; Pause = $true }
        @{ Label = 'Uninstall'; Command = '0' }
        @{ Label = 'CollectLogs'; Command = '0'; IgnoreExit = $true; Always = $true }
    ) -RunInfo $ri14 3>$null 6>$null)
if ($out14.Count -eq 1 -and $out14[0] -is [bool] -and $out14[0]) { Ok 'the output is exactly one [bool] $true (the teardown double''s object does not leak)' } else { Bad "output: $(@($out14 | ForEach-Object { "$($_.GetType().Name):$_" }) -join ', ')" }
$t14 = $ri14['Timing']
$nums14 = @('OpenSeconds', 'CopyInSeconds', 'TeardownSeconds', 'TotalSeconds' | Where-Object { $t14 -and $t14[$_] -is [double] -and $t14[$_] -ge 0 })
if ($nums14.Count -eq 4) { Ok 'Timing: OpenSeconds, CopyInSeconds, TeardownSeconds and TotalSeconds are numbers >= 0' } else { Bad "timing: $($t14 | ConvertTo-Json -Compress -Depth 4)" }
if ((@($t14['Phases'] | ForEach-Object { $_.Label }) -join '|') -eq 'Install|Uninstall|CollectLogs' -and @($t14['Phases'] | Where-Object { $_.Seconds -isnot [double] }).Count -eq 0) { Ok 'Timing.Phases: the phases that ran, in order, each with its seconds (the Pause is not one)' } else { Bad "phases: $($t14['Phases'] | ConvertTo-Json -Compress)" }
if ($t14['RevertMode'] -ceq 'Legacy' -and $t14['OpenRevertSkipped'] -eq $false -and $null -eq $t14['SecondsSinceTeardown'] -and $null -eq $t14['CopyInSha256'] -and $null -eq $t14['PrecheckSeconds']) { Ok 'Timing: RevertMode Legacy (a teardown restore ran), OpenRevertSkipped from the open, no hash without a prebuild, no pre-check' } else { Bad "timing: $($t14 | ConvertTo-Json -Compress -Depth 4)" }
$l14 = $ri14['Lane']
if ($l14 -and $l14.VMId -eq $vmId14 -and $l14.CheckpointName -eq 'clean-base' -and $script:laneVm -and $script:laneVm.Id -eq $vmId14) { Ok 'Lane comes from Get-Win32ToolkitHyperVLane, given the VM object the open read (one Get-VM)' } else { Bad "lane: $($l14 | ConvertTo-Json -Compress) vm=$($script:laneVm | ConvertTo-Json -Compress)" }
# A marker-skip open: its RevertSkipped and age reach the record.
$script:skip14 = $true; $script:since14 = 42.5
$ri14b = @{}
$out14b = @(Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(@{ Label = 'Install'; Command = '0' }) -RunInfo $ri14b 3>$null 6>$null)
if ($out14b.Count -eq 1 -and $out14b[0] -eq $true -and $ri14b['Timing']['OpenRevertSkipped'] -eq $true -and $ri14b['Timing']['SecondsSinceTeardown'] -eq 42.5) { Ok 'a skipped open restore: OpenRevertSkipped $true and SecondsSinceTeardown copied from the open' } else { Bad "skip: out=$($out14b -join ',') timing=$($ri14b['Timing'] | ConvertTo-Json -Compress -Depth 4)" }
$script:skip14 = $false; $script:since14 = $null
# A lane that cannot be read: Lane $null, the run unchanged.
$script:laneThrows = $true
$ri14c = @{}
$out14c = @(Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(@{ Label = 'Install'; Command = '0' }) -RunInfo $ri14c 3>$null 6>$null)
$script:laneThrows = $false
if ($out14c.Count -eq 1 -and $out14c[0] -is [bool] -and $out14c[0] -and $ri14c.ContainsKey('Lane') -and $null -eq $ri14c['Lane'] -and $ri14c['Timing']) { Ok 'Get-Win32ToolkitHyperVLane throws -> Lane $null, Timing still filled, the run exactly $true' } else { Bad "lane throws: out=$($out14c -join ',') keys=$(@($ri14c.Keys) -join ',')" }
# A run whose open throws: Timing still handed over (OpenSeconds $null), the run $false.
${function:New-Win32ToolkitHyperVSession_Saved} = ${function:New-Win32ToolkitHyperVSession}
function New-Win32ToolkitHyperVSession { param($VMName, $Credential, $CheckpointName, [switch]$SkipRevert, [switch]$EnsureDesktop, [hashtable]$Info) throw 'PowerShell Direct is not ready' }
$ri14d = @{}
$out14d = @(Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(@{ Label = 'Install'; Command = '0' }) -RunInfo $ri14d 3>$null 6>$null)
${function:New-Win32ToolkitHyperVSession} = ${function:New-Win32ToolkitHyperVSession_Saved}
Remove-Item Function:\New-Win32ToolkitHyperVSession_Saved
if ($out14d.Count -eq 1 -and $out14d[0] -eq $false -and $ri14d['Timing'] -and $null -eq $ri14d['Timing']['OpenSeconds'] -and $ri14d['Timing']['TotalSeconds'] -ge 0 -and @($ri14d['Timing']['Phases']).Count -eq 0) { Ok 'the open throws -> exactly $false; Timing handed over with OpenSeconds $null and no phase' } else { Bad "open throws: out=$($out14d -join ',') timing=$($ri14d['Timing'] | ConvertTo-Json -Compress -Depth 4)" }
# Without -RunInfo the run is unchanged (every existing caller).
$out14e = @(Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(@{ Label = 'Install'; Command = '0' }) 3>$null 6>$null)
if ($out14e.Count -eq 1 -and $out14e[0] -eq $true) { Ok 'no -RunInfo: exactly $true, as before' } else { Bad "no RunInfo: $($out14e -join ',')" }
# No teardown restore ran (spec §3.3): RevertMode $null in the provider's own record, both when the teardown
# reports Restored $false and when it fills nothing; the double still returns an object, the output stays one [bool].
${function:Remove-Win32ToolkitHyperVSession_Saved} = ${function:Remove-Win32ToolkitHyperVSession}
$script:td14Fill = $true
function Remove-Win32ToolkitHyperVSession { param($Session, $VMName, $CheckpointName, [switch]$Revert, [hashtable]$Info)
    if ($script:td14Fill -and $null -ne $Info) { $Info['Restored'] = $false; $Info['RevertMode'] = $null }
    [pscustomobject]@{ Leak = 'teardown' }
}
try {
    $ri14f = @{}
    $out14f = @(Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(@{ Label = 'Install'; Command = '0' }) -RunInfo $ri14f 3>$null 6>$null)
    $script:td14Fill = $false
    $ri14g = @{}
    $out14g = @(Invoke-Win32ToolkitHyperVRun -ProjectPath 'C:\proj' -Phase @(@{ Label = 'Install'; Command = '0' }) -RunInfo $ri14g 3>$null 6>$null)
}
finally {
    ${function:Remove-Win32ToolkitHyperVSession} = ${function:Remove-Win32ToolkitHyperVSession_Saved}
    Remove-Item Function:\Remove-Win32ToolkitHyperVSession_Saved
}
if ($out14f.Count -eq 1 -and $out14f[0] -is [bool] -and $ri14f['Timing'] -and $ri14f['Timing'].ContainsKey('RevertMode') -and $null -eq $ri14f['Timing']['RevertMode']) { Ok 'a failed teardown restore (Restored $false): Timing.RevertMode $null, the output exactly one [bool]' } else { Bad "failed teardown: out=$(@($out14f | ForEach-Object { "$($_.GetType().Name):$_" }) -join ', ') timing=$($ri14f['Timing'] | ConvertTo-Json -Compress -Depth 4)" }
if ($out14g.Count -eq 1 -and $out14g[0] -is [bool] -and $ri14g['Timing'] -and $ri14g['Timing'].ContainsKey('RevertMode') -and $null -eq $ri14g['Timing']['RevertMode']) { Ok 'a teardown that reports nothing (no Restored key): Timing.RevertMode $null, the output exactly one [bool]' } else { Bad "silent teardown: out=$(@($out14g | ForEach-Object { "$($_.GetType().Name):$_" }) -join ', ') timing=$($ri14g['Timing'] | ConvertTo-Json -Compress -Depth 4)" }
# C-12 static check.
$c12 = & $c12Check $c12Files $c12Names
if ($c12.Seen -ge 3 -and $c12.Bad.Count -eq 0) { Ok "C-12: all $($c12.Seen) calls of the round's helpers in the provider and the session helpers are assigned or tested" } else { Bad "C-12: seen=$($c12.Seen) unassigned: $($c12.Bad -join ', ')" }

Write-Host '[15] CopyInSha256: the copy-in zip''s content hash, computed in the prebuild thread job (A-3, V-8)' -ForegroundColor Cyan
if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) { Bad 'Start-ThreadJob is not available: the prebuild cannot be tested' }
else {
    . (Join-Path $repo 'Private\New-Win32ToolkitProjectZip.ps1')
    . (Join-Path $repo 'Private\Get-Win32ToolkitZipContentHash.ps1')
    $proj15 = Join-Path ([System.IO.Path]::GetTempPath()) ('w32hvp15_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $base15 = Join-Path ([System.IO.Path]::GetTempPath()) ('w32hvp15b_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $proj15 'Files'), $base15 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $proj15 'Files\setup.cmd') -Value 'echo install'
    Set-Content -LiteralPath (Join-Path $proj15 'Invoke-AppDeployToolkit.ps1') -Value '# deploy'
    Set-Content -LiteralPath (Join-Path $base15 'Invoke-AppDeployToolkit.ps1') -Value '# old deploy'
    # Records what each prebuild job emitted (project first, then baseline), passing it on unchanged.
    $script:jobOut15 = [System.Collections.Generic.List[object]]::new()
    function Receive-Job { param($Job, [switch]$Wait, $ErrorAction)
        $o = @(Microsoft.PowerShell.Core\Receive-Job -Job $Job -Wait -ErrorAction Stop)
        $script:jobOut15.Add($o)
        $o
    }
    $run15 = {
        param([switch]$WithBaseline)
        $ri = @{}
        $a = @{ ProjectPath = $proj15; Phase = @(@{ Label = 'Install'; Command = '0' }); RunInfo = $ri }
        if ($WithBaseline) { $a['BaselineProjectPath'] = $base15 }
        $o = @(Invoke-Win32ToolkitHyperVRun @a 3>$null 6>$null)
        [pscustomobject]@{ Out = $o; Hash = $ri['Timing']['CopyInSha256'] }
    }
    try {
        $script:jobOut15.Clear()
        $h1 = & $run15 -WithBaseline
        $h2 = & $run15
        if ($h1.Hash -is [string] -and $h1.Hash -cmatch '^[0-9A-F]{64}$' -and $h1.Out.Count -eq 1 -and $h1.Out[0] -eq $true) { Ok "the project zip's hash is one scalar [string] of 64 upper-case hex characters ($($h1.Hash.Substring(0, 12))...)" } else { Bad "hash: $($h1.Hash | ConvertTo-Json -Compress) out=$($h1.Out -join ',')" }
        if ($h2.Hash -ceq $h1.Hash) { Ok 'two runs of the same project give the same value' } else { Bad "second run: $($h2.Hash)" }
        if ($script:jobOut15.Count -ge 2 -and @($script:jobOut15[0]).Count -eq 1 -and @($script:jobOut15[1]).Count -eq 0) { Ok 'the project job emits only the hash, the baseline job nothing (the build''s zip path is discarded)' } else { Bad "job outputs: $(@($script:jobOut15 | ForEach-Object { '[' + (@($_) -join ',') + ']' }) -join ' ')" }
        (Get-Item -LiteralPath (Join-Path $proj15 'Files\setup.cmd')).LastWriteTime = [datetime]'2020-01-01T00:00:00'
        $h3 = & $run15
        if ($h3.Hash -ceq $h1.Hash) { Ok 'a file whose write time alone changed: the same value (zip timestamps do not count)' } else { Bad "write time changed the hash: $($h3.Hash)" }
        Set-Content -LiteralPath (Join-Path $proj15 'Files\setup.cmd') -Value 'echo install v2'
        $h4 = & $run15
        if ($h4.Hash -cmatch '^[0-9A-F]{64}$' -and $h4.Hash -cne $h1.Hash) { Ok 'a file whose bytes changed: a different value' } else { Bad "bytes changed, hash: $($h4.Hash)" }
        Remove-Item Function:\Get-Win32ToolkitZipContentHash
        $h5 = & $run15
        if ($null -eq $h5.Hash -and $h5.Out.Count -eq 1 -and $h5.Out[0] -eq $true) { Ok 'without Get-Win32ToolkitZipContentHash: CopyInSha256 $null, the run still exactly $true' } else { Bad "no hash helper: hash=$($h5.Hash) out=$($h5.Out -join ',')" }
    }
    finally {
        Remove-Item Function:\Receive-Job -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $proj15, $base15 -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Remove-Item Function:\New-Win32ToolkitHyperVSession, Function:\Copy-Win32ToolkitProjectToGuest, Function:\Copy-Win32ToolkitResultsFromGuest, Function:\Remove-Win32ToolkitHyperVSession, Function:\Invoke-Win32ToolkitGuestPhase, Function:\Get-Win32ToolkitConfigValue, Function:\Get-Win32ToolkitGuestCredential, Function:\Read-Host
function Get-Win32ToolkitHyperVLane { param($VMName, $CheckpointName, $VM) }
function Get-Win32ToolkitZipContentHash { param($ZipPath) }

if ($fail -eq 0) {
    Write-Host "`nAll HyperVProvider tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$fail HyperVProvider test(s) failed." -ForegroundColor Red
    exit 1
}
