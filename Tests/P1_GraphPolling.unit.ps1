<#
    P1 — Graph SAS-URI / commit polling used to cap at 60 s and could not be raised.

    Publish-Win32ToolkitIntuneApp had TWO hardcoded loops:

        for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Seconds 3; ... }
        ... throw 'Timed out waiting for file commit (60 s).'

    20 polls x 3 s = a hard 60-second ceiling with no parameter and no back-off. Intune's COMMIT
    decrypts and validates the whole package server-side, so it scales with package size — a 200 MB+
    .intunewin routinely needs longer, and the timeout fired AFTER the blob had already been uploaded,
    throwing away a publish that would have succeeded.

    Both waits now run through Private\Wait-Win32ToolkitUploadState (one helper, so they cannot drift),
    with -TimeoutSeconds (default 300) and a 2 s -> 4 -> 8 -> 15 s capped back-off.

    Graph and Start-Sleep are shadowed; nothing sleeps and nothing hits the network.

    Run:  pwsh -File Tests\P1_GraphPolling.unit.ps1
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

# ── shadows ──────────────────────────────────────────────────────────────────────────────────────
# Nothing may actually sleep: capture what WOULD have been slept instead.
$script:sleeps = @()
function Start-Sleep { param([int]$Seconds) $script:sleeps += $Seconds }

# GET poll driver: report $State until the Nth call, then $ReadyState.
$script:gets       = 0
$script:readyAfter = 1
$script:pendingState = 'azureStorageUriRequestPending'
$script:readyState   = 'azureStorageUriRequestSuccess'
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    $script:gets++
    if ($script:gets -ge $script:readyAfter) {
        return [pscustomobject]@{ uploadState = $script:readyState; azureStorageUri = 'https://blob/x' }
    }
    return [pscustomobject]@{ uploadState = $script:pendingState }
}
function Reset { param([int]$ReadyAfter = 1) $script:gets = 0; $script:readyAfter = $ReadyAfter; $script:sleeps = @() }

# ══ [1] THE BUG: a resource that becomes ready after MORE than 20 polls now SUCCEEDS ══════════════
Write-Host '[1] ready after MORE than 20 polls -> succeeds (the old 20x3s loop threw at 60 s)' -ForegroundColor Cyan

