function Get-Win32ToolkitUpdateInfo {
    <#
    .SYNOPSIS
        Non-nagging, fail-open check for a newer win32-toolkit release on GitHub.
    .DESCRIPTION
        Returns update status for the TUI to surface, or $null when the check is opted out, throttled
        with no cached answer, or fails for ANY reason. It is designed to never break or slow the
        toolkit:
          - opt-out is honoured BEFORE any network call (env vars, CI, non-interactive host, config)
          - the GitHub Releases API is queried at most once per TTL (cached under LOCALAPPDATA)
          - every network/parse error is swallowed to Write-Verbose and returns $null

        GitHub Releases (not the PowerShell Gallery) is the source: it lights up the instant a
        release-please release PR merges, needs no auth, and matches how this project ships. The
        version comparison uses the PS7 [semver] type and therefore stays HOST-SIDE only; it must
        never be spliced into the 5.1-safe device scripts the toolkit generates.
    .PARAMETER TtlHours
        Minimum hours between live network checks. Within the window the cached answer is reused.
    .PARAMETER Force
        Ignore the cache TTL and check now (used by the Settings 'check now' action).
    .OUTPUTS
        PSCustomObject { Installed, Latest, UpdateAvailable, Source, ReleasesUrl } or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [int]$TtlHours = 24,
        [switch]$Force
    )

    # ── opt-out, checked before any work ────────────────────────────────────────────────────────
    # WIN32TOOLKIT_NO_UPDATE_CHECK is ours; DO_NOT_TRACK / NO_UPDATE_NOTIFIER are community standards;
    # CI and a redirected/non-interactive host mean "not a person looking at a menu".
    if ($env:WIN32TOOLKIT_NO_UPDATE_CHECK) { Write-Verbose 'Update check: opted out (WIN32TOOLKIT_NO_UPDATE_CHECK).'; return $null }
    if ($env:DO_NOT_TRACK)                 { Write-Verbose 'Update check: opted out (DO_NOT_TRACK).';                 return $null }
    if ($env:NO_UPDATE_NOTIFIER)           { Write-Verbose 'Update check: opted out (NO_UPDATE_NOTIFIER).';           return $null }
    if ($env:CI)                           { Write-Verbose 'Update check: skipped under CI.';                          return $null }
    if ((Get-Win32ToolkitConfigValue -Name 'UpdateCheck' -Default 'On') -eq 'Off') { Write-Verbose 'Update check: disabled in Settings.'; return $null }

    # ── installed version ───────────────────────────────────────────────────────────────────────
    $installed = $null
    try { $installed = (Get-Module 'win32-toolkit' | Select-Object -First 1).Version } catch { }
    if (-not $installed) {
        try { $installed = [version](Import-PowerShellDataFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'win32-toolkit.psd1')).ModuleVersion } catch { }
    }
    if (-not $installed) { return $null }

    $repo        = 'MG-Cloudflow/win32-toolkit'
    $releasesUrl = "https://github.com/$repo/releases"

    # ── cache (one file, mirrors the HKCU:\Software\CloudFlow\win32-toolkit namespace) ──────────
    # Guard LOCALAPPDATA: a null/empty value would make Join-Path throw, breaking the never-throws
    # contract. If it is unset we simply run without a cache (live check each time) rather than crash.
    $cacheDir  = $null
    $cacheFile = $null
    if (-not [string]::IsNullOrEmpty($env:LOCALAPPDATA)) {
        $cacheDir  = Join-Path $env:LOCALAPPDATA 'CloudFlow\win32-toolkit'
        $cacheFile = Join-Path $cacheDir 'update-check.json'
    }
    $cache = $null
    try { if ($cacheFile -and (Test-Path $cacheFile)) { $cache = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }

    $latest = $null
    $fresh  = $false
    if (-not $Force -and $cache -and $cache.lastCheck) {
        try {
            $last = [datetime]::Parse($cache.lastCheck, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            if (((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalHours -lt $TtlHours) {
                $fresh  = $true
                $latest = $cache.latestVersion
            }
        } catch { }
    }

    # ── fetch (only when stale), fail open ──────────────────────────────────────────────────────
    if (-not $fresh) {
        $fetched = $null
        try {
            # GitHub rejects requests with no User-Agent; 3s timeout keeps a slow network from stalling
            # the menu. GitHub's 'latest' is already the newest non-prerelease/non-draft release.
            $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
                -Headers @{ 'User-Agent' = "win32-toolkit/$installed"; 'Accept' = 'application/vnd.github+json' } `
                -TimeoutSec 3 -ErrorAction Stop
            if ($resp.tag_name) { $fetched = ([string]$resp.tag_name).TrimStart('v', 'V') }
        }
        catch { Write-Verbose "Update check: fetch failed ($($_.Exception.Message)); failing open." }

        if ($fetched) { $latest = $fetched }
        # Rewrite lastCheck on BOTH success and failure so an outage backs off for the TTL instead of
        # retrying (and slowing the menu) on every launch. Skipped entirely when there is no cache dir.
        if ($cacheFile) {
            try {
                if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
                [pscustomobject]@{
                    lastCheck     = (Get-Date).ToUniversalTime().ToString('o')
                    latestVersion = $latest
                    source        = 'github'
                } | ConvertTo-Json | Set-Content -Path $cacheFile -Encoding UTF8
            } catch { }
        }
    }

    if (-not $latest) { return $null }

    # ── compare (PS7 [semver], host-side only) ──────────────────────────────────────────────────
    $updateAvailable = $false
    try {
        $li = $null; $lv = $null
        if ([System.Management.Automation.SemanticVersion]::TryParse("$installed", [ref]$li) -and
            [System.Management.Automation.SemanticVersion]::TryParse("$latest",    [ref]$lv)) {
            $updateAvailable = $lv -gt $li
        }
        else {
            $updateAvailable = ([version]"$latest") -gt ([version]"$installed")
        }
    }
    catch { return $null }

    [pscustomobject]@{
        Installed       = "$installed"
        Latest          = "$latest"
        UpdateAvailable = [bool]$updateAvailable
        Source          = 'github'
        ReleasesUrl     = $releasesUrl
    }
}
