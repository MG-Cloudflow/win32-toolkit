function ConvertFrom-Win32ToolkitWingetManifest {
    <#
    .SYNOPSIS
        Reads the installer facts of a winget manifest (installer, merged or singleton form) without a YAML module.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.3, L21, SV19). A sibling capture needs more of a winget manifest than
        Get-YAMLInstallerInfo reads: every installer of the version with its switches (Silent, SilentWithProgress,
        Custom), its product and upgrade codes, its Apps and Features entries and its default install location.

        Pure and data-only: an indentation-aware reader of the YAML subset winget-pkgs manifests use (block maps, block
        lists of maps or scalars, quoted and plain scalars, comments, '|' / '>' block scalars skipped, several documents
        separated by '---'); nothing is executed. Root-level installer keys are inherited the way winget inherits them
        (winget-cli ManifestYamlPopulator): Architecture, InstallerType, Scope, InstallerLocale, UpgradeCode and
        ReleaseDate by every installer that does not set them; NestedInstallerType only by a zip installer; ProductCode
        and AppsAndFeaturesEntries only by an installer whose effective type uses them (exe, inno, msi, nullsoft, wix,
        burn, portable) and has none of its own; InstallerSwitches and InstallationMetadata key by key (the root's
        Silent stays when an installer only adds Custom). Package facts (PackageIdentifier, PackageVersion, PackageName,
        Publisher, ReleaseDate) come from any document, the first non-empty value winning. YAML quotes are read as YAML
        reads them: a single-quoted value ends at its first lone quote ('' is one quote), a double-quoted one has its
        backslash escapes decoded; a trailing comment is dropped. Every value passes ConvertTo-Win32ToolkitSafeText (at
        most 256 characters; the InstallerSwitches values at most 2048, the longest winget-pkgs' schema allows (Custom):
        Download-OldVersionInstaller runs them, and a cut switch would change the install).

        Never throws: text without an 'Installers:' list, nested deeper than 32 levels, or that cannot be read gives $null.
    .PARAMETER Text
        The manifest text (several files may be concatenated with a '---' line between them).
    .OUTPUTS
        [pscustomobject] PackageIdentifier, PackageVersion, PackageName, Publisher, ReleaseDate, Installers[]
        {Architecture, InstallerType, NestedInstallerType, Scope, InstallerLocale, ProductCode, UpgradeCode, ReleaseDate,
        InstallerSwitches {Silent, SilentWithProgress, Custom}, AppsAndFeaturesEntries[] {DisplayName, Publisher,
        DisplayVersion, ProductCode, UpgradeCode, InstallerType}, DefaultInstallLocation}, or $null.
    .EXAMPLE
        $m = ConvertFrom-Win32ToolkitWingetManifest -Text (Get-Content -LiteralPath $yaml -Raw -Encoding UTF8)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    try {
        # ---- tokens: one per meaningful line ----
        $scalar = {
            param([string]$Raw)
            $v = $Raw.Trim()
            if ($v.Length -ge 2 -and $v[0] -eq "'") {
                # Single-quoted: '' is one quote; the value ends at the first quote that is not doubled (a comment after
                # it is dropped). Unterminated: read as a plain value below.
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 1; $i -lt $v.Length; $i++) {
                    if ($v[$i] -ne "'") { [void]$sb.Append($v[$i]); continue }
                    if ($i + 1 -lt $v.Length -and $v[$i + 1] -eq "'") { [void]$sb.Append("'"); $i++; continue }
                    return $sb.ToString()
                }
            }
            elseif ($v.Length -ge 2 -and $v[0] -eq '"') {
                # Double-quoted: the YAML backslash escapes are decoded (an unknown one is kept as written); the value
                # ends at the first unescaped quote. Unterminated: read as a plain value below.
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 1; $i -lt $v.Length; $i++) {
                    $ch = $v[$i]
                    if ($ch -eq '"') { return $sb.ToString() }
                    if ($ch -ne '\' -or $i + 1 -ge $v.Length) { [void]$sb.Append($ch); continue }
                    $i++
                    $e = [string]$v[$i]
                    $width = switch -CaseSensitive ($e) { 'x' { 2 } 'u' { 4 } 'U' { 8 } default { 0 } }
                    if ($width -gt 0) {
                        $code = -1
                        if ($i + $width -lt $v.Length -and $v.Substring($i + 1, $width) -match '^[0-9A-Fa-f]+$') { $code = [Convert]::ToInt32($v.Substring($i + 1, $width), 16) }
                        if ($code -ge 0 -and $code -le 0x10FFFF -and ($code -lt 0xD800 -or $code -gt 0xDFFF)) { [void]$sb.Append([char]::ConvertFromUtf32($code)); $i += $width }
                        else { [void]$sb.Append('\').Append($e) }
                        continue
                    }
                    $decoded = switch -CaseSensitive ($e) {
                        '0' { [string][char]0 } 'a' { [string][char]7 } 'b' { [string][char]8 } 't' { "`t" } "`t" { "`t" }
                        'n' { "`n" } 'v' { [string][char]11 } 'f' { [string][char]12 } 'r' { "`r" } 'e' { [string][char]27 }
                        ' ' { ' ' } '"' { '"' } '/' { '/' } '\' { '\' } 'N' { [string][char]0x85 } '_' { [string][char]0xA0 }
                        'L' { [string][char]0x2028 } 'P' { [string][char]0x2029 } default { '\' + $e }
                    }
                    [void]$sb.Append($decoded)
                }
            }
            ($v -replace '\s+#.*$', '').Trim()
        }
        $documents = [System.Collections.Generic.List[object]]::new()
        $tokens = [System.Collections.Generic.List[object]]::new()
        $blockIndent = -1
        foreach ($line in ($Text -split "`r?`n")) {
            if ($line -match '^---\s*$' -or $line -match '^\.\.\.\s*$') {
                if ($tokens.Count) { $documents.Add($tokens); $tokens = [System.Collections.Generic.List[object]]::new() }
                $blockIndent = -1
                continue
            }
            if ($line -match '^\s*(#.*)?$') { continue }
            $ind = $line.Length - $line.TrimStart(' ').Length
            if ($blockIndent -ge 0) {
                if ($ind -gt $blockIndent) { continue }   # the text of a '|' or '>' block scalar
                $blockIndent = -1
            }
            $body = $line.Substring($ind)
            $dash = $false; $col = $ind
            if ($body -match '^-(\s+|$)') {
                $dash = $true
                $rest = $body.Substring(1)
                $col = $ind + 1 + ($rest.Length - $rest.TrimStart(' ').Length)
                $body = $rest.TrimStart(' ')
            }
            $key = $null; $value = $null
            if ($body -match '^(?<k>[A-Za-z_][A-Za-z0-9_.-]*)\s*:(?:\s+(?<v>.*))?$') {
                $key = $Matches['k']; $value = [string]$Matches['v']
                if ($value -match '^[|>][+-]?\d*\s*(#.*)?$') { $blockIndent = $col; $value = '' }
            }
            else { $value = $body }
            $tokens.Add([pscustomobject]@{ Indent = $ind; Col = $col; Dash = $dash; Key = $key; Value = $value })
        }
        if ($tokens.Count) { $documents.Add($tokens) }

        # ---- tokens -> nodes (hashtables for maps, lists for sequences, strings for scalars) ----
        $state = @{ Tokens = $null; I = 0; Depth = 0 }
        $parseMap = $null; $parseList = $null; $parseValue = $null
        $parseValue = {
            # The value of a 'key:' with nothing after it: the block that follows, if any.
            param([int]$KeyCol)
            $t = $state.Tokens
            if ($state.I -ge $t.Count) { return '' }
            $n = $t[$state.I]
            $isList = $n.Dash -and $n.Indent -ge $KeyCol
            $isMap = -not $n.Dash -and $n.Indent -gt $KeyCol -and $n.Key
            if (-not ($isList -or $isMap)) { return '' }
            # The only place the reader descends. A winget manifest nests about six levels; deeper text is not one (and
            # every level costs a nested call, so a hostile file could keep the reader busy for minutes): give up.
            if ($state.Depth -ge 32) { throw 'nested deeper than 32 levels' }
            $state.Depth++
            try {
                if ($isList) { return , (& $parseList $n.Indent) }
                return (& $parseMap $n.Indent)
            }
            finally { $state.Depth-- }
        }
        $parseMap = {
            param([int]$Col)
            $map = @{}
            $t = $state.Tokens
            while ($state.I -lt $t.Count) {
                $n = $t[$state.I]
                if ($n.Dash -or $n.Indent -ne $Col -or -not $n.Key) { break }
                $state.I++
                if ($n.Value) { $map[$n.Key] = & $scalar $n.Value }
                else { $map[$n.Key] = & $parseValue $Col }
            }
            return $map
        }
        $parseList = {
            param([int]$Indent)
            $list = [System.Collections.Generic.List[object]]::new()
            $t = $state.Tokens
            while ($state.I -lt $t.Count) {
                $n = $t[$state.I]
                if (-not $n.Dash -or $n.Indent -ne $Indent) { break }
                $state.I++
                if (-not $n.Key) { $list.Add((& $scalar $n.Value)); continue }
                # A list item that is a map: its first key sits on the dash line, the others at the same column.
                $item = @{}
                if ($n.Value) { $item[$n.Key] = & $scalar $n.Value } else { $item[$n.Key] = & $parseValue $n.Col }
                $more = & $parseMap $n.Col
                foreach ($k in $more.Keys) { $item[$k] = $more[$k] }
                $list.Add($item)
            }
            return , $list
        }
        $roots = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($doc in $documents) {
            $state.Tokens = $doc; $state.I = 0
            $root = & $parseMap 0
            # Skip a token the subset does not understand (a stray scalar) and go on.
            while ($state.I -lt $doc.Count) {
                $state.I++
                $more = & $parseMap 0
                foreach ($k in $more.Keys) { if (-not $root.ContainsKey($k)) { $root[$k] = $more[$k] } }
            }
            $roots.Add($root)
        }

        # ---- extraction ----
        $str = { param($Map, [string]$Key) if ($Map -is [hashtable] -and $Map.ContainsKey($Key) -and $Map[$Key] -is [string]) { [string]$Map[$Key] } else { '' } }
        $first = {
            param([string]$Key)
            foreach ($r in $roots) { $v = & $str $r $Key; if ($v) { return $v } }
            ''
        }
        $installerRoot = $null
        foreach ($r in $roots) { if ($r.ContainsKey('Installers') -and $r['Installers'] -is [System.Collections.IList]) { $installerRoot = $r; break } }
        if ($null -eq $installerRoot) { return $null }

        # Inheritance as winget-cli's ManifestYamlPopulator does it: every installer starts as a copy of the root-level
        # installer keys; ProductCode and AppsAndFeaturesEntries come back only for an effective type that uses them,
        # NestedInstallerType only for an archive; InstallerSwitches and InstallationMetadata are maps the installer's own
        # keys are written into (so the root's Silent survives an installer that only adds Custom).
        $plain = @('Architecture', 'InstallerType', 'Scope', 'InstallerLocale', 'UpgradeCode', 'ReleaseDate')
        $usesCodes = @('exe', 'inno', 'msi', 'nullsoft', 'wix', 'burn', 'portable')
        $installers = [System.Collections.Generic.List[object]]::new()
        foreach ($it in @($installerRoot['Installers'])) {
            if ($it -isnot [hashtable]) { continue }
            foreach ($k in $plain) { if (-not $it.ContainsKey($k) -and $installerRoot.ContainsKey($k)) { $it[$k] = $installerRoot[$k] } }
            $baseType = (& $str $it 'InstallerType').Trim().ToLowerInvariant()
            if ($baseType -eq 'zip' -and -not (& $str $it 'NestedInstallerType') -and $installerRoot.ContainsKey('NestedInstallerType')) { $it['NestedInstallerType'] = $installerRoot['NestedInstallerType'] }
            $effectiveType = if ($baseType -eq 'zip') { (& $str $it 'NestedInstallerType').Trim().ToLowerInvariant() } else { $baseType }
            if ($effectiveType -in $usesCodes) {
                if (-not (& $str $it 'ProductCode') -and $installerRoot.ContainsKey('ProductCode')) { $it['ProductCode'] = $installerRoot['ProductCode'] }
                if (@($it['AppsAndFeaturesEntries'] | Where-Object { $_ -is [hashtable] }).Count -eq 0 -and $installerRoot.ContainsKey('AppsAndFeaturesEntries')) { $it['AppsAndFeaturesEntries'] = $installerRoot['AppsAndFeaturesEntries'] }
            }
            foreach ($k in @('InstallerSwitches', 'InstallationMetadata')) {
                if ($installerRoot[$k] -isnot [hashtable]) { continue }
                $merged = @{}
                foreach ($rk in $installerRoot[$k].Keys) { $merged[$rk] = $installerRoot[$k][$rk] }
                if ($it[$k] -is [hashtable]) { foreach ($ik in $it[$k].Keys) { $merged[$ik] = $it[$k][$ik] } }
                $it[$k] = $merged
            }
            $sw = if ($it['InstallerSwitches'] -is [hashtable]) { $it['InstallerSwitches'] } else { @{} }
            $meta = if ($it['InstallationMetadata'] -is [hashtable]) { $it['InstallationMetadata'] } else { @{} }
            $afe = [System.Collections.Generic.List[object]]::new()
            foreach ($a in @($it['AppsAndFeaturesEntries'])) {
                if ($a -isnot [hashtable]) { continue }
                $afe.Add([pscustomobject][ordered]@{
                        DisplayName    = & $safe (& $str $a 'DisplayName')
                        Publisher      = & $safe (& $str $a 'Publisher')
                        DisplayVersion = & $safe (& $str $a 'DisplayVersion')
                        ProductCode    = & $safe (& $str $a 'ProductCode')
                        UpgradeCode    = & $safe (& $str $a 'UpgradeCode')
                        InstallerType  = (& $safe (& $str $a 'InstallerType')).ToLowerInvariant()
                    })
            }
            $installers.Add([pscustomobject][ordered]@{
                    Architecture           = (& $safe (& $str $it 'Architecture')).ToLowerInvariant()
                    InstallerType          = (& $safe (& $str $it 'InstallerType')).ToLowerInvariant()
                    NestedInstallerType    = (& $safe (& $str $it 'NestedInstallerType')).ToLowerInvariant()
                    Scope                  = (& $safe (& $str $it 'Scope')).ToLowerInvariant()
                    InstallerLocale        = & $safe (& $str $it 'InstallerLocale')
                    ProductCode            = & $safe (& $str $it 'ProductCode')
                    UpgradeCode            = & $safe (& $str $it 'UpgradeCode')
                    ReleaseDate            = & $safe (& $str $it 'ReleaseDate')
                    InstallerSwitches      = [pscustomobject][ordered]@{
                        Silent             = & $safe (& $str $sw 'Silent') 2048
                        SilentWithProgress = & $safe (& $str $sw 'SilentWithProgress') 2048
                        Custom             = & $safe (& $str $sw 'Custom') 2048
                    }
                    AppsAndFeaturesEntries = @($afe.ToArray())
                    DefaultInstallLocation = & $safe (& $str $meta 'DefaultInstallLocation')
                })
        }
        if ($installers.Count -eq 0) { return $null }
        return [pscustomobject][ordered]@{
            PackageIdentifier = & $safe (& $first 'PackageIdentifier')
            PackageVersion    = & $safe (& $first 'PackageVersion')
            PackageName       = & $safe (& $first 'PackageName')
            Publisher         = & $safe (& $first 'Publisher')
            ReleaseDate       = & $safe (& $first 'ReleaseDate')
            Installers        = @($installers.ToArray())
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "ConvertFrom-Win32ToolkitWingetManifest: not read ($($_.Exception.Message))."
        return $null
    }
}
