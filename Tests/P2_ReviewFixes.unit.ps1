<#
    Regression tests for the two defects an adversarial review found in the P2 sweep.

      [1] Publish-Win32ToolkitIntuneApp gained SupportsShouldProcess, but only the app-shell POST was wrapped
          in the guard. Under -WhatIf that one POST was skipped ($appId became $null) while EVERY later step
          (content version, file entry, blob upload, commit) still fired LIVE Graph requests against a null app
          id. So -WhatIf authenticated for real and mutated the tenant instead of previewing — worse than having
          no -WhatIf at all. The whole publish is now gated by a single ShouldProcess check up front.

      [2] New-Win32ToolkitTestVM's "already exists — reusing" fast path (a normal success outcome) was converted
          to Write-Warning, making the happy path look like a problem. Reverted to Write-Host. (Asserted at the
          source level — the reuse path needs a live Hyper-V host to exercise.)

    The Graph layer is shadowed; no tenant, no network.

    Run:  pwsh -File Tests\P2_ReviewFixes.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Wait-Win32ToolkitUploadState.ps1')
. (Join-Path $repo 'Public\Publish-Win32ToolkitIntuneApp.ps1')

$APPID = '11111111-2222-3333-4444-555555555555'

# --- shadow the Graph + packaging layer, counting the side-effecting calls ------------------------
$script:connected = $false
$script:graphCalls = 0
function Connect-Win32ToolkitGraph { $script:connected = $true }
$INNER = 'IntuneWinPackage/Contents/payload.bin'
function Get-Win32IntuneWinMetadata {
    param($Path)
    [pscustomobject]@{ InnerEntryName = $INNER; UnencryptedSize = 100; SizeEncrypted = 128; EncryptionKey = 'k'
        MacKey = 'mk'; InitializationVector = 'iv'; Mac = 'mac'; FileDigest = 'fd'; FileDigestAlgorithm = 'SHA256' }
}
function Get-Win32DetectionRules { param($ProjectPath) @(@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryDetection' }) }
function Get-Win32ToolkitAppConfig { param($ProjectPath) [pscustomobject]@{ App = [pscustomobject]@{ DisplayName = 'Test App'; Version = '1.0'; Publisher = 'ACME' } } }
function Get-YAMLInstallerInfo { param($FilesPath) $null }
function Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1' } }
function Resolve-Win32ToolkitDependencies { param($ProjectPath, $TenantId, $BaseUri) @() }
function Set-Win32ToolkitAppRelationships { param($AppId, $Dependency, $BaseUri) 0 }
function Set-Win32ToolkitPublication { param($ProjectPath, $AppId, $TenantId, $DisplayName, $DisplayVersion, $WingetId) 'p' }
function Invoke-AzBlobUpload { param($SasUri, $FilePath) }
function Start-Sleep { param($Seconds) }
function Get-Content { param($Path, [switch]$Raw, $Encoding) '{}' }

$script:committed = $false
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    $script:graphCalls++
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

Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('w32p2_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$win = Join-Path $tmp 'app.intunewin'
$zip = [System.IO.Compression.ZipFile]::Open($win, 'Create')
try { $e = $zip.CreateEntry($INNER); $s = $e.Open(); $w = [System.IO.StreamWriter]::new($s); $w.Write('payload'); $w.Flush(); $w.Dispose(); $s.Dispose() }
finally { $zip.Dispose() }

Write-Host '[1] -WhatIf is a TRUE dry run: no auth, no Graph writes, no output object' -ForegroundColor Cyan
$script:connected = $false; $script:graphCalls = 0; $script:committed = $false
$outWhatIf = @(Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $tmp -WhatIf 6>$null)
if ($script:graphCalls -eq 0) { Ok 'ZERO Invoke-MgGraphRequest calls under -WhatIf (was: fired live POSTs against a null app id)' }
else { Bad "$($script:graphCalls) live Graph call(s) made under -WhatIf" }
if (-not $script:connected) { Ok 'did NOT authenticate to Graph under -WhatIf' } else { Bad 'authenticated to Graph under -WhatIf' }
if ($outWhatIf.Count -eq 0) { Ok 'emits no published-app object under -WhatIf' } else { Bad "emitted $($outWhatIf.Count) object(s) under -WhatIf" }

Write-Host '[2] a normal run still publishes (positive control)' -ForegroundColor Cyan
$script:connected = $false; $script:graphCalls = 0; $script:committed = $false
$out = @(Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $tmp 6>$null)
if ($script:connected) { Ok 'authenticates on a real run' } else { Bad 'did not authenticate on a real run' }
if ($script:graphCalls -ge 4) { Ok "makes the full sequence of Graph calls ($($script:graphCalls))" } else { Bad "only $($script:graphCalls) Graph call(s) on a real run" }
if ($out.Count -eq 1 -and $out[0].AppId -eq $APPID) { Ok 'returns the published-app object with the real app id' } else { Bad 'no/incorrect result object on a real run' }

Write-Host '[3] New-Win32ToolkitTestVM reuse path is not a warning (source check)' -ForegroundColor Cyan
# Read via .NET so the shadowed Get-Content above does not interfere.
$vmSrc = [System.IO.File]::ReadAllText((Join-Path $repo 'Public\New-Win32ToolkitTestVM.ps1'))
if ($vmSrc.Contains('Write-Host "VM ''$Name'' already exists with checkpoint')) { Ok 'reuse status is on Write-Host, not Write-Warning' }
else { Bad 'the reuse fast-path is not emitted via Write-Host' }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P2 review-fix tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P2 review-fix test(s) FAILED." -ForegroundColor Red; exit 1 }
