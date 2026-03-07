function Get-Win32IntuneWinMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntuneWinPath
    )

    # System.IO.Compression is built-in on PS7; needed on PS5.1
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue

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
