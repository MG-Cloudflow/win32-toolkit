<#
    Repair-Win32ToolkitTestVMCheckpoint — the TUI's "Configure guest AutoLogon + re-checkpoint" action.
    Regression suite for the field bug where a half-provisioned VM (exists, but NO clean-base checkpoint
    and NO stored guest credential — what an interrupted New-Win32ToolkitTestVM leaves) made the repair
    screen throw 'No guest credential is configured' / 'checkpoint not found' instead of repairing.

    Every Hyper-V cmdlet + toolkit helper is shadowed; no VM, no host mutation, no real prompt. Asserts:
    the missing-credential PROMPT path (and that a typed credential is persisted only AFTER
    Wait-Win32ToolkitVMReady proves it — never on a gate failure), revert-vs-boot selection by checkpoint
    presence, the ordered repair sequence, the desktop-unreachable $false path (no checkpoint frozen),
    and the VM-missing guard.

    Run:  pwsh -File Tests\TestVMCheckpointRepair.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Repair-Win32ToolkitTestVMCheckpoint.ps1')

# --- shadowed toolkit + Hyper-V surface, logging the call sequence --------------------------------
$script:calls      = @()
$script:cfg        = @{}
$script:vmExists   = $true
$script:vmState    = 'Running'
$script:cpExists   = $false
$script:storedCred = $null       # what Get-Win32ToolkitGuestCredential "has on disk"
$script:desktopUp  = $true
$script:waitThrows = $false

$typedCred = [pscredential]::new('w32admin', (ConvertTo-SecureString 'p' -AsPlainText -Force))

function Log($s) { $script:calls += $s }

function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
function Set-Win32ToolkitConfigValue { param($Name, $Value) $script:cfg[$Name] = "$Value"; Log "cfg:$Name=$Value" }
function Get-Win32ToolkitGuestCredential { $script:storedCred }
function Get-Win32ToolkitGuestCredentialInteractive { param($UserName, $Message) Log 'Prompt'; $typedCred }
function Set-Win32ToolkitGuestCredential { param($Credential) Log 'PersistCred' }
function Clear-Win32ToolkitHyperVStateCache { Log 'ClearCache' }
function Reset-Win32ToolkitTestVM { param($Name, $CheckpointName) Log 'Reset' }
function Wait-Win32ToolkitVMReady { param($VMName, $Credential) Log 'Wait'; if ($script:waitThrows) { throw "Heartbeat not 'OK' within 300 s" }; $true }
function Set-Win32ToolkitGuestAutoLogon { param($VMName, $Credential) Log 'AutoLogon' }
function Confirm-Win32ToolkitGuestDesktop { param($VMName, $Credential) Log 'ConfirmDesktop'; $script:desktopUp }

function Get-VM { param($Name, $ErrorAction) if ($script:vmExists) { [pscustomobject]@{ Name = $Name; State = $script:vmState } } else { $null } }
function Get-VMCheckpoint { param($VMName, $Name, $ErrorAction) if ($script:cpExists) { [pscustomobject]@{ Name = 'clean-base' } } else { $null } }
# [Parameter()] makes this an ADVANCED function -> it gets the common -ErrorAction for free (declaring
# an explicit $ErrorAction alongside it is a "defined multiple times" bind error).
function Remove-VMCheckpoint { param([Parameter(ValueFromPipeline)]$InputObject) process { if ($null -ne $InputObject) { Log 'Remove-VMCheckpoint' } } }
function Start-VM { param($Name, $ErrorAction) Log 'Start-VM' }
function Set-VM { param($Name, $CheckpointType) Log "Set-VM:CheckpointType=$CheckpointType" }
function Checkpoint-VM { param($VMName, $SnapshotName) Log "Checkpoint-VM:$SnapshotName" }

# 6> silences the helper's Write-Host progress without eating the [bool] return value (Ok/Bad keep Write-Host).
function Run {
    $script:calls = @(); $script:cfg = @{}; $script:ret = $null; $script:err = $null
    try { $script:ret = Repair-Win32ToolkitTestVMCheckpoint 6>$null 3>$null } catch { $script:err = $_.Exception.Message }
}
function Index($needle) { [array]::IndexOf($script:calls, $needle) }

# ══ [1] THE FIELD BUG: VM exists + running, NO checkpoint, NO stored credential -> full repair ═════
Write-Host '[1] broken provision state (no checkpoint, no credential) repairs instead of throwing' -ForegroundColor Cyan
$script:vmExists = $true; $script:vmState = 'Running'; $script:cpExists = $false; $script:storedCred = $null; $script:desktopUp = $true
Run
if (-not $script:err -and $script:ret -eq $true) { Ok 'repairs and returns $true (no throw)' } else { Bad "err='$script:err' ret=$script:ret" }
if ($script:calls -contains 'Prompt') { Ok 'missing credential -> interactive prompt (not a dead-end throw)' } else { Bad 'never prompted' }
if (-not ($script:calls -contains 'Reset')) { Ok 'missing checkpoint -> no revert attempted' } else { Bad 'tried to revert to a checkpoint that does not exist' }
if (-not ($script:calls -contains 'Start-VM')) { Ok 'VM already running -> not re-started' } else { Bad 'started a running VM' }
$order = @('Prompt', 'Wait', 'PersistCred', 'AutoLogon', 'ConfirmDesktop', 'Set-VM:CheckpointType=Standard', 'Checkpoint-VM:clean-base')
$prev = -1; $inOrder = $true
foreach ($step in $order) { $i = Index $step; if ($i -lt 0 -or $i -lt $prev) { $inOrder = $false }; $prev = $i }
if ($inOrder) { Ok "ordered: $($order -join ' > ')" } else { Bad "sequence wrong: $($script:calls -join ' > ')" }
if ((Index 'PersistCred') -gt (Index 'Wait')) { Ok 'typed credential persisted only AFTER PowerShell Direct proved it' } else { Bad 'credential persisted before verification' }
if ($script:cfg['HyperVVMName'] -eq 'win32tk-golden' -and $script:cfg['HyperVCheckpoint'] -eq 'clean-base') { Ok 'VM + checkpoint identity re-affirmed in config' } else { Bad "cfg=$($script:cfg.Keys -join ',')" }
if ($script:calls -contains 'ClearCache') { Ok 'readiness cache invalidated (banner sees the repair immediately)' } else { Bad 'readiness cache never cleared' }

