function Get-Win32ToolkitPsadtGalleryVersion {
    <#
    .SYNOPSIS
        Lists the PSAppDeployToolkit versions the menu may install from PowerShell Gallery (never throws).
    .DESCRIPTION
        Menu selectors design section 3.4, P1, P4, P8 (knowledge-base/designs/menu-selectors.md). One Find-Module -AllVersions
        on PSGallery, without -AllowPrerelease (stable versions only, as Create-PSADTProject), then:
          * inside the supported range (Test-Win32ToolkitPsadtVersionSupported) and a plain stable version text;
          * not installed (no candidate with the same VersionText);
          * Kind 'Replace' when an installed PRERELEASE has the same version number: PowerShellGet installs a prerelease
            into its base-version folder, so installing that version replaces the prerelease (Replaces names it);
            otherwise Kind 'Install'.
        Newest first. A failing Find-Module gives no versions and a sanitized Problem text (the list and the choices of
        the screen keep working offline). Nothing is installed or written.
    .PARAMETER Candidates
        The Candidates of a Select-Win32ToolkitPsadtModule result (VersionText, IsPrerelease).
    .OUTPUTS
        [pscustomobject] Versions ([pscustomobject[]] Version, VersionText, Kind, Replaces) and Problem ($null or text).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Candidates
    )

    $installed = @(@($Candidates) | Where-Object { $null -ne $_ })
    $found = $null
    try {
        $found = @(Find-Module -Name PSAppDeployToolkit -Repository PSGallery -AllVersions -ErrorAction Stop)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        return [pscustomobject]@{
            Versions = @()
            Problem  = "Could not reach PowerShell Gallery: $(ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200)"
        }
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $found) {
        if ($null -eq $m) { continue }
        $text = ([string]$m.Version).Trim()
        # Stable only, and a plain version text (it becomes -RequiredVersion later).
        if ($text -notmatch '^\d{1,9}\.\d{1,9}\.\d{1,9}(\.\d{1,9})?$') { continue }
        $ver = [version]$text
        if (-not (Test-Win32ToolkitPsadtVersionSupported -Version $ver)) { continue }
        if (-not $seen.Add($text)) { continue }
        if (@($installed | Where-Object { [string]::Equals([string]$_.VersionText, $text, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
        $pre = @($installed | Where-Object {
                $_.IsPrerelease -and ([string]$_.VersionText -replace '[-+].*$', '') -eq $text
            }) | Select-Object -First 1
        $rows.Add([pscustomobject]@{
            Version     = $ver
            VersionText = $text
            Kind        = $(if ($pre) { 'Replace' } else { 'Install' })
            Replaces    = $(if ($pre) { [string]$pre.VersionText } else { '' })
        })
    }

    [pscustomobject]@{
        Versions = @($rows | Sort-Object -Property Version -Descending)
        Problem  = $null
    }
}
