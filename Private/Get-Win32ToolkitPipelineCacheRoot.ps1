function Get-Win32ToolkitPipelineCacheRoot {
    <#
    .SYNOPSIS
        Returns the pipeline download-cache root (<BasePath>\Cache\winget), or $null when caching is off.
    .DESCRIPTION
        One switch for the Phase-3 download caches (old-version baselines, dependency staging reuse):
        config 'PipelineCache' — 'On' (default) / 'Off'. A $null return means "behave exactly as before
        the cache existed" (every caller treats it as a miss). The root is created on first use.

        Deliberately based on the registry-backed BasePath (resolved NON-interactively — a cache lookup
        must never prompt); when no BasePath is configured yet, caching silently disables rather than
        inventing a location.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        if ((Get-Win32ToolkitConfigValue -Name 'PipelineCache' -Default 'On') -eq 'Off') { return $null }
        $base = Get-Win32ToolkitBasePath -NonInteractive
        if ([string]::IsNullOrWhiteSpace($base)) { return $null }
        $root = Join-Path $base 'Cache\winget'
        if (-not (Test-Path -LiteralPath $root)) {
            New-Item -ItemType Directory -Path $root -Force | Out-Null
        }
        return $root
    }
    catch {
        # A cache-layer hiccup must never break a download path — fail open (no cache).
        Write-Verbose "Pipeline cache disabled for this call: $($_.Exception.Message)"
        return $null
    }
}
