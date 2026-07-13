<#
    Unit tests for the pure/logic parts of the Hyper-V golden-image build (Phase 2). No Hyper-V, no ISO,
    no disk I/O — DISM/Storage/Hyper-V cmdlets are shadowed. The heavy host-only orchestrators
    (New-Win32ToolkitGoldenVhdx / New-Win32ToolkitTestVM / Reset / Remove) are parse-checked separately;
    their real bake runs on an elevated Hyper-V host.

    Run:  pwsh -File Tests\GoldenImage.unit.ps1
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
. (Join-Path $repo 'Private\Get-Win32ToolkitHyperVPaths.ps1')
. (Join-Path $repo 'Private\New-Win32ToolkitUnattendXml.ps1')
. (Join-Path $repo 'Private\Get-Win32ToolkitInstallImage.ps1')
. (Join-Path $repo 'Private\Wait-Win32ToolkitVMReady.ps1')
. (Join-Path $repo 'Private\Assert-Win32ToolkitVhdxDisk.ps1')

Write-Host '[1] Get-Win32ToolkitHyperVPaths' -ForegroundColor Cyan
$p = Get-Win32ToolkitHyperVPaths -BasePath 'C:\Win32Apps'
if ($p.Root     -eq 'C:\Win32Apps\HyperV')          { Ok 'Root under BasePath\HyperV' }        else { Bad "root=$($p.Root)" }
if ($p.Golden   -eq 'C:\Win32Apps\HyperV\Golden')   { Ok 'Golden tier' }                        else { Bad "golden=$($p.Golden)" }
if ($p.VMs      -eq 'C:\Win32Apps\HyperV\VMs')      { Ok 'VMs tier' }                           else { Bad "vms=$($p.VMs)" }
if ($p.Unattend -eq 'C:\Win32Apps\HyperV\Unattend') { Ok 'Unattend tier' }                      else { Bad "unattend=$($p.Unattend)" }
if ($p.ISO      -eq 'C:\Win32Apps\HyperV\ISO')      { Ok 'ISO tier' }                           else { Bad "iso=$($p.ISO)" }

Write-Host '[2] New-Win32ToolkitUnattendXml' -ForegroundColor Cyan
$cred = [pscredential]::new('.\w32admin', (ConvertTo-SecureString 'P@ss<w0rd>&''"' -AsPlainText -Force))
$xml  = New-Win32ToolkitUnattendXml -AdminCredential $cred -ComputerName 'GB01' -Locale 'en-GB' -LogonCount 5
$doc  = $null
try { $doc = [xml]$xml; Ok 'unattend parses as XML (hostile password still valid)' } catch { Bad "not well-formed: $($_.Exception.Message)" }
if ($doc) {
    $passes = @($doc.unattend.settings.pass)
    if ($passes -contains 'specialize' -and $passes -contains 'oobeSystem') { Ok 'has specialize + oobeSystem passes' } else { Bad "passes: $($passes -join ',')" }
    $oobe = $doc.SelectNodes("//*[local-name()='OOBE']")[0]
    if ($oobe.HideOnlineAccountScreens -eq 'true') { Ok 'HideOnlineAccountScreens=true (Win11 MSA skip)' } else { Bad 'MSA screen not hidden' }
    $la = $doc.SelectNodes("//*[local-name()='LocalAccount']")[0]
    if ($la.Name -eq 'w32admin') { Ok "LocalAccount Name is SAM-only ('.\\' stripped)" } else { Bad "name=$($la.Name)" }
    $al = $doc.SelectNodes("//*[local-name()='AutoLogon']")[0]
    if ($al.Username -eq 'w32admin' -and $al.Enabled -eq 'true' -and $al.LogonCount -eq '5') { Ok 'AutoLogon user/enabled/count' } else { Bad "autologon=$($al.Username)/$($al.Enabled)/$($al.LogonCount)" }
    # password round-trips (XML decode) and matches in both places
    $laPw = $la.Password.Value
    $alPw = $al.Password.Value
    if ($laPw -eq 'P@ss<w0rd>&''"' -and $alPw -eq $laPw) { Ok 'password XML-encoded, decodes back, matches account + autologon' } else { Bad "pw la=[$laPw] al=[$alPw]" }
    if ($doc.SelectNodes("//*[local-name()='ComputerName']")[0].InnerText -eq 'GB01') { Ok 'ComputerName set' } else { Bad 'computername' }
    if ($doc.SelectNodes("//*[local-name()='SystemLocale']")[0].InnerText -eq 'en-GB') { Ok 'locale set' } else { Bad 'locale' }
    if ($xml -notmatch 'SkipMachineOOBE') { Ok 'does not use the unreliable SkipMachineOOBE' } else { Bad 'uses SkipMachineOOBE' }
}
try { New-Win32ToolkitUnattendXml -AdminCredential ([pscredential]::new('w32admin', (New-Object System.Security.SecureString))) | Out-Null; Bad 'empty password NOT rejected (blocks PS Direct + AutoLogon)' }
catch { Ok 'empty password -> throws (blank pw breaks AutoLogon/PS Direct)' }

