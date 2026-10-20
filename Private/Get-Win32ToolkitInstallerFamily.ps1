function Get-Win32ToolkitInstallerFamily {
    <#
    .SYNOPSIS
        The installer-technology family table: which winget installer types register the same way.
    .DESCRIPTION
        One table for every identity check (installer-identity PR 1, spec 2.1). A family groups the winget
        InstallerType values that register the same kind of uninstall entry:

          Type       Family    Precedence  Registers  Downloadable  Packageable  Label
          msstore    msix      1           yes        no            no           msstore (Microsoft Store)
          msix       msix      2           yes        yes           yes          msix (MSIX package)
          appx       msix      3           yes        yes           yes          appx (APPX package)
          msi        msi       4           yes        yes           yes          msi (MSI)
          wix        msi       5           yes        yes           yes          wix (MSI)
          burn       exe       6           yes        yes           yes          burn (EXE bundle)
          nullsoft   exe       7           yes        yes           yes          nullsoft (vendor EXE, NSIS)
          inno       exe       8           yes        yes           yes          inno (vendor EXE, Inno Setup)
          exe        exe       9           yes        yes           yes          exe (vendor EXE)
          portable   portable  10          no         yes           no           portable (no installer)
          zip + X    X's       X's         X's        X's           no           <X label>, zip-wrapped
          other      other     99          no         no            no           <type>

        Precedence follows winget's default installer-type order (winget 1.29.280 and later); appx is not in
        winget's list and is placed after msix.

        Type set: one row for -Type (and, for a zip, -NestedType). Testable = Registers and Downloadable and
        not ZipWrapped (the type can be packaged and used as an Update baseline). PinValue = the value to pass
        to -InstallerType / -BaselineInstallerType (ValidateSet msi, wix, burn, nullsoft, inno, exe, msix):
        the type itself when it is in that set, 'msix' for appx, '' otherwise.
        Family set: the types of a family in precedence order (-DownloadableOnly drops msstore).
        PinOrder set: the type first, then the other downloadable and packageable types of its family in
        precedence order (pin the family, not the type: Edge relabelled wix -> msi between two versions).

        Pure and total: input is lower-cased, an unknown or empty type is family 'other', nothing throws.
    .PARAMETER Type
        A winget InstallerType (msi, wix, nullsoft, zip, ...).
    .PARAMETER NestedType
        The NestedInstallerType of a zip (the effective type inside the archive).
    .PARAMETER Family
        A family name (msix, msi, exe, portable).
    .PARAMETER DownloadableOnly
        With -Family: only the types winget can download (drops msstore).
    .PARAMETER PinOrder
        The pinned type whose family order is wanted.
    .OUTPUTS
        Type set: [pscustomobject] Type, NestedType, EffectiveType, Family, Precedence, Registers, Downloadable,
        Packageable, ZipWrapped, Testable, PinValue, Label. Family and PinOrder sets: [string[]].
    .EXAMPLE
        (Get-Win32ToolkitInstallerFamily -Type wix).Family          # msi
        Get-Win32ToolkitInstallerFamily -PinOrder nullsoft          # nullsoft, burn, inno, exe
    #>
    [CmdletBinding(DefaultParameterSetName = 'Type')]
    [OutputType([pscustomobject], ParameterSetName = 'Type')]
    [OutputType([string[]], ParameterSetName = ('Family', 'PinOrder'))]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Type', Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Type,

        [Parameter(ParameterSetName = 'Type')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$NestedType,

        [Parameter(Mandatory, ParameterSetName = 'Family')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Family,

        [Parameter(ParameterSetName = 'Family')]
        [switch]$DownloadableOnly,

        [Parameter(Mandatory, ParameterSetName = 'PinOrder')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PinOrder
    )

    # Type -> Family, Precedence, Registers, Downloadable, Packageable, Label (order = precedence).
    $table = [ordered]@{
        msstore  = @('msix', 1, $true, $false, $false, 'msstore (Microsoft Store)')
        msix     = @('msix', 2, $true, $true, $true, 'msix (MSIX package)')
        appx     = @('msix', 3, $true, $true, $true, 'appx (APPX package)')
        msi      = @('msi', 4, $true, $true, $true, 'msi (MSI)')
        wix      = @('msi', 5, $true, $true, $true, 'wix (MSI)')
        burn     = @('exe', 6, $true, $true, $true, 'burn (EXE bundle)')
        nullsoft = @('exe', 7, $true, $true, $true, 'nullsoft (vendor EXE, NSIS)')
        inno     = @('exe', 8, $true, $true, $true, 'inno (vendor EXE, Inno Setup)')
        exe      = @('exe', 9, $true, $true, $true, 'exe (vendor EXE)')
        portable = @('portable', 10, $false, $true, $false, 'portable (no installer)')
    }
    # The -InstallerType / -BaselineInstallerType ValidateSet.
    $pinnable = @('msi', 'wix', 'burn', 'nullsoft', 'inno', 'exe', 'msix')

    $norm = { param([string]$Value) if ($null -eq $Value) { '' } else { $Value.Trim().ToLowerInvariant() } }

    switch ($PSCmdlet.ParameterSetName) {
        'Family' {
            $f = & $norm $Family
            return @($table.Keys | Where-Object {
                    $table[$_][0] -eq $f -and (-not $DownloadableOnly -or $table[$_][3])
                })
        }
        'PinOrder' {
            $t = & $norm $PinOrder
            if (-not $table.Contains($t) -or -not $table[$t][3] -or -not $table[$t][4]) { return @() }
            $fam = $table[$t][0]
            $rest = @($table.Keys | Where-Object { $_ -ne $t -and $table[$_][0] -eq $fam -and $table[$_][3] -and $table[$_][4] })
            return @(@($t) + $rest)
        }
        default {
            $t = & $norm $Type
            $n = & $norm $NestedType
            $zip = ($t -eq 'zip')
            $effective = if ($zip) { if ($n) { $n } else { 'zip' } } else { $t }

            if ($table.Contains($effective)) {
                $row = $table[$effective]
                $familyName = $row[0]; $precedence = $row[1]; $registers = $row[2]
                $downloadable = $row[3]; $packageable = $row[4]; $label = $row[5]
            } else {
                $familyName = 'other'; $precedence = 99; $registers = $false
                $downloadable = $false; $packageable = $false; $label = $effective
            }
            if ($zip) {
                # The toolkit cannot package a zip; the archive registers what its nested installer registers.
                $packageable = $false
                $label = if ($n) { "$label, zip-wrapped" } else { 'zip' }
            }

            $testable = $registers -and $downloadable -and -not $zip
            $pinValue = if ($zip) { '' }
                        elseif ($effective -in $pinnable) { $effective }
                        elseif ($effective -eq 'appx') { 'msix' }
                        else { '' }

            return [pscustomobject]@{
                Type          = $t
                NestedType    = $n
                EffectiveType = $effective
                Family        = $familyName
                Precedence    = $precedence
                Registers     = [bool]$registers
                Downloadable  = [bool]$downloadable
                Packageable   = [bool]$packageable
                ZipWrapped    = [bool]$zip
                Testable      = [bool]$testable
                PinValue      = $pinValue
                Label         = $label
            }
        }
    }
}
