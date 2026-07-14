function Publish-Win32ToolkitIntuneApp {
<#
.SYNOPSIS
    Uploads a packaged Win32 app (.intunewin) to Microsoft Intune via the Graph API.
.DESCRIPTION
    Authenticates to Microsoft Graph with the DeviceManagementApps.ReadWrite.All scope,
    then executes the full Win32 Lob App upload sequence:

    1. Reads app metadata (name, publisher, version, description, URL) from AppConfig.json (winget YAML fallback).
    2. Extracts encryption metadata from the .intunewin archive (metadata.xml).
    3. Builds a detection rule (install-tattoo version rule preferred; else from the NEWEST
       InstallationChanges_*.json capture in Documentation\).
    4. Creates the app shell in Intune.
    5. Registers a content version and file entry.
    6. Waits for the Azure Storage SAS URI.
    7. Uploads the encrypted content using the Azure Block Blob API (4 MB chunks).
    8. Commits the file and waits for confirmation.
    9. Links the content version to the app.

    Requires the Microsoft.Graph.Authentication module (installed automatically on prompt).

    With -AsUpdate the same .intunewin is published as a SECOND app of the same version whose
    requirement rule (a PowerShell presence check, built by Get-Win32ToolkitRequirementRule) makes it
    applicable only to devices that already have the app — the classic Intune "install app + update
    app" pattern. Detection stays the version-aware tattoo rule, so the update installs on machines
    with an older version and is detected once they reach this version. (Supersedence is separate.)
.PARAMETER IntuneWinPath
    Full path to the .intunewin file produced by Export-Win32ToolkitIntuneWin.
.PARAMETER ProjectPath
    Full path to the raw PSADT project folder. Used for YAML metadata and detection rules.
.PARAMETER AsUpdate
    Publish the update variant: append -UpdateNameSuffix to the display name and attach the
    "app already installed" requirement rule. Fails fast if no requirement rule can be built.
.PARAMETER UpdateNameSuffix
    Display-name suffix for the update app (default ' (Update)').
.EXAMPLE
    Publish-Win32ToolkitIntuneApp `
        -IntuneWinPath 'C:\Win32Apps\IntuneWin\Git_x64_2.53.0.intunewin' `
        -ProjectPath   'C:\Win32Apps\Projects\Git_x64_2.53.0'
.EXAMPLE
    # Publish the update app (2nd app, requirement-gated to devices that already have it)
    Publish-Win32ToolkitIntuneApp -IntuneWinPath $win -ProjectPath $proj -AsUpdate
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]   # { AppId; DisplayName; IsUpdateApp; PortalUri } — see the Summary block
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntuneWinPath,

        [Parameter(Mandatory = $true)]
        [string]$ProjectPath,

        # Publish this as the "update" app: a second Intune app of the same version whose requirement
        # rule (a PowerShell presence check) makes it applicable ONLY to devices that already have the
        # app — so it updates existing installs without installing on machines that shouldn't have it.
        [switch]$AsUpdate,

        # Display-name suffix that distinguishes the update app from the install app.
        [string]$UpdateNameSuffix = ' (Update)'
    )

    $baseUri  = 'https://graph.microsoft.com/beta/deviceAppManagement'
    $tempFile = $null

    try {
        # ── Validate inputs ───────────────────────────────────────────────────────
        if (-not (Test-Path $IntuneWinPath)) { throw "IntuneWin file not found: $IntuneWinPath" }
        if (-not (Test-Path $ProjectPath))   { throw "Project path not found: $ProjectPath" }

        Write-Host ''
        Write-Host 'Intune App Upload' -ForegroundColor Cyan
        Write-Host '=================' -ForegroundColor Cyan

        # ── App metadata (AppConfig.json first, winget YAML fallback) ─────────────
        $projectName = Split-Path $ProjectPath -Leaf
        $filesPath   = Join-Path $ProjectPath 'Files'

        $appCfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $app    = if ($appCfg.PSObject.Properties.Name -contains 'App') { $appCfg.App } else { $null }

        $yamlInfo = Get-YAMLInstallerInfo -FilesPath $filesPath
        $rawYaml  = ''
        $yamlFile = Get-ChildItem -Path $filesPath -Filter '*.yaml' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($yamlFile) { $rawYaml = Get-Content $yamlFile.FullName -Raw }

        $displayName = if     ($app -and $app.Name)                      { $app.Name }
                       elseif ($yamlInfo -and $yamlInfo.PackageName)     { $yamlInfo.PackageName }
                       else                                              { $projectName }
        $publisher   = if     ($app -and $app.Vendor)                    { $app.Vendor }
                       elseif ($yamlInfo -and $yamlInfo.Publisher)       { $yamlInfo.Publisher }
                       else                                              { 'Unknown' }
        $displayVersion = if     ($app -and $app.Version)                { $app.Version }
                          elseif ($yamlInfo -and $yamlInfo.PackageVersion) { $yamlInfo.PackageVersion }
                          else                                           { '' }
        $description = if     ($app -and $app.Description)               { $app.Description }
                       elseif ($rawYaml -match '(?m)^\s*ShortDescription:\s*(.+)') { $matches[1].Trim() }
                       elseif ($rawYaml -match '(?m)^\s*Description:\s*(.+)')      { $matches[1].Trim() }
                       else                                              { '' }
        $informationUrl = if     ($app -and $app.InformationUrl)         { $app.InformationUrl }
                          elseif ($rawYaml -match '(?m)^\s*PackageUrl:\s*(.+)')   { $matches[1].Trim() }
                          elseif ($rawYaml -match '(?m)^\s*PublisherUrl:\s*(.+)') { $matches[1].Trim() }
                          else                                           { '' }

        $wingetId = ''
        if ($rawYaml -match '(?m)^\s*PackageIdentifier:\s*(.+)') { $wingetId = $matches[1].Trim() }

        # ── Architecture: AppConfig.App.Arch, else parse the project folder name ──
        $arch = 'x64'
        if     ($app -and $app.Arch)           { $arch = $app.Arch }
        elseif ($projectName -match '_x86_')   { $arch = 'x86'   }
        elseif ($projectName -match '_arm64_') { $arch = 'arm64' }
        elseif ($projectName -match '_x64_')   { $arch = 'x64'   }

        # ── Update app: name suffix + requirement rule (applicable only where already installed) ──
        $requirementRules = @()
        if ($AsUpdate) {
            $reqRule = Get-Win32ToolkitRequirementRule -ProjectPath $ProjectPath
            if (-not $reqRule) {
                throw 'Update app requested, but no requirement rule could be built (AppConfig has no tattoo key, product code, or app name). Refusing to publish an update app that would apply to every device.'
            }
            $requirementRules = @($reqRule)
            $displayName      = "$displayName$UpdateNameSuffix"
        }

        Write-Host "  App name     : $displayName" -ForegroundColor Gray
        Write-Host "  Publisher    : $publisher"   -ForegroundColor Gray
        Write-Host "  Architecture : $arch"        -ForegroundColor Gray
        if ($AsUpdate) {
            Write-Host '  Mode         : UPDATE app (requirement: app already installed)' -ForegroundColor Gray
        }

        # ── Graph authentication ──────────────────────────────────────────────────
        Connect-Win32ToolkitGraph

        # ── Extract .intunewin metadata ───────────────────────────────────────────
        Write-Host 'Extracting .intunewin metadata...' -ForegroundColor Yellow
        $meta = Get-Win32IntuneWinMetadata -IntuneWinPath $IntuneWinPath
        Write-Host "  ✓ Unencrypted : $([math]::Round($meta.UnencryptedSize / 1MB, 2)) MB" -ForegroundColor Gray
        Write-Host "  ✓ Encrypted  : $([math]::Round($meta.SizeEncrypted   / 1MB, 2)) MB" -ForegroundColor Gray

        # ── Detection rules ───────────────────────────────────────────────────────
        Write-Host 'Building detection rules...' -ForegroundColor Yellow
        $detectionRules = @(Get-Win32DetectionRules -ProjectPath $ProjectPath)
        if ($detectionRules.Count -eq 0) {
            Write-Warning 'No detection rules found. The app will be created but you must add a detection rule manually in the Intune portal.'
        }

        # ── Step 1: Create app shell ──────────────────────────────────────────────
        Write-Host 'Creating app in Intune...' -ForegroundColor Yellow

        $appBody = @{
            '@odata.type'                      = '#microsoft.graph.win32LobApp'
            'displayName'                      = $displayName
            'displayVersion'                   = $displayVersion
            'description'                      = $description
            'publisher'                        = $publisher
            'informationUrl'                   = $informationUrl
            'privacyInformationUrl'            = ''
            'notes'                            = (@('win32-toolkit'; if ($AsUpdate) { 'update' }; if ($wingetId) { $wingetId }) | Where-Object { $_ }) -join '; '
            'isFeatured'                       = $false
            'fileName'                         = 'Invoke-AppDeployToolkit.ps1'
            'setupFilePath'                    = 'Invoke-AppDeployToolkit.ps1'
            'installCommandLine'               = 'powershell.exe -ExecutionPolicy Bypass -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install'
            'uninstallCommandLine'             = 'powershell.exe -ExecutionPolicy Bypass -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Uninstall'
            'applicableArchitectures'          = $arch
            'minimumSupportedWindowsRelease'   = '1607'
            'msiInformation'                   = $null
            'installExperience' = @{
                'runAsAccount'          = 'system'
                'deviceRestartBehavior' = 'suppress'
                'maxRunTimeInMinutes'   = 60
            }
            'returnCodes' = @(
                @{ 'returnCode' = 0;    'type' = 'success'    }
                @{ 'returnCode' = 1707; 'type' = 'success'    }
                @{ 'returnCode' = 3010; 'type' = 'softReboot' }
                @{ 'returnCode' = 1641; 'type' = 'hardReboot' }
                @{ 'returnCode' = 1618; 'type' = 'retry'      }
            )
            'detectionRules'   = @($detectionRules)
            'requirementRules' = @($requirementRules)
        }

        $appResponse = Invoke-MgGraphRequest -Method POST -Uri "$baseUri/mobileApps" `
            -Body ($appBody | ConvertTo-Json -Depth 10) -ContentType 'application/json' -OutputType PSObject
        $appId = $appResponse.id
        Write-Host "  ✓ App created: $appId" -ForegroundColor Green

        # ── Step 2: Create content version ────────────────────────────────────────
        Write-Host 'Creating content version...' -ForegroundColor Yellow
        $versionResponse = Invoke-MgGraphRequest -Method POST `
            -Uri "$baseUri/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions" `
            -Body @{} -OutputType PSObject
        $versionId = $versionResponse.id
        Write-Host "  ✓ Version: $versionId" -ForegroundColor Green

        # ── Step 3: Create file entry ─────────────────────────────────────────────
        Write-Host 'Registering file entry...' -ForegroundColor Yellow
        $fileBody = [ordered]@{
            '@odata.type'   = '#microsoft.graph.mobileAppContentFile'
            'name'          = [System.IO.Path]::GetFileName($IntuneWinPath)
            'size'          = [int64]$meta.UnencryptedSize
            'sizeEncrypted' = [int64]$meta.SizeEncrypted
            'manifest'      = $null
            'isDependency'  = $false
        }

        $fileUri      = "$baseUri/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$versionId/files"
        $fileResponse = Invoke-MgGraphRequest -Method POST -Uri $fileUri -Body ($fileBody | ConvertTo-Json -Depth 5) -ContentType 'application/json' -OutputType PSObject
        $fileId       = $fileResponse.id
        $fileUri      = "$fileUri/$fileId"
        Write-Host "  ✓ File entry: $fileId" -ForegroundColor Green

        # ── Step 4: Poll for Azure Storage SAS URI ────────────────────────────────
        Write-Host 'Waiting for Azure Storage SAS URI...' -ForegroundColor Yellow
        $sasUri = $null
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 3
            $poll = Invoke-MgGraphRequest -Method GET -Uri $fileUri -OutputType PSObject
            if ($poll.uploadState -eq 'azureStorageUriRequestSuccess') {
                $sasUri = $poll.azureStorageUri
                Write-Host '  ✓ SAS URI received.' -ForegroundColor Green
                break
            }
            if ($poll.uploadState -like '*Error*' -or $poll.uploadState -like '*Fail*') {
                throw "Azure Storage URI request failed. Upload state: $($poll.uploadState)"
            }
            Write-Host "  Waiting... (state: $($poll.uploadState))" -ForegroundColor Gray
        }
        if (-not $sasUri) { throw 'Timed out waiting for Azure Storage SAS URI (60 s).' }

        # ── Step 5: Extract inner encrypted file to temp ──────────────────────────
        Write-Host 'Extracting encrypted content file...' -ForegroundColor Yellow
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue

        $tempFile   = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($IntuneWinPath)
        try {
            $innerEntry  = $zipArchive.Entries | Where-Object { $_.FullName -eq $meta.InnerEntryName } | Select-Object -First 1
            if (-not $innerEntry) { throw "Inner content entry '$($meta.InnerEntryName)' not found in archive." }

            $entryStream = $innerEntry.Open()
            $outStream   = [System.IO.File]::Create($tempFile)
            try   { $entryStream.CopyTo($outStream) }
            finally {
                $outStream.Dispose()
                $entryStream.Dispose()
            }
        }
        finally {
            $zipArchive.Dispose()
        }
        Write-Host '  ✓ Content extracted to temp.' -ForegroundColor Green

        # ── Step 6: Upload to Azure Blob (block + blocklist) ──────────────────────
        Write-Host 'Uploading content to Azure Storage...' -ForegroundColor Yellow
        Invoke-AzBlobUpload -SasUri $sasUri -FilePath $tempFile

        # ── Step 7: Commit the file ───────────────────────────────────────────────
        Write-Host 'Committing file...' -ForegroundColor Yellow
        $commitBody = [ordered]@{
            'fileEncryptionInfo' = [ordered]@{
                'encryptionKey'        = $meta.EncryptionKey
                'macKey'               = $meta.MacKey
                'initializationVector' = $meta.InitializationVector
                'mac'                  = $meta.Mac
                'profileIdentifier'    = 'ProfileVersion1'
                'fileDigest'           = $meta.FileDigest
                'fileDigestAlgorithm'  = $meta.FileDigestAlgorithm
            }
        }
        Invoke-MgGraphRequest -Method POST -Uri "$fileUri/commit" -Body ($commitBody | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null

        # ── Step 8: Poll for commit success ───────────────────────────────────────
        Write-Host 'Waiting for commit confirmation...' -ForegroundColor Yellow
        $committed = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 3
            $poll = Invoke-MgGraphRequest -Method GET -Uri $fileUri -OutputType PSObject
            if ($poll.uploadState -eq 'commitFileSuccess') {
                Write-Host '  ✓ Commit successful.' -ForegroundColor Green
                $committed = $true
                break
            }
            if ($poll.uploadState -like '*Error*' -or $poll.uploadState -like '*Fail*') {
                throw "File commit failed. Upload state: $($poll.uploadState)"
            }
            Write-Host "  Waiting... (state: $($poll.uploadState))" -ForegroundColor Gray
        }
        if (-not $committed) { throw 'Timed out waiting for file commit (60 s).' }

        # ── Step 9: Link content version to app ──────────────────────────────────
        Write-Host 'Linking content version to app...' -ForegroundColor Yellow
        $patchBody = @{
            '@odata.type'             = '#microsoft.graph.win32LobApp'
            'committedContentVersion' = $versionId
        }
        Invoke-MgGraphRequest -Method PATCH -Uri "$baseUri/mobileApps/$appId" -Body ($patchBody | ConvertTo-Json -Depth 3) -ContentType 'application/json' | Out-Null

        # ── Summary ───────────────────────────────────────────────────────────────
        Write-Host ''
        Write-Host '✓ App published successfully!' -ForegroundColor Green
        Write-Host "  App ID : $appId"       -ForegroundColor Cyan
        Write-Host "  Name   : $displayName" -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  View in Intune portal:' -ForegroundColor Gray
        Write-Host "  https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$appId" -ForegroundColor DarkGray

        # EMIT the publication result. The app id previously existed only in a Write-Host line, so nothing
        # downstream could reference the app it had just created — which is exactly what an Intune
        # dependency relationship needs (you can only relate apps by id, and only AFTER the upload).
        # Emitted last so it is the sole object on the success pipeline.
        [pscustomobject]@{
            AppId        = $appId
            DisplayName  = $displayName
            IsUpdateApp  = [bool]$AsUpdate
            PortalUri    = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$appId"
        }
    }
    catch {
        $msg = "Publish-Win32ToolkitIntuneApp failed: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $msg += "`nGraph API error: $($_.ErrorDetails.Message)"
        }
        throw $msg
    }
    finally {
        if ($tempFile -and (Test-Path $tempFile)) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}
