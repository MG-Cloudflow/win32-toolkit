function Get-Win32ToolkitInstallerTechnology {
    <#
    .SYNOPSIS
        Reads the installer technology (NSIS or Inno Setup) from the signature inside an installer file.
    .DESCRIPTION
        A manual app (or a winget package labelled only 'exe') says nothing about the technology of its
        installer, so its EXE uninstaller got no silent switch. This helper recognises the two technologies
        whose silent switches the toolkit knows, from bytes the installer itself carries (the file is opened
        read-only and never executed):

          nullsoft   the NSIS first header: at a 512-byte aligned offset 512*k (k >= 1) within the first
                     1 MiB, the bytes at +4..+19 are EF BE AD DE 'NullsoftInst' (siginfo 0xDEADBEEF + magic)
          inno       the ASCII bytes 'rDlPtS' (the Inno Setup loader's offset-table id) within the first 4 MiB

        At most the first 4 MiB are read, once. Exactly one technology found -> that technology; both or
        neither, a missing file, a folder or a read error -> '' (with a verbose line). Never throws.
        A setup wrapped in another container (a 7-Zip self-extractor around an NSIS setup, Squirrel, Burn)
        is not recognised: it returns ''.
    .PARAMETER Path
        Full path to the installer file.
    .OUTPUTS
        [string] 'nullsoft', 'inno' or ''.
    .EXAMPLE
        Get-Win32ToolkitInstallerTechnology -Path 'C:\Win32Apps\Projects\Org\App\Files\setup.exe'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    $nsisWindow = 1MB
    $innoWindow = 4MB
    $shown = ([string]$Path) -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', '?'
    $stream = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) {
            Write-Verbose "Installer technology: '$shown' is not a file; technology unknown."
            return ''
        }
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $size = [int][Math]::Min([long]$stream.Length, [long]$innoWindow)
        $head = [byte[]]::new($size)
        $read = 0
        while ($read -lt $size) {
            $count = $stream.Read($head, $read, $size - $read)
            if ($count -le 0) { break }
            $read += $count
        }

        # NSIS first header: flags (4 bytes), then EF BE AD DE + 'NullsoftInst', at a 512-byte aligned offset.
        $nsisSignature = [byte[]](0xEF, 0xBE, 0xAD, 0xDE, 0x4E, 0x75, 0x6C, 0x6C, 0x73, 0x6F, 0x66, 0x74, 0x49, 0x6E, 0x73, 0x74)
        $nsisEnd = [Math]::Min($read, $nsisWindow)
        $isNsis = $false
        for ($offset = 512; $offset + 20 -le $nsisEnd -and -not $isNsis; $offset += 512) {
            $match = $true
            for ($i = 0; $i -lt 16; $i++) {
                if ($head[$offset + 4 + $i] -ne $nsisSignature[$i]) { $match = $false; break }
            }
            $isNsis = $match
        }

        # Inno Setup loader: the offset-table id 'rDlPtS' anywhere in the bytes read (Latin-1 maps bytes 1:1).
        $isInno = [System.Text.Encoding]::Latin1.GetString($head, 0, $read).IndexOf('rDlPtS', [System.StringComparison]::Ordinal) -ge 0

        if ($isNsis -and -not $isInno) { return 'nullsoft' }
        if ($isInno -and -not $isNsis) { return 'inno' }
        $why = if ($isNsis) { 'both an NSIS and an Inno Setup signature' } else { 'no NSIS or Inno Setup signature' }
        Write-Verbose "Installer technology: '$shown' has $why; technology unknown."
        return ''
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Installer technology: '$shown' could not be read ($(([string]$_.Exception.Message) -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', '?')); technology unknown."
        return ''
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}
