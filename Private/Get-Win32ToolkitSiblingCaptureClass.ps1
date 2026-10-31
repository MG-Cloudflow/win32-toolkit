function Get-Win32ToolkitSiblingCaptureClass {
    <#
    .SYNOPSIS
        Classifies one installer technology winget ships for an app: can its install be captured, and removed?
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.2 rule 2; SV21, SV29, Dv2). The one classification of a sibling tuple of the
        sibling probe (Get-Win32ToolkitSiblingInstaller), used by the capture plan (Get-Win32ToolkitSiblingCapturePlan)
        and by the winget wizard's capture question, so the two always agree:

            nullsoft, inno                    RemovableNow
            exe                               RemovableNow (Block-only unless the binary shows NSIS or Inno Setup)
            msi, wix                          ReportOnly   (removal of an MSI sibling ships in PR 3c)
            burn, msix, msstore, appx, ...    ReportOnly   (PR 7)
            arm64, not registering (portable, pwa), zip-wrapped
                                              NotCapturable (with the reason)

        Type is the registration type (msi and wix are one registration type; a wix tuple keeps the name wix), Key the
        de-duplication key of the plan. Pure.
    .PARAMETER Sibling
        One probe tuple: EffectiveType, InstallerType, Registers, ZipWrapped, Architecture.
    .OUTPUTS
        [pscustomobject] Type, EffectiveType, Class (RemovableNow | ReportOnly | NotCapturable), Reason, Key.
    .EXAMPLE
        @($probe.Siblings) | ForEach-Object { Get-Win32ToolkitSiblingCaptureClass -Sibling $_ } | Where-Object Class -eq 'RemovableNow'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Sibling
    )

    if ($null -eq $Sibling) { return $null }
    $regType = { param([string]$t) if ($t -in @('msi', 'wix')) { 'msi' } else { $t } }
    $eff = ([string]$Sibling.EffectiveType).ToLowerInvariant()
    $key = if ($Sibling.ZipWrapped -or -not $Sibling.Registers) { "nc|$($Sibling.InstallerType)|$eff" } else { & $regType $eff }
    $class = ''; $reason = ''
    if ([string]$Sibling.Architecture -eq 'arm64') { $class = 'NotCapturable'; $reason = 'an ARM64 installer cannot be installed on the x64 test VM' }
    elseif (-not $Sibling.Registers -or $eff -in @('portable', 'pwa')) { $class = 'NotCapturable'; $reason = "a $eff package registers no uninstall entry (nothing to remove)" }
    elseif ($Sibling.ZipWrapped) { $class = 'NotCapturable'; $reason = "zip-wrapped installer ($eff inside a zip); extraction is not supported yet" }
    elseif ($eff -in @('nullsoft', 'inno')) { $class = 'RemovableNow' }
    elseif ($eff -eq 'exe') { $class = 'RemovableNow'; $reason = 'a generic EXE gives Block-only rules unless its uninstaller shows NSIS or Inno Setup' }
    # Operator text: no internal plan id (live rows OP-OWN, SB-REGRESSION printed '(PR 3c)' inside another pair of brackets).
    elseif ($eff -in @('msi', 'wix')) { $class = 'ReportOnly'; $reason = 'removing an MSI sibling comes in a later win32-toolkit version' }
    else { $class = 'ReportOnly'; $reason = "removing a $eff sibling comes in a later win32-toolkit version" }
    $typeName = if ($class -eq 'NotCapturable') { $eff } else { & $regType $eff }
    if ($typeName -eq 'msi' -and $eff -eq 'wix') { $typeName = 'wix' }
    return [pscustomobject]@{ Type = $typeName; EffectiveType = $eff; Class = $class; Reason = $reason; Key = $key }
}
