function Add-Win32ToolkitPriorInstallProcessName {
    <#
    .SYNOPSIS
        Merges the process names of the Block and Enforce prior-install entries into AppConfig.ProcessesToClose (D20).
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.8, D20). The org close-apps dialog (the 'org-ui' block) closes the apps listed in
        ProcessesToClose BEFORE remove-prior runs; remove-prior refuses with 1618 while a prior's process still runs. So
        every Block or Enforce entry's ProcessNames must be in the list, or every device where the prior app is open would
        retry forever. The ONE place this merge happens: Set-Win32ToolkitPriorInstall and the carry-forward / same-version
        restore (Copy-Win32ToolkitPriorInstallState) call it.

        Union with the existing list (never removes a name; a later re-capture keeps them too), each name passing
        Test-Win32ToolkitProcessName, sorted - the merge rule of Update-PSADTProcessesToClose. Report entries are not
        merged (they remove nothing). Changes the given object only (the caller writes AppConfig.json).
    .PARAMETER Config
        The project's AppConfig object.
    .OUTPUTS
        [string[]] the names that were added.
    .EXAMPLE
        $added = Add-Win32ToolkitPriorInstallProcessName -Config $cfg
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Config
    )

    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $existing = @(@(& $prop $Config 'ProcessesToClose') | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $merged = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $existing) { if (-not $merged.Contains($n)) { $merged.Add($n) } }
    $added = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @(@(& $prop (& $prop $Config 'PriorInstalls') 'Entries') | Where-Object { $null -ne $_ })) {
        if (@('Block', 'Enforce') -cnotcontains [string](& $prop $e 'Mode')) { continue }
        foreach ($n in @(@(& $prop $e 'ProcessNames') | Where-Object { $_ } | ForEach-Object { [string]$_ })) {
            if (-not (Test-Win32ToolkitProcessName -Value $n)) { continue }
            if (@($merged | Where-Object { [string]::Equals($_, $n, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
            $merged.Add($n)
            $added.Add($n)
        }
    }
    if ($added.Count -gt 0 -or -not $Config.PSObject.Properties['ProcessesToClose']) {
        $Config | Add-Member -NotePropertyName ProcessesToClose -NotePropertyValue @($merged | Sort-Object) -Force
    }
    return [string[]]$added.ToArray()
}
