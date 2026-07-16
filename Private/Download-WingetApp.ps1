function Download-WingetApp {
    <#
    .SYNOPSIS
        Downloads a winget package's installer into the project's Files\ folder.
    .DESCRIPTION
        Fixes two real defects in the original implementation:

        1. IT REPORTED SUCCESS WHEN WINGET FAILED. The old version returned $true unless PowerShell itself
           threw — and a native command failing does NOT throw. A non-zero winget exit (package not found,
           no installer for the requested architecture, network failure) therefore produced an EMPTY Files\
           folder that every downstream step treated as a valid download: the project got scaffolded, the
           sandbox "tested" nothing, and detection rules were generated from an install that never happened.
           Now: `& winget @wingetArgs`, check $LASTEXITCODE, and verify an installer actually landed.

        2. INVOKE-EXPRESSION ON AN UNTRUSTED VALUE. The command was assembled as a STRING containing $AppId
           — a winget-supplied identifier — and run through Invoke-Expression, so an id carrying shell
           metacharacters was a code-execution surface on the packaging host. The arguments are now passed
           as an ARRAY: no shell parsing, nothing to escape.

        Mirrors Download-OldVersionInstaller, which already did both correctly.
    .PARAMETER AppId
        winget PackageIdentifier (e.g. 'Git.Git'). Passed as an argument, never spliced into a command line.
    .PARAMETER AppName
        Display name, for progress output only.
    .PARAMETER DownloadPath
        Destination folder (the project's Files\).
    .PARAMETER Architecture
        x64 | x86 | arm64. 'all' or empty lets winget choose.
    .OUTPUTS
        [bool] $true ONLY if winget exited 0 AND an installer file is actually present.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppId,

        [string]$AppName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DownloadPath,

        [string]$Architecture
    )

    $label = if ($AppName) { "$AppName ($AppId)" } else { $AppId }
    Write-Verbose "Downloading $label [$Architecture]..."

    if (-not (Test-Path -LiteralPath $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    # Argument ARRAY — no shell, no Invoke-Expression, nothing to escape.
    $wingetArgs = @(
        'download'
        '--id',                 $AppId
        '--download-directory', $DownloadPath
        '--accept-source-agreements'
        '--accept-package-agreements'
    )
    if ($Architecture -and $Architecture -ne 'all') {
        $wingetArgs += '--architecture'
        $wingetArgs += $Architecture
    }

    try {
        & winget @wingetArgs
    }
    catch {
        Write-Error "Failed to run winget for $label : $($_.Exception.Message)"
        return $false
    }

    # A native command failing does NOT throw — this check is the entire point of the fix.
    if ($LASTEXITCODE -ne 0) {
        Write-Error "winget download exited with code $LASTEXITCODE for $label — no usable installer was downloaded."
        return $false
    }

    # Belt and braces: winget can exit 0 having written only a manifest (a zip/portable/store package),
    # which would leave the project with nothing to install.
    # Bundles count as installers: .msixbundle/.appxbundle install and uninstall exactly like a plain
    # package (see Get-Win32ToolkitInstallerExtension). Note winget names the file after the manifest's
    # InstallerType, NOT the URL — Microsoft.PowerShell's manifest says 'msix' while serving a
    # .msixbundle, so a bundle routinely arrives here already called '.msix'. Extension-based bundle
    # handling is therefore useless; identity is content-detected downstream.
    $produced  = @(Get-ChildItem -LiteralPath $DownloadPath -File -ErrorAction SilentlyContinue)
    $installer = @($produced | Where-Object { $_.Extension -in (Get-Win32ToolkitInstallerExtension) })

    if ($installer.Count -eq 0) {
        Write-Error "winget reported success for $label but wrote no installer (.exe/.msi/.msix/.appx/.msixbundle/.appxbundle) to '$DownloadPath'. This is usually a zip/portable/store package with no silent installer."
        return $false
    }

    Write-Host "✓ Downloaded: $($installer[0].Name)" -ForegroundColor Green
    return $true
}
