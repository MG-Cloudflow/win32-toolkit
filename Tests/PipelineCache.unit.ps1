<#
    R11 — the pipeline download cache helpers + the cached-baseline path.

      (a) Get-Win32ToolkitPipelineCacheRoot — On by default, Off disables (=> $null), no configured
          BasePath => $null (never prompts), any error => $null (fail open = no cache).
      (b) Test-Win32ToolkitCachedInstaller — a cached winget download dir is reusable ONLY when the
          installer's real SHA256 matches the InstallerSha256 in its own cached manifest (tamper/torn
          entry => miss). Strictly stronger than the blind re-download it replaces.
      (c) Download-OldVersionInstaller cache behavior: pinned-version hit => NO winget call, same
          result contract; miss => winget runs and the result is cached; the UNPINNED-FALLBACK result
          is never cached under the pinned key (variant poisoning); unpinned 'latest' (dependency
          staging) is never cached here.

    Run:  pwsh -File Tests\PipelineCache.unit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok($m)  { Write-Host "  PASS: $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }

. (Join-Path $repo 'Private\Get-Win32ToolkitPipelineCacheRoot.ps1')
. (Join-Path $repo 'Private\Test-Win32ToolkitCachedInstaller.ps1')
. (Join-Path $repo 'Private\Get-WingetManifestFile.ps1')
. (Join-Path $repo 'Private\Resolve-Win32ToolkitBaselineSilentArgs.ps1')
. (Join-Path $repo 'Private\Get-YAMLInstallerInfo.ps1')
. (Join-Path $repo 'Private\Download-OldVersionInstaller.ps1')

function New-TempDir { $p = Join-Path ([System.IO.Path]::GetTempPath()) ('plc_' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $p -Force | Out-Null; $p }

# ── (a) cache root resolution ──────────────────────────────────────────────────────────────────────
Write-Host '[a] Get-Win32ToolkitPipelineCacheRoot' -ForegroundColor Cyan
$script:cfg  = @{}
$script:base = New-TempDir
function Get-Win32ToolkitConfigValue { param($Name, $Default) if ($script:cfg.ContainsKey($Name)) { $script:cfg[$Name] } else { $Default } }
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$NonInteractive, [switch]$Reconfigure) $script:base }

$root = Get-Win32ToolkitPipelineCacheRoot
if ($root -and $root -like (Join-Path $script:base 'Cache\winget') -and (Test-Path $root)) { Ok 'On by default -> <BasePath>\Cache\winget created' } else { Bad "root: $root" }
$script:cfg['PipelineCache'] = 'Off'
if ($null -eq (Get-Win32ToolkitPipelineCacheRoot)) { Ok "PipelineCache=Off -> `$null (cache disabled)" } else { Bad 'Off did not disable' }
$script:cfg.Clear()
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$NonInteractive, [switch]$Reconfigure) $null }
if ($null -eq (Get-Win32ToolkitPipelineCacheRoot)) { Ok "no configured BasePath -> `$null (never prompts)" } else { Bad 'invented a location' }
function Get-Win32ToolkitBasePath { param($BasePath, [switch]$NonInteractive, [switch]$Reconfigure) $script:base }

# ── (b) hash-validated reuse ───────────────────────────────────────────────────────────────────────
Write-Host '[b] Test-Win32ToolkitCachedInstaller' -ForegroundColor Cyan
function New-CachedDir {
    param([switch]$CorruptHash, [switch]$NoManifest, [switch]$NoInstaller)
    $d = New-TempDir
    if (-not $NoInstaller) { [System.IO.File]::WriteAllBytes((Join-Path $d 'app.msi'), [byte[]](1..64)) }
    if (-not $NoManifest) {
        $sha = if ($CorruptHash -or $NoInstaller) { 'F' * 64 } else { (Get-FileHash -LiteralPath (Join-Path $d 'app.msi') -Algorithm SHA256).Hash }
        Set-Content -LiteralPath (Join-Path $d 'x.installer.yaml') "InstallerType: msi`nInstallerSha256: $sha`nSilentSwitches: '/qn'" -Encoding UTF8
    }
    $d
}
$good = New-CachedDir
if (Test-Win32ToolkitCachedInstaller -Path $good) { Ok 'matching SHA256 -> reusable' } else { Bad 'valid entry rejected' }
$badHash = New-CachedDir -CorruptHash
if (-not (Test-Win32ToolkitCachedInstaller -Path $badHash)) { Ok 'hash mismatch -> MISS (tampered/torn entry never reused)' } else { Bad 'tampered entry accepted' }
if (-not (Test-Win32ToolkitCachedInstaller -Path (New-CachedDir -NoManifest))) { Ok 'no manifest -> miss' } else { Bad 'manifest-less entry accepted' }
if (-not (Test-Win32ToolkitCachedInstaller -Path (New-CachedDir -NoInstaller))) { Ok 'no installer -> miss' } else { Bad 'empty entry accepted' }
if (-not (Test-Win32ToolkitCachedInstaller -Path (Join-Path $script:base 'nope'))) { Ok 'missing dir -> miss' } else { Bad 'phantom dir accepted' }

