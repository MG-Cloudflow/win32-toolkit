#Requires -Version 7.2

# Module-scope state variables.
# In a .psm1, $script: is module scope — persists for the module lifetime,
# never visible in the caller's global session.
$script:OrgTemplate           = $null
$script:TemplateSchemaVersion = '2.0'

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

# Dot-source every .ps1 file in Private\ then Public\ at module load time.
foreach ($folder in @('Private', 'Public')) {
    $folderPath = Join-Path $PSScriptRoot $folder
    if (Test-Path $folderPath) {
        Get-ChildItem -Path $folderPath -Filter '*.ps1' -File |
            ForEach-Object { . $_.FullName }
    }
}
