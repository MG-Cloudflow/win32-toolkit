function Get-Win32ToolkitInstallerExtension {
    <#
    .SYNOPSIS
        The single source of truth for which installer file extensions the toolkit accepts.

    .DESCRIPTION
        These lists used to be duplicated across ~7 sites (download, cache probe, baseline download,
        file detection, rename), which is how .msixbundle support drifted: one site rejected bundles
        while another silently accepted a bundle that winget had named '.msix'.

        APPX-FAMILY NOTE — bundles are ordinary members of this family, not a special case:
        .msix/.appx and .msixbundle/.appxbundle install through exactly the same cmdlets
        (Add-AppxProvisionedPackage / Add-AppxPackage accept a bundle path natively) and uninstall by
        the same package Name. So Get-InstallerFileInfo deliberately reports Type 'msix'/'appx' for a
        bundle too: Type describes the INSTALL SEMANTICS, and every '-in @(''msix'',''appx'')' check
        downstream stays correct. Bundle-ness matters in exactly one place — reading the package
        identity — and Get-Win32ToolkitMsixIdentity detects that from the file's CONTENT, never its
        extension (winget names PowerShell's .msixbundle '.msix' because the manifest says
        InstallerType: msix — trusting the extension is what broke identity extraction).

    .PARAMETER PackagesOnly
        Return only the Appx-family extensions (no .exe/.msi).

    .PARAMETER BundlesOnly
        Return only the bundle extensions.

    .OUTPUTS
        [string[]] extensions, dot-prefixed and lower-case (e.g. '.msix').
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [switch]$PackagesOnly,
        [switch]$BundlesOnly
    )

    $bundles  = @('.msixbundle', '.appxbundle')
    $packages = @('.msix', '.appx') + $bundles

    # Leading comma: hand back the array as one object so callers get a string[] intact.
    if ($BundlesOnly)  { return , $bundles }
    if ($PackagesOnly) { return , $packages }
    return , (@('.exe', '.msi') + $packages)
}

function Get-Win32ToolkitInstallerType {
    <#
    .SYNOPSIS
        Maps an installer file extension to its INSTALL-SEMANTICS type — the single owner of that
        mapping.

    .DESCRIPTION
        The toolkit's installer Type is 'exe' | 'msi' | 'msix' | 'appx'. Bundles collapse into their
        family ('.msixbundle' -> 'msix', '.appxbundle' -> 'appx') because they install and uninstall
        identically; bundle-ness only matters to Get-Win32ToolkitMsixIdentity, which content-detects it.

        This exists because there were TWO independent extension->Type derivations: Get-InstallerFileInfo
        (which normalized) and Download-OldVersionInstaller (which returned the RAW extension). Once
        bundles became acceptable inputs, the un-normalized one started emitting Type 'msixbundle',
        which silently fell through the guest script's `-eq 'msix' -or -eq 'appx'` dependency dispatch
        into `Start-Process <file>.msixbundle` — opening the App Installer GUI and hanging the sandbox —
        and hard-failed Get-Win32ToolkitBaselineInstallCommand's ValidateSet. Both derivations now call
        this, so the mapping cannot drift again.

    .PARAMETER Extension
        File extension, with or without the leading dot (case-insensitive).

    .OUTPUTS
        [string] 'exe' | 'msi' | 'msix' | 'appx', or the lower-cased extension when unrecognized.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Extension
    )

    $e = $Extension.TrimStart('.').ToLowerInvariant()
    switch ($e) {
        'msixbundle' { return 'msix' }
        'appxbundle' { return 'appx' }
        default      { return $e }
    }
}