Reset -ReadyAfter 22   # the old code polled at most 20 times, so this used to be a guaranteed timeout
$threw = $false
$res   = $null
try {
    $res = Wait-Win32ToolkitUploadState -FileUri 'https://graph/x/files/f1' `
        -TargetState 'azureStorageUriRequestSuccess' -Activity 'the Azure Storage SAS URI' 6>$null
}
catch { $threw = $true }
if (-not $threw -and $res.uploadState -eq 'azureStorageUriRequestSuccess') {
    Ok "ready on poll 22 -> returned the file entry (polls made: $script:gets)"
} else { Bad "threw=$threw after $script:gets poll(s)" }
if ($res.azureStorageUri -eq 'https://blob/x') { Ok 'the successful poll object is returned (SAS URI reachable)' } else { Bad 'poll object not returned' }
if (($script:sleeps | Measure-Object -Sum).Sum -gt 60) {
    Ok "it waited $((($script:sleeps | Measure-Object -Sum).Sum)) s — past the old 60 s ceiling"
} else { Bad 'still gave up inside 60 s' }

# ══ [2] BACK-OFF, not a flat 3 s ═════════════════════════════════════════════════════════════════
Write-Host '[2] the delays back off exponentially and saturate at the cap' -ForegroundColor Cyan

Reset -ReadyAfter 8
$null = Wait-Win32ToolkitUploadState -FileUri 'u' -TargetState 'azureStorageUriRequestSuccess' `
    -Activity 'the Azure Storage SAS URI' 6>$null
$s = @($script:sleeps)
if (($s | Select-Object -Unique).Count -gt 1) { Ok "not a flat 3 s poll any more: $($s -join ',')" } else { Bad "flat delays: $($s -join ',')" }
if ($s[0] -eq 2 -and $s[1] -eq 4 -and $s[2] -eq 8) { Ok 'doubles: 2 -> 4 -> 8' } else { Bad "no doubling: $($s -join ',')" }
if (($s | Measure-Object -Maximum).Maximum -le 15) { Ok 'and is capped at 15 s (a slow tenant is polled patiently, not hammered)' } else { Bad "delay exceeded the 15 s cap: $($s -join ',')" }
if ($s -notcontains 3 -or ($s | Where-Object { $_ -ne 3 }).Count -gt 0) { Ok 'the fixed 3 s sleep is gone' } else { Bad 'still sleeping a flat 3 s' }

# ══ [3] never ready -> still throws, quoting the REAL timeout ═════════════════════════════════════
Write-Host '[3] a resource that never becomes ready still throws — with the ACTUAL timeout in the message' -ForegroundColor Cyan

Reset -ReadyAfter 100000   # never ready
$msg = $null
try {
    $null = Wait-Win32ToolkitUploadState -FileUri 'u' -TargetState 'commitFileSuccess' `
        -Activity 'the file commit' -TimeoutSeconds 45 6>$null
}
catch { $msg = $_.Exception.Message }
if ($msg) { Ok 'a stuck resource still fails (no infinite wait)' } else { Bad 'did not throw' }
if ($msg -match '45') { Ok "the message quotes the configured timeout, not a hardcoded 60: '$msg'" } else { Bad "timeout not in message: $msg" }
if ($msg -notmatch '60 s') { Ok "no hardcoded '60 s' string" } else { Bad "message still says 60 s: $msg" }
if ($msg -match 'the file commit') { Ok 'the message names WHICH wait timed out' } else { Bad 'activity missing from the message' }

# (d) the total simulated wait respects the configured timeout
$total = ($script:sleeps | Measure-Object -Sum).Sum
if ($total -le 45) { Ok "total simulated wait ($total s) never overshoots the configured timeout (45 s)" } else { Bad "slept $total s against a 45 s timeout" }
if ($total -ge 40) { Ok "…and it actually used the budget ($total s of 45 s), rather than bailing early" } else { Bad "gave up after only $total s of a 45 s budget" }

Reset -ReadyAfter 100000
try { $null = Wait-Win32ToolkitUploadState -FileUri 'u' -TargetState 'commitFileSuccess' -Activity 'the file commit' -TimeoutSeconds 600 6>$null } catch { }
$total600 = ($script:sleeps | Measure-Object -Sum).Sum
if ($total600 -le 600 -and $total600 -ge 570) { Ok "a larger timeout is honoured too ($total600 s of 600 s)" } else { Bad "600 s timeout -> slept $total600 s" }

# ══ [4] an Intune-side failure is NOT waited out ══════════════════════════════════════════════════
Write-Host '[4] an error/failed uploadState throws immediately (unchanged behaviour)' -ForegroundColor Cyan
$script:pendingState = 'commitFileFailed'
Reset -ReadyAfter 100000
$msg = $null
try { $null = Wait-Win32ToolkitUploadState -FileUri 'u' -TargetState 'commitFileSuccess' -Activity 'the file commit' -TimeoutSeconds 600 6>$null } catch { $msg = $_.Exception.Message }
if ($msg -match 'commitFileFailed' -and $script:gets -eq 1) { Ok 'a failed upload state throws on the first poll instead of burning the timeout' } else { Bad "gets=$script:gets msg=$msg" }
$script:pendingState = 'azureStorageUriRequestPending'

# ══ [5] END TO END through Publish-Win32ToolkitIntuneApp ══════════════════════════════════════════
Write-Host '[5] Publish: a SAS URI that takes 22 polls now publishes (backwards compatible, no new args)' -ForegroundColor Cyan

$INNER = 'IntuneWinPackage/Contents/payload.bin'
function Connect-Win32ToolkitGraph { }
function Get-MgContext { [pscustomobject]@{ TenantId = 'tenant-1' } }
function Get-Win32IntuneWinMetadata { param($IntuneWinPath) [pscustomobject]@{ InnerEntryName = $INNER; UnencryptedSize = 100; SizeEncrypted = 128; EncryptionKey = 'k'; MacKey = 'mk'; InitializationVector = 'iv'; Mac = 'm'; FileDigest = 'fd'; FileDigestAlgorithm = 'SHA256' } }
function Get-Win32DetectionRules { param($ProjectPath) @(@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryDetection' }) }
function Get-Win32ToolkitRequirementRule { param($ProjectPath) 'rule' }
function Get-Win32ToolkitAppConfig { param($ProjectPath) [pscustomobject]@{ App = [pscustomobject]@{ Name = 'Test App'; Version = '1.0'; Vendor = 'ACME' } } }
function Get-YAMLInstallerInfo { param($FilesPath) $null }
function Invoke-AzBlobUpload { param($SasUri, $FilePath) $script:uploaded = $true }
function Set-Win32ToolkitPublication { param($ProjectPath, $AppId, $TenantId, $DisplayName, $DisplayVersion, $WingetId) 'p' }
function Resolve-Win32ToolkitDependencies { param($ProjectPath, $TenantId, $BaseUri) @() }

# Graph shadow for the full publish: the SAS URI stays 'pending' for 21 polls, the commit for 21 more.
$script:sasPolls    = 0
$script:commitPolls = 0
$script:posted      = $false   # commit POSTed?
$script:uploaded    = $false
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    if ($Method -eq 'POST' -and $Uri -match '/mobileApps$')     { return [pscustomobject]@{ id = 'app-1' } }
    if ($Method -eq 'POST' -and $Uri -match 'contentVersions$') { return [pscustomobject]@{ id = '1' } }
    if ($Method -eq 'POST' -and $Uri -match 'files$')           { return [pscustomobject]@{ id = 'f1' } }
    if ($Method -eq 'POST' -and $Uri -match 'commit')           { $script:posted = $true; return $null }
    if ($Method -eq 'PATCH')                                    { return $null }
    if ($Method -eq 'GET') {
        if ($script:posted) {
            $script:commitPolls++
            if ($script:commitPolls -ge 22) { return [pscustomobject]@{ uploadState = 'commitFileSuccess' } }
            return [pscustomobject]@{ uploadState = 'commitFilePending' }
        }
        $script:sasPolls++
        if ($script:sasPolls -ge 22) { return [pscustomobject]@{ uploadState = 'azureStorageUriRequestSuccess'; azureStorageUri = 'https://blob/x' } }
        return [pscustomobject]@{ uploadState = 'azureStorageUriRequestPending' }
    }
    return $null
}

Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('w32gp_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$win = Join-Path $tmp 'app.intunewin'
$zip = [System.IO.Compression.ZipFile]::Open($win, 'Create')
try { $e = $zip.CreateEntry($INNER); $s2 = $e.Open(); $w = [System.IO.StreamWriter]::new($s2); $w.Write('x'); $w.Flush(); $w.Dispose(); $s2.Dispose() } finally { $zip.Dispose() }

$script:sleeps = @()
$out   = $null
$threw = $null
try { $out = Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $tmp 6>$null 3>$null } catch { $threw = $_.Exception.Message }
if (-not $threw -and $out.AppId -eq 'app-1') { Ok 'publish succeeds with NO -TimeoutSeconds argument (existing callers unchanged)' } else { Bad "threw: $threw" }
if ($script:sasPolls -ge 22)    { Ok "the SAS wait polled $script:sasPolls times (the old loop stopped at 20)" }    else { Bad "sas polls: $script:sasPolls" }
if ($script:commitPolls -ge 22) { Ok "the COMMIT wait polled $script:commitPolls times — the 200 MB+ package case" } else { Bad "commit polls: $script:commitPolls" }
if ($script:uploaded)           { Ok 'the blob upload still happened between the two waits' }                        else { Bad 'blob never uploaded' }

Write-Host '[5b] an honestly stuck tenant still fails the publish, quoting the caller-supplied timeout' -ForegroundColor Cyan
$script:sasPolls = 0; $script:commitPolls = 0; $script:posted = $false; $script:uploaded = $false
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $ContentType, $OutputType)
    if ($Method -eq 'POST' -and $Uri -match '/mobileApps$')     { return [pscustomobject]@{ id = 'app-1' } }
    if ($Method -eq 'POST' -and $Uri -match 'contentVersions$') { return [pscustomobject]@{ id = '1' } }
    if ($Method -eq 'POST' -and $Uri -match 'files$')           { return [pscustomobject]@{ id = 'f1' } }
    if ($Method -eq 'GET') { $script:sasPolls++; return [pscustomobject]@{ uploadState = 'azureStorageUriRequestPending' } }
    return $null
}
$script:sleeps = @()
$msg = $null
try { $null = Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $tmp -TimeoutSeconds 90 6>$null 3>$null } catch { $msg = $_.Exception.Message }
$total90 = ($script:sleeps | Measure-Object -Sum).Sum
if ($msg -match '90') { Ok "the failure quotes the real timeout (90 s), not 60: '$msg'" } else { Bad "msg: $msg" }
if ($total90 -le 90)  { Ok "and it waited no longer than asked ($total90 s)" }                else { Bad "slept $total90 s for a 90 s timeout" }
if (-not $script:uploaded) { Ok 'no blob upload attempted without a SAS URI' } else { Bad 'uploaded without a SAS URI' }

# ══ [6] the two loops are DRIVEN BY ONE HELPER and the old constants are gone ═════════════════════
Write-Host '[6] source: both waits share one helper; no 20-iteration loop, no flat 3 s, no hardcoded 60 s' -ForegroundColor Cyan
$pubPath = Join-Path $repo 'Public\Publish-Win32ToolkitIntuneApp.ps1'
$pubSrc  = Get-Content -LiteralPath $pubPath -Raw
if (([regex]::Matches($pubSrc, 'Wait-Win32ToolkitUploadState')).Count -ge 2) { Ok 'BOTH waits go through the same helper (they cannot drift apart)' } else { Bad 'the two waits are not both on the helper' }
if ($pubSrc -notmatch '\$i\s*-lt\s*20')                { Ok 'the 20-iteration loop is gone' }        else { Bad 'a 20-iteration loop remains' }
if ($pubSrc -notmatch 'Start-Sleep\s+-Seconds\s+3\b')  { Ok 'the flat 3 s Start-Sleep is gone' }     else { Bad 'a flat 3 s Start-Sleep remains' }
if ($pubSrc -notmatch "'Timed out[^']*60 s")           { Ok "the hardcoded '(60 s)' throw text is gone" } else { Bad "a hardcoded 60 s timeout message remains" }

# the parameter exists, is an int, and defaults to MORE than the old 60 s
$ast   = [System.Management.Automation.Language.Parser]::ParseFile($pubPath, [ref]$null, [ref]$null)
$fnAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Publish-Win32ToolkitIntuneApp' }, $true)
$p     = $fnAst.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TimeoutSeconds' }
if ($p) { Ok '-TimeoutSeconds is a real parameter (the wait is configurable at last)' } else { Bad 'no -TimeoutSeconds parameter' }
$def = if ($p -and $p.DefaultValue) { [int]$p.DefaultValue.Extent.Text } else { 0 }
if ($def -gt 60) { Ok "its default ($def s) is longer than the old hardcoded 60 s" } else { Bad "default is $def s" }

# and Export forwards it, so the packaging entry point can raise it too
$expSrc = Get-Content -LiteralPath (Join-Path $repo 'Public\Export-Win32ToolkitIntuneWin.ps1') -Raw
if ($expSrc -match '\[int\]\$PublishTimeoutSeconds' -and $expSrc -match "TimeoutSeconds'\]\s*=\s*\`$PublishTimeoutSeconds") {
    Ok 'Export-Win32ToolkitIntuneWin threads the timeout through to Publish'
} else { Bad 'Export does not forward a publish timeout' }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -eq 0) { Write-Host 'All P1_GraphPolling tests passed.' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail P1_GraphPolling test(s) FAILED." -ForegroundColor Red; exit 1 }
