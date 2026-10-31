function Copy-Win32ToolkitDeployExtension {
    <#
    .SYNOPSIS
        Copies win32-toolkit's own PSADT extension module (PSAppDeployToolkit.Win32Toolkit) into a project, byte for byte.
    .DESCRIPTION
        PSADT 4.1.x and 4.2.x import every 'PSAppDeployToolkit.*' folder next to Invoke-AppDeployToolkit.ps1, so the copy
        goes to the project root. Fail closed, nothing half-done:

          1. the installed source must match the current known version (Get-Win32ToolkitDeployExtension -Verify);
          2. a project folder of that name that is a link (reparse point) is refused, never followed or deleted;
          3. an existing toolkit folder is replaced (it is the toolkit's own, never an org's: org extension folders may not
             start with the reserved name, Get-Win32ToolkitOrgExtensionLayoutFinding);
          4. the copy is hashed again; a difference removes it.

        Any failure throws W32T.DeployExtensionInvalid. The toolkit never writes into these files.
    .PARAMETER ProjectPath
        The PSADT project folder (it holds Invoke-AppDeployToolkit.ps1).
    .OUTPUTS
        [System.IO.DirectoryInfo] the project's extension folder (nothing under -WhatIf).
    .EXAMPLE
        Copy-Win32ToolkitDeployExtension -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.DirectoryInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $fail = {
        param([string]$Why, [string]$Target)
        [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("win32-toolkit could not place its PSADT extension module in the project: $Why"),
            'W32T.DeployExtensionInvalid', [System.Management.Automation.ErrorCategory]::InvalidData, $Target)
    }

    $ext = Get-Win32ToolkitDeployExtension -Verify
    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) { throw (& $fail "the project folder '$ProjectPath' does not exist." $ProjectPath) }
    $dest = Join-Path $ProjectPath $ext.Name
    if (-not $PSCmdlet.ShouldProcess($dest, "Copy win32-toolkit's PSADT extension module $($ext.Version)")) { return }

    if (Test-Path -LiteralPath $dest) {
        $item = Get-Item -LiteralPath $dest -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw (& $fail "'$dest' is a link (reparse point); it is not followed or deleted. Remove it and re-create the project." $dest) }
        if (-not $item.PSIsContainer) { throw (& $fail "'$dest' is a file, not the extension folder. Remove it and re-create the project." $dest) }
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop
    }
    $null = New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop
    foreach ($file in $ext.Files.Keys) {
        Copy-Item -LiteralPath (Join-Path $ext.SourcePath $file) -Destination (Join-Path $dest $file) -Force -ErrorAction Stop
    }

    $bad = @(foreach ($file in $ext.Files.Keys) {
            $copied = Join-Path $dest $file
            if (-not (Test-Path -LiteralPath $copied -PathType Leaf) -or (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ne $ext.Files[$file]) { $file }
        })
    if ($bad.Count -gt 0) {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        throw (& $fail "the copy of $($bad -join ', ') in '$dest' does not match the source (removed again)." $dest)
    }
    Write-Verbose "  win32-toolkit PSADT extension module $($ext.Version) copied: $dest"
    Get-Item -LiteralPath $dest
}
