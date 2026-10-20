function Get-Win32ToolkitTechnologySwitch {
    <#
    .SYNOPSIS
        Finds Update tests whose old installer of ANOTHER technology was still registered after the update (ID-TECH-SWITCH).
    .DESCRIPTION
        Installer-identity PR 1, spec 2.12 (V42, L5, L21). Reads Documentation\TestResults.json and judges the
        latest Update record of every baseline family (Baseline.Family). A finding is returned when that record
        has OldArpGone-PostUpdate = FAIL, its baseline family is known (not 'other' or empty) and differs from
        the package's family: the vendor install of the old version (e.g. an NSIS EXE) survived the package of
        another technology (e.g. a WiX MSI), so devices that have it get two registrations over one folder.

        Records marked Baseline.Unavailable (the baseline technology could not be downloaded, L21) are never
        judged and never hide an older record of their family.

        A record written before PR 1 (no Baseline) is judged only when all of these hold (L5):
          1. it is the newest Update record (Unavailable records aside);
          2. it has no TattooBaseline-PreUpdate assertion (that one is written only for a project baseline,
             which never refreshes Sandbox\OldVersion\);
          3. the installer manifest in Sandbox\OldVersion\ has a PackageVersion equal to the
             $expectedOldVersion line of the generated Sandbox\UpdateAssertions.ps1 (read as data, never run).
        Its baseline type then comes from that manifest (zip -> the nested type), its survivors from the last
        OldArpGone-PostUpdate line of Sandbox\Logs\UpdateAssertions.log, and Legacy = $true.

        Never throws: unreadable files give no finding (Write-Verbose). Every string from a record, a manifest
        or the log passes ConvertTo-Win32ToolkitSafeText; messages are ASCII templates.
    .PARAMETER ProjectPath
        The project whose Update tests are judged.
    .PARAMETER PackageType
        The packaged installer type (default: Get-Win32ToolkitProjectSource).
    .PARAMETER PackageFamily
        The packaged installer family (default: from the source, else from the type).
    .OUTPUTS
        [pscustomobject[]] Code ('ID-TECH-SWITCH'), PackageType, PackageFamily, BaselineType, BaselineFamily,
        BaselineVersion, Survivors, TimestampUtc, Legacy, Message. Nothing when there is no switch.
    .EXAMPLE
        foreach ($s in @(Get-Win32ToolkitTechnologySwitch -ProjectPath $p)) { Write-Warning $s.Message }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowEmptyString()]
        [string]$PackageType = '',

        [AllowEmptyString()]
        [string]$PackageFamily = ''
    )

    $prop  = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $null } }
    $safe  = { param($Value, [int]$Max = 128) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $lower = { param($Value) ([string]$Value).Trim().ToLowerInvariant() }
    $iso   = { param($Value) if ($Value -is [datetime]) { $Value.ToUniversalTime().ToString('o') } else { [string]$Value } }
    $unquote = {
        param([string]$Value)
        $v = ([string]$Value).Trim()
        if ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) { return $v.Substring(1, $v.Length - 2).Replace("''", "'") }
        if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { return $v.Substring(1, $v.Length - 2) }
        return $v
    }
    $familyLabels = @{ msi = 'MSI'; exe = 'vendor EXE'; msix = 'MSIX package'; portable = 'portable' }
    $failed = {
        param($Record)
        @(@(& $prop $Record 'Assertions') | Where-Object {
                $_ -and [string](& $prop $_ 'Name') -eq 'OldArpGone-PostUpdate' -and [string](& $prop $_ 'Result') -eq 'FAIL'
            }).Count -gt 0
    }

    # ---- The package's technology ----
    if (-not $PackageType -or -not $PackageFamily) {
        $src = Get-Win32ToolkitProjectSource -ProjectPath $ProjectPath
        if (-not $PackageType) { $PackageType = [string](& $prop $src 'InstallerType') }
        if (-not $PackageFamily) { $PackageFamily = [string](& $prop $src 'Family') }
    }
    $PackageType = & $lower $PackageType
    $PackageFamily = & $lower $PackageFamily
    if (-not $PackageFamily -and $PackageType) { $PackageFamily = [string](Get-Win32ToolkitInstallerFamily -Type $PackageType).Family }
    if (-not $PackageFamily -or $PackageFamily -eq 'other') {
        Write-Verbose 'Get-Win32ToolkitTechnologySwitch: the package technology is unknown; nothing to compare.'
        return
    }

    # ---- Update records, oldest first (Add-Win32ToolkitTestResult appends newest-last) ----
    $records = @(Get-Win32ToolkitTestResult -ProjectPath $ProjectPath -WarningAction SilentlyContinue | ForEach-Object { $_ } |
            Where-Object { $_ -and [string](& $prop $_ 'Scenario') -eq 'Update' })
    $judged = @($records | Where-Object { -not ((& $prop (& $prop $_ 'Baseline') 'Unavailable') -eq $true) })
    if ($judged.Count -eq 0) { return }

    # Latest judged record per baseline family.
    $latest = [ordered]@{}
    foreach ($r in $judged) {
        $b = & $prop $r 'Baseline'
        if ($null -eq $b) { continue }
        $fam = & $lower (& $prop $b 'Family')
        $latest[$fam] = [pscustomobject]@{
            Record          = $r
            BaselineType    = & $lower (& $prop $b 'InstallerType')
            BaselineFamily  = $fam
            BaselineVersion = [string](& $prop $b 'Version')
            Survivors       = @(@(& $prop $r 'OldArpSurvivors') | Where-Object { $_ })
            Legacy          = $false
        }
    }

    # A record from before PR 1 (no Baseline): only the newest one, and only when it provably used the vendor
    # baseline that is still in Sandbox\OldVersion\ (L5).
    $newest = $judged[-1]
    if ($null -eq (& $prop $newest 'Baseline')) {
        $legacy = $null
        $hasProjectBaseline = @(@(& $prop $newest 'Assertions') | Where-Object { $_ -and [string](& $prop $_ 'Name') -eq 'TattooBaseline-PreUpdate' }).Count -gt 0
        if ($hasProjectBaseline) {
            Write-Verbose 'Get-Win32ToolkitTechnologySwitch: the newest Update record used a project baseline; not judged.'
        } else {
            try {
                $expected = $null
                $assertScript = Join-Path $ProjectPath 'Sandbox\UpdateAssertions.ps1'
                if (Test-Path -LiteralPath $assertScript) {
                    $text = Get-Content -LiteralPath $assertScript -Raw -Encoding UTF8
                    $m = [regex]::Match([string]$text, "(?m)^\`$expectedOldVersion = '((?:[^']|'')*)'")
                    if ($m.Success) { $expected = $m.Groups[1].Value.Replace("''", "'") }
                }
                $manifest = Get-WingetManifestFile -Path (Join-Path $ProjectPath 'Sandbox\OldVersion') -Kind Installer
                if ($expected -and $manifest) {
                    $yaml = [string](Get-Content -LiteralPath $manifest.FullName -Raw -Encoding UTF8)
                    $ver = if ($yaml -match '(?m)^\s*PackageVersion:\s*(.+?)\s*$') { & $unquote $Matches[1] } else { '' }
                    if ($ver -and [string]::Equals($ver, $expected.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                        $type   = if ($yaml -match '(?m)^\s*-?\s*InstallerType:\s*(\S+)') { & $lower (& $unquote $Matches[1]) } else { '' }
                        $nested = if ($yaml -match '(?m)^\s*-?\s*NestedInstallerType:\s*(\S+)') { & $lower (& $unquote $Matches[1]) } else { '' }
                        $row = Get-Win32ToolkitInstallerFamily -Type $type -NestedType $nested
                        $survivors = @()
                        $log = Join-Path $ProjectPath 'Sandbox\Logs\UpdateAssertions.log'
                        if (Test-Path -LiteralPath $log) {
                            $last = @(Get-Content -LiteralPath $log -Encoding UTF8 | Where-Object { $_ -match 'ASSERT\s+OldArpGone-PostUpdate\s*=' }) | Select-Object -Last 1
                            if ($last) { $survivors = @(ConvertFrom-Win32ToolkitArpSurvivor -Line $last) }
                        }
                        $legacy = [pscustomobject]@{
                            Record          = $newest
                            BaselineType    = [string]$row.EffectiveType
                            BaselineFamily  = [string]$row.Family
                            BaselineVersion = $ver
                            Survivors       = $survivors
                            Legacy          = $true
                        }
                    } else {
                        Write-Verbose 'Get-Win32ToolkitTechnologySwitch: Sandbox\OldVersion does not hold the baseline of the newest Update record.'
                    }
                } else {
                    Write-Verbose 'Get-Win32ToolkitTechnologySwitch: no old-version manifest or expected old version for the newest Update record.'
                }
            } catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Get-Win32ToolkitTechnologySwitch: the legacy Update record could not be read: $($_.Exception.Message)"
                $legacy = $null
            }
        }
        if ($legacy) { $latest[$legacy.BaselineFamily] = $legacy }
    }

    foreach ($c in $latest.Values) {
        if (-not (& $failed $c.Record)) { continue }
        if (-not $c.BaselineFamily -or $c.BaselineFamily -eq 'other' -or $c.BaselineFamily -eq $PackageFamily) { continue }

        $first = @($c.Survivors) | Select-Object -First 1
        $who = if ($first) {
            " ({0}, ARP key '{1}')" -f (& $safe (& $prop $first 'DisplayName') 256), (& $safe (& $prop $first 'KeyLeaf') 256)
        } else { '' }
        $famLabel = if ($familyLabels.ContainsKey($c.BaselineFamily)) { $familyLabels[$c.BaselineFamily] } else { & $safe $c.BaselineFamily 32 }
        $msg = ('Technology switch: the vendor {0} install of v{1}{2} was still registered after the {3} package installed. ' +
                'Devices that have the {4} install get two registrations over one folder. Do not publish this package to them; ' +
                'see docs/packaging.md, Installer technology.') -f (& $safe $c.BaselineType 32), (& $safe $c.BaselineVersion), $who,
               (& $safe $PackageType 32), $famLabel

        [pscustomobject]@{
            Code            = 'ID-TECH-SWITCH'
            PackageType     = & $safe $PackageType 32
            PackageFamily   = & $safe $PackageFamily 32
            BaselineType    = & $safe $c.BaselineType 32
            BaselineFamily  = & $safe $c.BaselineFamily 32
            BaselineVersion = & $safe $c.BaselineVersion
            Survivors       = @($c.Survivors)
            TimestampUtc    = & $iso (& $prop $c.Record 'TimestampUtc')
            Legacy          = [bool]$c.Legacy
            Message         = $msg
        }
    }
}
