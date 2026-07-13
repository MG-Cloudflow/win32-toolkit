<#
    Unit tests for Mount-Win32ToolkitIso — placeholder staging, in-place retry, and stage-on-failure.
    Disk cmdlets (Mount/Dismount-DiskImage, Get-Volume), Copy-Item, Get-Item and Start-Sleep are shadowed
    in-scope; nothing touches a real ISO or disk.

    Run:  pwsh -File Tests\MountIso.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Mount-Win32ToolkitIso.ps1')

# --- shared shadows -------------------------------------------------------------------------------
function Test-Path { param([Parameter(ValueFromPipeline)]$Path, [switch]$LiteralPath) $true }
function Start-Sleep { param($Seconds) }
function Dismount-DiskImage { param($ImagePath, $ErrorAction) }
function Copy-Item { param($LiteralPath, $Destination, [switch]$Force, $ErrorAction) $script:copies++ }
function Get-Volume { param([Parameter(ValueFromPipeline)]$InputObject) [pscustomobject]@{ DriveLetter = 'X' } }

# Attributes are set per-test via $script:attrs.
function Get-Item { param($LiteralPath) [pscustomobject]@{ Attributes = $script:attrs; Length = 100 } }
# Free space reported for the stage-directory drive; per-test override via $script:free.
$script:free = 500GB
function Get-PSDrive { param($Name, $ErrorAction) [pscustomobject]@{ Free = $script:free } }

Write-Host '[1] normal local ISO -> mounts in place, no staging' -ForegroundColor Cyan
$script:attrs = [System.IO.FileAttributes]::Archive; $script:copies = 0; $script:mountCalls = 0
function Mount-DiskImage { param($ImagePath, $StorageType, [switch]$PassThru, $ErrorAction) $script:mountCalls++; [pscustomobject]@{ ImagePath = $ImagePath } }
$r = Mount-Win32ToolkitIso -IsoPath 'C:\iso\win.iso'
if ($r.DriveLetter -eq 'X' -and $null -eq $r.StagedPath -and $script:copies -eq 0) { Ok 'in-place mount, no copy' } else { Bad "drive=$($r.DriveLetter) staged=$($r.StagedPath) copies=$script:copies" }

Write-Host '[2] OneDrive placeholder (Offline) -> stages first, then mounts the copy' -ForegroundColor Cyan
$script:attrs = [System.IO.FileAttributes]::Offline; $script:copies = 0
$r = Mount-Win32ToolkitIso -IsoPath 'C:\Users\me\Downloads\win.iso'
if ($r.DriveLetter -eq 'X' -and $r.StagedPath -and $r.ImagePath -eq $r.StagedPath -and $script:copies -eq 1) { Ok 'proactive stage + mount of staged copy' } else { Bad "staged=$($r.StagedPath) img=$($r.ImagePath) copies=$script:copies" }

Write-Host '[3] transient mount failure -> retries then succeeds (no staging)' -ForegroundColor Cyan
$script:attrs = [System.IO.FileAttributes]::Archive; $script:copies = 0; $script:n = 0
function Mount-DiskImage { param($ImagePath, $StorageType, [switch]$PassThru, $ErrorAction) $script:n++; if ($script:n -lt 2) { throw 'The semaphore timeout period has expired.' } [pscustomobject]@{ ImagePath = $ImagePath } }
$r = Mount-Win32ToolkitIso -IsoPath 'C:\iso\win.iso' -WarningAction SilentlyContinue
if ($r.DriveLetter -eq 'X' -and $null -eq $r.StagedPath -and $script:copies -eq 0) { Ok 'retry recovered without staging' } else { Bad "drive=$($r.DriveLetter) staged=$($r.StagedPath) copies=$script:copies n=$script:n" }

Write-Host '[4] in-place mount always fails -> stages a copy and retries the staged path' -ForegroundColor Cyan
$script:attrs = [System.IO.FileAttributes]::Archive; $script:copies = 0
# Fail every mount of the ORIGINAL path; succeed for any staged (temp) path.
function Mount-DiskImage {
    param($ImagePath, $StorageType, [switch]$PassThru, $ErrorAction)
    if ($ImagePath -like '*Downloads*') { throw 'The semaphore timeout period has expired.' }
    [pscustomobject]@{ ImagePath = $ImagePath }
}
$r = Mount-Win32ToolkitIso -IsoPath 'C:\Users\me\Downloads\win.iso' -MountRetries 2 -WarningAction SilentlyContinue
if ($r.DriveLetter -eq 'X' -and $r.StagedPath -and $script:copies -eq 1) { Ok 'stage-on-failure fallback works' } else { Bad "drive=$($r.DriveLetter) staged=$($r.StagedPath) copies=$script:copies" }

