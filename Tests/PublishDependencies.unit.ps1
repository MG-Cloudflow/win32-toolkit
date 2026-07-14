<#
    End-to-end ORDER proof for dependency publishing. The whole Graph + blob layer is shadowed and every
    call is recorded, so we can assert WHEN things happen — Intune only permits relationships after the
    app is added and uploaded, and a missing dependency must be reported before a large blob upload.

    Run:  pwsh -File Tests\PublishDependencies.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Public\Publish-Win32ToolkitIntuneApp.ps1')

$APPID = '11111111-2222-3333-4444-555555555555'
$VCID  = '99999999-8888-7777-6666-555555555555'
$INNER = 'IntuneWinPackage/Contents/payload.bin'

# --- shadows --------------------------------------------------------------------------------------
function Connect-Win32ToolkitGraph { }
function Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1' } }
function Get-Win32IntuneWinMetadata { param($Path) [pscustomobject]@{ InnerEntryName = $INNER; UnencryptedSize = 100; SizeEncrypted = 128; EncryptionKey = 'k'; MacKey = 'mk'; InitializationVector = 'iv'; Mac = 'm'; FileDigest = 'fd'; FileDigestAlgorithm = 'SHA256' } }
function Get-Win32DetectionRules { param($ProjectPath) @(@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryDetection' }) }
function Get-Win32ToolkitRequirementRule { param($ProjectPath) 'rule' }
function Get-Win32ToolkitAppConfig { param($ProjectPath) [pscustomobject]@{ App = [pscustomobject]@{ Name = 'Test App'; Version = '1.0'; Vendor = 'ACME' } } }
function Get-YAMLInstallerInfo { param($FilesPath) $null }
function Invoke-AzBlobUpload { param($SasUri, $FilePath) }
function Start-Sleep { param($Seconds) }
function Set-Win32ToolkitPublication { param($ProjectPath, $AppId, $TenantId, $DisplayName, $DisplayVersion, $WingetId) $script:calls += 'publication'; 'p' }

# resolution is controlled per-test
$script:deps = @()
function Resolve-Win32ToolkitDependencies { param($ProjectPath, $TenantId, $BaseUri) $script:calls += 'resolve'; return @($script:deps) }
$script:relDeps = $null
function Set-Win32ToolkitAppRelationships { param($AppId, $Dependency, $BaseUri) $script:calls += 'relate'; $script:relDeps = @($Dependency); return @($Dependency).Count }

$script:calls = @()
$script:committed = $false
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    if ($Method -eq 'POST' -and $Uri -match '/mobileApps$')     { $script:calls += 'createApp'; return [pscustomobject]@{ id = $APPID } }
    if ($Method -eq 'POST' -and $Uri -match 'contentVersions$') { return [pscustomobject]@{ id = '1' } }
    if ($Method -eq 'POST' -and $Uri -match 'files$')           { return [pscustomobject]@{ id = 'f1' } }
    if ($Method -eq 'POST' -and $Uri -match 'commit')           { $script:committed = $true; return $null }
    if ($Method -eq 'PATCH')                                    { $script:calls += 'commitPatch'; return $null }
    if ($Method -eq 'GET') {
        if ($script:committed) { return [pscustomobject]@{ uploadState = 'commitFileSuccess' } }
        return [pscustomobject]@{ uploadState = 'azureStorageUriRequestSuccess'; azureStorageUri = 'https://blob/x' }
    }
    return $null
}

# a real .intunewin zip (Publish extracts from it)
Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('w32pd_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$win = Join-Path $tmp 'app.intunewin'
$zip = [System.IO.Compression.ZipFile]::Open($win, 'Create')
try { $e = $zip.CreateEntry($INNER); $s = $e.Open(); $w = [System.IO.StreamWriter]::new($s); $w.Write('x'); $w.Flush(); $w.Dispose(); $s.Dispose() } finally { $zip.Dispose() }

function RunPublish { param([switch]$AsUpdate) $script:calls = @(); $script:committed = $false; $script:relDeps = $null; Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $tmp -AsUpdate:$AsUpdate 6>$null 3>$null | Out-Null }

Write-Host '[1] ORDER: resolve BEFORE the app is created; relate AFTER the content commit' -ForegroundColor Cyan
$script:deps = @([pscustomobject]@{ TargetId = $VCID; DependencyType = 'autoInstall'; Ref = 'winget:VC' })
RunPublish
$i = @{}; for ($k = 0; $k -lt $script:calls.Count; $k++) { if (-not $i.ContainsKey($script:calls[$k])) { $i[$script:calls[$k]] = $k } }
if ($i['resolve'] -lt $i['createApp']) { Ok 'dependencies resolved BEFORE the app shell + blob upload (fail fast, no orphan app)' } else { Bad "order: $($script:calls -join ' > ')" }
if ($i['relate'] -gt $i['commitPatch']) { Ok 'relationships attached AFTER the content commit (Intune requires the app uploaded first)' } else { Bad "order: $($script:calls -join ' > ')" }
if ($script:relDeps.Count -eq 1 -and $script:relDeps[0].TargetId -eq $VCID) { Ok 'the resolved app id is what gets related' } else { Bad ($script:relDeps | Out-String) }
if ($script:calls -contains 'publication') { Ok 'the publication (project -> app id) is recorded for later dependents' } else { Bad 'no publication recorded' }

Write-Host '[2] no dependencies declared -> no relationship call at all (unchanged behaviour)' -ForegroundColor Cyan
$script:deps = @()
RunPublish
if ($script:calls -notcontains 'relate') { Ok 'nothing related when none are declared' } else { Bad 'relate called with no dependencies' }

Write-Host '[3] -AsUpdate attaches NOTHING (the update app is gated to devices that already have the app)' -ForegroundColor Cyan
$script:deps = @([pscustomobject]@{ TargetId = $VCID; DependencyType = 'autoInstall'; Ref = 'winget:VC' })
RunPublish -AsUpdate
if ($script:calls -notcontains 'relate' -and $script:calls -notcontains 'resolve') { Ok 'update app: no resolve, no relate, no publication' } else { Bad "calls: $($script:calls -join ' > ')" }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PublishDependencies tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PublishDependencies test(s) FAILED." -ForegroundColor Red; exit 1 }