Write-Host '[3] Get-Win32ToolkitInstallImage' -ForegroundColor Cyan
$src = Join-Path $env:SystemDrive 'sources'   # use an existing drive so Join-Path can resolve the provider
$script:haveWim = $true; $script:haveEsd = $false
function Test-Path { param([string]$LiteralPath, [Parameter(ValueFromRemainingArguments = $true)]$rest)
    if ($LiteralPath -like '*install.wim') { return $script:haveWim }
    if ($LiteralPath -like '*install.esd') { return $script:haveEsd }
    return $false
}
# Consumer multi-edition ISO (Home first, Pro later) — the real case that picked Home before the fix.
$script:images = @(
    [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Home' },
    [pscustomobject]@{ ImageIndex = 6; ImageName = 'Windows 11 Pro' },
    [pscustomobject]@{ ImageIndex = 7; ImageName = 'Windows 11 Pro N' }
)
function Get-WindowsImage { param([string]$ImagePath) $script:images }

$img = Get-Win32ToolkitInstallImage -SourcesPath $src
if ($img.Format -eq 'wim' -and $img.ImagePath -like '*install.wim') { Ok 'detects install.wim' } else { Bad "path=$($img.ImagePath) fmt=$($img.Format)" }
if ($img.Index -eq 6 -and $img.ImageName -eq 'Windows 11 Pro') { Ok "default prefers 'Windows 11 Pro' (NOT Home/Index:1)" } else { Bad "sel=$($img.Index)/$($img.ImageName)" }
$imgH = Get-Win32ToolkitInstallImage -SourcesPath $src -EditionPreference 'Home'
if ($imgH.Index -eq 1) { Ok '-EditionPreference Home forces Home' } else { Bad "home=$($imgH.Index)" }
$img2 = Get-Win32ToolkitInstallImage -SourcesPath $src -ImageIndex 7
if ($img2.Index -eq 7) { Ok 'explicit -ImageIndex honored' } else { Bad "idx=$($img2.Index)" }
try { Get-Win32ToolkitInstallImage -SourcesPath $src -ImageIndex 99 | Out-Null; Bad 'missing index did not throw' } catch { Ok 'missing index -> throws (lists available)' }

# Enterprise-eval ISO (no Pro) — the priority list must fall through to Enterprise.
$script:images = @([pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Enterprise Evaluation' })
$imgE = Get-Win32ToolkitInstallImage -SourcesPath $src
if ($imgE.Index -eq 1 -and $imgE.ImageName -match 'Enterprise') { Ok 'eval ISO: default falls through to Enterprise' } else { Bad "eval=$($imgE.Index)/$($imgE.ImageName)" }

$script:haveWim = $false; $script:haveEsd = $true
$img3 = Get-Win32ToolkitInstallImage -SourcesPath $src
if ($img3.Format -eq 'esd' -and $img3.ImagePath -like '*install.esd') { Ok 'falls back to install.esd' } else { Bad "esd path=$($img3.ImagePath)" }
$script:haveWim = $false; $script:haveEsd = $false
try { Get-Win32ToolkitInstallImage -SourcesPath $src | Out-Null; Bad 'no media did not throw' } catch { Ok 'no wim/esd -> throws' }
Remove-Item Function:\Test-Path, Function:\Get-WindowsImage

Write-Host '[4] Wait-Win32ToolkitVMReady' -ForegroundColor Cyan
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }   # no-op
function Get-VMIntegrationService { param([string]$VMName, [string]$Name, $ErrorAction) [pscustomobject]@{ PrimaryStatusDescription = $script:hb } }
function Invoke-Command { param($VMName, $Credential, [scriptblock]$ScriptBlock, $ErrorAction)
    $s = "$ScriptBlock"
    if ($s -match 'Get-ExecutionPolicy') { return 'RemoteSigned' }
    if ($s -match 'Set-ExecutionPolicy') { return }
    return $true
}
$vmCred = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
$script:hb = 'OK'
if ((Wait-Win32ToolkitVMReady -VMName x -Credential $vmCred -HeartbeatTimeoutSec 5 -PSDirectTimeoutSec 5) -eq $true) { Ok 'all gates ready -> $true' } else { Bad 'ready path failed' }
$script:hb = 'Lost Communication'
try { Wait-Win32ToolkitVMReady -VMName x -Credential $vmCred -HeartbeatTimeoutSec 0.2 -PSDirectTimeoutSec 0.2 | Out-Null; Bad 'no heartbeat did not throw' } catch { if ("$_" -match 'Heartbeat') { Ok 'heartbeat timeout -> throws' } else { Bad "$_" } }
$script:hb = 'OK'
function Invoke-Command { param($VMName, $Credential, [scriptblock]$ScriptBlock, $ErrorAction) throw 'a remote session might have ended' }
try { Wait-Win32ToolkitVMReady -VMName x -Credential $vmCred -HeartbeatTimeoutSec 5 -PSDirectTimeoutSec 0.2 | Out-Null; Bad 'PS-Direct timeout did not throw' } catch { if ("$_" -match 'PowerShell Direct') { Ok 'PS-Direct timeout -> throws' } else { Bad "$_" } }
Remove-Item Function:\Start-Sleep, Function:\Get-VMIntegrationService, Function:\Invoke-Command

Write-Host '[5] Assert-Win32ToolkitVhdxDisk (data-loss guard)' -ForegroundColor Cyan
if ((Assert-Win32ToolkitVhdxDisk -Disk ([pscustomobject]@{ Number = 7; BusType = 'File Backed Virtual' })) -eq 7) { Ok 'mounted VHDX -> returns disk number' } else { Bad 'file-backed not accepted' }
try { Assert-Win32ToolkitVhdxDisk -Disk ([pscustomobject]@{ Number = 0; BusType = 'SATA' }) | Out-Null; Bad 'physical disk NOT refused (DATA-LOSS RISK)' } catch { if ("$_" -match 'not a mounted VHDX') { Ok 'physical disk -> refused (guard holds)' } else { Bad "$_" } }

if ($fail -eq 0) {
    Write-Host "`nAll GoldenImage unit tests passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n$fail GoldenImage test(s) failed." -ForegroundColor Red
    exit 1
}
