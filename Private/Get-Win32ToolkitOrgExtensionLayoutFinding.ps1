function Get-Win32ToolkitOrgExtensionLayoutFinding {
    <#
    .SYNOPSIS
        The project-independent checks of an org PSADT extension module folder (TUI audit G4, tui-gaps-spec 7.4).
    .DESCRIPTION
        Shared by Assert-Win32ToolkitOrgExtensionModule (which throws the first finding as W32T.OrgExtensionInvalid
        and then checks the RequiredModules versions against the PSAppDeployToolkit bundled in the project) and the
        org template wizard (New-OrgTemplate, which warns about every finding when the extension module is enabled).
        The Why texts are the Assert's, byte for byte. Rules, in order:

          1. no '<Dir>\<Dir>.psd1' manifest (PSADT 4.2 imports the module by it; a psm1-only folder or a Save-Module
             '1.0.0\' layout fails every deployment of a PSADT 4.2 project). Nothing else is checked then.
          2. the manifest cannot be read. Nothing else is checked then.
          3. the manifest has no RootModule (then rule 4 is skipped).
          4. the RootModule file does not exist in the folder.
          5. a RequiredModules entry (hashtable) for PSAppDeployToolkit that is not a valid Windows PowerShell 5.1
             module specification (a prerelease label, ModuleVersion with RequiredVersion, no version, ...).
          6. such an entry with a GUID that is not PSAppDeployToolkit's.

        Never throws: its catch starts with the W32T.* re-throw, then writes Write-Verbose and returns the findings
        found so far.
    .PARAMETER ModuleFolder
        One Templates\<name>\PSAppDeployToolkit.<Org>\ folder.
    .OUTPUTS
        [pscustomobject] { Folder; Why } per finding, in rule order (none for a valid folder).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.IO.DirectoryInfo]$ModuleFolder)

    $dir = $ModuleFolder.Name
    $findings = [System.Collections.Generic.List[object]]::new()
    $add = { param([string]$Why) $findings.Add([pscustomobject]@{ Folder = $dir; Why = $Why }) }
    $psadtGuid = [guid]'8c3c366b-8606-4576-9f2d-4051144f7ca2'
    $versionHint = "Fix: declare ModuleVersion = '4.1.0' (a minimum) or no version, and drop RequiredVersion/MaximumVersion - win32-toolkit builds PSADT 4.1.x and 4.2.x projects side by side."
    $layoutHint = "A Save-Module '1.0.0\' version-folder layout is not supported - put the module files directly in Templates\<name>\$dir\."
    try {
        $psd1 = Join-Path $ModuleFolder.FullName "$dir.psd1"
        if (-not (Test-Path -LiteralPath $psd1 -PathType Leaf)) {
            & $add "it has no '$dir\$dir.psd1' manifest. PSADT 4.2 imports extensions by that manifest, so a psm1-only folder fails every deployment of a PSADT 4.2 project (PSADT 4.1 still loads it by folder, but an org template must work for both: win32-toolkit builds PSADT 4.1.x and 4.2.x projects side by side). Fix: rename/add '$dir.psd1' (named exactly like the folder) with RootModule = '$dir.psm1'. $layoutHint"
            return $findings.ToArray()
        }
        $manifest = $null
        try { $manifest = Import-PowerShellDataFile -LiteralPath $psd1 -ErrorAction Stop }
        catch {
            if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
            & $add "its manifest '$dir.psd1' could not be read: $($_.Exception.Message)"
            return $findings.ToArray()
        }
        $root = if ($manifest.ContainsKey('RootModule')) { [string]$manifest['RootModule'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($root)) {
            & $add "its manifest '$dir.psd1' has no RootModule. Fix: set RootModule = '$dir.psm1' and put that file next to the manifest. $layoutHint"
        }
        elseif (-not (Test-Path -LiteralPath (Join-Path $ModuleFolder.FullName $root) -PathType Leaf)) {
            & $add "the RootModule '$root' of '$dir.psd1' does not exist in the folder. Fix: set RootModule to the module file next to the manifest (e.g. '$dir.psm1'). $layoutHint"
        }

        foreach ($req in @($manifest['RequiredModules'])) {
            # A bare 'PSAppDeployToolkit' string carries no version; only a hashtable can pin one.
            if ($null -eq $req -or $req -isnot [hashtable]) { continue }
            if ([string]$req['ModuleName'] -ne 'PSAppDeployToolkit') { continue }
            $given = (@($req.Keys | Where-Object { $_ -ne 'ModuleName' } | Sort-Object | ForEach-Object { "$_ = '$($req[$_])'" }) -join '; ')
            # The same constructor Windows PowerShell 5.1 uses for RequiredModules: it rejects a prerelease label,
            # ModuleVersion with RequiredVersion, unknown keys and an entry without any version.
            $spec = $null
            try { $spec = [Microsoft.PowerShell.Commands.ModuleSpecification]::new($req) }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                $inner = $_.Exception
                while ($inner.InnerException) { $inner = $inner.InnerException }
                & $add "its RequiredModules entry for PSAppDeployToolkit ($given) is not valid for Windows PowerShell 5.1: $($inner.Message) Every deployment would fail. $versionHint"
                continue
            }
            if ($spec.Guid -and $spec.Guid -ne $psadtGuid) {
                & $add "its RequiredModules entry for PSAppDeployToolkit has GUID $($spec.Guid), which is not PSAppDeployToolkit's ($psadtGuid), so every deployment would fail. Fix: use Guid = '$psadtGuid' or drop the GUID."
            }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Org extension module '$dir': the layout check stopped early: $($_.Exception.Message)"
    }
    $findings.ToArray()
}
