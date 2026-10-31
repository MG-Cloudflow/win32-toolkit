function Get-Win32ToolkitInstallRoot {
    <#
    .SYNOPSIS
        Derives the app's own install folders (install roots) from a sandbox install capture.
    .DESCRIPTION
        The uninstall cleanup paths may only lie inside the app's own install folders
        (Test-Win32ToolkitCleanupPath). This helper finds those folders in an InstallationChanges_*.json
        capture, from the app's PRIMARY uninstall (ARP) entry only:

          Keys considered   new HKLM ...\CurrentVersion\Uninstall\<key> keys (WOW6432Node included). HKCU
                            keys never yield a root.
          Primary key(s)    the first rule that selects at least one key:
                              ProductCode  the key name equals a 'ProductCode:' value of the project's
                                           winget installer manifest (Files\, needs -ProjectPath)
                              OnlyKey      exactly one key was created
                              DisplayName  the key's DisplayName starts with -DisplayName
                            Every other key is reported as Rejected, Origin CoInstalled (a primary key
                            exists: e.g. a co-installed maintenance service: our Uninstall block never calls
                            its uninstaller (first success wins), and the product's own uninstaller removes it
                            only when nothing else uses it) or Unidentified.
          Candidate roots   per primary key, the first that applies:
                              InstallLocation  its InstallLocation value (quotes and a trailing '\' trimmed)
                              UninstallerIcon  the uninstaller's folder (UninstallString) and the DisplayIcon
                                               folder: when both exist, the one that contains the other;
                                               when neither contains the other, NO root (a common ancestor
                                               is a vendor folder that sibling products share on devices)
                            plus DefaultInstallLocation: the manifest's DefaultInstallLocation, expanded to
                            guest paths (%ProgramFiles%, %ProgramW6432%, %ProgramFiles(x86)%, %ProgramData%),
                            only when the capture created that folder.
          Validation        every candidate must pass Test-Win32ToolkitCleanupPath -AsInstallRoot; the others
                            are reported as Rejected.

        A new folder alone never becomes a root (that is how an updater's folders reached the cleanup paths).
        Reads nothing but the project's one installer manifest, never throws: a capture of an unexpected shape
        gives an empty result.
    .PARAMETER Capture
        The parsed InstallationChanges_*.json (NewFiles[] {Path, Type}, NewRegistryKeys[] {Path, Values}).
    .PARAMETER ProjectPath
        The project folder; its Files\ winget installer manifest supplies the ProductCode and
        DefaultInstallLocation values. Without it those two sources are skipped.
    .PARAMETER DisplayName
        The app's display name (AppConfig App.DisplayName, else App.Name) for the DisplayName rule.
    .OUTPUTS
        [pscustomobject] Roots ([string[]], unique, sorted), Rejected ([pscustomobject[]] Candidate, Origin,
        Reasons), CreatedDirectories ([string[]]: the capture's new folders), PrimaryKeys ([string[]]: key
        names), PrimaryBy ('ProductCode', 'OnlyKey', 'DisplayName' or ''), PrimaryKeyEntries
        ([pscustomobject[]] Name, View 'Registry64'|'Registry32': the primary keys with their registry view).
    .EXAMPLE
        $capture = Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json
        (Get-Win32ToolkitInstallRoot -Capture $capture -ProjectPath $proj -DisplayName 'Git').Roots
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Capture,

        [string]$ProjectPath,

        [string]$DisplayName
    )

    $ignoreCase = [System.StringComparison]::OrdinalIgnoreCase
    $uninstallKeyPattern = '^(HKEY_LOCAL_MACHINE|HKLM)\\SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\]+$'

    $created     = [System.Collections.Generic.List[string]]::new()
    $roots       = [System.Collections.Generic.List[string]]::new()
    $rejected    = [System.Collections.Generic.List[object]]::new()
    $primaryKeys = [System.Collections.Generic.List[string]]::new()
    $primaryKeyEntries = [System.Collections.Generic.List[object]]::new()
    $primaryBy   = ''

    # A property of a parsed JSON object (or a hashtable); $null when absent or not an object.
    $getValue = {
        param($Object, [string]$Name)
        if ($null -eq $Object -or $Object -is [string] -or $Object -is [System.ValueType]) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $property = $Object.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
        return $null
    }
    # One matching pair of surrounding quotes removed ('' inside single quotes = ').
    $removeQuote = {
        param([string]$Value)
        $text = ([string]$Value).Trim()
        if ($text.Length -ge 2 -and $text[0] -eq $text[$text.Length - 1] -and ($text[0] -eq [char]39 -or $text[0] -eq [char]34)) {
            $quote = $text[0]
            $text = $text.Substring(1, $text.Length - 2)
            if ($quote -eq [char]39) { $text = $text.Replace("''", "'") }
        }
        $text
    }
    $isUnder = { param([string]$Child, [string]$Parent) ($Child + '\').StartsWith($Parent + '\', $ignoreCase) }
    $getFolder = {
        param([string]$File)
        $index = $File.LastIndexOf('\')
        if ($index -gt 0) { $File.Substring(0, $index) } else { '' }
    }
    $containsText = {
        param([string[]]$List, [string]$Value)
        foreach ($item in $List) { if ([string]::Equals($item, $Value, $ignoreCase)) { return $true } }
        return $false
    }

    try {
        # -- folders the install created -------------------------------------------------------------------
        foreach ($entry in @(& $getValue $Capture 'NewFiles')) {
            if ([string](& $getValue $entry 'Type') -ne 'Directory') { continue }
            $folder = ([string](& $getValue $entry 'Path')).TrimEnd('\')
            if ($folder -and -not (& $containsText $created.ToArray() $folder)) { $created.Add($folder) }
        }

        # -- new HKLM uninstall keys -------------------------------------------------------------------------
        $keys = @(foreach ($key in @(& $getValue $Capture 'NewRegistryKeys')) {
                $keyPath = [string](& $getValue $key 'Path')
                if ($keyPath -match $uninstallKeyPattern) {
                    $view = if ($keyPath -match '^(HKEY_LOCAL_MACHINE|HKLM)\\SOFTWARE\\WOW6432Node\\') { 'Registry32' } else { 'Registry64' }
                    [pscustomobject]@{ Name = $keyPath.Substring($keyPath.LastIndexOf('\') + 1); View = $view; Values = (& $getValue $key 'Values'); IsPrimary = $false }
                }
            })

        # -- the project's winget installer manifest (ProductCode, DefaultInstallLocation) ----------------------
        $manifestText = ''
        if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
            try {
                $manifest = Get-WingetManifestFile -Path ([System.IO.Path]::Combine($ProjectPath, 'Files')) -Kind Installer
                if ($manifest) { $manifestText = [string](Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8 -ErrorAction Stop) }
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Install roots: the winget manifest in '$ProjectPath\Files' could not be read ($($_.Exception.Message)); ProductCode and DefaultInstallLocation are not used."
                $manifestText = ''
            }
        }
        $productCodes = @(foreach ($m in [regex]::Matches($manifestText, '(?m)^\s*-?\s*ProductCode:\s*(.+?)\s*$')) {
                $code = & $removeQuote $m.Groups[1].Value
                if ($code) { $code }
            })

        # -- the app's primary key(s) --------------------------------------------------------------------------
        $primary = @()
        if ($productCodes.Count) {
            $primary = @($keys | Where-Object { & $containsText $productCodes $_.Name })
            if ($primary.Count) { $primaryBy = 'ProductCode' }
        }
        if (-not $primary.Count -and $keys.Count -eq 1) {
            $primary = @($keys); $primaryBy = 'OnlyKey'
        }
        if (-not $primary.Count -and -not [string]::IsNullOrWhiteSpace($DisplayName)) {
            $primary = @($keys | Where-Object { ([string](& $getValue $_.Values 'DisplayName')).StartsWith($DisplayName, $ignoreCase) })
            if ($primary.Count) { $primaryBy = 'DisplayName' }
        }

        foreach ($key in $primary) { $key.IsPrimary = $true }

        $candidates = [System.Collections.Generic.List[object]]::new()
        foreach ($key in $keys) {
            if (-not $key.IsPrimary) {
                $origin = if ($primary.Count) { 'CoInstalled' } else { 'Unidentified' }
                $rejected.Add([pscustomobject]@{ Candidate = $key.Name; Origin = $origin; Reasons = [string[]]@() })
                continue
            }
            $primaryKeys.Add($key.Name)
            $primaryKeyEntries.Add([pscustomobject]@{ Name = $key.Name; View = $key.View })
            $values = $key.Values

            $location = (& $removeQuote ([string](& $getValue $values 'InstallLocation'))).TrimEnd('\')
            if ($location) {
                $candidates.Add([pscustomobject]@{ Candidate = $location; Origin = 'InstallLocation' })
                continue
            }

            $uninstallerFolder = ''
            $uninstallString = [string](& $getValue $values 'UninstallString')
            if ($uninstallString -match '^\s*"([A-Za-z]:\\[^"]+?\.exe)"') { $uninstallerFolder = & $getFolder $Matches[1] }
            elseif ($uninstallString -match '^\s*([A-Za-z]:\\[^"]*?\.exe)(\s|$)') { $uninstallerFolder = & $getFolder $Matches[1] }

            $iconFolder = ''
            $icon = (([string](& $getValue $values 'DisplayIcon')).Trim().Trim('"') -replace ',\s*-?\d+$', '').Trim().Trim('"')
            if ($icon -match '^[A-Za-z]:\\.+\.(exe|ico|dll)$') { $iconFolder = & $getFolder $icon }

            if ($uninstallerFolder -and $iconFolder) {
                if (& $isUnder $uninstallerFolder $iconFolder) { $candidates.Add([pscustomobject]@{ Candidate = $iconFolder; Origin = 'UninstallerIcon' }) }
                elseif (& $isUnder $iconFolder $uninstallerFolder) { $candidates.Add([pscustomobject]@{ Candidate = $uninstallerFolder; Origin = 'UninstallerIcon' }) }
                else {
                    $rejected.Add([pscustomobject]@{ Candidate = "$uninstallerFolder | $iconFolder"; Origin = 'UninstallerIcon'; Reasons = [string[]]@('AncestorAboveBoth') })
                }
            }
            elseif ($uninstallerFolder) { $candidates.Add([pscustomobject]@{ Candidate = $uninstallerFolder; Origin = 'UninstallerIcon' }) }
            elseif ($iconFolder) { $candidates.Add([pscustomobject]@{ Candidate = $iconFolder; Origin = 'UninstallerIcon' }) }
        }

        # -- the manifest's DefaultInstallLocation, only when the install created that folder ------------------
        $expansions = @(
            @{ Token = '%ProgramFiles%';      Bases = @('C:\Program Files', 'C:\Program Files (x86)') }
            @{ Token = '%ProgramW6432%';      Bases = @('C:\Program Files') }
            @{ Token = '%ProgramFiles(x86)%'; Bases = @('C:\Program Files (x86)') }
            @{ Token = '%ProgramData%';       Bases = @('C:\ProgramData') }
        )
        foreach ($m in [regex]::Matches($manifestText, '(?m)^\s+DefaultInstallLocation:\s*(.+?)\s*$')) {
            $value = & $removeQuote $m.Groups[1].Value
            foreach ($expansion in $expansions) {
                if (-not $value.StartsWith($expansion.Token, $ignoreCase)) { continue }
                $rest = $value.Substring($expansion.Token.Length)
                if ($rest -and -not $rest.StartsWith('\')) { continue }
                foreach ($base in $expansion.Bases) {
                    $folder = ($base + $rest).TrimEnd('\')
                    if (& $containsText $created.ToArray() $folder) { $candidates.Add([pscustomobject]@{ Candidate = $folder; Origin = 'DefaultInstallLocation' }) }
                    else { Write-Verbose "Install roots: DefaultInstallLocation '$folder' was not created by the install; not a root." }
                }
            }
        }

        # -- validation --------------------------------------------------------------------------------------
        foreach ($candidate in $candidates) {
            $check = Test-Win32ToolkitCleanupPath -Path $candidate.Candidate -AsInstallRoot
            if ($check.Valid) {
                if (-not (& $containsText $roots.ToArray() $candidate.Candidate)) { $roots.Add($candidate.Candidate) }
            }
            else {
                Write-Verbose "Install roots: $($candidate.Origin) candidate '$($candidate.Candidate)' rejected ($($check.Reasons -join ', '))."
                $rejected.Add([pscustomobject]@{ Candidate = $candidate.Candidate; Origin = $candidate.Origin; Reasons = [string[]]$check.Reasons })
            }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Install roots: the capture could not be read ($($_.Exception.Message)); no install root."
        $created.Clear(); $roots.Clear(); $rejected.Clear(); $primaryKeys.Clear(); $primaryKeyEntries.Clear(); $primaryBy = ''
    }

    [pscustomobject]@{
        Roots              = [string[]]@($roots | Sort-Object)
        Rejected           = [pscustomobject[]]$rejected.ToArray()
        CreatedDirectories = [string[]]$created.ToArray()
        PrimaryKeys        = [string[]]$primaryKeys.ToArray()
        PrimaryBy          = $primaryBy
        PrimaryKeyEntries  = [pscustomobject[]]$primaryKeyEntries.ToArray()
    }
}
