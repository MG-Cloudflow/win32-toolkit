<#
    Unit tests for Confirm-Win32ToolkitGuestInternet — probe / repair / retry decision logic.
    Invoke-Command (probe vs repair) and Start-Sleep are shadowed in-scope; no VM, no network.

    Run:  pwsh -File Tests\GuestInternet.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Confirm-Win32ToolkitGuestInternet.ps1')

$cred = [pscredential]::new('w32admin', (ConvertTo-SecureString 'p' -AsPlainText -Force))

# Probe calls have no -ArgumentList; repair calls do. Probe returns the next queued boolean.
$script:probes  = [System.Collections.Queue]::new()
$script:repairs = 0
function Invoke-Command {
    param($VMName, $Credential, [scriptblock]$ScriptBlock, $ArgumentList, $ErrorAction)
    if ($PSBoundParameters.ContainsKey('ArgumentList')) { $script:repairs++; return }
    return $script:probes.Dequeue()
}
function Start-Sleep { param($Seconds) }   # no-op so retries don't wait

Write-Host '[1] reachable on first probe -> true, no repair' -ForegroundColor Cyan
$script:probes = [System.Collections.Queue]::new((@($true))); $script:repairs = 0
$r = Confirm-Win32ToolkitGuestInternet -VMName vm -Credential $cred -TimeoutSeconds 60
if ($r -and $script:repairs -eq 0) { Ok 'returns true without repairing' } else { Bad "r=$r repairs=$script:repairs" }

Write-Host '[2] down then up -> repairs once, then true' -ForegroundColor Cyan
$script:probes = [System.Collections.Queue]::new((@($false, $true))); $script:repairs = 0
$r = Confirm-Win32ToolkitGuestInternet -VMName vm -Credential $cred -TimeoutSeconds 60 -Verbose:$false
if ($r -and $script:repairs -eq 1) { Ok 'repairs DHCP/DNS then confirms' } else { Bad "r=$r repairs=$script:repairs" }

Write-Host '[3] two failures then success -> repairs twice, then true' -ForegroundColor Cyan
$script:probes = [System.Collections.Queue]::new((@($false, $false, $true))); $script:repairs = 0
$r = Confirm-Win32ToolkitGuestInternet -VMName vm -Credential $cred -TimeoutSeconds 60
if ($r -and $script:repairs -eq 2) { Ok 'keeps repairing until reachable' } else { Bad "r=$r repairs=$script:repairs" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All GuestInternet tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail GuestInternet test(s) FAILED." -ForegroundColor Red; exit 1 }
