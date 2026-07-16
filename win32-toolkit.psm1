#Requires -Version 7.2

# Module-scope state variables.
# In a .psm1, $script: is module scope — persists for the module lifetime,
# never visible in the caller's global session.
$script:OrgTemplate           = $null
$script:TemplateSchemaVersion = '3.0'

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
