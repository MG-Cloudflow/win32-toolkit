function Test-Win32ToolkitCachedInstaller {
    <#
    .SYNOPSIS
        Validates a cached winget download directory: the installer's SHA256 must match its own manifest.
    .DESCRIPTION
        The cache stores the WHOLE winget download directory (installer + every .yaml winget wrote —
        the installer manifest carries SilentSwitches/InstallerType that downstream resolution needs).
        Reuse is allowed only when the cached installer's real SHA256 equals the InstallerSha256 recorded
        in the cached installer manifest — strictly stronger than today's blind re-download, and it makes
        a tampered or torn cache entry a MISS instead of a poisoned baseline. Returns $true when the
        directory is safe to reuse.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $installer = Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.exe', '.msi', '.msix', '.appx' } |
        Select-Object -First 1
    if (-not $installer) { return $false }

    # The installer manifest (not the locale manifest) carries the expected hash.
    $yamlFile = Get-WingetManifestFile -Path $Path -Kind Installer
    if (-not $yamlFile) { return $false }
    $yaml = Get-Content -LiteralPath $yamlFile.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not ($yaml -match '(?m)^\s*InstallerSha256:\s*([0-9A-Fa-f]{64})')) { return $false }
    $expected = $matches[1]

    try { $actual = (Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
    catch { return $false }

    return ($actual -eq $expected)
}
