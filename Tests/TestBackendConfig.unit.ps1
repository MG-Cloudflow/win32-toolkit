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
. (Join-Path $repo 'Private\Get-Win32ToolkitBasePath.ps1')
# C-9 (speed-up PR 3): the resolver (and its safe-text helper) the readiness check and the backend use; no pin leaks in.
. (Join-Path $repo 'Private\Get-Win32ToolkitHyperVTarget.ps1')
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitSafeText.ps1')
Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue

Write-Host '[0] an absent optional config value leaves no error record (test campaign 2026-10-21)' -ForegroundColor Cyan
# READ-ONLY against the real HKCU key: on a host with the key this is the absent-VALUE path, on a clean
# CI runner the absent-KEY path. Nothing is written. The reads run inside an advanced function so its
# -ErrorVariable sees what a caller would.
function Invoke-CfgProbe { [CmdletBinding()] param([string]$Name) Get-Win32ToolkitConfigValue -Name $Name -Default 'dflt' }
$absent = 'W32T_NoSuch_' + [guid]::NewGuid().ToString('N')
$Error.Clear()
$ev = $null
$r0 = Invoke-CfgProbe -Name $absent -ErrorVariable ev
if ($r0 -eq 'dflt') { Ok 'absent value -> -Default' } else { Bad "returned '$r0'" }
if (@($ev).Count -eq 0) { Ok 'the caller''s -ErrorVariable stays empty' } else { Bad "ErrorVariable: $(@($ev | ForEach-Object { "$_" }) -join ' | ')" }
if ($Error.Count -eq 0) { Ok '$Error does not grow (no TerminatingError(Get-ItemProperty) in a transcript)' } else { Bad "`$Error: $(@($Error | ForEach-Object { "$_" }) -join ' | ')" }

# The value read itself, against a fake key (no registry writes): present / DWORD / blank / unreadable.
$script:fakeVals = @{ Str = 'C:\Packaging'; Dword = 5; Blank = '  ' }
function Get-Item { param([string]$LiteralPath, $ErrorAction)
    $o = [pscustomobject]@{}
    $o | Add-Member -MemberType ScriptMethod -Name GetValue -Value { param($n) if ($n -eq 'Boom') { throw [System.Security.SecurityException]::new('denied') }; $script:fakeVals[$n] }
    $o | Add-Member -MemberType ScriptMethod -Name Close -Value { $script:closed++ }
    $o
}
$script:closed = 0
if ((Get-Win32ToolkitConfigValue -Name 'Str' -Default 'd') -eq 'C:\Packaging') { Ok 'present value round-trips' } else { Bad 'present value lost' }
if ((Get-Win32ToolkitConfigValue -Name 'Dword' -Default 'd') -eq '5') { Ok 'DWORD value comes back as a string' } else { Bad 'DWORD value lost' }
if ((Get-Win32ToolkitConfigValue -Name 'Blank' -Default 'd') -eq 'd') { Ok 'blank value -> -Default' } else { Bad 'blank value not defaulted' }
if ((Get-Win32ToolkitConfigValue -Name 'Boom' -Default 'd') -eq 'd') { Ok 'unreadable value -> -Default (fail-open)' } else { Bad 'unreadable value not defaulted' }
if ($script:closed -eq 4) { Ok 'the key handle is closed after every read' } else { Bad "closed $($script:closed) of 4" }
$script:fakeVals = @{ BasePath = 'D:\W32' }
if ((Get-Win32ToolkitBasePath -NonInteractive) -eq 'D:\W32') { Ok 'BasePath: stored value read the same way' } else { Bad 'BasePath stored value lost' }
$script:fakeVals = @{}
$Error.Clear()
function Invoke-BaseProbe { [CmdletBinding()] param() Get-Win32ToolkitBasePath -NonInteractive }
$ev = $null
$rb = Invoke-BaseProbe -ErrorVariable ev
if ($null -eq $rb -and @($ev).Count -eq 0 -and $Error.Count -eq 0) { Ok 'BasePath: absent value -> $null with no error record' } else { Bad "BasePath absent: '$rb' ev=$(@($ev).Count) err=$($Error.Count)" }
Remove-Item Function:\Get-Item

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

