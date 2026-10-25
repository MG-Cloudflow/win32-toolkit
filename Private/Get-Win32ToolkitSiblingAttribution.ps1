function Get-Win32ToolkitSiblingAttribution {
    <#
    .SYNOPSIS
        Ranks the new uninstall entries of one sibling capture and names the sibling installer's own (the primary).
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.8 rule 1, SV1, SV16). The host side of the attribution: it creates its
        scriptblock from the catalog text Get-Win32ToolkitSiblingAttributionScript - the SAME text the capture guest
        embeds - and calls $w32tScAttribute with the record's Observation.Candidates and Sibling.Manifest (plus, on the
        host, the signer subjects the host verified on the copied uninstaller and main program, and the sibling
        installer's own signer as Manifest.InstallerSignerSubject). Pure: no file, registry or network access. Those signer
        subjects exist only for the guest's provisional primary, which the guest ranked High or not at all, so Medium is
        not reached by a capture in PR 3b (see Get-Win32ToolkitSiblingAttributionScript).
    .PARAMETER Candidates
        The candidates (Observation.Candidates shape: Key, View, DisplayName, DisplayVersion, Publisher, SystemComponent,
        InstallLocation, UninstallerPath, InstallDir, UninstallerSignerSubject, MainSignerSubject).
    .PARAMETER Manifest
        The sibling's manifest facts (ProductCodes, Afe, PackageName, Publisher, DefaultInstallLocation,
        InstallerSignerSubject).
    .PARAMETER Own
        The package's own identity (ArpKeys, ProductCodes).
    .PARAMETER PackagePublisher
        The package's publisher (App.Vendor): a Microsoft publisher is ranked only for a Microsoft package.
    .PARAMETER NewRoots
        The folders the capture created (Observation.NewRoots): an entry inside one of them is CoInstalled when it is not
        the primary, and a Medium entry may match by the leaf of the one that holds it.
    .OUTPUTS
        [pscustomobject] Primary, PrimaryView, Rank, Reason, SameKey, CoInstalled, Unattributed.
    .EXAMPLE
        $a = Get-Win32ToolkitSiblingAttribution -Candidates $rec.Observation.Candidates -Manifest $rec.Sibling.Manifest -Own $own -NewRoots $rec.Observation.NewRoots
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Candidates,

        [AllowNull()]
        [object]$Manifest,

        [AllowNull()]
        [object]$Own,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$PackagePublisher = '',

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$NewRoots = @()
    )

    $w32tScAttribute = $null
    . ([scriptblock]::Create((Get-Win32ToolkitSiblingAttributionScript)))
    $r = & $w32tScAttribute @($Candidates | Where-Object { $null -ne $_ }) $Manifest $Own $PackagePublisher @($NewRoots | Where-Object { $_ })
    [pscustomobject][ordered]@{
        Primary      = [string]$r.Primary
        PrimaryView  = [string]$r.PrimaryView
        Rank         = [string]$r.Rank
        Reason       = [string]$r.Reason
        SameKey      = [bool]$r.SameKey
        CoInstalled  = @($r.CoInstalled | ForEach-Object { [pscustomobject]@{ Key = [string]$_.Key; View = [string]$_.View } })
        Unattributed = @($r.Unattributed | ForEach-Object { [pscustomobject]@{ Key = [string]$_.Key; View = [string]$_.View } })
    }
}
