function Copy-Win32ToolkitResultsFromGuest {
    <#
    .SYNOPSIS
        Copies result files the guest produced back to the host project, preserving structure.
    .DESCRIPTION
        The Hyper-V equivalent of the mapped folder's live write-back: after the guest phases run, the
        outputs (e.g. Documentation\InstallationChanges_*.json, Sandbox\Logs\*) live only on the guest
        VHDX, so copy them back UNDER the host project at the same relative path. This is what lets the
        existing host-side consumers (Wait-ForDocumentationAndProcess, Wait-Win32ToolkitUpdateAssertion,
        New-IntuneRequirementScript, ...) work unchanged — by the time they read, the files are on disk.
    .PARAMETER Session
        An open PowerShell Direct PSSession.
    .PARAMETER GuestPath
        One or more guest paths/globs under C:\PSADT to pull back (e.g. 'C:\PSADT\Documentation\*').
    .PARAMETER Destination
        Host project root that mirrors C:\PSADT.
    .PARAMETER GuestRoot
        The guest root that maps to Destination (default 'C:\PSADT'); used to compute relative paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string[]]$GuestPath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Destination,
        [string]$GuestRoot = 'C:\PSADT'
    )

    # Resolve the globs to concrete guest file paths.
    $files = Invoke-Command -Session $Session -ScriptBlock {
        param($globs)
        # PS Direct doesn't inherit the host's $ProgressPreference (separate runspace); keep this remote
        # enumeration from relaying any progress onto the host's Spectre TUI. (5.1-safe assignment.)
        $ProgressPreference = 'SilentlyContinue'
        foreach ($g in $globs) {
            Get-ChildItem -Path $g -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
        }
    } -ArgumentList (, $GuestPath)

    $rootPrefix = $GuestRoot.TrimEnd('\') + '\'
    foreach ($f in @($files)) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        $rel = if ($f.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $f.Substring($rootPrefix.Length) } else { Split-Path -Leaf $f }
        $dest    = Join-Path $Destination $rel
        $destDir = Split-Path -Parent $dest
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -FromSession $Session -LiteralPath $f -Destination $dest -Force -ErrorAction SilentlyContinue
    }
}
