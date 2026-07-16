function Resolve-Win32ToolkitBaselineSilentArgs {
    <#
    .SYNOPSIS
        Resolves the silent-install switches for an old-baseline installer in the Update test.
    .DESCRIPTION
        Centralizes the switch-guessing so the Update test fails fast (not after a 30-minute sandbox
        hang) on installer "types" that have no silent path:

          - portable / zip / pwa  → THROW. A winget 'portable' package is just the app EXE (running it
            launches the app and blocks -Wait); zip/pwa aren't silent installers either.
          - a known type (nsis/inno/wix/burn/msi/msix/appx) → its documented switches, Guessed = $false.
          - an unknown type, or a typeless .exe → '/S' as a last-ditch GUESS, Guessed = $true (the caller
            warns; the run degrades to INCONCLUSIVE, not a hang, if the guess is wrong).

        YamlSilentArgs (from the downloaded manifest) always wins when present — but portable/zip/pwa
        still throw, since no switch makes them installable non-interactively.
    .PARAMETER InstallerTypeName
        winget InstallerType (lowercased), if known.
    .PARAMETER Extension
        Installer file extension incl. dot (e.g. '.exe') — used when no type is known.
    .PARAMETER YamlSilentArgs
        Silent switches parsed from the winget manifest, if any.
    .OUTPUTS
        [pscustomobject] @{ SilentArgs = <string>; Guessed = <bool> }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$InstallerTypeName,
        [string]$Extension,
        [string]$YamlSilentArgs
    )

    if ($InstallerTypeName -match '^(portable|zip|pwa)$') {
        throw "The baseline for this version is a '$InstallerTypeName' winget package — it has no silent installer (running it would launch the app itself and hang the sandbox). Pick a different baseline with -SpecificVersion, or test with -Scenario InstallUninstall."
    }

    if ($YamlSilentArgs) {
        return [pscustomobject]@{ SilentArgs = $YamlSilentArgs; Guessed = $false }
    }

    if ($InstallerTypeName) {
        $args = switch -Regex ($InstallerTypeName) {
            '^(nullsoft|nsis)$' { '/S';                          break }
            '^inno$'            { '/VERYSILENT /NORESTART /SP-'; break }
            '^(wix|burn)$'      { '/quiet /norestart';           break }
            '^msi$'             { '/qn /norestart';              break }
            '^(msix|appx)$'     { '';                            break }   # installed via Add-AppxPackage, no switches
            default             { '/S' }   # unknown type — guess
        }
        $guessed = $InstallerTypeName -notmatch '^(nullsoft|nsis|inno|wix|burn|msi|msix|appx)$'
        return [pscustomobject]@{ SilentArgs = $args; Guessed = $guessed }
    }

    switch (($Extension | ForEach-Object { $_.ToLower() })) {
        '.msi'  { return [pscustomobject]@{ SilentArgs = '/qn /norestart'; Guessed = $false } }
        # Appx-family (incl. bundles): install is standardized — no silent args exist.
        { $_ -in (Get-Win32ToolkitInstallerExtension -PackagesOnly) } {
                  return [pscustomobject]@{ SilentArgs = '';               Guessed = $false } }
        default { return [pscustomobject]@{ SilentArgs = '/S';             Guessed = $true } }   # typeless .exe — guess
    }
}
