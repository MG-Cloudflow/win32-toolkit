function Get-Win32ToolkitOrgExtensionLayoutFinding {
    <#
    .SYNOPSIS
        The project-independent checks of an org PSADT extension module folder (TUI audit G4, tui-gaps-spec 7.4).
    .DESCRIPTION
        Shared by Assert-Win32ToolkitOrgExtensionModule (which throws the first finding as W32T.OrgExtensionInvalid
        and then checks the RequiredModules versions against the PSAppDeployToolkit bundled in the project) and the
        org template wizard (New-OrgTemplate, which warns about every finding when the extension module is enabled).
        The Why texts are the Assert's, byte for byte. Rules, in order:

          0. the folder name starts with 'PSAppDeployToolkit.Win32Toolkit' (case-insensitive, trailing dots and spaces
             trimmed as Windows does): win32-toolkit reserves it for its own PSADT extension module, which every package
             carries (Get-Win32ToolkitDeployExtension). Nothing else is checked then.
          1. no '<Dir>\<Dir>.psd1' manifest (PSADT 4.2 imports the module by it; a psm1-only folder or a Save-Module
             '1.0.0\' layout fails every deployment of a PSADT 4.2 project). Nothing else is checked then.
          2. the manifest cannot be read. Nothing else is checked then.
          3. the manifest has no RootModule (then rule 4 is skipped).
          4. the RootModule file does not exist in the folder.
          5. a RequiredModules entry (hashtable) for PSAppDeployToolkit that is not a valid Windows PowerShell 5.1
             module specification (a prerelease label, ModuleVersion with RequiredVersion, no version, ...).
          6. such an entry with a GUID that is not PSAppDeployToolkit's.
          7. a command whose noun starts with 'W32T' (a function a .ps1/.psm1 in the folder defines, a string that names
             one - an alias or a function: drive entry -, or a manifest FunctionsToExport / CmdletsToExport /
             AliasesToExport entry): win32-toolkit reserves that prefix for its extension's functions. One finding per
             name.

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
    # win32-toolkit's own extension (Get-Win32ToolkitDeployExtension; the same prefix as Test-Win32ToolkitDeployExtension's
    # EXTENSION-STRAY rule and the copy guard in Add-Win32ToolkitOrgHooks).
    $reserved = 'PSAppDeployToolkit.Win32Toolkit'
    try {
        if ($dir.TrimEnd('.', ' ').StartsWith($reserved, [System.StringComparison]::OrdinalIgnoreCase)) {
            & $add "its folder name starts with '$reserved', which win32-toolkit reserves for its own PSADT extension module (every package carries it, and this folder would replace it). Fix: rename the folder, its manifest and its module, for example to 'PSAppDeployToolkit.<YourOrg>'."
            return $findings.ToArray()
        }
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

        # Rule 7: command names with the noun prefix W32T (the toolkit extension's functions; the deploy script calls them
        # module-qualified, so another module cannot shadow them, but the names must stay unambiguous in logs and help).
        $w32tName = '^(function:[\\/]?)?[A-Za-z]+-W32T\w*$'
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($key in 'FunctionsToExport', 'CmdletsToExport', 'AliasesToExport') {
            foreach ($entry in @($manifest[$key])) { if ($entry -is [string] -and $entry -match $w32tName) { $names.Add($entry) } }
        }
        foreach ($code in @(Get-ChildItem -LiteralPath $ModuleFolder.FullName -Recurse -File -Include '*.ps1', '*.psm1' -ErrorAction SilentlyContinue)) {
            $codeAst = [System.Management.Automation.Language.Parser]::ParseFile($code.FullName, [ref]$null, [ref]$null)
            foreach ($node in $codeAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
                $value = if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $node.Name } else { $node.Value }
                if ($value -match $w32tName) { $names.Add($value) }
            }
        }
        foreach ($n in @($names | Sort-Object -Unique)) {
            & $add "it defines or names the command '$n', and win32-toolkit reserves command names whose noun starts with 'W32T' for its own PSADT extension module. Fix: rename the command."
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Org extension module '$dir': the layout check stopped early: $($_.Exception.Message)"
    }
    $findings.ToArray()
}
