function Get-Win32ToolkitSiblingInstaller {
    <#
    .SYNOPSIS
        Asks winget-pkgs which installer technologies one app version ships (the sibling probe).
    .DESCRIPTION
        One raw GET of the version's *.installer.yaml from the public winget-pkgs repository, a short timeout,
        fail-open (installer-identity PR 1, spec 2.7, D2). The manifest is parsed by an indentation-aware
        tuple reader (no YAML module, nothing is executed): one tuple per Installers: item, root-level keys
        inherited (e.g. a root 'InstallerType: zip'), EffectiveType = NestedInstallerType for a zip, and the
        first InstallerType inside an item's AppsAndFeaturesEntries: block is the item's RegisteredType (the
        technology the installer registers as: Paint.NET's zipped EXE registers as its MSI).

        Siblings = registering tuples for -Architecture (or 'neutral') whose family differs from
        -PackagedType's (all registering families when -PackagedType is not given), one per EffectiveType,
        highest precedence first. SameFamilyOther = same family, other registration type (msi and wix count
        as one). NotRegistering = e.g. zip/portable. Consumers split Siblings by Testable.

        Results are memoised per process in $script:W32TSiblingProbeMemo (key BaseUri|WingetId|Version|
        Architecture, lower-case): Ok and NotFound for the process, RateLimited until its RetryAfterUtc,
        Network/Timeout/TooLarge/Parse for five minutes; -RetryFailed asks a memoised failure again, -NoMemo bypasses
        the memo. Every value read from the manifest passes ConvertTo-Win32ToolkitSafeText.
        Logging is Write-Verbose only: the callers print the warnings. Never throws. An HTTP error status is read
        as a response (-SkipHttpErrorCheck), so it leaves no error record; a DNS/TLS/proxy/timeout/redirect failure
        is caught and leaves one $Error record.

        HTTP 429 (live rows RAISE, INNO: raw.githubusercontent.com limits a host that asks for many manifests): the
        Retry-After header (seconds or an RFC 1123 HTTP date; none or unreadable -> 60 s) is clamped to 1-600 s. A wait of at
        most 15 s is waited once and the GET asked again; otherwise, or when the second answer is a 429 too, the
        result is RateLimited and the process-wide gate $script:W32TSiblingProbeRateLimitUntil (UTC) closes until
        then: while it is closed every probe returns RateLimited without a request (-RetryFailed too). -NoMemo
        neither reads nor closes the gate.

        Status/Reason: Ok/''; Unavailable/NotFound (404), RateLimited (429; RetryAfterUtc says when to ask again),
        Network (any other HTTP status, DNS, TLS, proxy), Timeout, TooLarge (> 2 MB), Parse (no Installers: tuple),
        InvalidId (bad id, version or BaseUri: no request is made); Skipped/NoWingetId.
    .PARAMETER WingetId
        The winget PackageIdentifier ('' -> Skipped).
    .PARAMETER Version
        The PackageVersion ('Unknown', blank or not a single path segment -> InvalidId, no request).
    .PARAMETER Architecture
        The packaged architecture (x64, x86, arm64); tuples marked 'neutral' always match.
    .PARAMETER PackagedType
        The packaged installer type; its family is excluded from Siblings.
    .PARAMETER TimeoutSec
        The GET timeout (default 10).
    .PARAMETER BaseUri
        The manifests root (https only). For tests; the default is the public winget-pkgs master branch.
    .PARAMETER NoMemo
        Bypass the per-process memo and the rate-limit gate (tests).
    .PARAMETER RetryFailed
        Ask again when the memo holds a failure (an explicit capture plan); Ok and NotFound are still reused, and a
        closed rate-limit gate still answers RateLimited without a request.
    .OUTPUTS
        [pscustomobject] SchemaVersion, Status, Reason, Url, ProbedUtc, FromMemo, WingetId, Version,
        Architecture, PackagedType, PackagedFamily, Tuples, Siblings, SameFamilyOther, NotRegistering, ReleaseDate (the
        manifest's root ReleaseDate, yyyy-MM-dd, or '' when the root has none or it is no calendar day, e.g. 2025-02-30;
        each tuple carries its own date, the root's unless the installer sets one, '' under the same rule),
        RetryAfterUtc (RateLimited: when to ask again, ISO 8601 UTC; '' otherwise).
    .EXAMPLE
        Get-Win32ToolkitSiblingInstaller -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1' -Architecture x64 -PackagedType wix
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WingetId,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Architecture,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$PackagedType = '',

        [ValidateRange(1, 300)]
        [int]$TimeoutSec = 10,

        [ValidateNotNullOrEmpty()]
        [string]$BaseUri = 'https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests',

        [switch]$NoMemo,

        [switch]$RetryFailed
    )

    $ProgressPreference = 'SilentlyContinue'   # no progress bar from Invoke-WebRequest (local to this call)

    $id    = ([string]$WingetId).Trim()
    $ver   = ([string]$Version).Trim()
    $arch  = ([string]$Architecture).Trim().ToLowerInvariant()
    $ptype = ([string]$PackagedType).Trim().ToLowerInvariant()
    $base  = ([string]$BaseUri).Trim().TrimEnd('/')
    $pfam  = if ($ptype) { [string](Get-Win32ToolkitInstallerFamily -Type $ptype).Family } else { '' }
    $now   = [datetime]::UtcNow

    # ---- The tuple reader (pure; indentation-aware; values are data, never executed) ----
    $parse = {
        param([string]$Text)
        $want  = @('Architecture', 'InstallerType', 'NestedInstallerType', 'Scope', 'ProductCode', 'InstallerLocale', 'ReleaseDate')
        $clean = {
            param([string]$Value)
            $v = ($Value -replace '\s+#.*$', '').Trim()
            if ($v.Length -ge 2 -and $v[0] -eq "'" -and $v[-1] -eq "'") { $v = $v.Substring(1, $v.Length - 2).Replace("''", "'") }
            elseif ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[-1] -eq '"') { $v = $v.Substring(1, $v.Length - 2) }
            ConvertTo-Win32ToolkitSafeText -Text $v -MaxLength 128
        }
        # A ReleaseDate is kept only when it is a real calendar day in yyyy-MM-dd: the pattern alone lets an impossible
        # manifest date (2025-02-30, 2025-13-01) through, and a consumer that parses it would throw.
        $dateOk = {
            param([string]$Value)
            $d = [datetime]::MinValue
            $Value -match '^\d{4}-\d{2}-\d{2}$' -and [datetime]::TryParseExact($Value, 'yyyy-MM-dd',
                [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)
        }
        $root  = @{}
        $items = [System.Collections.Generic.List[hashtable]]::new()
        $inInstallers = $false
        $itemIndent = -1; $ownKeyCol = -1
        $cur = $null; $inAfe = $false
        foreach ($line in ($Text -split "`r?`n")) {
            if ($line -match '^\s*(#|$)') { continue }
            $ind = $line.Length - $line.TrimStart(' ').Length
            if ($ind -eq 0 -and -not $line.StartsWith('-')) {
                # A column-0 key: a root key, or the start/end of the Installers: block.
                $cur = $null; $inAfe = $false
                $inInstallers = $line -match '^Installers:\s*(#.*)?$'
                if (-not $inInstallers -and $line -match '^([A-Za-z][A-Za-z0-9]*):\s*(\S.*)$' -and $Matches[1] -in $want) {
                    $rootKey = $Matches[1]; $rootVal = $Matches[2]
                    $root[$rootKey] = & $clean $rootVal
                }
                continue
            }
            if (-not $inInstallers) { continue }
            if ($line -notmatch '^(?<ind>\s*)(?<dash>-\s+)?(?<key>[A-Za-z][A-Za-z0-9]*):(?:\s+(?<val>.*))?\s*$') { continue }
            $dash = [string]$Matches['dash']
            $key  = $Matches['key']
            $val  = [string]$Matches['val']
            $keyCol = $ind + $dash.Length
            if ($dash -and ($itemIndent -lt 0 -or $ind -eq $itemIndent)) {
                # A new installer item.
                $itemIndent = $ind; $ownKeyCol = $keyCol
                $cur = @{}; $items.Add($cur); $inAfe = ($key -eq 'AppsAndFeaturesEntries')
                if ($key -in $want -and $val.Trim()) { $cur[$key] = & $clean $val }
                continue
            }
            if ($null -eq $cur) { continue }
            if (-not $dash -and $keyCol -eq $ownKeyCol) {
                # The item's own key.
                $inAfe = ($key -eq 'AppsAndFeaturesEntries')
                if ($key -in $want -and $val.Trim()) { $cur[$key] = & $clean $val }
                continue
            }
            if ($keyCol -gt $ownKeyCol -and $inAfe -and $key -eq 'InstallerType' -and -not $cur.ContainsKey('RegisteredType') -and $val.Trim()) {
                # The first InstallerType of AppsAndFeaturesEntries = what the installer registers as.
                $cur['RegisteredType'] = & $clean $val
            }
        }

        # The version's own release date is the ROOT key (L32); an installer's own date stays on its tuple only.
        if (& $dateOk ([string]$root['ReleaseDate'])) { $parsed.ReleaseDate = [string]$root['ReleaseDate'] }
        foreach ($it in $items) {
            foreach ($k in $want) { if (-not $it.ContainsKey($k) -and $root.ContainsKey($k)) { $it[$k] = $root[$k] } }
            $type   = ([string]$it['InstallerType']).ToLowerInvariant()
            $nested = ([string]$it['NestedInstallerType']).ToLowerInvariant()
            $reg    = ([string]$it['RegisteredType']).ToLowerInvariant()
            $own    = Get-Win32ToolkitInstallerFamily -Type $type -NestedType $nested
            $regRow = if ($reg) { Get-Win32ToolkitInstallerFamily -Type $reg } else { $own }
            [pscustomobject]@{
                Architecture        = ([string]$it['Architecture']).ToLowerInvariant()
                InstallerType       = $type
                NestedInstallerType = $nested
                EffectiveType       = $own.EffectiveType
                RegisteredType      = $reg
                Family              = $regRow.Family
                Scope               = ([string]$it['Scope']).ToLowerInvariant()
                ProductCode         = [string]$it['ProductCode']
                Locale              = [string]$it['InstallerLocale']
                ReleaseDate         = if (& $dateOk ([string]$it['ReleaseDate'])) { [string]$it['ReleaseDate'] } else { '' }
                ZipWrapped          = $own.ZipWrapped
                Registers           = $regRow.Registers
                Testable            = $own.Testable
                PinValue            = $own.PinValue
                Precedence          = $own.Precedence
                Label               = $own.Label
            }
        }
    }

    $result = [ordered]@{
        SchemaVersion   = '1.0'
        Status          = 'Unavailable'
        Reason          = ''
        Url             = ''
        ProbedUtc       = $now.ToString('o')
        FromMemo        = $false
        WingetId        = ConvertTo-Win32ToolkitSafeText -Text $id -MaxLength 128
        Version         = ConvertTo-Win32ToolkitSafeText -Text $ver -MaxLength 128
        Architecture    = ConvertTo-Win32ToolkitSafeText -Text $arch -MaxLength 32
        PackagedType    = ConvertTo-Win32ToolkitSafeText -Text $ptype -MaxLength 32
        PackagedFamily  = $pfam
        Tuples          = @()
        Siblings        = @()
        SameFamilyOther = @()
        NotRegistering  = @()
        ReleaseDate     = ''
        RetryAfterUtc   = ''
    }

    # ---- Validate before any request ----
    if (-not $id) {
        $result.Status = 'Skipped'; $result.Reason = 'NoWingetId'
        Write-Verbose 'Sibling probe skipped: no winget id.'
        return [pscustomobject]$result
    }
    $idOk   = $id -match '^[^.\s\\/:*?"<>|\x00-\x1f%#]{1,32}(\.[^.\s\\/:*?"<>|\x00-\x1f%#]{1,32}){1,7}$'
    $verOk  = $ver -match '^[^\\/:*?"<>|\x00-\x1f%#\s]{1,128}$' -and $ver -notmatch '\.\.' -and $ver -ne '.' -and $ver -ne 'Unknown'
    $baseOk = $base.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not ($idOk -and $verOk -and $baseOk)) {
        $result.Reason = 'InvalidId'
        Write-Verbose "Sibling probe not run: invalid id, version or base URI (id ok: $idOk, version ok: $verOk, https: $baseOk)."
        return [pscustomobject]$result
    }

    $segments = @($id.Split('.') | ForEach-Object { [uri]::EscapeDataString($_) })
    $url = '{0}/{1}/{2}/{3}/{4}.installer.yaml' -f $base, $id.Substring(0, 1).ToLowerInvariant(), ($segments -join '/'),
        [uri]::EscapeDataString($ver), [uri]::EscapeDataString($id)
    $result.Url = $url

    # ---- Memo ----
    $memoKey = ('{0}|{1}|{2}|{3}' -f $base, $id, $ver, $arch).ToLowerInvariant()
    $entry = $null
    if (-not $NoMemo) {
        # -ErrorAction Ignore, not SilentlyContinue: a first call must not leave a VariableNotFound record in
        # $Error or in a caller's -ErrorVariable.
        if ((Get-Variable -Name W32TSiblingProbeMemo -Scope Script -ValueOnly -ErrorAction Ignore) -isnot [hashtable]) {
            $script:W32TSiblingProbeMemo = @{}
        }
        $hit = $script:W32TSiblingProbeMemo[$memoKey]
        if ($hit) {
            # Ok and NotFound for the process; a failure is asked again with -RetryFailed; RateLimited until its time;
            # any other failure for five minutes.
            $fresh = if ($hit.Status -eq 'Ok' -or $hit.Reason -eq 'NotFound') { $true }
                     elseif ($RetryFailed) { $false }
                     elseif ($hit.Reason -eq 'RateLimited') { $hit.RetryAfter -is [datetime] -and [datetime]::UtcNow -lt $hit.RetryAfter }
                     else { ($now - [datetime]$hit.CachedUtc).TotalMinutes -lt 5 }
            if ($fresh) { $entry = $hit; $result.FromMemo = $true; Write-Verbose "Sibling probe: memo hit for $url" }
        }
    }

    if (-not $entry) {
        $status = 'Unavailable'; $reason = ''; $tuples = @(); $retryAt = $null
        $parsed = @{ ReleaseDate = '' }   # the root ReleaseDate, set by the reader (a hashtable: it runs in a child scope)
        $text = $null
        # A Retry-After value (untrusted) as the seconds to wait, 1-600: ASCII delta-seconds of any length, or an HTTP date
        # in the RFC 1123 form both header sources normalise every valid date to; anything else (none, '3, 4', '12.31') ->
        # 60. Clamped as doubles: Math.Min(int, int) would throw on a value outside Int32 (the probe never throws).
        $waitOf = {
            param([string]$Value)
            $v = ([string]$Value).Trim()
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $s = 60.0; $n = 0.0; $d = [datetimeoffset]::MinValue
            if ($v -cmatch '^[0-9]+$' -and [double]::TryParse($v, [System.Globalization.NumberStyles]::None, $inv, [ref]$n)) { $s = $n }
            elseif ($v -and [datetimeoffset]::TryParseExact($v, 'r', $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) {
                $s = [Math]::Ceiling(($d.UtcDateTime - [datetime]::UtcNow).TotalSeconds)
            }
            [int][Math]::Max(1.0, [Math]::Min(600.0, [double]$s))
        }
        $gate = if ($NoMemo) { $null } else { Get-Variable -Name W32TSiblingProbeRateLimitUntil -Scope Script -ValueOnly -ErrorAction Ignore }
        if ($gate -is [datetime] -and [datetime]::UtcNow -lt $gate) {
            # GitHub limited this computer a moment ago: no request until then (live rows RAISE, INNO).
            $reason = 'RateLimited'; $retryAt = $gate
            Write-Verbose "Sibling probe: not asked ($url); GitHub limits requests from this computer until $($gate.ToString('o'))."
        }
        else {
            # At most two attempts: the second only after a 429 whose Retry-After is 15 s or less.
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                $reason = ''; $text = $null; $retryHeader = ''
                try {
                    Write-Verbose "Sibling probe: GET $url"
                    # -SkipHttpErrorCheck (PowerShell 7.0+; re-verification 2026-10-21, B1 r2.1): an HTTP error status (404,
                    # 429, 5xx) comes back as a response and is classified below, so a passing build keeps no record of it in
                    # $Error or in a caller's -ErrorVariable (a thrown one did, plus 'TerminatingError(Invoke-WebRequest)' in a
                    # transcript). A failure without a usable response (DNS, TLS, proxy, timeout, a redirect refused by
                    # -MaximumRedirection 0) still throws into the catch: classified there, it still leaves one $Error record
                    # by design (fail-open: a status, never a throw).
                    $resp = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction Stop
                    $code = [int]$resp.StatusCode
                    if ($code -eq 404) { $reason = 'NotFound' }
                    elseif ($code -eq 429) {
                        $reason = 'RateLimited'
                        if ($resp.PSObject.Properties['Headers'] -and $resp.Headers) {
                            foreach ($hk in @($resp.Headers.Keys)) { if ([string]$hk -eq 'Retry-After') { $retryHeader = [string](@($resp.Headers[$hk]) | Select-Object -First 1) } }
                        }
                    }
                    elseif ($code -ne 200) { $reason = 'Network' }
                    else {
                        $content = $resp.Content
                        if ($content -is [byte[]]) {
                            if ($content.Length -gt 2MB) { $reason = 'TooLarge' } else { $text = [System.Text.Encoding]::UTF8.GetString($content) }
                        } else {
                            $text = [string]$content
                            if ($text.Length -gt 2MB) { $reason = 'TooLarge'; $text = $null }
                        }
                    }
                } catch {
                    if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                    $httpCode = 0; $timedOut = $false
                    $ex = $_.Exception
                    while ($ex) {
                        if ($ex -is [System.TimeoutException] -or $ex -is [System.OperationCanceledException]) { $timedOut = $true }
                        if (-not $httpCode -and $ex.PSObject.Properties['Response'] -and $ex.Response -and
                            $ex.Response.PSObject.Properties['StatusCode']) {
                            $httpCode = [int]$ex.Response.StatusCode
                            if ($ex.Response.PSObject.Properties['Headers'] -and $ex.Response.Headers -and
                                $ex.Response.Headers.PSObject.Properties['RetryAfter'] -and $ex.Response.Headers.RetryAfter) { $retryHeader = [string]$ex.Response.Headers.RetryAfter }
                        }
                        $ex = $ex.InnerException
                    }
                    $reason = if ($httpCode -eq 404) { 'NotFound' } elseif ($httpCode -eq 429) { 'RateLimited' } elseif ($httpCode) { 'Network' } elseif ($timedOut) { 'Timeout' } else { 'Network' }
                    Write-Verbose "Sibling probe: GET failed ($reason): $($_.Exception.Message)"
                }
                if ($reason -ne 'RateLimited') { break }
                $wait = & $waitOf $retryHeader
                if ($attempt -eq 1 -and $wait -le 15) {
                    Write-Verbose "Sibling probe: HTTP 429; asking again in $wait s."
                    Start-Sleep -Seconds $wait
                    continue
                }
                $retryAt = [datetime]::UtcNow.AddSeconds($wait)
                if (-not $NoMemo) { $script:W32TSiblingProbeRateLimitUntil = $retryAt }
                Write-Verbose "Sibling probe: HTTP 429; no request until $($retryAt.ToString('o'))."
                break
            }
        }
        if ($null -ne $text -and -not $reason) {
            $tuples = @(& $parse $text)
            if ($tuples.Count -eq 0) { $reason = 'Parse' } else { $status = 'Ok' }
        }
        $entry = @{ Status = $status; Reason = $reason; Url = $url; ProbedUtc = $now.ToString('o'); Tuples = $tuples; CachedUtc = $now; ReleaseDate = [string]$parsed.ReleaseDate; RetryAfter = $retryAt }
        if (-not $NoMemo) { $script:W32TSiblingProbeMemo[$memoKey] = $entry }
    }

    $result.Status    = $entry.Status
    $result.Reason    = $entry.Reason
    $result.ProbedUtc = $entry.ProbedUtc
    $result.Tuples    = @($entry.Tuples)
    if ($entry['RetryAfter'] -is [datetime]) { $result.RetryAfterUtc = ([datetime]$entry['RetryAfter']).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($entry.Status -ne 'Ok') { return [pscustomobject]$result }
    # The version's release date (installer-identity PR 3b, L32: the sibling-capture floor): the manifest's ROOT ReleaseDate,
    # '' when it has none (an installer's own date stays on its tuple: one installer's date is not the version's).
    $result.ReleaseDate = [string]$entry['ReleaseDate']

    # ---- Split for this architecture and packaged type (recomputed per call; the memo holds the tuples) ----
    $forArch = @($entry.Tuples | Where-Object { -not $arch -or $_.Architecture -eq $arch -or $_.Architecture -eq 'neutral' } |
        Sort-Object -Stable -Property Precedence, @{ Expression = { -not $_.Testable } })
    $pick = {
        param([object[]]$Tuples, [scriptblock]$Key)
        $seen = @{}
        foreach ($t in $Tuples) {
            $k = & $Key $t
            if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $t }
        }
    }
    $isMsiPair = { param([string]$A, [string]$B) ($A -in @('msi', 'wix')) -and ($B -in @('msi', 'wix')) }

    $result.Siblings = @(& $pick @($forArch | Where-Object { $_.Registers -and $_.Family -ne $pfam }) { param($t) $t.EffectiveType })
    if ($ptype) {
        $result.SameFamilyOther = @(& $pick @($forArch | Where-Object {
                    $regType = if ($_.RegisteredType) { $_.RegisteredType } else { $_.EffectiveType }
                    $_.Registers -and $_.Family -eq $pfam -and $regType -ne $ptype -and -not (& $isMsiPair $regType $ptype)
                }) { param($t) $t.EffectiveType })
    }
    $result.NotRegistering = @(& $pick @($forArch | Where-Object { -not $_.Registers }) { param($t) "$($t.InstallerType)|$($t.EffectiveType)" })

    return [pscustomobject]$result
}
