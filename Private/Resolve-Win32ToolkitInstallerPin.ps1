function Resolve-Win32ToolkitInstallerPin {
    <#
    .SYNOPSIS
        Decides which installer technology (winget installer type) a winget package download is pinned to.
    .DESCRIPTION
        Installer-identity PR 1, spec 2.10 (D3, V24, V34, L1, L3). In order:

          1. -InstallerType given (the CLI parameter or the TUI technology question): that type,
             PinnedBy 'parameter', Reason 'requested'. When it is another family than an anchored
             -SelfAnchor, one warning says that devices with the rebuilt version get a second registration.
          2. Otherwise the version being REBUILT, when it is itself published or pinned (-SelfAnchor, read
             by Get-Win32ToolkitSelfAnchor before the old folder is deleted): it keeps its own technology,
             Reason 'kept from <name> (published|pinned, rebuilt)'. PinnedBy stays its own explicit pin
             ('parameter' or 'operator') so it keeps anchoring later versions, else 'continuity' (a
             published rebuild keeps anchoring through its Intune\Publications.json, which
             Invoke-Win32Toolkit carries over the re-creation).
          3. Otherwise continuity: the highest earlier version of the same winget id in this template folder
             that was published (to -TenantId when given) or pinned explicitly
             (Get-Win32ToolkitPreviousProject .Anchor) keeps its technology: InstallerType = the anchor's pin
             value (appx -> msix), PinnedBy 'continuity', Reason 'kept from <name> (published|pinned)'.
             The match is by winget id only: the new app's Publisher and PackageName are not known before the
             download (L1, Dv1); the Vendor + DisplayName match runs after the download in the identity checks
             (ID-FAMILY). A version that cannot be read ('Unknown') skips this step with one warning.
          4. Otherwise no pin: InstallerType '', PinnedBy 'winget-default', Reason "winget's choice".

        WingetClient is 'winget --version' without the leading 'v' ('' when it cannot be read). The values are
        data (AppConfig.Source); nothing here is ever turned into code. Never throws: a failed predecessor
        lookup warns once and falls back to winget's choice.
    .PARAMETER TemplateDirectory
        The template folder under Projects\ (<BasePath>\Projects\<Template>).
    .PARAMETER WingetId
        The winget PackageIdentifier being packaged.
    .PARAMETER Version
        The version being packaged ('Unknown' when the search table had none).
    .PARAMETER InstallerType
        An explicit pin (msi, wix, burn, nullsoft, inno, exe, msix); '' or absent = not pinned by the operator.
    .PARAMETER ExcludePath
        The project being built (never its own predecessor).
    .PARAMETER TenantId
        Only publications to this tenant anchor continuity ('' = any recorded publication, Dv4).
    .PARAMETER SelfAnchor
        The project being rebuilt, when it is itself published or pinned (Get-Win32ToolkitSelfAnchor:
        Name, InstallerType, PinnedBy, AnchorReason 'published' | 'pinned:parameter' | 'pinned:operator').
        $null (default) = a new project, or one that anchors nothing.
    .OUTPUTS
        [pscustomobject] InstallerType ('' = no pin), Family, PinnedBy (parameter | continuity |
        winget-default), Predecessor (the anchor match or $null), WingetClient, Reason.
    .EXAMPLE
        $pin = Resolve-Win32ToolkitInstallerPin -TemplateDirectory $projectsDir -WingetId 'Notepad++.Notepad++' -Version '8.9.8.1'
        Download-WingetApp -AppId 'Notepad++.Notepad++' -DownloadPath $files -Architecture x64 -InstallerType $pin.InstallerType -PinnedBy $pin.PinnedBy -PinReason $pin.Reason
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TemplateDirectory,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WingetId,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$InstallerType = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExcludePath = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TenantId = '',

        [AllowNull()]
        [object]$SelfAnchor = $null
    )

    # ---- winget client version (data only; '' when winget is missing or prints something unexpected) ----
    $client = ''
    try {
        $raw = & winget --version 2>$null | Select-Object -First 1
        $text = ([string]$raw).Trim() -replace '^[vV]', ''
        if ($text -match '^\d+(\.\d+){0,3}([-+][0-9A-Za-z.-]{1,32})?$') { $client = $text }
        else { Write-Verbose "Resolve-Win32ToolkitInstallerPin: 'winget --version' gave no readable version." }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Resolve-Win32ToolkitInstallerPin: 'winget --version' failed: $($_.Exception.Message)"
    }

    $result = [pscustomobject]@{
        InstallerType = ''
        Family        = ''
        PinnedBy      = 'winget-default'
        Predecessor   = $null
        WingetClient  = $client
        Reason        = "winget's choice"
    }

    # The version being rebuilt, when it is itself published or pinned (its folder is deleted before this
    # runs, and the predecessor lookup excludes it): its own pin value, or nothing.
    $self = $null
    $selfRow = $null
    if ($null -ne $SelfAnchor) {
        $selfType = if ($SelfAnchor.PSObject.Properties['InstallerType']) { ([string]$SelfAnchor.InstallerType).Trim() } else { '' }
        if ($selfType) { $selfRow = Get-Win32ToolkitInstallerFamily -Type $selfType }
        if ($selfRow -and $selfRow.PinValue) { $self = $SelfAnchor }
        else { Write-Verbose "Resolve-Win32ToolkitInstallerPin: the rebuilt project has no installer type that can be pinned ('$selfType')." }
    }
    $selfName = if ($self -and $self.PSObject.Properties['Name']) { [string]$self.Name } else { 'the project being rebuilt' }
    $selfReason = if ($self -and $self.PSObject.Properties['AnchorReason']) { [string]$self.AnchorReason } else { '' }
    $selfHow = if ($selfReason -eq 'published') { 'published' } else { 'pinned' }

    # ---- 1. explicit pin ----
    $requested = ([string]$InstallerType).Trim().ToLowerInvariant()
    if ($requested) {
        $result.InstallerType = $requested
        $result.Family        = [string](Get-Win32ToolkitInstallerFamily -Type $requested).Family
        $result.PinnedBy      = 'parameter'
        $result.Reason        = 'requested'
        if ($self -and $result.Family -and $selfRow.Family -and $result.Family -ne [string]$selfRow.Family) {
            Write-Warning ("Rebuilding $selfName, which is $selfHow as $($selfRow.EffectiveType) ($($selfRow.Family)), with -InstallerType $requested ($($result.Family)): " +
                'devices that already have it get a second registration over one folder.')
        }
        return $result
    }

    # ---- 2. the version being rebuilt keeps its own technology ----
    if ($self) {
        $ownPin = if ($self.PSObject.Properties['PinnedBy']) { ([string]$self.PinnedBy).Trim().ToLowerInvariant() } else { '' }
        if ($ownPin -notin @('parameter', 'operator') -and $selfReason -match '^pinned:(parameter|operator)$') { $ownPin = $Matches[1] }
        $result.InstallerType = [string]$selfRow.PinValue
        $result.Family        = [string](Get-Win32ToolkitInstallerFamily -Type $selfRow.PinValue).Family
        $result.PinnedBy      = if ($ownPin -in @('parameter', 'operator')) { $ownPin } else { 'continuity' }
        $result.Predecessor   = $self
        $result.Reason        = "kept from $selfName ($selfHow, rebuilt)"
        return $result
    }

    # ---- 3. continuity from a published or pinned earlier version (winget id only, L1) ----
    if ([string]::IsNullOrWhiteSpace($WingetId)) {
        Write-Verbose 'Resolve-Win32ToolkitInstallerPin: no winget id; winget chooses.'
        return $result
    }
    $ver = ([string]$Version).Trim()
    if (-not $ver -or $ver -notmatch '^[vV]?\d+(\.\d+)*') {
        Write-Warning 'Installer-technology continuity was not checked before the download: the version is unknown. The identity checks after the download still compare it with earlier versions.'
        return $result
    }

    try {
        $lookup = Get-Win32ToolkitPreviousProject -TemplateDirectory $TemplateDirectory -WingetId $WingetId -Version $ver -ExcludePath $ExcludePath -TenantId $TenantId
        $anchor = if ($lookup) { $lookup.Anchor } else { $null }
        if ($anchor) {
            $result.Predecessor = $anchor
            $row = Get-Win32ToolkitInstallerFamily -Type ([string]$anchor.InstallerType)
            if ($row.PinValue) {
                $how = if ([string]$anchor.AnchorReason -eq 'published') { 'published' } else { 'pinned' }
                $result.InstallerType = [string]$row.PinValue
                $result.Family        = [string](Get-Win32ToolkitInstallerFamily -Type $row.PinValue).Family
                $result.PinnedBy      = 'continuity'
                $result.Reason        = "kept from $($anchor.Name) ($how)"
            } else {
                Write-Verbose "Resolve-Win32ToolkitInstallerPin: '$($anchor.Name)' has no installer type that can be pinned ('$($anchor.InstallerType)'); winget chooses."
            }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning "Installer-technology continuity could not be checked ($($_.Exception.Message)); winget chooses the installer."
        $result.InstallerType = ''; $result.Family = ''; $result.PinnedBy = 'winget-default'
        $result.Predecessor = $null; $result.Reason = "winget's choice"
    }
    return $result
}
