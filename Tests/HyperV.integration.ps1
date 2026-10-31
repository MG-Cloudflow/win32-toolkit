<#
    OPT-IN live integration test for the Hyper-V test/capture backend. Requires a real, provisioned
    'clean-base' VM (New-Win32ToolkitTestVM) and an ELEVATED session. It is SKIPPED unless the env var
    W32T_LIVE_HYPERV is set, so it never runs in normal/CI passes.

    What it proves end-to-end: Invoke-Win32ToolkitHyperVRun performs revert → copy project in →
    run a phase over PowerShell Direct → copy the requested output back → revert. We write a unique
    sentinel inside the guest and assert it lands under the host project, and that the phase itself
    exited 0 (no 'Guest phase ... exited with code' / 'did not finish' / 'Hyper-V run failed' warning).

    Exit codes: 0 = PASS, 1 = FAIL, 3 = SKIP (Run-All reports SKIP, never PASS): not gated in, not
    elevated, or the Hyper-V backend is not ready.

    Run:  $env:W32T_LIVE_HYPERV=1; pwsh -File Tests\HyperV.integration.ps1
#>
[CmdletBinding()]
param()

if (-not $env:W32T_LIVE_HYPERV) {
    Write-Host 'SKIP: set W32T_LIVE_HYPERV=1 to run (needs a provisioned clean-base VM + an elevated session).' -ForegroundColor Yellow
    exit 3
}

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

# Load the module's private functions (the provider + its helpers) the same way the loader does.
Get-ChildItem -Path (Join-Path $repo 'Private') -Filter '*.ps1' -File | ForEach-Object { . $_.FullName }

if (-not (Test-Win32ToolkitElevated)) { Write-Host 'SKIP: not elevated.' -ForegroundColor Yellow; exit 3 }
$reasons = @(Test-Win32ToolkitHyperVReady)
if ($reasons.Count -gt 0) {
    Write-Host "SKIP: Hyper-V backend not ready — $($reasons -join '; ')" -ForegroundColor Yellow
    exit 3
}

# A throwaway project with a Documentation folder; the phase writes a unique sentinel there in the guest.
$proj = Join-Path ([System.IO.Path]::GetTempPath()) ('w32hvlive_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $proj 'Documentation') -Force | Out-Null
$sentinel = 'sentinel_' + [guid]::NewGuid().ToString('N').Substring(0, 12)

Write-Host "[1] revert -> copy-in -> run phase -> copy-out (sentinel '$sentinel')" -ForegroundColor Cyan
try {
    $ran = Invoke-Win32ToolkitHyperVRun -ProjectPath $proj -Phase @(
        @{ Label = 'Write sentinel'; Command = "Set-Content -LiteralPath 'C:\PSADT\Documentation\$sentinel.txt' -Value 'ok' -Encoding ASCII" }
    ) -Output @("Documentation\$sentinel.txt") -WarningVariable hvWarn

    $landed = Join-Path $proj "Documentation\$sentinel.txt"
    if ($ran -and (Test-Path -LiteralPath $landed)) { Ok 'sentinel written in the guest was copied back to the host project' }
    else { Bad "ran=$ran; sentinel present on host = $(Test-Path -LiteralPath $landed)" }
    # The sentinel can land even when the phase was cut short; the phase's own result must be clean too.
    $phaseWarn = @($hvWarn | Where-Object { "$_" -match "^Guest phase '.*' (exited with code|did not finish)" -or "$_" -like 'Hyper-V run failed*' })
    if ($phaseWarn.Count -eq 0) { Ok 'guest phase exited 0 (no exit-code warning)' } else { Bad "guest phase warning(s): $($phaseWarn -join ' | ')" }
}
catch { Bad "live run threw: $($_.Exception.Message)" }
finally { Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail -eq 0) { Write-Host 'HyperV live integration test PASSED.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail HyperV live integration check(s) FAILED." -ForegroundColor Red; exit 1 }
