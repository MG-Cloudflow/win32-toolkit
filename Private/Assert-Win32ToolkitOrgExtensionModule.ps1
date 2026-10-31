function Assert-Win32ToolkitOrgExtensionModule {
    <#
    .SYNOPSIS
        D11 / ORG-08 - validates the org PSADT extension module folder(s) of a template against a project,
        without writing anything; throws W32T.OrgExtensionInvalid on the first violation.

    .DESCRIPTION
        Every Templates\<name>\PSAppDeployToolkit.<Org>\ folder is imported by the PSADT frontend inside the
        deployment's try block, so a broken extension fails EVERY deployment with exit code 60001. Checked
        for each folder, before any of them is copied:

          * PSADT 4.2 imports '<Dir>\<Dir>.psd1': the folder must contain that manifest (named exactly like
            the folder) with a RootModule that exists in the folder (a psm1-only folder or a Save-Module
            '1.0.0\' version-folder layout fails on PSADT 4.2 projects; refused for every project because
            one org template serves PSADT 4.1 and 4.2 projects alike - 4.1 loads a psm1-only folder).
          * A RequiredModules entry (hashtable) naming PSAppDeployToolkit must be a valid module
            specification for Windows PowerShell 5.1 (no prerelease label, not ModuleVersion and
            RequiredVersion together) and must be satisfied by the PSAppDeployToolkit bundled in the project
            (PSAppDeployToolkit\PSAppDeployToolkit.psd1), key by key as PowerShell checks it: ModuleVersion
            is a minimum, RequiredVersion an exact pin, MaximumVersion an upper bound (a trailing '*' is a
            wildcard, as in PowerShell). Versions compare as plain [version] values (4.2.0.0 is not 4.2.0
            on the device either). A GUID, when given, must be PSAppDeployToolkit's.

        The project-independent rules (the manifest and RootModule layout, a RequiredModules entry valid for
        Windows PowerShell 5.1, PSAppDeployToolkit's GUID) come from Get-Win32ToolkitOrgExtensionLayoutFinding,
        which the org template wizard runs too; the version checks against the bundled module stay here.

        Called by Apply-OrgTemplate before its first write and again by Add-Win32ToolkitOrgHooks before it
        places, copies or writes anything (defence in depth). A template without ExtensionModule, or whose
        asset folder cannot be resolved, has nothing to validate.

    .PARAMETER ProjectPath
        The generated PSADT project (its bundled PSAppDeployToolkit is the version checked against).

    .PARAMETER Template
        The org-template object. ExtensionModule and TemplateName are read defensively.

    .OUTPUTS
        [System.IO.DirectoryInfo] the validated extension module folders (none when the feature is off).
    #>
    [CmdletBinding()]
    [OutputType([System.IO.DirectoryInfo])]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][PSCustomObject]$Template,
        # The run's base folder (its Templates\<name>\ holds the module); empty = the configured base folder.
        [string]$BasePath
    )

    $extEnabled = $false
    if ($Template.PSObject.Properties['ExtensionModule']) { $extEnabled = [bool]$Template.ExtensionModule }
    if (-not $extEnabled) { return }

    $assetFolder = $null
    $tn = if ($Template.PSObject.Properties['TemplateName']) { [string]$Template.TemplateName } else { '' }
    if ($tn) {
        try { $assetFolder = Get-Win32ToolkitTemplateAssetFolder -TemplateName $tn -BasePath $BasePath } catch {
            Write-Verbose "Org extension module: could not resolve template asset folder - skipping ($($_.Exception.Message))"
        }
    }
    if (-not $assetFolder -or -not (Test-Path -LiteralPath $assetFolder)) { return }

    $modDirs = @(Get-ChildItem -LiteralPath $assetFolder -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^PSAppDeployToolkit\..+' })

    $versionHint = "Fix: declare ModuleVersion = '4.1.0' (a minimum) or no version, and drop RequiredVersion/MaximumVersion - win32-toolkit builds PSADT 4.1.x and 4.2.x projects side by side."
    $bundledVersion = $null
    foreach ($md in $modDirs) {
        $dir = $md.Name
        $fail = {
            param([string]$Why)
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Org extension module '$dir' cannot be used: $Why"),
                'W32T.OrgExtensionInvalid', [System.Management.Automation.ErrorCategory]::InvalidData, $md.FullName)
        }
        # The project-independent rules (layout, manifest, RootModule, a RequiredModules entry valid for Windows
        # PowerShell 5.1 with PSAppDeployToolkit's GUID) are shared with the org template wizard; the first finding
        # is thrown with the same text as before.
        $layoutFindings = @(Get-Win32ToolkitOrgExtensionLayoutFinding -ModuleFolder $md)
        if ($layoutFindings.Count -gt 0) { throw (& $fail $layoutFindings[0].Why) }
        $psd1 = Join-Path $md.FullName "$dir.psd1"
        try { $manifest = Import-PowerShellDataFile -LiteralPath $psd1 -ErrorAction Stop }
        catch { throw (& $fail "its manifest '$dir.psd1' could not be read: $($_.Exception.Message)") }

        foreach ($req in @($manifest['RequiredModules'])) {
            # A bare 'PSAppDeployToolkit' string carries no version; only a hashtable can pin one.
            if ($null -eq $req -or $req -isnot [hashtable]) { continue }
            if ([string]$req['ModuleName'] -ne 'PSAppDeployToolkit') { continue }
            $given = (@($req.Keys | Where-Object { $_ -ne 'ModuleName' } | Sort-Object | ForEach-Object { "$_ = '$($req[$_])'" }) -join '; ')
            # Valid for Windows PowerShell 5.1 with PSAppDeployToolkit's GUID (checked by the layout finding above).
            $spec = [Microsoft.PowerShell.Commands.ModuleSpecification]::new($req)

            if ($null -eq $bundledVersion) {
                $bundledPsd1 = Join-Path $ProjectPath 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'
                try { $bundledVersion = [version](Import-PowerShellDataFile -LiteralPath $bundledPsd1 -ErrorAction Stop).ModuleVersion }
                catch { throw (& $fail "it requires PSAppDeployToolkit ($given; RequiredModules), but the project's bundled PSAppDeployToolkit\PSAppDeployToolkit.psd1 could not be read to check it: $($_.Exception.Message)") }
            }

            if ($spec.Version -and $spec.Version -gt $bundledVersion) {
                throw (& $fail "it requires PSAppDeployToolkit $($spec.Version) or newer (RequiredModules ModuleVersion), but this project bundles PSAppDeployToolkit $bundledVersion, so every deployment would fail. $versionHint")
            }
            if ($spec.RequiredVersion -and $spec.RequiredVersion -ne $bundledVersion) {
                throw (& $fail "it requires exactly PSAppDeployToolkit $($spec.RequiredVersion) (RequiredModules RequiredVersion), but this project bundles PSAppDeployToolkit $bundledVersion, so every deployment would fail. $versionHint")
            }
            if ($spec.MaximumVersion) {
                # PowerShell reads a '*' in MaximumVersion as 999999999 ('4.1.*' -> 4.1.999999999).
                $max = $null
                if (-not [version]::TryParse(([string]$spec.MaximumVersion).Replace('*', '999999999'), [ref]$max)) {
                    throw (& $fail "its RequiredModules entry for PSAppDeployToolkit has an unreadable MaximumVersion '$($spec.MaximumVersion)', so every deployment would fail. $versionHint")
                }
                if ($max -lt $bundledVersion) {
                    throw (& $fail "it requires PSAppDeployToolkit $($spec.MaximumVersion) at most (RequiredModules MaximumVersion), but this project bundles PSAppDeployToolkit $bundledVersion, so every deployment would fail. $versionHint")
                }
            }
        }
    }

    $modDirs
}
