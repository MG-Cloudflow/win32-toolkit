function Remove-Win32ToolkitPathWithRetry {
    <#
    .SYNOPSIS
        Recursively removes a path, retrying with back-off to ride out transient file locks.
    .DESCRIPTION
        Right after a bulk copy, Windows Defender (real-time scan) or the search indexer briefly hold open
        freshly-written files — notably PSADT .psm1 modules — so an immediate Remove-Item -Recurse fails
        with 'being used by another process' / 'The directory is not empty'. Retrying with a short back-off
        (400 ms doubling to a 3 s cap) almost always clears it.

        Returns $true when the path is gone (including when it never existed), $false if it still could not
        be removed after every retry. Progress is silenced for the duration so a large recursive delete
        never paints a progress bar over an interactive (Spectre) TUI.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateRange(1, 20)]
        [int]$Retries = 5,

        [ValidateRange(0, 60000)]
        [int]$InitialDelayMs = 400
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $delay = $InitialDelayMs
        for ($attempt = 1; $attempt -le $Retries; $attempt++) {
            try {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
                return $true
            }
            catch {
                # A partial delete may have already removed it (the error is about a now-gone child).
                if (-not (Test-Path -LiteralPath $Path)) { return $true }
                if ($attempt -eq $Retries) {
                    Write-Warning "Could not remove '$Path' after $Retries attempts (a file is locked — antivirus scan or an open handle): $($_.Exception.Message)"
                    return $false
                }
                Start-Sleep -Milliseconds $delay
                $delay = [Math]::Min($delay * 2, 3000)
            }
        }
        return $false
    }
    finally { $ProgressPreference = $prevProgress }
}
