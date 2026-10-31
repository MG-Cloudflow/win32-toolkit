function Test-Win32ToolkitCleanupPath {
    <#
    .SYNOPSIS
        The one allowlist predicate for uninstall cleanup paths (V1, S18): is this folder safe to delete?
    .DESCRIPTION
        The data-driven uninstall deletes every SupportFiles\AppConfig.json Uninstall.CleanupPaths entry
        recursively, as SYSTEM, on every device. This predicate decides which folders may be listed there.
        It is used by the capture (Update-PSADTUninstallLogic), the Export check
        (Get-Win32ToolkitCleanupPathFinding / Assert-Win32ToolkitPackageReady) and the Publish warning, so
        they can never disagree.

        It is PURE: the paths are GUEST paths from a sandbox capture, so it never looks at the host file
        system or registry. The character and segment checks run first; [IO.Path]::GetFullPath runs only
        on a path that already passed them (an 8.3 name such as C:\PROGRA~2\X would otherwise be expanded
        through the HOST file system).

        Reason codes, in this order (NotCanonical short-circuits):
          NotCanonical         not a plain absolute folder path: blank, longer than 240 characters, not
                               'X:\name', a wildcard or one of / * ? " < > | [ ] ~, a ':' after the drive,
                               a control or format character, a trailing '\', an empty, '.' or '..'
                               segment, a segment that ends with '.' or a space or starts with a space, a
                               device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9), or GetFullPath changes it
          ShellFolder          it IS X:\Program Files, X:\Program Files (x86) or X:\ProgramData
          OutsideShellRoots    not at least one folder below one of those three (not added with ShellFolder)
          DeniedTree           a shared or system tree: X:\Windows, X:\Users, any 'Microsoft', 'Common Files',
                               'WindowsApps' or 'Package Cache' segment, a vendor folder that starts with
                               'Microsoft' or 'Windows' (whoever the publisher is) or is ModifiableWindowsApps,
                               Internet Explorer, Reference Assemblies, MSBuild or dotnet, or a legacy
                               ProgramData junction (Application Data, Desktop, Documents, Start Menu, Templates)
          NoInstallRoot        (cleanup set) no valid install root is known
          OutsideInstallRoot   (cleanup set) not equal to or below a valid install root (separator-aware)
          NotCreatedByInstall  (cleanup set, -CreatedDirectory given) the install capture did not create it

        A cleanup path does not have to be a top-most folder here: the capture keeps top-most folders only,
        but sub-folders stored by older captures inside a valid root delete nothing outside that root.
    .PARAMETER Path
        The folder to check. $null or '' is reported as NotCanonical (never a binding error).
    .PARAMETER InstallRoot
        The app's own install folders (Uninstall.InstallRoots, or Get-Win32ToolkitInstallRoot). Each one is
        trimmed of a trailing '\' and re-validated as an install root; invalid ones are ignored here.
    .PARAMETER CreatedDirectory
        The folders the install capture created. Not given = no capture available: the check is skipped.
        Given and empty = the capture created no folder: every path fails NotCreatedByInstall.
    .PARAMETER AsInstallRoot
        Check the path as an install root instead: only the NotCanonical, ShellFolder, OutsideShellRoots and
        DeniedTree rules apply.
    .OUTPUTS
        [pscustomobject] Path, Valid ([bool]), Reasons ([string[]]), Root (the longest matching install root,
        '' unless Valid), Explanation (the human-readable reasons, ASCII, joined with '; ').
    .EXAMPLE
        Test-Win32ToolkitCleanupPath -Path 'C:\Program Files\Git\usr\bin' -InstallRoot 'C:\Program Files\Git'
        # Valid = $true, Root = 'C:\Program Files\Git'
    .EXAMPLE
        (Test-Win32ToolkitCleanupPath -Path 'C:\Program Files (x86)' -InstallRoot 'C:\Program Files\Git').Reasons
        # ShellFolder, OutsideInstallRoot
    #>
    [CmdletBinding(DefaultParameterSetName = 'Cleanup')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Cleanup')]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$InstallRoot,

        [Parameter(ParameterSetName = 'Cleanup')]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$CreatedDirectory,

        [Parameter(Mandatory, ParameterSetName = 'Root')]
        [switch]$AsInstallRoot
    )

    $ignoreCase = [System.StringComparison]::OrdinalIgnoreCase
    $shellNames = @('Program Files', 'Program Files (x86)', 'ProgramData')
    $deniedAnywhere = @('Microsoft', 'Common Files', 'WindowsApps', 'Package Cache')
    $deniedVendor = @('ModifiableWindowsApps', 'Internet Explorer', 'Reference Assemblies', 'MSBuild', 'dotnet')
    # Legacy junctions in C:\ProgramData (-> C:\ProgramData, C:\Users\Public\..., C:\ProgramData\Microsoft\Windows\...):
    # a recursive delete under Windows PowerShell 5.1 can follow them.
    $deniedJunction = @('Application Data', 'Desktop', 'Documents', 'Start Menu', 'Templates')
    $texts = @{
        NotCanonical        = "it is not a plain absolute folder path (short 8.3 name, wildcard, '..', trailing dot or space, ...)"
        ShellFolder         = 'it is a Windows system folder itself'
        OutsideShellRoots   = 'it is not inside Program Files, Program Files (x86) or ProgramData'
        DeniedTree          = 'it is inside a shared or system tree (Windows, Users, Microsoft, Common Files, WindowsApps, Package Cache, ...)'
        NoInstallRoot       = "the app's own install folder is unknown (no Uninstall.InstallRoots and no install capture)"
        NotCreatedByInstall = 'the install capture did not create this folder'
    }

    # True when $Value is one of $List (ordinal, case-insensitive).
    $isOneOf = {
        param([string]$Value, [string[]]$List)
        foreach ($item in $List) { if ([string]::Equals($Value, $item, $ignoreCase)) { return $true } }
        return $false
    }

    # Rule 1: a plain, absolute, canonical folder path. Character and segment checks first, GetFullPath last.
    $testCanonical = {
        param([string]$Candidate)
        if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
        if ($Candidate.Length -gt 240) { return $false }
        if ($Candidate -notmatch '^[A-Za-z]:\\[^\\]') { return $false }
        if ($Candidate.IndexOfAny([char[]]'/*?"<>|[]~') -ge 0) { return $false }
        if ($Candidate.IndexOf(':', 2) -ge 0) { return $false }
        foreach ($ch in $Candidate.ToCharArray()) {
            $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
            if ($category -in @([System.Globalization.UnicodeCategory]::Control, [System.Globalization.UnicodeCategory]::Format,
                                [System.Globalization.UnicodeCategory]::LineSeparator, [System.Globalization.UnicodeCategory]::ParagraphSeparator)) {
                return $false
            }
        }
        if ($Candidate.EndsWith('\')) { return $false }
        foreach ($segment in @($Candidate.Split('\') | Select-Object -Skip 1)) {
            if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') { return $false }
            if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment.StartsWith(' ')) { return $false }
            if ($segment -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { return $false }
        }
        $full = $null
        try { $full = [System.IO.Path]::GetFullPath($Candidate) }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            return $false
        }
        return ($full -ceq $Candidate)
    }

    # Rules 1-4 (the install-root checks). Writes the reason codes to the pipeline (none = a valid root).
    $getShapeReason = {
        param([string]$Candidate)
        if (-not (& $testCanonical $Candidate)) { return 'NotCanonical' }
        $found = [System.Collections.Generic.List[string]]::new()
        $segments = @($Candidate.Split('\'))
        $isShell = $segments.Count -eq 2 -and (& $isOneOf $segments[1] $shellNames)
        $underShell = $segments.Count -ge 3 -and (& $isOneOf $segments[1] $shellNames)
        if ($isShell) { $found.Add('ShellFolder') }
        elseif (-not $underShell) { $found.Add('OutsideShellRoots') }

        $denied = $segments.Count -ge 2 -and (& $isOneOf $segments[1] @('Windows', 'Users'))
        foreach ($segment in $segments) { if (& $isOneOf $segment $deniedAnywhere) { $denied = $true } }
        if ($underShell) {
            $vendor = $segments[2]
            if ($vendor -match '^(Microsoft|Windows)' -or (& $isOneOf $vendor $deniedVendor)) { $denied = $true }
            if ([string]::Equals($segments[1], 'ProgramData', $ignoreCase) -and (& $isOneOf $vendor $deniedJunction)) { $denied = $true }
        }
        if ($denied) { $found.Add('DeniedTree') }
        $found.ToArray()
    }

    $reasons = [System.Collections.Generic.List[string]]::new()
    foreach ($code in @(& $getShapeReason $Path)) { $reasons.Add($code) }
    $root = ''
    $validRoots = [System.Collections.Generic.List[string]]::new()

    if ($PSCmdlet.ParameterSetName -eq 'Cleanup' -and -not $reasons.Contains('NotCanonical')) {
        foreach ($candidateRoot in @($InstallRoot)) {
            if ([string]::IsNullOrWhiteSpace($candidateRoot)) { continue }
            $trimmed = $candidateRoot.TrimEnd('\')
            if (@(& $getShapeReason $trimmed).Count -eq 0 -and -not (& $isOneOf $trimmed $validRoots.ToArray())) { $validRoots.Add($trimmed) }
        }
        $matchingRoot = ''
        foreach ($validRoot in $validRoots) {
            if (($Path + '\').StartsWith($validRoot + '\', $ignoreCase) -and $validRoot.Length -gt $matchingRoot.Length) { $matchingRoot = $validRoot }
        }
        if ($validRoots.Count -eq 0) { $reasons.Add('NoInstallRoot') }
        elseif (-not $matchingRoot) { $reasons.Add('OutsideInstallRoot') }

        if ($PSBoundParameters.ContainsKey('CreatedDirectory')) {
            $created = @(@($CreatedDirectory) | Where-Object { -not [string]::IsNullOrEmpty($_) } | ForEach-Object { $_.TrimEnd('\') })
            if (-not (& $isOneOf $Path $created)) { $reasons.Add('NotCreatedByInstall') }
        }
        if ($reasons.Count -eq 0) { $root = $matchingRoot }
    }

    $explanation = @(foreach ($code in $reasons) {
            if ($code -eq 'OutsideInstallRoot') { "it is outside the app's own install folder(s): $($validRoots.ToArray() -join ', ')" }
            else { $texts[$code] }
        }) -join '; '

    [pscustomobject]@{
        Path        = $Path
        Valid       = ($reasons.Count -eq 0)
        Reasons     = [string[]]$reasons.ToArray()
        Root        = $root
        Explanation = $explanation
    }
}
