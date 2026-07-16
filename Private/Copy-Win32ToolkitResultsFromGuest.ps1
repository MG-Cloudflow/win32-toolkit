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

        The transfer is ONE zip, not a Copy-Item -FromSession round trip per file: N sessions round trips
        (0.5-2 s each) collapse to 3, and -FromSession's per-file attribute replay is sidestepped (the
        same failure mode the copy-IN zip already avoids). Entries are added PER FILE with try/catch so
        one locked/unreadable guest file loses only itself — and, unlike the old per-file
        -ErrorAction SilentlyContinue loop, every skipped file is now REPORTED instead of vanishing.
        A guest-vs-host entry-count check makes a torn transfer loud.
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

    # In-guest: resolve the globs and zip every match (relative to GuestRoot) into one archive.
    # 5.1-safe; untrusted values are arguments only. Returns @{ Zip; Count; Failed }.
    $guestResult = Invoke-Command -Session $Session -ScriptBlock {
        param($globs, $rootPrefix)
        # PS Direct doesn't inherit the host's $ProgressPreference (separate runspace); keep this remote
        # work from relaying any progress onto the host's Spectre TUI. (5.1-safe assignment.)
        $ProgressPreference = 'SilentlyContinue'

        $files = @()
        foreach ($g in $globs) {
            $files += @(Get-ChildItem -Path $g -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
        $files = @($files | Sort-Object -Unique)
        if ($files.Count -eq 0) { return @{ Zip = $null; Count = 0; Failed = @() } }

        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
        $zipPath = 'C:\Windows\Temp\w32results_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip'
        $failed  = @()
        $added   = 0
        $archive = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
        try {
            foreach ($f in $files) {
                # Entry name = path relative to the guest root ('/' separators per the zip spec).
                $rel = if ($f.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $f.Substring($rootPrefix.Length)
                } else { Split-Path -Leaf $f }
                try {
                    $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $archive, $f, ($rel -replace '\\', '/'), [System.IO.Compression.CompressionLevel]::NoCompression)
                    $added++
                }
                catch {
                    # One locked file must lose only itself (parity with the old per-file loop) — but
                    # visibly, so the host can warn about exactly what is missing.
                    $failed += ($rel + ' (' + $_.Exception.Message + ')')
                }
            }
        }
        finally { $archive.Dispose() }

        if ($added -eq 0) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            return @{ Zip = $null; Count = 0; Failed = $failed }
        }
        return @{ Zip = $zipPath; Count = $added; Failed = $failed }
    } -ArgumentList (, $GuestPath), ($GuestRoot.TrimEnd('\') + '\')

    foreach ($miss in @($guestResult.Failed)) {
        Write-Warning "Result file could not be read in the guest and was NOT copied back: $miss"
    }
    if (-not $guestResult.Zip) {
        Write-Verbose 'No result files matched in the guest — nothing to copy back.'
        return
    }

    # One transfer + host-side extract, then verify the count so a torn transfer cannot pass silently.
    $hostZip = Join-Path ([System.IO.Path]::GetTempPath()) ('w32results_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.zip')
    try {
        Copy-Item -FromSession $Session -Path $guestResult.Zip -Destination $hostZip -Force -ErrorAction Stop

        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
        $destRoot  = [System.IO.Path]::GetFullPath(($Destination.TrimEnd('\') + '\'))
        $extracted = 0
        $archive   = [System.IO.Compression.ZipFile]::OpenRead($hostZip)
        try {
            foreach ($entry in $archive.Entries) {
                $target = [System.IO.Path]::GetFullPath((Join-Path $Destination ($entry.FullName -replace '/', '\')))
                # The guest just ran an untrusted installer: never let an entry escape the project root.
                if (-not $target.StartsWith($destRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Warning "Skipped a result entry that resolves outside the project ('$($entry.FullName)')."
                    continue
                }
                $targetDir = Split-Path -Parent $target
                if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                $extracted++
            }
        }
        finally { $archive.Dispose() }

        if ($extracted -ne [int]$guestResult.Count) {
            Write-Warning "Result copy-back mismatch: the guest zipped $($guestResult.Count) file(s) but $extracted were extracted — review the warnings above and the guest logs."
        }
    }
    finally {
        if (Test-Path -LiteralPath $hostZip) { Remove-Item -LiteralPath $hostZip -Force -ErrorAction SilentlyContinue }
        Invoke-Command -Session $Session -ScriptBlock {
            param($zip)
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        } -ArgumentList $guestResult.Zip -ErrorAction SilentlyContinue
    }
}