Write-Host '[5] -NoStage + persistent failure -> throws, never copies' -ForegroundColor Cyan
$script:attrs = [System.IO.FileAttributes]::Offline; $script:copies = 0
function Mount-DiskImage { param($ImagePath, $StorageType, [switch]$PassThru, $ErrorAction) throw 'The semaphore timeout period has expired.' }
$threw = $false
try { Mount-Win32ToolkitIso -IsoPath 'C:\iso\win.iso' -NoStage -MountRetries 2 -WarningAction SilentlyContinue | Out-Null }
catch { $threw = $true }
if ($threw -and $script:copies -eq 0) { Ok 'NoStage never stages and surfaces the error' } else { Bad "threw=$threw copies=$script:copies" }

Write-Host '[6] staged copy but staged mount fails -> throws AND deletes the temp copy (no leak)' -ForegroundColor Cyan
$script:attrs = [System.IO.FileAttributes]::Offline; $script:copies = 0; $script:removed = $null
function Remove-Item { param($LiteralPath, [switch]$Force, $ErrorAction) $script:removed = $LiteralPath }
function Mount-DiskImage { param($ImagePath, $StorageType, [switch]$PassThru, $ErrorAction) throw 'The semaphore timeout period has expired.' }
$threw = $false
try { Mount-Win32ToolkitIso -IsoPath 'C:\Users\me\Downloads\win.iso' -MountRetries 2 -WarningAction SilentlyContinue | Out-Null }
catch { $threw = $true }
if ($threw -and $script:copies -eq 1 -and $script:removed -like '*w32iso_*') { Ok 'staged temp copy cleaned up on failure' } else { Bad "threw=$threw copies=$script:copies removed=$script:removed" }

Write-Host '[7] full stage drive (Free = 0) -> friendly space error, no copy' -ForegroundColor Cyan
$script:attrs = [System.IO.FileAttributes]::Offline; $script:copies = 0; $script:free = 0
$msg = $null
try { Mount-Win32ToolkitIso -IsoPath 'C:\Users\me\Downloads\win.iso' -MountRetries 2 -WarningAction SilentlyContinue | Out-Null }
catch { $msg = $_.Exception.Message }
if ($msg -like 'Not enough free space*' -and $script:copies -eq 0) { Ok 'Free=0 trips the guard (not bypassed)' } else { Bad "msg=$msg copies=$script:copies" }
$script:free = 500GB

Write-Host '[8] mount succeeds but no drive letter -> retries then throws (-NoStage)' -ForegroundColor Cyan
$script:attrs = [System.IO.FileAttributes]::Archive; $script:m = 0
function Mount-DiskImage { param($ImagePath, $StorageType, [switch]$PassThru, $ErrorAction) $script:m++; [pscustomobject]@{ ImagePath = $ImagePath } }
function Get-Volume { param([Parameter(ValueFromPipeline)]$InputObject) [pscustomobject]@{ DriveLetter = $null } }
$threw = $false
try { Mount-Win32ToolkitIso -IsoPath 'C:\iso\win.iso' -NoStage -MountRetries 2 -WarningAction SilentlyContinue | Out-Null }
catch { $threw = $true }
if ($threw -and $script:m -eq 2) { Ok 'null drive letter -> retry loop -> throw' } else { Bad "threw=$threw mounts=$script:m" }
function Get-Volume { param([Parameter(ValueFromPipeline)]$InputObject) [pscustomobject]@{ DriveLetter = 'X' } }

Write-Host '[9] Copy-Item fails mid-stage -> partial temp deleted, no orphan (leak fix)' -ForegroundColor Cyan
$script:attrs = [System.IO.FileAttributes]::Offline; $script:removed = $null
function Remove-Item { param($LiteralPath, [switch]$Force, $ErrorAction) $script:removed = $LiteralPath }
function Copy-Item { param($LiteralPath, $Destination, [switch]$Force, $ErrorAction) throw 'Recall failed mid-copy.' }
$threw = $false
try { Mount-Win32ToolkitIso -IsoPath 'C:\Users\me\Downloads\win.iso' -MountRetries 2 -WarningAction SilentlyContinue | Out-Null }
catch { $threw = $true }
if ($threw -and $script:removed -like '*w32iso_*') { Ok 'partial staged copy removed on copy failure' } else { Bad "threw=$threw removed=$script:removed" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All MountIso tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail MountIso test(s) FAILED." -ForegroundColor Red; exit 1 }
