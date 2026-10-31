function Get-Win32ToolkitPriorProofGroup {
    <#
    .SYNOPSIS
        Groups a project's Enforce prior-install entries into proof groups: the entries one Update run can prove.
    .DESCRIPTION
        Installer-identity PR 3 (L27, spec 2.10, 2.15.3). One Update run installs ONE baseline, so it can prove only
        the Enforce entries that baseline produces:
          - capture lineage (Source SiblingCapture, a CaptureId or an Approval): one group per floor capture record
            (CaptureId) - its baseline is that record's installer (version, type, hash);
          - every other Enforce entry: one group per (UninstallerType, View) - its baseline is that uninstaller
            technology, pinned, with an architecture whose installer writes that view on the 64-bit test guest
            (Wow6432 -> x86; Native -> x64 for an x86 package, else the package's own: an x86 old version writes
            WOW6432Node, so it can never produce a Native entry).
        Groups come in the Id order (ordinal) of their first entry. OtherEntryIds of a group = every entry of the
        set (any mode) whose (UninstallerType, View) differs from the group's: the run asserts them absent. Pure
        read of AppConfig.json and the decisions file.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .OUTPUTS
        [pscustomobject[]] Key, EntryIds[], OtherEntryIds[], UninstallerType, View, Lineage (Capture|Other),
        CaptureId, Architecture.
    .EXAMPLE
        $groups = @(Get-Win32ToolkitPriorProofGroup -ProjectPath $p)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $entries = @(@(& $prop (& $prop $cfg 'PriorInstalls') 'Entries') | Where-Object { $null -ne $_ })
    if ($entries.Count -eq 0) { return @() }
    $lineage = (Test-Win32ToolkitPriorInstallEntry -Config $cfg -Decisions @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath) -PreCapture).Lineage
    $packageArch = [string](& $prop (& $prop $cfg 'Source') 'Architecture')
    if (-not $packageArch) { $packageArch = [string](& $prop (& $prop $cfg 'App') 'Arch') }
    $packageArch = $packageArch.ToLowerInvariant()
    # The baseline architecture of a Native group: a 64-bit installer (an x86 package's Native entry comes from its x64 build;
    # an unknown or neutral package architecture stays as it is, winget's choice).
    $nativeArch = if ($packageArch -eq 'x86') { 'x64' } else { $packageArch }

    $ids = [string[]]@($entries | ForEach-Object { [string](& $prop $_ 'Id') })
    $order = [int[]]@(0..($entries.Count - 1))
    [Array]::Sort($ids, $order, [System.StringComparer]::Ordinal)
    $groups = [ordered]@{}
    foreach ($i in $order) {
        $e = $entries[$i]
        if ([string](& $prop $e 'Mode') -cne 'Enforce') { continue }
        $id = [string](& $prop $e 'Id')
        $type = [string](& $prop $e 'UninstallerType')
        $view = [string](& $prop $e 'View')
        $isCapture = $lineage.ContainsKey($id) -and $lineage[$id] -eq 'Capture'
        $cid = [string](& $prop $e 'CaptureId')
        $key = if ($isCapture) { "capture|$cid" } else { "other|$type|$view" }
        if (-not $groups.Contains($key)) {
            $groups[$key] = [pscustomobject]@{
                Key             = $key
                EntryIds        = [System.Collections.Generic.List[string]]::new()
                OtherEntryIds   = [string[]]@()
                UninstallerType = $type
                View            = $view
                Lineage         = if ($isCapture) { 'Capture' } else { 'Other' }
                CaptureId       = if ($isCapture) { $cid } else { '' }
                Architecture    = if ($view -eq 'Wow6432') { 'x86' } else { $nativeArch }
            }
        }
        $groups[$key].EntryIds.Add($id)
    }
    $out = foreach ($g in $groups.Values) {
        $g.OtherEntryIds = [string[]]@($entries | Where-Object { [string](& $prop $_ 'UninstallerType') -cne $g.UninstallerType -or [string](& $prop $_ 'View') -cne $g.View } |
                ForEach-Object { [string](& $prop $_ 'Id') } | Where-Object { $_ })
        $g.EntryIds = [string[]]$g.EntryIds.ToArray()
        $g
    }
    return @($out)
}
