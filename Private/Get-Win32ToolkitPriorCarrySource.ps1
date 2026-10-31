function Get-Win32ToolkitPriorCarrySource {
    <#
    .SYNOPSIS
        Finds the project whose prior-install rules a new version of an app carries forward.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.13 step 2, L5, Dv6). The source is, among the earlier versions of the same app in
        the same template folder (Get-Win32ToolkitPreviousProject Matches: the same winget id, else the same Vendor and
        DisplayName; anchored or not), the HIGHEST lower-version project with the SAME architecture as the new one
        (AppConfig.Source.Architecture, else the '_<arch>_' segment of the project folder name, else App.Arch; an x86 or
        arm64 project of the same app is never the source of an x64 one) whose AppConfig HAS a PriorInstalls property.
        A project without the property is skipped; one with an empty Entries list IS the source (its rules were removed
        on purpose and stay removed). Copy-Win32ToolkitPriorInstallState carries from it, and the Export gate compares
        with exactly this project (ID-PRIOR-DROPPED, ID-PRIOR-OWN).
        Never throws (C-7): an unreadable project is skipped (Write-Verbose); a W32T.* error is re-thrown.
    .PARAMETER ProjectPath
        The new project (its parent folder is the template folder).
    .OUTPUTS
        [pscustomobject] Path, Name, Version, Architecture, Entries (the source's PriorInstalls entries), or $null.
    .EXAMPLE
        $source = Get-Win32ToolkitPriorCarrySource -ProjectPath $projectFullPath
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath
    )

    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { $Object.$Name } else { $null } }
    $archOf = {
        param([string]$Path, $Config)
        $a = [string](& $prop (& $prop $Config 'Source') 'Architecture')
        if (-not $a -and (Split-Path -Path $Path -Leaf) -match '_(x64|x86|arm64)_') { $a = $Matches[1] }
        if (-not $a) { $a = [string](& $prop (& $prop $Config 'App') 'Arch') }
        $a.Trim().ToLowerInvariant()
    }
    try {
        $path = $ProjectPath.TrimEnd('\')
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $path
        $app = & $prop $cfg 'App'
        $version = [string](& $prop $app 'Version')
        $arch = & $archOf $path $cfg
        if (-not $version -or -not $arch) { Write-Verbose 'Get-Win32ToolkitPriorCarrySource: the new project has no version or architecture.'; return $null }
        $wingetId = [string](& $prop (& $prop $cfg 'Source') 'WingetId')
        if (-not $wingetId) { $wingetId = [string](Get-WingetIdFromProject -FilesPath (Join-Path $path 'Files')) }
        $display = [string](& $prop $app 'DisplayName')
        if (-not $display) { $display = [string](& $prop $app 'Name') }
        $prev = Get-Win32ToolkitPreviousProject -TemplateDirectory (Split-Path -Path $path -Parent) -Version $version -WingetId $wingetId -Vendor ([string](& $prop $app 'Vendor')) -DisplayName $display -ExcludePath $path
        foreach ($m in @($prev.Matches)) {
            try {
                $mCfg = Get-Win32ToolkitAppConfig -ProjectPath $m.Path
                if ((& $archOf $m.Path $mCfg) -cne $arch) { Write-Verbose "Get-Win32ToolkitPriorCarrySource: '$($m.Name)' is another architecture - skipped."; continue }
                if ($null -eq $mCfg.PSObject.Properties['PriorInstalls']) { continue }
                return [pscustomobject]@{
                    Path         = $m.Path
                    Name         = $m.Name
                    Version      = $m.Version
                    Architecture = $arch
                    Entries      = @(@(& $prop $mCfg.PriorInstalls 'Entries') | Where-Object { $null -ne $_ })
                }
            }
            catch {
                if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
                Write-Verbose "Get-Win32ToolkitPriorCarrySource: '$($m.Name)' skipped: $($_.Exception.Message)"
            }
        }
        return $null
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Get-Win32ToolkitPriorCarrySource: no source ($($_.Exception.Message))."
        return $null
    }
}
