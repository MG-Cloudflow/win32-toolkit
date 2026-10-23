#Requires -Version 7.4

# Module-scope state variables.
# In a .psm1, $script: is module scope — persists for the module lifetime,
# never visible in the caller's global session.
$script:OrgTemplate           = $null
$script:TemplateSchemaVersion = '4.0'

# Supported PSAppDeployToolkit range (impact analysis §13 D1/D3, L3): Min inclusive, MaxExclusive exclusive.
# Widen MaxExclusive only after the template-contract suite and the golden-drift test pass on the new minor
# (a new minor normally needs a new deploy-script shape - L5). Never narrow it (D3). Keep Display in sync.
$script:PsadtSupportedRange = [pscustomobject]@{
    Min          = [version]'4.1.0'
    MaxExclusive = [version]'4.3.0'
    Display      = '4.1.x and 4.2.x'
}

# Ensure downloads (winget icons, IntuneWinAppUtil.exe, GitHub/PSGallery, Graph/Azure)
# negotiate a modern TLS version — add TLS 1.2 (and 1.3 where the OS supports it)
# without disturbing any protocols the host already enabled.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
    }
} catch {
    Write-Verbose "Could not raise TLS SecurityProtocol: $($_.Exception.Message)"
}

# Self-unblock: when the module was downloaded (repo ZIP, browser, Teams/OneDrive copy), every file
# carries the Mark-of-the-Web (Zone.Identifier), and under RemoteSigned each dot-sourced file below
# would raise its own "Do you want to run ...?" prompt (~40 of them). Clearing MOTW here — before
# dot-sourcing — means at most the FIRST import of the module itself can prompt; every other file,
# and every later session, loads silently. No-op for files that were never blocked (e.g. git clone).
try {
    Get-ChildItem -Path $PSScriptRoot -Recurse -File -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue
} catch {
    Write-Verbose "Self-unblock skipped: $($_.Exception.Message)"
}

# Dot-source every .ps1 file in Private\ then Public\ at module load time.
foreach ($folder in @('Private', 'Public')) {
    $folderPath = Join-Path $PSScriptRoot $folder
    if (Test-Path $folderPath) {
        Get-ChildItem -Path $folderPath -Filter '*.ps1' -File |
            ForEach-Object { . $_.FullName }
    }
}

# The machine-wide test-VM and project leases this process holds are open lock files (Enter-Win32ToolkitHyperVLease,
# Hyper-V speed-up PR 3). Remove-Module or Import-Module -Force must close them: an unreferenced handle would keep the
# lease, and block this very process, until the garbage collector finds it.
$ExecutionContext.SessionState.Module.OnRemove = {
    if ($script:HyperVLeases) {
        foreach ($hold in @($script:HyperVLeases.Values)) {
            try { $hold['Stream'].Dispose() }
            catch { Write-Verbose "A test-VM lease could not be closed: $($_.Exception.Message)" }
        }
        $script:HyperVLeases = $null
    }
}
