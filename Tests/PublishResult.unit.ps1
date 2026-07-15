<#
    Unit tests for the Publish result object (Intune dependencies, step 1).

    Publish-Win32ToolkitIntuneApp used to throw its app id away (it only ever reached a Write-Host), so
    nothing downstream could reference the app it had just created — which is exactly what an Intune
    dependency relationship needs. It now emits { AppId; DisplayName; IsUpdateApp; PortalUri }.

    The whole Graph + blob layer is shadowed; no tenant, no network.

    Run:  pwsh -File Tests\PublishResult.unit.ps1
    Exits non-zero on any failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Wait-Win32ToolkitUploadState.ps1')   # the SAS-URI / commit poller Publish now uses
. (Join-Path $repo 'Private\ConvertTo-Win32ToolkitPngBytes.ps1') # normalizes the tile icon
. (Join-Path $repo 'Private\Get-Win32ToolkitLargeIconBytes.ps1') # the app-tile icon (largeIcon) Publish now attaches
. (Join-Path $repo 'Public\Publish-Win32ToolkitIntuneApp.ps1')

$APPID = '11111111-2222-3333-4444-555555555555'

# --- shadow the entire Graph + packaging layer ----------------------------------------------------
function Connect-Win32ToolkitGraph { }
$INNER = 'IntuneWinPackage/Contents/payload.bin'
function Get-Win32IntuneWinMetadata {
    param($Path)
    [pscustomobject]@{
        InnerEntryName       = $INNER
        UnencryptedSize      = 100
        SizeEncrypted        = 128
        EncryptionKey        = 'k'
        MacKey               = 'mk'
        InitializationVector = 'iv'
        Mac                  = 'mac'
        FileDigest           = 'fd'
        FileDigestAlgorithm  = 'SHA256'
    }
}
function Get-Win32DetectionRules { param($ProjectPath) @(@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryDetection' }) }
# A real rule: Publish (rightly) refuses -AsUpdate without one, or the update app would hit every device.
function Get-Win32ToolkitRequirementRule { param($ProjectPath) 'if ($true) { "Installed" }' }
function Get-Win32ToolkitAppConfig { param($ProjectPath) [pscustomobject]@{ App = [pscustomobject]@{ DisplayName = 'Test App'; Version = '1.0'; Publisher = 'ACME' } } }
function Get-YAMLInstallerInfo { param($FilesPath) $null }
# Publish now resolves + attaches app dependencies and records the publication; this project declares none.
function Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1' } }
function Resolve-Win32ToolkitDependencies { param($ProjectPath, $TenantId, $BaseUri) @() }
function Set-Win32ToolkitAppRelationships { param($AppId, $Dependency, $BaseUri) 0 }
function Set-Win32ToolkitPublication { param($ProjectPath, $AppId, $TenantId, $DisplayName, $DisplayVersion, $WingetId) 'p' }
function Invoke-AzBlobUpload { param($SasUri, $FilePath) }
function Start-Sleep { param($Seconds) }
function Get-Content { param($Path, [switch]$Raw, $Encoding) '{}' }

# Stateful: the file GET is polled twice — first for the SAS URI, then (after the commit POST) for the
# commit result. Returning one fixed state makes the commit wait time out.
$script:committed = $false
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    if ($Method -eq 'POST' -and $Uri -match '/mobileApps$')      { return [pscustomobject]@{ id = $APPID } }
    if ($Method -eq 'POST' -and $Uri -match 'contentVersions$')  { return [pscustomobject]@{ id = '1' } }
    if ($Method -eq 'POST' -and $Uri -match 'files$')            { return [pscustomobject]@{ id = 'f1' } }
    if ($Method -eq 'POST' -and $Uri -match 'commit')            { $script:committed = $true; return $null }
    if ($Method -eq 'GET') {
        if ($script:committed) { return [pscustomobject]@{ uploadState = 'commitFileSuccess' } }
        return [pscustomobject]@{ uploadState = 'azureStorageUriRequestSuccess'; azureStorageUri = 'https://blob/x' }
    }
    return $null
}

# Publish opens the .intunewin as a REAL zip and extracts $meta.InnerEntryName — so build a valid one.
Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('w32pub_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$win = Join-Path $tmp 'app.intunewin'
$zip = [System.IO.Compression.ZipFile]::Open($win, 'Create')
try {
    $entry  = $zip.CreateEntry($INNER)
    $es     = $entry.Open()
    $writer = [System.IO.StreamWriter]::new($es)
    $writer.Write('payload'); $writer.Flush(); $writer.Dispose(); $es.Dispose()
}
finally { $zip.Dispose() }

Write-Host '[1] Publish EMITS exactly one result object carrying the app id' -ForegroundColor Cyan
$script:committed = $false
$out = @(Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $tmp 6>$null)
if ($out.Count -eq 1) { Ok 'exactly one object on the pipeline (no stray output)' } else { Bad "emitted $($out.Count) object(s)" }
if ($out[0].AppId -eq $APPID) { Ok 'AppId is the id Graph returned' } else { Bad "AppId=$($out[0].AppId)" }
if ($out[0].PSObject.Properties.Name -contains 'DisplayName' -and $out[0].PSObject.Properties.Name -contains 'PortalUri') { Ok 'carries DisplayName + PortalUri' } else { Bad 'missing DisplayName/PortalUri' }
if ($out[0].IsUpdateApp -eq $false) { Ok 'IsUpdateApp=false for the install app' } else { Bad "IsUpdateApp=$($out[0].IsUpdateApp)" }

Write-Host '[2] -AsUpdate flags the result (dependencies must NOT attach to the update app)' -ForegroundColor Cyan
$script:committed = $false
$outU = @(Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $tmp -AsUpdate 6>$null)
if ($outU[0].IsUpdateApp -eq $true) { Ok 'IsUpdateApp=true under -AsUpdate' } else { Bad "IsUpdateApp=$($outU[0].IsUpdateApp)" }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All PublishResult tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail PublishResult test(s) FAILED." -ForegroundColor Red; exit 1 }
