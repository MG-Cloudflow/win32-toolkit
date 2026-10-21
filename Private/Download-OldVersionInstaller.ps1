function Download-OldVersionInstaller {
<#
.SYNOPSIS
    Downloads a specific older version of a Winget package into
    <ProjectPath>\Sandbox\OldVersion\ and returns installer details.
.DESCRIPTION
    Without -FamilyPin (dependency staging, and every caller before installer-identity PR 1) the scope /
    installer-type / locale pins are tried once and, when that download fails, retried unpinned with a warning.

    With -FamilyPin (the Update-test baseline, installer-identity PR 1 spec 2.11, L19) the installer TYPE is a
    hard pin and there is never an unpinned retry: the types of the pinned type's family are tried in order
    (Get-Win32ToolkitInstallerFamily -PinOrder, e.g. nullsoft, burn, inno, exe). An explicit -Scope (machine or
    user) is only a preference: when winget answers "no applicable installer" (0x8A150010) the same type is
    retried without --scope (ScopeRelaxed, one warning). Each such fallback step is announced with one host line
    that names the next attempt. Any other winget exit code is a plain error. When no
    type of the family is offered, a W32T.InstallerVariantUnavailable error names every attempt. The pipeline
    cache key is computed per tried (type, scope) ('any' for a relaxed scope). The attempts download into a
    staging folder next to the destination ('<destination>.attempt'); the destination is replaced only after a
    successful download or cache hit and is left untouched when the call fails, so Sandbox\OldVersion stays
    paired with the last generated Sandbox\UpdateAssertions.ps1 (spec 2.12 legacy rule, L21).

    Every winget call runs through Invoke-Win32ToolkitWingetDownload: winget's console lines go to the host
    (never into the returned object), and when a configured source cannot authenticate (exit 0x8A150075 or 0x8A150076) the
    same download is retried once with '--source winget' (one warning); later attempts of this call then ask
    '--source winget' directly. The retry's exit code is classified exactly like a first attempt's.
.OUTPUTS
    PSCustomObject with:
      InstallerPath          — full path to the downloaded installer file
      InstallerName          — file name only (used to build the sandbox path)
      InstallerType          — extension without dot (exe, msi, msix, appx)
      SilentArgs             — silent install switches for this installer
      UsedFallback           — $true when the pinned download failed and the unpinned retry was used
                               (never with -FamilyPin)
      RequestedInstallerType — the -InstallerType pin ('' when none)
      ManifestInstallerType  — the downloaded manifest's InstallerType (lower case)
      ManifestProductCode    — the downloaded manifest's ProductCode
      Scope, Locale          — the downloaded manifest's Scope and InstallerLocale
      Family                 — with -FamilyPin: the downloaded type's installer family; otherwise ''
      TriedTypes             — with -FamilyPin: the installer types tried, in order; otherwise @()
      ScopeRelaxed           — with -FamilyPin: $true when the scope pin was dropped; otherwise $false
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        # Omit to download the LATEST version (used when staging a dependency, where any current version
        # of e.g. the VC++ redistributable will do). The Update baseline always pins a version.
        [Parameter(Mandatory = $false)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$ProjectPath,

        # Where the installer lands. Defaults to the Update baseline folder (Sandbox\OldVersion); the
        # dependency stager points it at Sandbox\Dependencies\<id> instead. The folder is always emptied
        # first (with -FamilyPin: only once a download succeeded), so callers must NOT share one.
        [Parameter(Mandatory = $false)]
        [string]$DestinationDir,

        [Parameter(Mandatory = $false)]
        [string]$Architecture,

        # Variant pins from the packaged project's YAML (scope/installer-type/locale) so the baseline
        # matches the packaged variant (e.g. machine-scope MSI, not the user-scope EXE). If the pinned
        # download fails (the old version may not publish that variant), we retry unpinned with a warning.
        [Parameter(Mandatory = $false)]
        [string]$Scope,

        [Parameter(Mandatory = $false)]
        [string]$InstallerType,

        [Parameter(Mandatory = $false)]
        [string]$Locale,

        # Update-test baseline (installer-identity PR 1): -InstallerType pins the installer FAMILY (its types are
        # tried in order), the scope is a soft preference and there is never an unpinned retry. Requires
        # -InstallerType.
        [Parameter(Mandatory = $false)]
        [switch]$FamilyPin
    )

    if ($FamilyPin -and [string]::IsNullOrWhiteSpace($InstallerType)) {
        throw '-FamilyPin requires -InstallerType (the installer type whose family the baseline is pinned to).'
    }

    # Fail fast (before any download) on a pinned type that has no silent installer — otherwise the
    # sandbox would launch the app itself and hang until the 30-minute assertion timeout.
    $verLabel = if ($Version) { "v$Version" } else { 'the latest version' }

    if ($InstallerType -match '^(portable|zip|pwa)$') {
        throw "The baseline for '$AppId' $verLabel is a '$InstallerType' winget package — it has no silent installer (it would launch the app and hang the sandbox). Pick a different baseline with -SpecificVersion, or test with -Scenario InstallUninstall."
    }

    $oldVersionDir = if ($DestinationDir) { $DestinationDir } else { Join-Path $ProjectPath 'Sandbox\OldVersion' }
    # With -FamilyPin every attempt downloads into a sibling staging folder, and the result replaces
    # $oldVersionDir only after a download or cache hit succeeded. When no type of the family is offered
    # (W32T.InstallerVariantUnavailable), $oldVersionDir keeps the previous baseline, still paired with the
    # last generated Sandbox\UpdateAssertions.ps1: the legacy Update record judging rule (spec 2.12) needs
    # that pair, and an Unavailable run must never hide an older FAIL (L21). Without -FamilyPin the download
    # goes straight to $oldVersionDir, as before.
    $downloadDir = if ($FamilyPin) { "$oldVersionDir.attempt" } else { $oldVersionDir }
    # Download-failure text: the code in decimal (callers match that prefix) AND hex, plus, for winget's source-
    # authentication codes 0x8A150073-0x8A150078, that a re-run fails the same way (not a transient failure).
    $authHint = {
        param([int]$Code)
        if ($Code -ge -1978335117 -and $Code -le -1978335112) {
            ' A configured winget source needs a sign-in (winget authentication error): re-running fails the same way until you sign in to that source or it is removed from the search; win32-toolkit never signs in or changes sources.'
        }
        else { '' }
    }

    # Always start fresh so we don't accidentally pick up a stale installer. -LiteralPath enumeration
    # (not a wildcard -Path) so files with [ ] etc. are removed too; a survivor is a hard error rather
    # than a silent stale baseline.
    $clearDir = {
        param([string]$Dir)
        if (Test-Path -LiteralPath $Dir) {
            Get-ChildItem -LiteralPath $Dir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            if (@(Get-ChildItem -LiteralPath $Dir -Force).Count -gt 0) {
                throw "Could not clear $Dir (files in use? a sandbox still running?). Close the sandbox and retry."
            }
        } else {
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        }
    }
    & $clearDir $downloadDir

    # ── Pipeline cache (PINNED versions only) ────────────────────────────────────────────────────────
    # A released version's installer is immutable, so a hash-validated cached copy is strictly stronger
    # than re-downloading it every Update test (which is what happened before). The key encodes the full
    # requested variant; the WHOLE download directory is cached — the installer manifest next to the
    # binary carries SilentSwitches/InstallerType that the resolution below needs. Unpinned 'latest'
    # (dependency staging) is deliberately NEVER cached here: it is a moving target. With -FamilyPin the
    # key is computed per tried (type, scope) below, so a relaxed-scope download never lands under a
    # scoped key.
    $cacheDir  = $null
    $cacheRoot = $null
    # Sanitize [ and ] too: they are legal in winget ids/versions but are WILDCARD character
    # classes to any -Path parameter downstream.
    $san = { param($v) if ([string]::IsNullOrWhiteSpace($v)) { 'any' } else { ($v -replace '[\\/:*?"<>|\[\]]', '_').ToLowerInvariant() } }
    $cacheKey = {
        param($KeyScope, $KeyType)
        if (-not $cacheRoot) { return $null }
        $keyLeaf = ('{0}_{1}_{2}_{3}' -f (& $san $Architecture), (& $san $KeyScope), (& $san $KeyType), (& $san $Locale))
        return (Join-Path $cacheRoot (Join-Path ($AppId -replace '[\\/:*?"<>|\[\]]', '_') (Join-Path ($Version -replace '[\\/:*?"<>|\[\]]', '_') $keyLeaf)))
    }
    if ($Version) {
        try { $cacheRoot = Get-Win32ToolkitPipelineCacheRoot } catch { $cacheRoot = $null }   # fail open: no cache
        if (-not $FamilyPin) { $cacheDir = & $cacheKey $Scope $InstallerType }
    }

    # Copies a hash-validated cache entry into the download folder. FAIL OPEN: a cache-layer copy failure
    # must fall through to the real download, never abort it.
    $useCache = {
        param($Dir)
        if (-not $Dir -or -not (Test-Win32ToolkitCachedInstaller -Path $Dir)) { return $false }
        try {
            Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop |
                Copy-Item -Destination $downloadDir -Recurse -Force -ErrorAction Stop
            Write-Host "✓ Using the cached download for '$AppId' $verLabel (SHA256-validated against its manifest)." -ForegroundColor Green
            return $true
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Cache hit could not be materialized ($($_.Exception.Message)) — downloading."
            Get-ChildItem -LiteralPath $downloadDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }
    }

    # Caches a fresh download. The write is validated and rolled back on any inconsistency (fail open).
    $storeCache = {
        param($Dir)
        if (-not $Dir) { return }
        $stage = $null
        try {
            # Publish ~atomically: stage into a temp sibling, validate, then swap into place — a
            # concurrent run reading the key sees either the old complete entry or the new one,
            # never a half-written directory (which the SHA check would reject as a miss anyway).
            $stage = "$Dir.tmp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            Get-ChildItem -LiteralPath $downloadDir -Force -ErrorAction Stop |
                Copy-Item -Destination $stage -Recurse -Force -ErrorAction Stop
            if (Test-Win32ToolkitCachedInstaller -Path $stage) {
                if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
                Move-Item -LiteralPath $stage -Destination $Dir -Force -ErrorAction Stop
            }
            else {
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            Write-Verbose "Could not cache the download (non-fatal): $($_.Exception.Message)"
            if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    $downloadArgs = @(
        'download',
        '--id',                        $AppId,
        '--download-directory',        $downloadDir,
        '--accept-source-agreements',
        '--accept-package-agreements'
    )
    # No -Version => let winget pick the latest (the dependency-staging case).
    if ($Version) { $downloadArgs += '--version'; $downloadArgs += $Version }

    if ($Architecture -and $Architecture -ne 'all') {
        $downloadArgs += '--architecture'
        $downloadArgs += $Architecture
    }

    $usedFallback = $false
    $scopeRelaxed = $false
    $triedTypes   = [System.Collections.Generic.List[string]]::new()

    if ($FamilyPin) {
        # ── Family pin (Update-test baseline): never an unpinned download ──────────────────────────────
        # Every attempt lands in $downloadDir (the staging folder); $oldVersionDir changes only on success.
        try {
            $types = @(Get-Win32ToolkitInstallerFamily -PinOrder $InstallerType)
            if ($types.Count -eq 0) {
                throw "Cannot pin the baseline for '$AppId' $verLabel to installer type '$InstallerType': it is not a type win32-toolkit can download and install as a baseline."
            }
            $pinScope = if ($Scope -and $Scope -in @('machine', 'user')) { $Scope.ToLowerInvariant() } else { '' }
            $attempts = [System.Collections.Generic.List[string]]::new()
            $done = $false
            # The scope is a soft preference (L19): the same type is retried without --scope before the next type.
            $tryScopes = if ($pinScope) { @($pinScope, '') } else { @('') }
            for ($ti = 0; $ti -lt $types.Count; $ti++) {
                $t = $types[$ti]
                $triedTypes.Add($t)
                for ($si = 0; $si -lt $tryScopes.Count; $si++) {
                    $s = $tryScopes[$si]
                    if ($s) { $attempts.Add("$t/$s") } elseif (-not $pinScope) { $attempts.Add($t) }
                    $cacheDir = if ($Version) { & $cacheKey $s $t } else { $null }
                    if (& $useCache $cacheDir) {
                        $done = $true
                    }
                    else {
                        Write-Verbose "Downloading $verLabel of '$AppId' (installer type $t$(if ($s) { ", scope $s" }))..."
                        $attemptArgs = @()
                        if ($s)      { $attemptArgs += '--scope';  $attemptArgs += $s }
                        $attemptArgs += '--installer-type'; $attemptArgs += $t
                        if ($Locale) { $attemptArgs += '--locale'; $attemptArgs += $Locale }
                        $attempt = Invoke-Win32ToolkitWingetDownload -ArgumentList ($downloadArgs + $attemptArgs) -Label "'$AppId' $verLabel"
                        # A source that could not authenticate was left out by the retry: later attempts ask 'winget' directly.
                        if ($attempt.SourceFallback) { $downloadArgs += @('--source', 'winget') }
                        $code = $attempt.ExitCode
                        if ($code -eq 0) {
                            $done = $true
                            & $storeCache $cacheDir
                        }
                        elseif (Test-Win32ToolkitWingetNoApplicableInstaller -ExitCode $code) {
                            # Nothing of this attempt may survive into the next one (a survivor is a hard error).
                            & $clearDir $downloadDir
                            # winget has just printed its own 'No applicable installer found' line: name the next
                            # attempt on the host (never the output stream). After the last attempt nothing is printed
                            # here - the W32T.InstallerVariantUnavailable error below explains (re-verification 2026-10-21).
                            $missText = if ($s) { "no $s-scope '$t' installer" } else { "no '$t' installer" }
                            $nextText = if ($si + 1 -lt $tryScopes.Count) {
                                "trying '$t' without a scope"
                            }
                            elseif ($ti + 1 -lt $types.Count) {
                                $nextScope = if ($tryScopes[0]) { ", $($tryScopes[0]) scope" } else { '' }
                                "trying '$($types[$ti + 1])' (same technology family$nextScope)"
                            }
                            else { $null }
                            if ($nextText) {
                                Write-Host "winget offers $missText for '$AppId' $verLabel (the line above is winget's); $nextText." -ForegroundColor DarkGray
                            }
                        }
                        else {
                            throw ("winget download exited with code {0} (0x{0:X8}) for '{1}' {2}.{3}" -f $code, $AppId, $verLabel, (& $authHint $code))
                        }
                    }
                    if ($done) {
                        if ($pinScope -and -not $s) {
                            $scopeRelaxed = $true
                            Write-Warning "$verLabel has no $pinScope-scope $t installer; the baseline uses winget's choice of scope for $t."
                        }
                        break
                    }
                }
                if ($done) { break }
            }

            if (-not $done) {
                # $oldVersionDir is left exactly as it was (L21).
                $familyName = [string](Get-Win32ToolkitInstallerFamily -Type $InstallerType).Family
                $familyLabel = switch ($familyName) { 'msi' { 'MSI' } 'exe' { 'vendor EXE' } 'msix' { 'MSIX package' } default { $familyName } }
                $archText = if ($Architecture) { $Architecture } else { 'any architecture' }
                $relaxedText = if ($pinScope) { ', each scope also relaxed' } else { '' }
                $msg = "winget offers no $familyLabel installer for $AppId $verLabel ($archText); tried: $($attempts -join ', ')$relaxedText. " +
                       'The Update baseline cannot use that technology at this version: pick a version that ships it (-SpecificVersion) or another technology (-BaselineInstallerType).'
                throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($msg),
                    'W32T.InstallerVariantUnavailable', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $AppId)
            }

            # Success: only now is the previous baseline replaced by the downloaded (or cached) one.
            & $clearDir $oldVersionDir
            Get-ChildItem -LiteralPath $downloadDir -Force | Move-Item -Destination $oldVersionDir -Force -ErrorAction Stop
        }
        finally {
            # The staging folder never outlives the call: moved into place on success, discarded otherwise.
            if (Test-Path -LiteralPath $downloadDir) { Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    elseif (-not (& $useCache $cacheDir)) {
        Write-Verbose "Downloading $verLabel of '$AppId'..."

        # Pin the packaged variant so the baseline matches (machine vs user scope, msi vs exe, locale).
        $pinArgs = @()
        if ($Scope -and $Scope -in @('machine', 'user')) { $pinArgs += '--scope';          $pinArgs += $Scope }
        if ($InstallerType)                              { $pinArgs += '--installer-type'; $pinArgs += $InstallerType }
        if ($Locale)                                     { $pinArgs += '--locale';         $pinArgs += $Locale }

        $attempt = Invoke-Win32ToolkitWingetDownload -ArgumentList ($downloadArgs + $pinArgs) -Label "'$AppId' $verLabel"
        # A source that could not authenticate was left out by the retry: the unpinned retry asks 'winget' directly.
        if ($attempt.SourceFallback) { $downloadArgs += @('--source', 'winget') }
        $code = $attempt.ExitCode

        if ($code -ne 0 -and $pinArgs.Count -gt 0) {
            # The old version may not publish the pinned variant (or the winget build may not support a
            # pin flag) — retry unpinned rather than failing the whole test, but say so clearly.
            Write-Warning "Pinned download (scope/installer-type/locale of the packaged variant) failed for '$AppId' $verLabel — retrying without pins. The baseline may be a DIFFERENT variant than the packaged app; check the installed baseline in the sandbox."
            Get-ChildItem -LiteralPath $oldVersionDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            $code = (Invoke-Win32ToolkitWingetDownload -ArgumentList $downloadArgs -Label "'$AppId' $verLabel").ExitCode
            $usedFallback = $true
        }

        if ($code -ne 0) {
            throw ("winget download exited with code {0} (0x{0:X8}) for '{1}' {2}.{3}" -f $code, $AppId, $verLabel, (& $authHint $code))
        }

        # Cache the download — but NEVER a fallback result under the pinned key: the unpinned retry can
        # legitimately deliver a DIFFERENT variant, and caching it would poison every future pinned run
        # (unlike today's re-download, a cache would never self-heal when the vendor publishes the
        # pinned variant).
        if (-not $usedFallback) { & $storeCache $cacheDir }
    }

    # Locate the downloaded installer file
    $installer = Get-ChildItem -Path $oldVersionDir -File |
        Where-Object { $_.Extension -in (Get-Win32ToolkitInstallerExtension) } |
        Select-Object -First 1

    # Read the manifest installer type first — it lets the "no installer found" message below name the
    # type (e.g. a 'zip' package downloads no .exe/.msi/.msix/.appx), and drives the silent-args choice.
    # InstallerType lives in *.installer.yaml — NOT in the locale manifest that winget also writes here
    # (and that often sorts first). Read it as UTF-8 like every other manifest read.
    $installerTypeName = $null
    $yamlFile = Get-WingetManifestFile -Path $oldVersionDir -Kind Installer
    if ($yamlFile) {
        $yamlContent = Get-Content -LiteralPath $yamlFile.FullName -Raw -Encoding UTF8
        if ($yamlContent -match '(?m)^\s*InstallerType:\s*(\S+)') {
            $installerTypeName = $matches[1].Trim().ToLowerInvariant()
        }
    }

    if (-not $installer) {
        $typeHint = if ($installerTypeName) { " (manifest InstallerType: '$installerTypeName')" } else { '' }
        throw "winget download completed but no installer file (.exe/.msi/.msix/.appx/.msixbundle/.appxbundle) was found in $oldVersionDir$typeHint. This baseline may be a zip/portable/store package with no silent installer — use -SpecificVersion for a different version, or test with -Scenario InstallUninstall."
    }

    $yamlInfo   = Get-YAMLInstallerInfo -FilesPath $oldVersionDir
    $yamlSilent = if ($yamlInfo) { $yamlInfo.SilentArgs } else { $null }
    $resolved = Resolve-Win32ToolkitBaselineSilentArgs `
        -InstallerTypeName $installerTypeName `
        -Extension         $installer.Extension `
        -YamlSilentArgs    $yamlSilent
    $silentArgs = $resolved.SilentArgs
    if ($resolved.Guessed) {
        Write-Warning "No silent switches found in the winget manifest for '$($installer.Name)' — guessing '/S'. If the baseline install shows UI or hangs in the sandbox, the update run will be INCONCLUSIVE; use -SpecificVersion for a version whose manifest has silent switches, or watch the sandbox."
    }

    Write-Host "✓ Downloaded    : $($installer.Name)"  -ForegroundColor Green
    Write-Host "  Installer type: $installerTypeName"  -ForegroundColor Gray
    Write-Host "  Silent args   : $silentArgs"         -ForegroundColor Gray

    # The downloaded variant, for the Update test record (installer-identity PR 1). Family, TriedTypes and
    # ScopeRelaxed are filled only under -FamilyPin, so the default path calls no new helper.
    $manifestType = if ($installerTypeName) { $installerTypeName.Trim("'", '"') }
                    elseif ($yamlInfo -and $yamlInfo.InstallerType) { [string]$yamlInfo.InstallerType }
                    else { '' }
    $family = ''
    if ($FamilyPin) {
        $familyType = if ($manifestType) { $manifestType } else { $InstallerType }
        $family = [string](Get-Win32ToolkitInstallerFamily -Type $familyType).Family
    }

    return [PSCustomObject]@{
        InstallerPath          = $installer.FullName
        InstallerName          = $installer.Name
        # Normalized to INSTALL SEMANTICS, never the raw extension: a '.msixbundle' must report 'msix'.
        # Consumers key off this — the guest dependency script dispatches on `-eq 'msix' -or -eq 'appx'`
        # (a raw 'msixbundle' would fall through to Start-Process and hang the sandbox on the App
        # Installer GUI) and Get-Win32ToolkitBaselineInstallCommand ValidateSets exe|msi|msix|appx.
        InstallerType          = Get-Win32ToolkitInstallerType -Extension $installer.Extension
        SilentArgs             = $silentArgs
        UsedFallback           = $usedFallback
        RequestedInstallerType = [string]$InstallerType
        ManifestInstallerType  = $manifestType
        ManifestProductCode    = if ($yamlInfo -and $yamlInfo.ProductCode) { [string]$yamlInfo.ProductCode } else { '' }
        Scope                  = if ($yamlInfo -and $yamlInfo.Scope) { [string]$yamlInfo.Scope } else { '' }
        Locale                 = if ($yamlInfo -and $yamlInfo.InstallerLocale) { [string]$yamlInfo.InstallerLocale } else { '' }
        Family                 = $family
        TriedTypes             = @(if ($FamilyPin) { $triedTypes.ToArray() })
        ScopeRelaxed           = $scopeRelaxed
    }
}
