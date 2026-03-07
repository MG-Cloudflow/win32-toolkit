#Requires -Version 5.1

# Module-scope state variables.
# In a .psm1, $script: is module scope — persists for the module lifetime,
# never visible in the caller's global session.
$script:OrgTemplate           = $null
$script:TemplateSchemaVersion = '2.0'

# Dot-source every .ps1 file in Private\ then Public\ at module load time.
foreach ($folder in @('Private', 'Public')) {
    $folderPath = Join-Path $PSScriptRoot $folder
    if (Test-Path $folderPath) {
        Get-ChildItem -Path $folderPath -Filter '*.ps1' -File |
            ForEach-Object { . $_.FullName }
    }
}