# ── (c) the cached baseline path in Download-OldVersionInstaller ───────────────────────────────────
Write-Host '[c] Download-OldVersionInstaller: hit skips winget; fallback never poisons the pinned key' -ForegroundColor Cyan
$script:wingetCalls = @()
$script:wingetFailPinned = $false
function winget {
    $script:wingetCalls += , @($args)
    # Simulate: pinned call fails when requested (exit 1), the unpinned retry succeeds.
    $isPinned = ($args -contains '--scope') -or ($args -contains '--installer-type') -or ($args -contains '--locale')
    if ($script:wingetFailPinned -and $isPinned) { $global:LASTEXITCODE = 1; return }
    # "Download": write an installer + manifest into --download-directory.
    $dirIdx = [array]::IndexOf($args, '--download-directory') + 1
    $dir = $args[$dirIdx]
    [System.IO.File]::WriteAllBytes((Join-Path $dir 'app.msi'), [byte[]](7..99))
    $sha = (Get-FileHash -LiteralPath (Join-Path $dir 'app.msi') -Algorithm SHA256).Hash
    Set-Content -LiteralPath (Join-Path $dir 'a.installer.yaml') "InstallerType: msi`nInstallerSha256: $sha`nSilentSwitches: '/qn'" -Encoding UTF8
    $global:LASTEXITCODE = 0
}

$proj = New-TempDir
# c1: first pinned download -> winget runs once, result cached.
$r1 = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Scope machine -InstallerType msi 6>$null 3>$null
if ($r1.InstallerName -eq 'app.msi' -and $r1.SilentArgs -match 'qn') { Ok 'miss: downloads and returns the normal contract' } else { Bad "r1: $($r1 | Out-String)" }
if (@($script:wingetCalls).Count -eq 1) { Ok 'miss: exactly one winget call' } else { Bad "winget calls: $(@($script:wingetCalls).Count)" }
$cacheDir = Join-Path (Get-Win32ToolkitPipelineCacheRoot) 'Acme.App\1.2.3\any_machine_msi_any'
if (Test-Path -LiteralPath (Join-Path $cacheDir 'app.msi')) { Ok 'the whole download dir (installer + YAML) was cached under the pinned key' } else { Bad "no cache at $cacheDir" }

# c2: same pinned request again -> served from cache, ZERO winget calls.
$script:wingetCalls = @()
$r2 = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Scope machine -InstallerType msi 6>$null 3>$null
if (@($script:wingetCalls).Count -eq 0) { Ok 'hit: winget never invoked (the re-download is gone)' } else { Bad "winget called $(@($script:wingetCalls).Count)x on a hit" }
if ($r2.InstallerName -eq 'app.msi' -and $r2.SilentArgs -match 'qn' -and (Test-Path -LiteralPath $r2.InstallerPath)) { Ok 'hit: identical result contract (installer present in the project)' } else { Bad "r2: $($r2 | Out-String)" }

# c3: a corrupted cache entry is a MISS -> re-download.
[System.IO.File]::WriteAllBytes((Join-Path $cacheDir 'app.msi'), [byte[]](0, 0, 0))
$script:wingetCalls = @()
$null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Scope machine -InstallerType msi 6>$null 3>$null
if (@($script:wingetCalls).Count -eq 1) { Ok 'corrupted cache -> hash miss -> real download (self-heals)' } else { Bad "winget calls: $(@($script:wingetCalls).Count)" }

# c4: the UNPINNED FALLBACK result must NOT be written under the pinned key.
Remove-Item -LiteralPath (Split-Path (Split-Path $cacheDir -Parent) -Parent) -Recurse -Force -ErrorAction SilentlyContinue
$script:wingetCalls = @(); $script:wingetFailPinned = $true
$r4 = Download-OldVersionInstaller -AppId 'Acme.App' -Version '9.9.9' -ProjectPath $proj -Scope machine -InstallerType msi 6>$null 3>$null
$fallbackKey = Join-Path (Get-Win32ToolkitPipelineCacheRoot) 'Acme.App\9.9.9\any_machine_msi_any'
if ($r4.InstallerName -eq 'app.msi') { Ok 'fallback: the unpinned retry still delivers a baseline' } else { Bad 'fallback broken' }
if (-not (Test-Path -LiteralPath $fallbackKey)) { Ok 'fallback result NOT cached under the pinned key (no variant poisoning)' } else { Bad 'fallback poisoned the pinned key' }
$script:wingetFailPinned = $false

# c5: unpinned latest (dependency staging: no -Version) is never cached.
$script:wingetCalls = @()
$depDir = New-TempDir
$null = Download-OldVersionInstaller -AppId 'Acme.Dep' -ProjectPath $proj -DestinationDir $depDir 6>$null 3>$null
if (-not (Test-Path -LiteralPath (Join-Path (Get-Win32ToolkitPipelineCacheRoot) 'Acme.Dep'))) { Ok "unpinned 'latest' never enters the version cache" } else { Bad 'latest was cached (staleness risk)' }

# c6: PipelineCache=Off -> always downloads, never reads or writes the cache.
$script:cfg['PipelineCache'] = 'Off'
$script:wingetCalls = @()
$null = Download-OldVersionInstaller -AppId 'Acme.App' -Version '1.2.3' -ProjectPath $proj -Scope machine -InstallerType msi 6>$null 3>$null
if (@($script:wingetCalls).Count -eq 1) { Ok 'cache Off -> bit-identical old behavior (always downloads)' } else { Bad "winget calls with cache off: $(@($script:wingetCalls).Count)" }
$script:cfg.Clear()

Write-Host ''
if ($fail -eq 0) { Write-Host 'ALL PASS' -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
