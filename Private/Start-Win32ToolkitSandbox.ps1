function Start-Win32ToolkitSandbox {
    <#
    .SYNOPSIS
        Launches Windows Sandbox with a prepared .wsb config file (the Sandbox backend's launch step).
    .DESCRIPTION
        Consolidates the three fire-and-forget WindowsSandbox.exe launches (documentation capture,
        InstallUninstall, Update) into one place so the launch + failure handling is consistent. On
        failure it warns and returns $false (rather than emitting a raw error and misleadingly reporting
        success) so callers can guide the operator to launch the .wsb manually.
    .PARAMETER ConfigPath
        Full path to the .wsb configuration file.
    .OUTPUTS
        [bool] — $true if WindowsSandbox.exe was started, $false (with a warning) if the launch failed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath
    )

    try {
        Start-Process -FilePath 'WindowsSandbox.exe' -ArgumentList "`"$ConfigPath`"" -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "Failed to start Windows Sandbox automatically: $($_.Exception.Message)"
        return $false
    }
}
