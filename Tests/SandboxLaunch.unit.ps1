<#
    Unit tests for the Sandbox test-backend launch primitives (no real sandbox launched).
    Shadows Get-Process / Start-Process to exercise the guard, launch, and dispatcher.

    Run:  pwsh -File Tests\SandboxLaunch.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Test-Win32ToolkitSandboxRunning.ps1')
. (Join-Path $repo 'Private\Start-Win32ToolkitSandbox.ps1')
. (Join-Path $repo 'Private\Invoke-Win32ToolkitTestRun.ps1')

Write-Host '[1] Test-Win32ToolkitSandboxRunning' -ForegroundColor Cyan
function Get-Process { param([string[]]$Name, $ErrorAction) @() }               # no sandbox
if (-not (Test-Win32ToolkitSandboxRunning)) { Ok 'no sandbox -> $false' } else { Bad 'false positive' }
function Get-Process { param([string[]]$Name, $ErrorAction) [pscustomobject]@{ Name = 'WindowsSandbox' } }  # running
if (Test-Win32ToolkitSandboxRunning) { Ok 'running sandbox -> $true' } else { Bad 'missed running sandbox' }
Remove-Item Function:\Get-Process

Write-Host '[2] Start-Win32ToolkitSandbox' -ForegroundColor Cyan
$script:started = $null
function Start-Process { param([string]$FilePath, [string[]]$ArgumentList, $ErrorAction) $script:started = @{ FilePath = $FilePath; Args = $ArgumentList } }
if ((Start-Win32ToolkitSandbox -ConfigPath 'C:\x\demo.wsb') -eq $true) { Ok 'launch success -> $true' } else { Bad 'launch success wrong' }
if ($script:started.FilePath -eq 'WindowsSandbox.exe') { Ok 'invokes WindowsSandbox.exe' } else { Bad "exe=$($script:started.FilePath)" }
if (@($script:started.Args) -contains '"C:\x\demo.wsb"') { Ok 'passes quoted config path' } else { Bad "args=$(@($script:started.Args) -join '|')" }
function Start-Process { param([string]$FilePath, [string[]]$ArgumentList, $ErrorAction) throw 'boom' }     # failure
if ((Start-Win32ToolkitSandbox -ConfigPath 'C:\x\demo.wsb' -WarningAction SilentlyContinue) -eq $false) { Ok 'launch failure -> $false (+warns)' } else { Bad 'failure not $false' }

Write-Host '[3] Invoke-Win32ToolkitTestRun dispatch (Sandbox)' -ForegroundColor Cyan
function Start-Process { param([string]$FilePath, [string[]]$ArgumentList, $ErrorAction) }                  # success
$r = Invoke-Win32ToolkitTestRun -Backend Sandbox -SandboxConfigPath 'C:\x\demo.wsb'
if ($r.Backend -eq 'Sandbox' -and $r.Launched -eq $true) { Ok 'dispatch -> Backend=Sandbox, Launched=$true' } else { Bad "dispatch: $($r | ConvertTo-Json -Compress)" }
function Start-Process { param([string]$FilePath, [string[]]$ArgumentList, $ErrorAction) throw 'boom' }     # failure
$r2 = Invoke-Win32ToolkitTestRun -Backend Sandbox -SandboxConfigPath 'C:\x\demo.wsb' -WarningAction SilentlyContinue
if ($r2.Launched -eq $false) { Ok 'dispatch surfaces launch failure (Launched=$false)' } else { Bad "dispatch failure: $($r2 | ConvertTo-Json -Compress)" }
Remove-Item Function:\Start-Process

Write-Host '[4] Invoke-Win32ToolkitTestRun rejects unknown backend' -ForegroundColor Cyan
try { Invoke-Win32ToolkitTestRun -Backend HyperV -SandboxConfigPath 'C:\x\demo.wsb' | Out-Null; Bad 'HyperV accepted (should be Phase 3)' }
catch { Ok 'unknown/not-yet backend rejected by ValidateSet' }

if ($fail -eq 0) {
    Write-Host "`nAll SandboxLaunch tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$fail SandboxLaunch test(s) failed." -ForegroundColor Red
    exit 1
}
