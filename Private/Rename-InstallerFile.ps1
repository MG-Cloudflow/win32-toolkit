function Rename-InstallerFile {
    <#
    .SYNOPSIS
        Normalizes the installer filename in a project's Files\ folder to AppName_arch_version.ext.
    .DESCRIPTION
        For each supported installer extension (msi/exe/msix/appx) this renames the ONE unambiguous
        installer of that extension to the clean base name.

        It used to loop over EVERY file of a given extension and rename each one to the SAME target
        name, doing `Remove-Item $newPath -Force` first to clear the way. With two .exe files in Files\
        (a vendor drop of setup.exe + helper.exe, an installer beside its uninstaller, ...) the first
        file was renamed to the target name and then DELETED by the second iteration — silent data loss,
        the installer simply gone. The same hole existed when a correctly-named file was already present:
        it was filtered out of the candidate list but still sat at $newPath, so it got deleted too.

        Now: if an extension has more than one candidate, the rename is SKIPPED for that extension and
        the collision is named in a warning. Nothing is deleted, ever.

        The clean name is cosmetic — nothing downstream depends on it. Get-InstallerFileInfo selects the
        installer out of Files\ by EXTENSION PRECEDENCE (msi > exe > msix > appx), taking the first match
        by name; it does not inspect content, and it now warns when the choice is ambiguous. So skipping
        the rename leaves the pipeline working, but on an ambiguous folder the operator — not this
        function — has to decide which binary is the real installer.

        PSADT's own binaries (Invoke-AppDeployToolkit.exe, ServiceUI.exe) are not installer candidates,
        matching the exclusion in Get-InstallerFileInfo, so a stray copy of one of them next to the real
        installer does not block the rename.
    .PARAMETER FilesPath
        The project's Files\ folder.
    #>
    [CmdletBinding()]
    param(
        [string]$FilesPath,
        [string]$AppName,
        [string]$Version,
        [string]$Architecture
    )

    # Build a clean base name: AppName_Architecture_Version  (no spaces, filesystem-safe chars only)
    $cleanName = ($AppName -replace '[^A-Za-z0-9._-]', '_') -replace '_+', '_'
    $cleanVer  = ($Version  -replace '[^A-Za-z0-9._-]', '_') -replace '_+', '_'
    $cleanArch = ($Architecture -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    $baseName  = "${cleanName}_${cleanArch}_${cleanVer}"

    $renamed = $false
    # Bundles keep their own extension when renamed (App_x64_1.0.msixbundle) — the extension is
    # cosmetic; Get-InstallerFileInfo maps both to Type 'msix'/'appx'.
    foreach ($ext in @((Get-Win32ToolkitInstallerExtension) | ForEach-Object { $_.TrimStart('.') })) {
        # ALL files of this extension are candidates — including one that already carries the target
        # name. Excluding it from this list is what let the old code delete it.
        $candidates = @(Get-ChildItem -Path $FilesPath -Filter "*.$ext" -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -notlike '*Invoke-AppDeployToolkit*' -and
                $_.Name -notlike '*ServiceUI*'
            })

        if ($candidates.Count -eq 0) { continue }

        if ($candidates.Count -gt 1) {
            # Ambiguous: we cannot know which one the installer is, and collapsing them onto one name
            # would destroy every file but the last. Leave them all alone and say so.
            Write-Warning ("Files\ contains {0} .{1} files ({2}) — cannot normalize the installer filename without overwriting one of them, so all of them are left as-is. Packaging continues, but which one is treated as THE installer is then decided by name order, not by content — remove the file(s) that are not the installer from Files\." -f `
                $candidates.Count, $ext, (($candidates | ForEach-Object { $_.Name }) -join ', '))
            continue
        }

        $file = $candidates[0]
        if ($file.BaseName -eq $baseName) { continue }   # already clean

        $newName = "$baseName.$ext"
        $newPath = Join-Path $FilesPath $newName

        # Belt and braces: the only way $newPath can exist here is if it is an excluded PSADT binary
        # (i.e. the operator's app is literally named ServiceUI). Never delete it — skip instead.
        if ((Test-Path -LiteralPath $newPath) -and ($newPath -ne $file.FullName)) {
            Write-Warning "Cannot rename '$($file.Name)' to '$newName' — a file with that name already exists in Files\. Leaving it as-is."
            continue
        }

        # -Force here only covers read-only/hidden source files; it can never clobber a sibling now that
        # the destination is guaranteed free by the check above.
        Rename-Item -LiteralPath $file.FullName -NewName $newName -Force
        Write-Host "Renamed: $($file.Name)  ->  $newName" -ForegroundColor Cyan
        $renamed = $true
    }

    if (-not $renamed) {
        Write-Host 'Installer filename already clean — no rename needed.' -ForegroundColor Gray
    }
}
