function Resolve-Win32ToolkitBaselineSilentArgs {
    <#
    .SYNOPSIS
        Resolves the silent-install switches for an old-baseline (or sibling) installer, the way winget composes them.
    .DESCRIPTION
        Centralizes the switch-guessing so the Update test fails fast (not after a 30-minute sandbox
        hang) on installer "types" that have no silent path:

          - portable / zip / pwa  -> THROW. A winget 'portable' package is just the app EXE (running it
            launches the app and blocks -Wait); zip/pwa aren't silent installers either.
          - a known type -> winget's per-type default switches, Guessed = $false:
              nullsoft/nsis '/S'; inno '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' (winget's own Inno default);
              wix/burn '/quiet /norestart'; msi '/qn /norestart'; msix/appx '' (Add-AppxPackage).
          - an unknown type, or a typeless .exe -> '/S' as a last-ditch GUESS, Guessed = $true (the caller
            warns; the run degrades to INCONCLUSIVE, not a hang, if the guess is wrong).

        YamlSilentArgs (the manifest's InstallerSwitches Silent) replaces the default when present - but
        portable/zip/pwa still throw, since no switch makes them installable non-interactively. YamlCustomArgs (the
        manifest's InstallerSwitches Custom, for example Inno Setup's '/ALLUSERS') is appended after one space, as
        winget does, unless the switches already hold it as whole switches (case-insensitive; '/ALLUSERSX' does not
        hold '/ALLUSERS') (installer-identity PR 3b, L21, SV19). An MSIX/APPX package never gets switches.

        Source names where the switches came from: 'manifest-silent', 'manifest-silent+custom', 'catalog',
        'catalog+custom' or 'guessed'.
    .PARAMETER InstallerTypeName
        winget InstallerType (lowercased), if known.
    .PARAMETER Extension
        Installer file extension incl. dot (e.g. '.exe') - used when no type is known.
    .PARAMETER YamlSilentArgs
        Silent switches parsed from the winget manifest, if any.
    .PARAMETER YamlCustomArgs
        Custom switches parsed from the winget manifest, if any.
    .OUTPUTS
        [pscustomobject] @{ SilentArgs = <string>; Guessed = <bool>; Source = <string> }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$InstallerTypeName,
        [string]$Extension,
        [string]$YamlSilentArgs,
        [string]$YamlCustomArgs
    )

    if ($InstallerTypeName -match '^(portable|zip|pwa)$') {
        throw "The baseline for this version is a '$InstallerTypeName' winget package - it has no silent installer (running it would launch the app itself and hang the sandbox). Pick a different baseline with -SpecificVersion, or test with -Scenario InstallUninstall."
    }

    $custom = ([string]$YamlCustomArgs).Trim()
    # "Already present" means as whole switches (case-insensitive): '/ALLUSERSX' does not hold '/ALLUSERS'.
    $present = { param([string]$Switches) $Switches -match ('(?i)(?<!\S)' + [regex]::Escape($custom) + '(?!\S)') }
    $result = {
        param([string]$Switches, [bool]$Guessed, [string]$Source, [bool]$Package = $false)
        if ($custom -and -not $Package -and $Source -ne 'guessed' -and -not (& $present $Switches)) {
            $Switches = ("$Switches $custom").Trim()
            $Source = "$Source+custom"
        }
        [pscustomobject]@{ SilentArgs = $Switches; Guessed = $Guessed; Source = $Source }
    }

    if ($YamlSilentArgs) {
        return (& $result $YamlSilentArgs $false 'manifest-silent' ($InstallerTypeName -match '^(msix|appx)$'))
    }

    if ($InstallerTypeName) {
        $known = $InstallerTypeName -match '^(nullsoft|nsis|inno|wix|burn|msi|msix|appx)$'
        $switches = switch -Regex ($InstallerTypeName) {
            '^(nullsoft|nsis)$' { '/S'; break }
            '^inno$'            { '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; break }
            '^(wix|burn)$'      { '/quiet /norestart'; break }
            '^msi$'             { '/qn /norestart'; break }
            '^(msix|appx)$'     { ''; break }   # installed via Add-AppxPackage, no switches
            default             { '/S' }        # unknown type - guess
        }
        return (& $result $switches (-not $known) $(if ($known) { 'catalog' } else { 'guessed' }) ($InstallerTypeName -match '^(msix|appx)$'))
    }

    switch (($Extension | ForEach-Object { $_.ToLower() })) {
        '.msi'  { return (& $result '/qn /norestart' $false 'catalog') }
        # Appx-family (incl. bundles): install is standardized - no silent args exist.
        { $_ -in (Get-Win32ToolkitInstallerExtension -PackagesOnly) } { return (& $result '' $false 'catalog' $true) }
        default { return (& $result '/S' $true 'guessed') }   # typeless .exe - guess
    }
}
