function Invoke-AzBlobUpload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SasUri,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath
    )

    $chunkSize  = 1024 * 1024 * 6   # 6 MB — matches reference
    $isoEncoding = [System.Text.Encoding]::GetEncoding('iso-8859-1')
    $fileInfo   = Get-Item -Path $FilePath
    $totalSize  = $fileInfo.Length
    $chunkCount = [System.Math]::Ceiling($totalSize / $chunkSize)
    $chunkIds   = @()
    $chunkIndex = 0

    Write-Verbose "  File size: $([math]::Round($totalSize / 1MB, 1)) MB — uploading in $chunkCount chunk(s)..."

    $binaryReader = New-Object System.IO.BinaryReader(
        [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    )
    $null = $binaryReader.BaseStream.Seek(0, [System.IO.SeekOrigin]::Begin)

    try {
        for ($i = 0; $i -lt $chunkCount; $i++) {
            $start  = $i * $chunkSize
            $length = [System.Math]::Min($chunkSize, $totalSize - $start)
            $bytes  = $binaryReader.ReadBytes($length)

            # Block ID: 4-digit zero-padded index → ASCII bytes → base64 (no URL-encoding — matches reference)
            $chunkId  = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($i.ToString('0000')))
            $chunkIds += $chunkId

            # Convert bytes via ISO-8859-1 (1:1 byte→char mapping preserves binary content)
            $encodedBytes = $isoEncoding.GetString($bytes)
            $headers = @{
                'x-ms-blob-type' = 'BlockBlob'
                'content-type'   = 'text/plain; charset=iso-8859-1'
            }

            $blockUri = "$SasUri&comp=block&blockid=$chunkId"
            Invoke-WebRequest -Uri $blockUri -Method Put -Headers $headers `
                -Body $encodedBytes -UseBasicParsing | Out-Null

            $currentChunk = $i + 1
            Write-Progress -Activity 'Uploading to Azure Storage' `
                -Status "Uploading chunk $currentChunk of $chunkCount" `
                -PercentComplete ($currentChunk / $chunkCount * 100)
        }
    }
    finally {
        $binaryReader.Close()
        $binaryReader.Dispose()
    }

    # ── Commit: Put Block List ─────────────────────────────────────────────────────
    $blockListXml = '<?xml version="1.0" encoding="utf-8"?><BlockList>'
    foreach ($id in $chunkIds) { $blockListXml += "<Latest>$id</Latest>" }
    $blockListXml += '</BlockList>'

    $finalizeHeaders = @{ 'content-type' = 'text/plain; charset=UTF-8' }
    $commitUri = "$SasUri&comp=blocklist"
    Invoke-RestMethod -Uri $commitUri -Method Put -Body $blockListXml `
        -Headers $finalizeHeaders -ErrorAction Stop | Out-Null

    Write-Progress -Activity 'Uploading to Azure Storage' -Completed
    Write-Host '  ✓ Upload complete.' -ForegroundColor Green
}
