function Write-Win32ToolkitOwnIdentity {
    <#
    .SYNOPSIS
        Records the package's own uninstall identity (AppConfig.OwnIdentity) from its install capture.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.2, L1, Dv1). The remove-prior device blocks and the host validator must
        never treat the package's own uninstall entry as a "prior install": they compare every prior-install key
        with the package's own identity. That identity is recorded here, for EVERY installer type, in a new
        top-level AppConfig section (not under Uninstall: an MSI project has no Uninstall section, and writing one
        would make the device's Uninstall block run with nothing to do and throw):

            OwnIdentity = { SchemaVersion '1.0'; ProductCode; UpgradeCode; ArpKeys = @({ Key; View }); CapturedOn }

          - ProductCode / UpgradeCode: the MSI Property table of the packaged installer
            (Get-Win32ToolkitProjectSource -Rebuild; '' for every other installer type);
          - ArpKeys: every NEW key of the capture directly under HKLM\SOFTWARE\[WOW6432Node\]Microsoft\Windows\
            CurrentVersion\Uninstall whose name is a plain key name, co-installed ones included; View 'Wow6432'
            under WOW6432Node, else 'Native'; sorted, unique, at most 64;
          - CapturedOn: the capture's own date (its Timestamp), else today, so a re-run with the same capture
            writes the same bytes.

        The install tattoo (HKLM\SOFTWARE\<Author>\<Vendor>\<Name>) is not an uninstall key and is never recorded.
        Read-modify-write of AppConfig.json; every other section is kept. Fail-open (C-7): any problem gives one
        warning and $false, and AppConfig.json is left as it was (every prior-install rule is then refused at
        Export: PRIOR-NO-OWNIDENTITY). A W32T.* error from a helper is re-thrown.
    .PARAMETER ProjectPath
        The PSADT project folder.
    .PARAMETER Capture
        The parsed install capture (InstallationChanges_*.json).
    .OUTPUTS
        [bool] $true when OwnIdentity was written (or already held the same values).
    .EXAMPLE
        $null = Write-Win32ToolkitOwnIdentity -ProjectPath $projectPath -Capture $parsed
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Capture
    )

    try {
        if ($null -eq $Capture) { throw 'the install capture could not be read' }
        $guid = '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$'
        $uninstallKey = '^(HKEY_LOCAL_MACHINE|HKLM)\\SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Uninstall\\([^\\]+)$'
        $keyNameRule = '^[^\\/:*?"<>|\p{Cc}\p{Cf}\p{Zl}\p{Zp}]{1,255}\z'

        $source = Get-Win32ToolkitProjectSource -ProjectPath $ProjectPath -Rebuild
        $productCode = if ([string]$source.ProductCode -match $guid) { [string]$source.ProductCode } else { '' }
        $upgradeCode = if ([string]$source.UpgradeCode -match $guid) { [string]$source.UpgradeCode } else { '' }

        $seen = @{}
        $keys = [System.Collections.Generic.List[object]]::new()
        $newKeys = @()
        if ($Capture.PSObject.Properties['NewRegistryKeys']) { $newKeys = @($Capture.NewRegistryKeys | Where-Object { $_ }) }
        foreach ($k in $newKeys) {
            $path = if ($k.PSObject.Properties['Path']) { [string]$k.Path } else { '' }
            $m = [regex]::Match($path, $uninstallKey, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $m.Success) { continue }
            $leaf = $m.Groups[3].Value
            if ($leaf -notmatch $keyNameRule -or $leaf -eq '.' -or $leaf -eq '..') {
                Write-Verbose ('Own identity: the uninstall key name ' + (ConvertTo-Win32ToolkitSafeText -Text $leaf -MaxLength 80) + ' is not a plain key name; not recorded.')
                continue
            }
            $view = if ($m.Groups[2].Success -and $m.Groups[2].Value) { 'Wow6432' } else { 'Native' }
            $id = "$view|$($leaf.ToUpperInvariant())"
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $keys.Add([pscustomobject]@{ Key = $leaf; View = $view })
        }
        # Ordinal order (no culture): View, then the key name upper-cased.
        $order = [string[]]@(for ($i = 0; $i -lt $keys.Count; $i++) { '{0}|{1}|{2:D4}' -f $keys[$i].View, $keys[$i].Key.ToUpperInvariant(), $i })
        [Array]::Sort($order, [System.StringComparer]::Ordinal)
        $sorted = @($order | Select-Object -First 64 | ForEach-Object { $keys[[int]($_.Substring($_.LastIndexOf('|') + 1))] })

        # The capture's own date keeps a re-run byte-identical.
        $capturedOn = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        foreach ($section in 'InstallationInfo', 'DocumentationInfo') {
            if ($Capture.PSObject.Properties[$section] -and $Capture.$section -and $Capture.$section.PSObject.Properties['Timestamp']) {
                $ts = [string]$Capture.$section.Timestamp
                if ($ts -match '^(\d{4})(\d{2})(\d{2})_\d{6}$') { $capturedOn = '{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3]; break }
            }
        }

        $own = [pscustomobject][ordered]@{
            SchemaVersion = '1.0'
            ProductCode   = $productCode
            UpgradeCode   = $upgradeCode
            ArpKeys       = @($sorted | ForEach-Object { [pscustomobject][ordered]@{ Key = $_.Key; View = $_.View } })
            CapturedOn    = $capturedOn
        }
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $cfg | Add-Member -NotePropertyName OwnIdentity -NotePropertyValue $own -Force
        $null = Set-Win32ToolkitAppConfig -ProjectPath $ProjectPath -Config $cfg

        $pcShown = if ($productCode) { $productCode } else { 'none' }
        Write-Host ("$([char]0x2713) Own identity recorded: $($own.ArpKeys.Count) uninstall key(s), product code $pcShown") -ForegroundColor Green
        return $true
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning ('The package''s own uninstall identity was not recorded (' + (ConvertTo-Win32ToolkitSafeText -Text $_.Exception.Message -MaxLength 200) + '): prior-install rules for this project are refused until the install capture runs again.')
        return $false
    }
}
