function Get-Win32IntuneWinMetadata {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$IntuneWinPath
    )

    # System.IO.Compression.ZipFile is available by default on PowerShell 7.
    $zip = [System.IO.Compression.ZipFile]::OpenRead($IntuneWinPath)
    try {
        # ── Read Detection.xml ──────────────────────────────────────────────────
        # Actual path produced by IntuneWinAppUtil.exe: IntuneWinPackage/Metadata/Detection.xml
        $metaEntry = $zip.Entries | Where-Object { $_.FullName -eq 'IntuneWinPackage/Metadata/Detection.xml' } | Select-Object -First 1
        if (-not $metaEntry) {
            throw "Detection.xml not found inside .intunewin archive: $IntuneWinPath"
        }

        $stream  = $metaEntry.Open()
        $reader  = [System.IO.StreamReader]::new($stream)
        $xmlText = $reader.ReadToEnd()
        $reader.Close()
        $stream.Close()

        [xml]$xml = $xmlText
        $appInfo  = $xml.ApplicationInfo
        $encInfo  = $appInfo.EncryptionInfo

        # ── Find inner encrypted content file ─────────────────────────────────────
        # IntuneWinAppUtil.exe always names the inner file IntunePackage.intunewin
        $innerEntry = $zip.Entries |
            Where-Object { $_.FullName -eq 'IntuneWinPackage/Contents/IntunePackage.intunewin' } |
            Select-Object -First 1

        # Fallback: any .intunewin file inside Contents/ (future-proofing)
        if (-not $innerEntry) {
            $innerEntry = $zip.Entries |
                Where-Object { $_.FullName -like 'IntuneWinPackage/Contents/*.intunewin' } |
                Select-Object -First 1
        }

        if (-not $innerEntry) {
            throw "Inner content file not found in .intunewin archive: $IntuneWinPath"
        }

        return @{
            FileName             = $appInfo.FileName
            SetupFile            = $appInfo.SetupFile
            UnencryptedSize      = [long]$appInfo.UnencryptedContentSize
            EncryptionKey        = $encInfo.EncryptionKey
            MacKey               = $encInfo.MacKey
            InitializationVector = $encInfo.InitializationVector
            Mac                  = $encInfo.Mac
            FileDigest           = $encInfo.FileDigest
            FileDigestAlgorithm  = $encInfo.FileDigestAlgorithm
            ProfileIdentifier    = $encInfo.ProfileIdentifier
            InnerEntryName       = $innerEntry.FullName
            SizeEncrypted        = $innerEntry.Length   # uncompressed length = actual encrypted file size
        }
    }
    finally {
        $zip.Dispose()
    }
}
