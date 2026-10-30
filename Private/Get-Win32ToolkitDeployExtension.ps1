function Get-Win32ToolkitDeployExtension {
    <#
    .SYNOPSIS
        Describes win32-toolkit's own PSADT extension module (PSAppDeployToolkit.Win32Toolkit): the current version, any
        version this toolkit ever shipped, and whether the installed copy is intact.
    .DESCRIPTION
        The extension module lives in DeployExtension\PSAppDeployToolkit.Win32Toolkit\ next to Public\ and Private\. It is
        copied byte for byte into every package (Copy-Win32ToolkitDeployExtension) and identified by the SHA-256 of its two
        files. The known-versions table below lists every version this toolkit has shipped, with those hashes and the
        revisions of the logic it provides (UninstallRevision: the uninstall routine; RemovePriorRevision: the prior-install
        pair, 0 = not in the extension). Rows are never removed: a project keeps the extension version it was built with
        and stays packageable.

        A change of either file must bump ModuleVersion in its manifest and add a row here (Tests\DeployExtension.unit.ps1
        recomputes the current row and fails on a difference).

        Design: knowledge-base/designs/lean-deploy-script-extension.md (sections 4.1 and 4.7).
    .PARAMETER Version
        Return the known row of this version instead of the current one ($null when this toolkit never shipped it).
    .PARAMETER All
        Return every known row, oldest first.
    .PARAMETER Verify
        Re-hash the installed DeployExtension\ copy against the current row: exactly the known files, the known hashes, no
        link. Throws W32T.DeployExtensionInvalid on any difference.
    .OUTPUTS
        [pscustomobject] Name, Version, Files (ordered: file name -> SHA-256, upper-case hex), UninstallRevision,
        RemovePriorRevision, IsCurrent, SourcePath.
    .EXAMPLE
        Get-Win32ToolkitDeployExtension -Verify
    #>
    [CmdletBinding(DefaultParameterSetName = 'Current')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Version')]
        [version]$Version,

        [Parameter(Mandatory, ParameterSetName = 'All')]
        [switch]$All,

        [Parameter(ParameterSetName = 'Current')]
        [switch]$Verify
    )

    $name = 'PSAppDeployToolkit.Win32Toolkit'
    $sourcePath = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeployExtension') $name

    # ---- the known-versions table (constants; one row per shipped version, oldest first, never removed) ----
    $known = @(
        @{
            Version             = '1.0.0'
            UninstallRevision   = 2
            RemovePriorRevision = 0
            Files               = [ordered]@{
                'PSAppDeployToolkit.Win32Toolkit.psd1' = '2D7E271DBF126DD0875946193DF4BE4427D100FBA4AF47BD185E14F305954922'
                'PSAppDeployToolkit.Win32Toolkit.psm1' = 'EBC3E53510337C0C021BA0EFA0B8862DF8DA4A8DB03A3177678C4E90F9337BD2'
            }
        }
    )

    $rows = for ($i = 0; $i -lt $known.Count; $i++) {
        [pscustomobject]@{
            Name                = $name
            Version             = [version]$known[$i].Version
            Files               = $known[$i].Files
            UninstallRevision   = [int]$known[$i].UninstallRevision
            RemovePriorRevision = [int]$known[$i].RemovePriorRevision
            IsCurrent           = ($i -eq $known.Count - 1)
            SourcePath          = $sourcePath
        }
    }
    $rows = @($rows)

    if ($All) { return $rows }
    if ($PSCmdlet.ParameterSetName -eq 'Version') { return ($rows | Where-Object { $_.Version -eq $Version } | Select-Object -First 1) }

    $current = $rows[-1]
    if ($Verify) {
        $why = [System.Collections.Generic.List[string]]::new()
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { $why.Add('the folder is missing') }
        elseif ((Get-Item -LiteralPath $sourcePath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $why.Add('the folder is a link (reparse point)') }
        else {
            $present = @(Get-ChildItem -LiteralPath $sourcePath -Force -ErrorAction Stop)
            foreach ($item in $present) {
                if ($item.PSIsContainer -or -not $current.Files.Contains($item.Name)) { $why.Add("unexpected item '$($item.Name)'") }
            }
            foreach ($file in $current.Files.Keys) {
                $path = Join-Path $sourcePath $file
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $why.Add("'$file' is missing"); continue }
                $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                if ($hash -ne $current.Files[$file]) { $why.Add("'$file' was changed") }
            }
        }
        if ($why.Count -gt 0) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("win32-toolkit's own PSADT extension module at '$sourcePath' does not match this win32-toolkit version $($current.Version) ($($why -join '; ')). Reinstall win32-toolkit. Nothing was written."),
                'W32T.DeployExtensionInvalid', [System.Management.Automation.ErrorCategory]::InvalidData, $sourcePath)
        }
    }
    $current
}
