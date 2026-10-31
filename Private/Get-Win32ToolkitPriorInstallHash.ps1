function Get-Win32ToolkitPriorInstallHash {
    <#
    .SYNOPSIS
        The binding hash of a project's prior-install rules, or the tuple hash of one rule or proposal.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.3, L12, SV2, SV5, SV6).

        Binding (Proof.PriorInstallsHash): SHA-256 of a canonical JSON of everything the device reads to decide a
        removal - every PriorInstalls entry (sorted by Id, ordinal; Id, Kind, Mode, Key, View, Publisher,
        DisplayName, DisplayNameTemplate, VersionMin, VersionMax, UninstallerType, UninstallerFileName,
        UninstallerSigner, InstallDir, MainExe, ProcessNames sorted), the own identity (OwnIdentity codes and keys,
        Uninstall.ProductCodes and Uninstall.PrimaryKeys), App.Version, App.ScriptAuthor (the marker root),
        Installer.Type and Installer.FileName. Any change there - a mode included - changes it, so every proof is
        re-done. AddedOn, Source, CaptureId and Track are not in it.

        Tuple (an Approval's ProposalHash, lineage equality): the same canonical form over ONE entry or proposal,
        fields Kind, Key, View, Publisher, DisplayName, DisplayNameTemplate, UninstallerType, UninstallerFileName,
        UninstallerSigner, InstallDir, MainExe, ProcessNames - the identity and the removal method, without Id,
        Mode and the version window.

        JSON: ConvertTo-Json -Depth 6 -Compress -EscapeHandling EscapeNonAscii, UTF-8 without BOM; a missing
        string is ''. Pure.
    .PARAMETER Config
        The project's AppConfig object (Binding).
    .PARAMETER Kind
        Binding (default) or Tuple.
    .PARAMETER Entry
        Tuple only: the entry or proposal (a parsed object or a dictionary: a dictionary's keys are its fields, so an
        entry hashes the same whichever form it has).
    .OUTPUTS
        [string] 64 upper-case hex characters.
    .EXAMPLE
        Get-Win32ToolkitPriorInstallHash -Config (Get-Win32ToolkitAppConfig -ProjectPath $p)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Config,

        [ValidateSet('Binding', 'Tuple')]
        [string]$Kind = 'Binding',

        [AllowNull()]
        [object]$Entry
    )

    # A field of a parsed AppConfig object or of a dictionary (a proposal or an entry built in memory), as
    # Test-Win32ToolkitPriorInstallEntry reads it: a dictionary's keys are its fields, never its .NET properties.
    $field = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return , $Object[$Name] } else { return $null } }
        if ($Object.PSObject.Properties[$Name]) { return , $Object.$Name }
        return $null
    }
    $value = {
        param($Object, [string]$Name)
        $v = & $field $Object $Name
        if ($null -ne $v) { return [string]$v }
        return ''
    }
    $list = {
        param($Object, [string]$Name)
        $v = & $field $Object $Name
        if ($null -eq $v) { return @() }
        return @(@($v) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    }
    $sorted = {
        param([string[]]$Items, [switch]$IgnoreCase)
        $a = [string[]]@($Items | Where-Object { $null -ne $_ })
        $cmp = if ($IgnoreCase) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
        [Array]::Sort($a, $cmp)
        return $a
    }
    $tupleOf = {
        param($E)
        [ordered]@{
            Kind                = & $value $E 'Kind'
            Key                 = & $value $E 'Key'
            View                = & $value $E 'View'
            Publisher           = & $value $E 'Publisher'
            DisplayName         = & $value $E 'DisplayName'
            DisplayNameTemplate = & $value $E 'DisplayNameTemplate'
            UninstallerType     = & $value $E 'UninstallerType'
            UninstallerFileName = & $value $E 'UninstallerFileName'
            UninstallerSigner   = & $value $E 'UninstallerSigner'
            InstallDir          = & $value $E 'InstallDir'
            MainExe             = & $value $E 'MainExe'
            ProcessNames        = @(& $sorted (& $list $E 'ProcessNames') -IgnoreCase)
        }
    }

    if ($Kind -eq 'Tuple') {
        if ($null -eq $Entry) { throw [System.ArgumentException]::new('Get-Win32ToolkitPriorInstallHash -Kind Tuple needs -Entry.') }
        $canon = & $tupleOf $Entry
    }
    else {
        $entries = @()
        $pi = if ($null -ne $Config -and $Config.PSObject.Properties['PriorInstalls']) { $Config.PriorInstalls } else { $null }
        if ($null -ne $pi -and $pi.PSObject.Properties['Entries']) { $entries = @(@($pi.Entries) | Where-Object { $null -ne $_ }) }
        $ids = [string[]]@($entries | ForEach-Object { & $value $_ 'Id' })
        $order = [int[]]@(0..([Math]::Max(0, $entries.Count) - 1))
        if ($entries.Count -gt 0) { [Array]::Sort($ids, $order, [System.StringComparer]::Ordinal) } else { $order = @() }
        $canonEntries = @(foreach ($i in $order) {
                $e = $entries[$i]
                [ordered]@{
                    Id                  = & $value $e 'Id'
                    Kind                = & $value $e 'Kind'
                    Mode                = & $value $e 'Mode'
                    Key                 = & $value $e 'Key'
                    View                = & $value $e 'View'
                    Publisher           = & $value $e 'Publisher'
                    DisplayName         = & $value $e 'DisplayName'
                    DisplayNameTemplate = & $value $e 'DisplayNameTemplate'
                    VersionMin          = & $value $e 'VersionMin'
                    VersionMax          = & $value $e 'VersionMax'
                    UninstallerType     = & $value $e 'UninstallerType'
                    UninstallerFileName = & $value $e 'UninstallerFileName'
                    UninstallerSigner   = & $value $e 'UninstallerSigner'
                    InstallDir          = & $value $e 'InstallDir'
                    MainExe             = & $value $e 'MainExe'
                    ProcessNames        = @(& $sorted (& $list $e 'ProcessNames') -IgnoreCase)
                }
            })
        $own = if ($null -ne $Config -and $Config.PSObject.Properties['OwnIdentity']) { $Config.OwnIdentity } else { $null }
        $uninstall = if ($null -ne $Config -and $Config.PSObject.Properties['Uninstall']) { $Config.Uninstall } else { $null }
        $app = if ($null -ne $Config -and $Config.PSObject.Properties['App']) { $Config.App } else { $null }
        $installer = if ($null -ne $Config -and $Config.PSObject.Properties['Installer']) { $Config.Installer } else { $null }
        $arpKeys = @()
        if ($null -ne $own -and $own.PSObject.Properties['ArpKeys']) { $arpKeys = @(@($own.ArpKeys) | Where-Object { $null -ne $_ } | ForEach-Object { (& $value $_ 'View') + '|' + (& $value $_ 'Key') }) }
        $primary = @()
        if ($null -ne $uninstall -and $uninstall.PSObject.Properties['PrimaryKeys']) { $primary = @(@($uninstall.PrimaryKeys) | Where-Object { $null -ne $_ } | ForEach-Object { (& $value $_ 'View') + '|' + (& $value $_ 'Name') }) }
        $canon = [ordered]@{
            SchemaVersion = '1'
            Entries       = $canonEntries
            Own           = [ordered]@{
                ProductCode           = & $value $own 'ProductCode'
                UpgradeCode           = & $value $own 'UpgradeCode'
                ArpKeys               = @(& $sorted $arpKeys)
                UninstallProductCodes = @(& $sorted (& $list $uninstall 'ProductCodes'))
                PrimaryKeys           = @(& $sorted $primary)
            }
            App           = [ordered]@{ Version = & $value $app 'Version'; ScriptAuthor = & $value $app 'ScriptAuthor' }
            Installer     = [ordered]@{ Type = & $value $installer 'Type'; FileName = & $value $installer 'FileName' }
        }
    }

    $json = ConvertTo-Json -InputObject $canon -Depth 6 -Compress -EscapeHandling EscapeNonAscii
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.UTF8Encoding]::new($false).GetBytes($json)) }
    finally { $sha.Dispose() }
    return (-join ($hash | ForEach-Object { $_.ToString('X2') }))
}
