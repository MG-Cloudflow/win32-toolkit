function Assert-Win32ToolkitProjectTripwire {
    <#
    .SYNOPSIS
        Fails closed (W32T.GuestTamper) when a guest run changed a project file outside Sandbox\ or a link in it.
    .DESCRIPTION
        Installer-identity PR 3 (L18, SV4). Compares the project with the snapshot Get-Win32ToolkitProjectTripwire
        took before the guest started. Called once the guest can no longer write (Hyper-V: the run returned - the
        project is copied in, never mapped; Windows Sandbox: after the host closed this run's sandbox) and BEFORE any
        record is written. Any changed, new or missing file outside Sandbox\, or any new, changed or removed link
        anywhere in the project (Get-Win32ToolkitProjectTripwire records links and never follows them) ->
          - Documentation\GuestTamper.json { On, Scenario, Files (at most 20 relative paths), Reason } (BOM-less);
          - a terminating error W32T.GuestTamper ("rebuild the project": nothing it holds can be trusted any more).
        Fail closed: a project that cannot be read again in full (a locked file, a denied folder) is a tamper too
        (the marker's Reason says so, Files is empty). With -Reason and no -Before (the sandbox could not be confirmed
        closed) the marker is written and the error thrown without comparing. The marker makes Export refuse the
        project (GUEST-TAMPER). Writing it never follows a link: a Documentation\ junction or link, or a
        GuestTamper.json link, is removed (the link only, never its target) and the marker is created new inside the
        project. A marker that cannot be written is a warning; W32T.GuestTamper is thrown either way.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Before
        The snapshot from Get-Win32ToolkitProjectTripwire.
    .PARAMETER Scenario
        The run's scenario (Update, InstallUninstall, SiblingCapture), for the marker.
    .PARAMETER Reason
        Why the run is not trusted when there is nothing to compare.
    .EXAMPLE
        Assert-Win32ToolkitProjectTripwire -ProjectPath $p -Before $trip -Scenario Update
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [hashtable]$Before,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Scenario,

        [string]$Reason
    )

    $changed = [System.Collections.Generic.List[string]]::new()
    $now = $null
    if ($null -ne $Before) {
        # Fail closed (C-7): a project that cannot be read again in full (a file locked, a folder denied, a path the
        # guest made unreadable) cannot be shown unchanged, so it is a tamper like a changed file.
        try { $now = Get-Win32ToolkitProjectTripwire -ProjectPath $ProjectPath }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            if (-not $Reason) { $Reason = 'the project could not be read again after the guest run (' + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200) + ')' }
        }
    }
    if ($null -ne $now) {
        $all = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $Before.Keys) { [void]$all.Add([string]$k) }
        foreach ($k in $now.Keys) { [void]$all.Add([string]$k) }
        $sorted = [string[]]@($all)
        [Array]::Sort($sorted, [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $sorted) {
            $a = if ($Before.ContainsKey($k)) { [string]$Before[$k] } else { $null }
            $b = if ($now.ContainsKey($k)) { [string]$now[$k] } else { $null }
            if ($a -cne $b) { $changed.Add($k) }
        }
        if ($changed.Count -eq 0 -and -not $Reason) { return }
        if (-not $Reason) { $Reason = "the guest run changed $($changed.Count) project file(s) or link(s)" }
    }
    elseif (-not $Reason) {
        throw [System.ArgumentException]::new('Assert-Win32ToolkitProjectTripwire needs -Before or -Reason.')
    }

    $marker = [ordered]@{
        On       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        Scenario = ConvertTo-Win32ToolkitSafeText -Text $Scenario -MaxLength 32
        Files    = @($changed | Select-Object -First 20 | ForEach-Object { ConvertTo-Win32ToolkitSafeText -Text $_ -MaxLength 260 })
        Reason   = ConvertTo-Win32ToolkitSafeText -Text $Reason -MaxLength 512
    }
    # The one host write after a detection never follows a link the guest left behind: the session is elevated, so a
    # Documentation\ junction or a GuestTamper.json symbolic link would make it a write anywhere on the host. Only
    # the link itself is removed (Directory.Delete without recursion, File.Delete: never what is behind it), a real
    # folder takes its place, and the marker is created with CreateNew (which fails on a name that exists, a link
    # included, instead of opening it).
    $docDir = Join-Path $ProjectPath 'Documentation'
    $markerPath = Join-Path $docDir 'GuestTamper.json'
    $attributesOf = {
        param($Path)
        try { [System.IO.File]::GetAttributes($Path) }
        catch {
            $inner = $_.Exception.GetBaseException()
            if ($inner -is [System.IO.FileNotFoundException] -or $inner -is [System.IO.DirectoryNotFoundException]) { $null } else { throw }
        }
    }
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $folder = [System.IO.FileAttributes]::Directory
    try {
        $a = & $attributesOf $docDir
        if ($null -ne $a -and ($a -band $reparse)) {
            if ($a -band $folder) { [System.IO.Directory]::Delete($docDir) } else { [System.IO.File]::Delete($docDir) }
            $a = $null
        }
        if ($null -eq $a) { $null = [System.IO.Directory]::CreateDirectory($docDir) }
        elseif (-not ($a -band $folder)) { throw [System.IO.IOException]::new('Documentation is a file, not a folder.') }
        $a = & $attributesOf $markerPath
        if ($null -ne $a) {
            if (($a -band $folder) -and -not ($a -band $reparse)) { throw [System.IO.IOException]::new('Documentation\GuestTamper.json is a folder.') }
            if ($a -band $folder) { [System.IO.Directory]::Delete($markerPath) } else { [System.IO.File]::Delete($markerPath) }
        }
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $marker -Depth 4))
        $stream = [System.IO.File]::Open($markerPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    catch { Write-Warning ('Documentation\GuestTamper.json could not be written: ' + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200)) }
    $shown = if ($changed.Count -gt 0) { ' Changed: ' + (@($marker.Files) -join ', ') + $(if ($changed.Count -gt 20) { ", ... ($($changed.Count) in all)" } else { '' }) + '.' } else { '' }
    throw [System.Management.Automation.ErrorRecord]::new(
        [System.InvalidOperationException]::new("The $Scenario test of $ProjectPath cannot be trusted: $($marker.Reason).$shown No test result was recorded. Re-create the project: nothing in it can be trusted any more (Documentation\GuestTamper.json)."),
        'W32T.GuestTamper', [System.Management.Automation.ErrorCategory]::SecurityError, $ProjectPath)
}
