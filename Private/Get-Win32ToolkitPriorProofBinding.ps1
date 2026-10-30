function Get-Win32ToolkitPriorProofBinding {
    <#
    .SYNOPSIS
        What a prior-install proof is bound to: the hashes of everything the device reads when it removes a prior.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.3, 2.10, L12, Dv4). An Update test that proves Enforce rules records these
        values (TestResults.json Proof); Get-Win32ToolkitPriorProofState only accepts a proof whose values equal the
        project's CURRENT ones, so any later change re-opens the proof:
          - PriorInstallsHash  : Get-Win32ToolkitPriorInstallHash -Kind Binding (every entry, own identity, App.Version,
                                 App.ScriptAuthor, Installer.Type / FileName);
          - ScriptSha256       : the bytes of Invoke-AppDeployToolkit.ps1;
          - FilesSha256        : SHA-256 of the UTF-8 text '<relative path, lower case>:<SHA-256>' + LF for every file
                                 under Files\, sorted ordinal (the installer, transforms, extra files);
          - SupportFilesSha256 : the same over SupportFiles\ (AppConfig.json, the org hooks dot-sourced before
                                 remove-prior, UpdateRequirement.ps1);
          - CatalogVersion     : Get-Win32ToolkitDeployScriptBlock -Name RemovePriorCatalogVersion;
          - ExtensionSha256    : the same tree hash over the project's copy of win32-toolkit's PSADT extension module
                                 (lean deploy script PR 2; its functions run the uninstall, the tattoo and the org
                                 dialogs), '' when the project has none (GeneratorVersion 0 / 2).
        Hashes are 64 upper-case hex characters; a missing file or folder hashes as empty ('' for the script). Pure
        read; never throws for a missing part (a W32T.* error from a helper is re-thrown).
    .PARAMETER ProjectPath
        The PSADT project folder.
    .OUTPUTS
        [pscustomobject] PriorInstallsHash, ScriptSha256, FilesSha256, SupportFilesSha256, CatalogVersion, ExtensionSha256.
    .EXAMPLE
        $binding = Get-Win32ToolkitPriorProofBinding -ProjectPath $p
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $hex = {
        param([byte[]]$Bytes)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') })) } finally { $sha.Dispose() }
    }
    $treeHash = {
        param([string]$Folder)
        $lines = [System.Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath $Folder -PathType Container) {
            $base = (Get-Item -LiteralPath $Folder).FullName.TrimEnd('\') + '\'
            foreach ($f in @(Get-ChildItem -LiteralPath $Folder -File -Recurse -Force -ErrorAction Stop)) {
                $rel = $f.FullName.Substring($base.Length).ToLowerInvariant()
                $lines.Add($rel + ':' + (& $hex ([System.IO.File]::ReadAllBytes($f.FullName))))
            }
        }
        $arr = [string[]]$lines.ToArray()
        [Array]::Sort($arr, [System.StringComparer]::Ordinal)
        $text = -join ($arr | ForEach-Object { $_ + "`n" })
        return (& $hex ([System.Text.UTF8Encoding]::new($false).GetBytes([string]$text)))
    }

    $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
    $script = Join-Path $ProjectPath 'Invoke-AppDeployToolkit.ps1'
    $scriptHash = if (Test-Path -LiteralPath $script -PathType Leaf) { & $hex ([System.IO.File]::ReadAllBytes($script)) } else { '' }
    $extension = Join-Path $ProjectPath 'PSAppDeployToolkit.Win32Toolkit'
    $extensionHash = if (Test-Path -LiteralPath $extension -PathType Container) { & $treeHash $extension } else { '' }
    [pscustomobject]@{
        PriorInstallsHash  = Get-Win32ToolkitPriorInstallHash -Config $cfg -Kind Binding
        ScriptSha256       = $scriptHash
        FilesSha256        = & $treeHash (Join-Path $ProjectPath 'Files')
        SupportFilesSha256 = & $treeHash (Join-Path $ProjectPath 'SupportFiles')
        CatalogVersion     = [string](Get-Win32ToolkitDeployScriptBlock -Name RemovePriorCatalogVersion)
        ExtensionSha256    = $extensionHash
    }
}
