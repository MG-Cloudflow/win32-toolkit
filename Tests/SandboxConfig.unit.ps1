<#
    Unit tests for New-Win32ToolkitSandboxConfig — the shared .wsb builder (test-backend seam, Phase 0).
    No winget / no sandbox needed.

    Run:  pwsh -File Tests\SandboxConfig.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\ConvertTo-XmlEncoded.ps1')
. (Join-Path $repo 'Private\New-Win32ToolkitSandboxConfig.ps1')

Write-Host '[1] Single read-write mount (documentation / InstallUninstall shape)' -ForegroundColor Cyan
$logon = 'powershell.exe -NoExit -ExecutionPolicy Bypass -File C:\PSADT\SupportFiles\TargetedDocumentationScript.ps1'
$xml   = New-Win32ToolkitSandboxConfig -Mount @{ HostPath = 'C:\Win32Apps\Contoso\Git_x64_2.53.0'; GuestPath = 'C:\PSADT'; ReadOnly = $false } -LogonCommandXml $logon

$doc = $null
try { $doc = [xml]$xml; Ok 'output parses as well-formed XML' } catch { Bad "not well-formed XML: $($_.Exception.Message)" }
if ($doc) {
    if ($doc.Configuration.VGpu -eq 'Disable')       { Ok 'VGpu Disable' }        else { Bad "VGpu=$($doc.Configuration.VGpu)" }
    if ($doc.Configuration.Networking -eq 'Enable')  { Ok 'Networking Enable' }   else { Bad "Networking=$($doc.Configuration.Networking)" }
    $mf = @($doc.Configuration.MappedFolders.MappedFolder)
    if ($mf.Count -eq 1)                              { Ok 'one mapped folder' }  else { Bad "mounts=$($mf.Count)" }
    if ($mf[0].HostFolder -eq 'C:\Win32Apps\Contoso\Git_x64_2.53.0') { Ok 'host path preserved' } else { Bad "host=$($mf[0].HostFolder)" }
    if ($mf[0].SandboxFolder -eq 'C:\PSADT')         { Ok 'guest path C:\PSADT' } else { Bad "guest=$($mf[0].SandboxFolder)" }
    if ($mf[0].ReadOnly -eq 'false')                 { Ok 'ReadOnly false' }      else { Bad "ro=$($mf[0].ReadOnly)" }
    if ($doc.Configuration.LogonCommand.Command -eq $logon) { Ok 'LogonCommand emitted verbatim' } else { Bad "logon=$($doc.Configuration.LogonCommand.Command)" }
}

Write-Host '[2] Two mounts incl. read-only baseline (Update shape) + order preserved' -ForegroundColor Cyan
$mounts = @(
    @{ HostPath = 'C:\Win32Apps\Contoso\Git_x64_2.55.0'; GuestPath = 'C:\PSADT';    ReadOnly = $false },
    @{ HostPath = 'C:\Win32Apps\Contoso\Git_x64_2.53.0'; GuestPath = 'C:\PSADTOld'; ReadOnly = $true }
)
$doc2 = [xml](New-Win32ToolkitSandboxConfig -Mount $mounts -LogonCommandXml 'powershell.exe -Command &quot;exit&quot;')
$mf2  = @($doc2.Configuration.MappedFolders.MappedFolder)
if ($mf2.Count -eq 2) { Ok 'two mapped folders' } else { Bad "mounts=$($mf2.Count)" }
if ($mf2[0].SandboxFolder -eq 'C:\PSADT' -and $mf2[1].SandboxFolder -eq 'C:\PSADTOld') { Ok 'order preserved (project then baseline)' } else { Bad "order: $($mf2[0].SandboxFolder),$($mf2[1].SandboxFolder)" }
if ($mf2[1].ReadOnly -eq 'true')  { Ok 'baseline ReadOnly true' } else { Bad "baseline ro=$($mf2[1].ReadOnly)" }
if ($mf2[0].ReadOnly -eq 'false') { Ok 'project ReadOnly false' } else { Bad "project ro=$($mf2[0].ReadOnly)" }

Write-Host '[3] Host path with XML-special characters is encoded (untrusted-value contract)' -ForegroundColor Cyan
$xml3 = New-Win32ToolkitSandboxConfig -Mount @{ HostPath = 'C:\A & B <x>'; GuestPath = 'C:\PSADT'; ReadOnly = $false } -LogonCommandXml 'x'
if ($xml3 -match [regex]::Escape('C:\A &amp; B &lt;x&gt;')) { Ok 'host path XML-encoded in raw output' } else { Bad 'host path not encoded' }
$doc3 = [xml]$xml3
if (@($doc3.Configuration.MappedFolders.MappedFolder)[0].HostFolder -eq 'C:\A & B <x>') { Ok 'decodes back to original host path' } else { Bad 'decoded host path wrong' }

Write-Host '[4] Missing HostPath throws' -ForegroundColor Cyan
try { New-Win32ToolkitSandboxConfig -Mount @{ GuestPath = 'C:\PSADT' } -LogonCommandXml 'x' | Out-Null; Bad 'no throw on missing HostPath' }
catch { Ok 'missing HostPath throws' }

if ($fail -eq 0) {
    Write-Host "`nAll SandboxConfig tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$fail SandboxConfig test(s) failed." -ForegroundColor Red
    exit 1
}