# ══ [2] same state but VM is OFF -> boots it (Start-VM), still no revert ═══════════════════════════
Write-Host '[2] no checkpoint + VM off -> cold-boots the VM instead of reverting' -ForegroundColor Cyan
$script:vmState = 'Off'
Run
if (-not $script:err -and ($script:calls -contains 'Start-VM') -and -not ($script:calls -contains 'Reset')) { Ok 'Start-VM called, Reset not called' } else { Bad "err='$script:err' calls=$($script:calls -join ',')" }
if ((Index 'Start-VM') -lt (Index 'Wait')) { Ok 'boots before waiting for readiness' } else { Bad 'waited before booting' }
$script:vmState = 'Running'

# ══ [3] healthy state (checkpoint + stored credential) -> classic revert path, no prompt ═══════════
Write-Host '[3] checkpoint + stored credential -> reverts, never prompts, re-checkpoints' -ForegroundColor Cyan
$script:cpExists = $true; $script:storedCred = $typedCred
Run
if (-not $script:err -and $script:ret -eq $true) { Ok 'succeeds' } else { Bad "err='$script:err' ret=$script:ret" }
if (($script:calls -contains 'Reset') -and -not ($script:calls -contains 'Start-VM')) { Ok 'reverts via Reset-Win32ToolkitTestVM' } else { Bad "calls=$($script:calls -join ',')" }
if (-not ($script:calls -contains 'Prompt') -and -not ($script:calls -contains 'PersistCred')) { Ok 'stored credential used as-is (no prompt, no re-persist)' } else { Bad 'prompted / re-persisted with a stored credential' }
if (($script:calls -contains 'Remove-VMCheckpoint') -and ($script:calls -contains 'Checkpoint-VM:clean-base')) { Ok 'old checkpoint dropped and re-taken' } else { Bad 'checkpoint not recreated' }

# ══ [4] typed credential + readiness gate fails -> throws and NEVER persists the credential ════════
Write-Host '[4] wrong typed password (Wait throws) -> credential is NOT saved' -ForegroundColor Cyan
$script:cpExists = $false; $script:storedCred = $null; $script:waitThrows = $true
Run
if ($script:err) { Ok "gate failure surfaces: $script:err" } else { Bad 'did not throw' }
if (-not ($script:calls -contains 'PersistCred')) { Ok 'unverified credential never persisted' } else { Bad 'stored a credential PowerShell Direct never accepted' }
if (-not ($script:calls | Where-Object { $_ -like 'Checkpoint-VM*' })) { Ok 'no checkpoint taken on a failed repair' } else { Bad 'checkpointed anyway' }
$script:waitThrows = $false

# ══ [5] desktop unreachable -> $false, credential still repaired, nothing frozen ═══════════════════
Write-Host '[5] desktop never reachable -> returns $false, does not freeze, keeps the verified credential' -ForegroundColor Cyan
$script:desktopUp = $false
Run
if (-not $script:err -and $script:ret -eq $false) { Ok 'returns $false (caller shows the log-in-once warning)' } else { Bad "err='$script:err' ret=$script:ret" }
if (-not ($script:calls | Where-Object { $_ -like 'Checkpoint-VM*' }) -and -not ($script:calls | Where-Object { $_ -like 'Set-VM:*' })) { Ok 'no checkpoint frozen without a desktop' } else { Bad 'froze a desktop-less state' }
if ($script:calls -contains 'PersistCred') { Ok 'the verified credential IS kept (half the repair sticks)' } else { Bad 'verified credential thrown away' }
$script:desktopUp = $true

# ══ [6] no VM at all -> clear guard ════════════════════════════════════════════════════════════════
Write-Host '[6] VM missing -> "provision it first" guard' -ForegroundColor Cyan
$script:vmExists = $false
Run
if ($script:err -like "*does not exist*") { Ok 'clear error pointing at provisioning' } else { Bad "err='$script:err'" }
if ($script:calls.Count -eq 0) { Ok 'nothing else ran' } else { Bad "calls=$($script:calls -join ',')" }
$script:vmExists = $true

Write-Host ''
if ($fail -eq 0) { Write-Host 'All TestVMCheckpointRepair tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TestVMCheckpointRepair test(s) FAILED." -ForegroundColor Red; exit 1 }
