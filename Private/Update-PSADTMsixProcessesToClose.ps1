function Update-PSADTMsixProcessesToClose {
    <#
    .SYNOPSIS
        Writes AppConfig.json's ProcessesToClose for an MSIX/APPX project from the package manifest.

    .DESCRIPTION
        Runs at CONFIGURE time (capture-independent), exactly like Update-PSADTMsixUninstallLogic and
        for the same reason: the capture-based writer (Update-PSADTProcessesToClose) only recognises
        classic Win32 artifacts — App Paths keys, the Uninstall key's DisplayIcon, EXEs under
        InstallLocation — and an MSIX writes none of them (registry virtualization; payload lands in
        %ProgramFiles%\WindowsApps\<PackageFullName>\). So every MSIX ended up with
        ProcessesToClose = @() and the deployment never offered to close the running app.

        The package manifest declares them outright (<Application Executable="pwsh.exe" />), so read
        that. Names are validated with Test-Win32ToolkitProcessName — the same guard the capture path
        uses — because they end up in the deploy script's AppProcessesToClose, and are stored as DATA in
        AppConfig.json (never spliced into code).

    .PARAMETER ProjectPath
        Full path to the PSADT project folder.

    .OUTPUTS
        [bool] $true when a ProcessesToClose list was written (even an empty one for a package that
        genuinely declares no apps); $false when this is not an MSIX project or the package is unreadable.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    try {
        $filesPath = Join-Path $ProjectPath 'Files'
        $fileInfo  = Get-InstallerFileInfo -FilesPath $filesPath
        if (-not $fileInfo.FileName -or $fileInfo.Type -notin @('msix', 'appx')) { return $false }

        $apps = @(Get-Win32ToolkitMsixApplication -Path (Join-Path $filesPath $fileInfo.FileName))

        # Same validation + noise filter as the capture-based path.
        $excludePattern = 'uninstall|uninst|setup|install|update|patch|redist'
        $valid = [System.Collections.Generic.List[string]]::new()
        foreach ($a in $apps) {
            if ($a -and $a -notmatch $excludePattern -and (Test-Win32ToolkitProcessName $a) -and $a -notin $valid) {
                $valid.Add($a)
            }
        }
        $sorted = @($valid | Sort-Object)

        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $cfg | Add-Member -NotePropertyName ProcessesToClose -NotePropertyValue $sorted -Force
        Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg | Out-Null

        if ($sorted.Count -gt 0) {
            Write-Host "✓ ProcessesToClose written from the MSIX manifest: $($sorted -join ', ')" -ForegroundColor Green
        } else {
            Write-Verbose 'MSIX manifest declares no launchable applications — ProcessesToClose left empty.'
        }
        return $true
    }
    catch {
        Write-Warning "Failed to write MSIX ProcessesToClose data: $($_.Exception.Message)"
        return $false
    }
}