Write-Host '[4] (speed-up PR 3, D11) a VM pinned by W32T_HYPERV_VM that is not ready: W32T.HyperVTargetNotReady, never the Sandbox fallback' -ForegroundColor Cyan
$script:cfgBackend = 'HyperV'
function Get-Win32ToolkitConfigValue { param([string]$Name, [string]$Default) if ($Name -eq 'TestBackend') { return $script:cfgBackend } return $Default }
$script:hvReasons = @()
function Test-Win32ToolkitHyperVReady { return $script:hvReasons }
$probe4 = {
    param([hashtable]$Splat = @{})
    $r = $null; $threw = $null; $w = $null
    try { $r = Get-Win32ToolkitTestBackend @Splat -WarningVariable w 3>$null } catch { $threw = $_ }
    [pscustomobject]@{ R = $r; Threw = $threw; Warnings = @($w | ForEach-Object { "$_" }) }
}
try {
    $env:W32T_HYPERV_VM = 'lane-vm'
    foreach ($case in @(@{ Tag = '-Backend HyperV'; Splat = @{ Backend = 'HyperV' } }, @{ Tag = 'TestBackend HyperV (config)'; Splat = @{} })) {
        $script:hvReasons = @("VM 'lane-vm' not found", 'guest credential is not configured')
        $x = & $probe4 $case.Splat
        $want = "The test VM pinned by W32T_HYPERV_VM ('lane-vm') is not ready (VM 'lane-vm' not found; guest credential is not configured); the test was not started. Fix the VM or remove the pin."
        if ($x.Threw.FullyQualifiedErrorId -eq 'W32T.HyperVTargetNotReady' -and $x.Threw.CategoryInfo.Category -eq 'ResourceUnavailable' -and "$($x.Threw)" -ceq $want -and $x.Warnings.Count -eq 0 -and $null -eq $x.R) {
            Ok "pinned + not ready, $($case.Tag): throws W32T.HyperVTargetNotReady naming the VM and the reasons (no fallback warning)"
        } else { Bad "$($case.Tag): r=$($x.R) threw=$($x.Threw.FullyQualifiedErrorId) $($x.Threw) warnings=$($x.Warnings -join ' | ')" }
    }
    $x = & $probe4 @{ Backend = 'HyperV'; NoPinThrow = $true }
    if (-not $x.Threw -and $x.R -eq 'Sandbox' -and $x.Warnings.Count -eq 1) { Ok '-NoPinThrow (display): Sandbox with the usual warning, no throw' } else { Bad "nopinthrow: r=$($x.R) threw=$($x.Threw)" }
    $script:hvReasons = @()
    $x = & $probe4 @{ Backend = 'HyperV' }
    if (-not $x.Threw -and $x.R -eq 'HyperV') { Ok 'pinned + ready: HyperV' } else { Bad "pinned ready: $($x.R) $($x.Threw)" }
    $x = & $probe4 @{ Backend = 'Sandbox' }
    if (-not $x.Threw -and $x.R -eq 'Sandbox') { Ok 'pinned, -Backend Sandbox: Sandbox (the pin is for Hyper-V runs only)' } else { Bad "pinned sandbox: $($x.R) $($x.Threw)" }
    Remove-Item Env:\W32T_HYPERV_VM
    $script:hvReasons = @("VM 'win32tk-golden' not found")
    $x = & $probe4 @{ Backend = 'HyperV' }
    if (-not $x.Threw -and $x.R -eq 'Sandbox' -and $x.Warnings.Count -eq 1 -and $x.Warnings[0] -like 'Hyper-V test backend requested but not ready*falling back to Windows Sandbox.') { Ok 'not pinned + not ready: the Sandbox fallback and its warning, unchanged' } else { Bad "unpinned: $($x.R) $($x.Threw) $($x.Warnings -join ' | ')" }
    $env:W32T_HYPERV_CHECKPOINT = 'clean-auto'
    $x = & $probe4 @{ Backend = 'HyperV' }
    if (-not $x.Threw -and $x.R -eq 'Sandbox') { Ok 'a checkpoint pin alone does not pin the VM: the fallback stays' } else { Bad "cp pin: $($x.R) $($x.Threw)" }
    Remove-Item Env:\W32T_HYPERV_CHECKPOINT
    # An invalid pin: the readiness check reports it, the backend throws the resolver's error.
    $env:W32T_HYPERV_VM = '   '
    $script:hvReasons = @('W32T_HYPERV_VM is not a valid VM name (1 to 100 characters, no control character)')
    $x = & $probe4 @{ Backend = 'HyperV' }
    if ($x.Threw.FullyQualifiedErrorId -eq 'W32T.HyperVTargetNotReady' -and "$($x.Threw)" -like 'W32T_HYPERV_VM is not a valid VM name*') { Ok 'an invalid pin: W32T.HyperVTargetNotReady (the resolver''s message)' } else { Bad "invalid: $($x.Threw.FullyQualifiedErrorId) $($x.Threw)" }
    $script:cfgBackend = 'Sandbox'
    $x = & $probe4 @{}
    if (-not $x.Threw -and $x.R -eq 'Sandbox') { Ok 'an invalid pin with the Sandbox backend: Sandbox, no throw' } else { Bad "invalid sandbox: $($x.Threw)" }
}
finally { Remove-Item Env:\W32T_HYPERV_VM, Env:\W32T_HYPERV_CHECKPOINT -ErrorAction SilentlyContinue }
if ($fail -eq 0) {
    Write-Host "`nAll TestBackendConfig tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$fail TestBackendConfig test(s) failed." -ForegroundColor Red
    exit 1
}
