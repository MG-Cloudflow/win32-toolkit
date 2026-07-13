function Get-Win32ToolkitInstallImage {
    <#
    .SYNOPSIS
        Locates the Windows install image on mounted ISO media and selects an edition index.
    .DESCRIPTION
        Detects install.wim vs install.esd under a mounted ISO's \sources folder (both are readable by
        Get-WindowsImage / DISM apply — branch only on the filename), enumerates the editions, and picks
        an ImageIndex: an explicit -ImageIndex when given, otherwise the first edition whose name matches
        -EditionPreference (default 'Enterprise'), else the first image. Never hard-codes /Index:1 —
        index order differs between ISOs. See knowledge-base/designs/hyperv-golden-image-build.md (§2.2).
    .PARAMETER SourcesPath
        Path to the mounted media's \sources directory (e.g. 'E:\sources').
    .PARAMETER ImageIndex
        Explicit image index to select. When omitted, -EditionPreference decides.
    .PARAMETER EditionPreference
        Ordered list of ImageName substrings tried when no explicit index is given; the first image
        matching the first pattern that hits wins. The default prefers 'Windows 11 Pro' (the sensible
        target on a consumer multi-edition ISO — NOT Home/Index:1) and falls back to 'Enterprise' for
        VL / evaluation media. Pass a single value (e.g. -EditionPreference 'Home') to force one.
    .OUTPUTS
        PSCustomObject with: ImagePath, Index, ImageName, Format ('wim' | 'esd').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcesPath,

        [int]$ImageIndex,

        [string[]]$EditionPreference = @('Windows 11 Pro', 'Windows 10 Pro', 'Enterprise', 'Pro')
    )

    $wim = Join-Path $SourcesPath 'install.wim'
    $esd = Join-Path $SourcesPath 'install.esd'
    $imagePath =
        if     (Test-Path -LiteralPath $wim) { $wim }
        elseif (Test-Path -LiteralPath $esd) { $esd }
        else   { throw "No install.wim or install.esd found under '$SourcesPath' — is this Windows install media?" }

    $images = @(Get-WindowsImage -ImagePath $imagePath)
    if ($images.Count -eq 0) { throw "No images found in '$imagePath'." }

    if ($PSBoundParameters.ContainsKey('ImageIndex') -and $ImageIndex) {
        $sel = $images | Where-Object { [int]$_.ImageIndex -eq $ImageIndex } | Select-Object -First 1
        if (-not $sel) {
            $have = ($images | ForEach-Object { "$($_.ImageIndex)=$($_.ImageName)" }) -join ', '
            throw "Image index $ImageIndex not present in '$imagePath'. Available: $have"
        }
    }
    else {
        $sel = $null
        foreach ($pattern in $EditionPreference) {
            $sel = $images | Where-Object { $_.ImageName -match [regex]::Escape($pattern) } | Select-Object -First 1
            if ($sel) { break }
        }
        if (-not $sel) {
            $sel = $images | Select-Object -First 1
            Write-Warning "No preferred edition ($($EditionPreference -join ', ')) found in this ISO — defaulting to '$($sel.ImageName)' (index $($sel.ImageIndex)). Use -Edition or -ImageIndex to choose."
        }
    }

    [pscustomobject]@{
        ImagePath = $imagePath
        Index     = [int]$sel.ImageIndex
        ImageName = [string]$sel.ImageName
        Format    = if ($imagePath -like '*.wim') { 'wim' } else { 'esd' }
    }
}
