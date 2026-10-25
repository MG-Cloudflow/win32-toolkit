function Sync-Win32ToolkitPriorInstallOwnIdentity {
    <#
    .SYNOPSIS
        Re-checks a project's prior-install rules once the install capture recorded the package's own identity.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.13 "After the install capture", L34). Carried and restored rules were checked
        before the install capture (-PreCapture: only an MSI's ProductCode was known as the package's own key). Called by
        Wait-ForDocumentationAndProcess right after Write-Win32ToolkitOwnIdentity returned $true, this reads the new
        OwnIdentity and:
          - drops every entry whose Key is now one of the package's own uninstall keys (OwnIdentity.ProductCode and
            ArpKeys, Uninstall.ProductCodes and PrimaryKeys; never the tattoo), one ID-PRIOR-OWN warning each - for
            example an EXE package whose capture shows the carried key as its own;
          - re-validates the rest with the full rules (Test-Win32ToolkitPriorInstallEntry with the decisions and the
            hash-verified capture records) and drops an entry that fails (an invalid or duplicate Id included), one
            warning each naming the problem. A 'capture record:' problem alone does not drop it: the Export gate reports
            it (PRIOR-CAPTURE-RECORD).
        AppConfig.json is written only when something was dropped; the ProcessesToClose names merged earlier are kept.
        Fail-open (C-7): any problem gives one warning and leaves AppConfig.json as it was (a W32T.* error is re-thrown).
    .PARAMETER ProjectPath
        The PSADT project folder.
    .OUTPUTS
        [pscustomobject] Own (ids dropped as the package's own key), Dropped (@{ Id; Reason }), or $null when the
        project has no prior-install rules.
    .EXAMPLE
        $null = Sync-Win32ToolkitPriorInstallOwnIdentity -ProjectPath $ProjectPath
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    try {
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $entries = @(@(& $prop (& $prop $cfg 'PriorInstalls') 'Entries') | Where-Object { $null -ne $_ })
        if ($entries.Count -eq 0) { return $null }

        $ownKeys = [System.Collections.Generic.List[string]]::new()
        $ownId = & $prop $cfg 'OwnIdentity'
        if ([string](& $prop $ownId 'ProductCode')) { $ownKeys.Add([string](& $prop $ownId 'ProductCode')) }
        foreach ($k in @(& $prop $ownId 'ArpKeys')) { if ($k -and [string](& $prop $k 'Key')) { $ownKeys.Add([string](& $prop $k 'Key')) } }
        $uninstall = & $prop $cfg 'Uninstall'
        foreach ($k in @(& $prop $uninstall 'ProductCodes')) { if ($k) { $ownKeys.Add([string]$k) } }
        # Uninstall.PrimaryKeys holds { Name; View } objects (Update-PSADTUninstallLogic): the key is the Name, as
        # Test-Win32ToolkitPriorInstallEntry reads it.
        foreach ($k in @(& $prop $uninstall 'PrimaryKeys')) { if ($k -and [string](& $prop $k 'Name')) { $ownKeys.Add([string](& $prop $k 'Name')) } }

        $own = [System.Collections.Generic.List[string]]::new()
        $dropped = [System.Collections.Generic.List[object]]::new()
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($e in $entries) {
            $key = [string](& $prop $e 'Key')
            if (@($ownKeys | Where-Object { [string]::Equals($_, $key, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                $eid = & $safe (& $prop $e 'Id') 40
                $own.Add($eid)
                Write-Warning "ID-PRIOR-OWN: the install capture shows $(& $safe $key) as this package's own uninstall key: the prior-install rule '$eid' was removed (a package never removes itself)."
                continue
            }
            $kept.Add($e)
        }
        $probe = $cfg.PSObject.Copy()
        $probe | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; Entries = @($kept.ToArray()) }) -Force
        $check = Test-Win32ToolkitPriorInstallEntry -Config $probe -Decisions @(Get-Win32ToolkitPriorInstallDecision -ProjectPath $ProjectPath) -Records @(Get-Win32ToolkitSiblingCaptureRecord -ProjectPath $ProjectPath)
        $final = [System.Collections.Generic.List[object]]::new()
        # PerEntry holds one result per entry, in order: matched by position, so an entry with an invalid or a duplicate
        # Id (PerEntry names it 'entry <n>', or twice) is checked as itself.
        $perEntry = @($check.PerEntry)
        if ($perEntry.Count -ne $kept.Count) { throw "the rule check returned $($perEntry.Count) results for $($kept.Count) rules" }
        for ($i = 0; $i -lt $kept.Count; $i++) {
            $e = $kept[$i]
            $pe = $perEntry[$i]
            $problems = @(@($pe.Problems) | Where-Object { [string]$_ -notlike 'capture record:*' })
            if ($problems.Count -gt 0) {
                $label = & $safe $pe.Id 40
                $why = ($problems | ForEach-Object { & $safe $_ 200 }) -join '; '
                $dropped.Add([pscustomobject]@{ Id = $label; Reason = $why })
                Write-Warning "The prior-install rule '$label' is not valid for this package after the install capture and was removed ($why). Declare it again with Set-Win32ToolkitPriorInstall."
                continue
            }
            $final.Add($e)
        }
        if ($own.Count -gt 0 -or $dropped.Count -gt 0) {
            $cfg | Add-Member -NotePropertyName PriorInstalls -NotePropertyValue ([pscustomobject][ordered]@{ SchemaVersion = '1.0'; Entries = @($final.ToArray()) }) -Force
            if ($PSCmdlet.ShouldProcess((Join-Path $ProjectPath 'SupportFiles\AppConfig.json'), 'Remove the prior-install rules the install capture invalidated')) {
                $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg -Confirm:$false
            }
        }
        return [pscustomobject]@{ Own = [string[]]@($own.ToArray()); Dropped = @($dropped.ToArray()) }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning ("The prior-install rules were not re-checked against the install capture (" + (& $safe $_.Exception.Message 200) + '): Export checks them.')
        return $null
    }
}
