function Get-Win32ToolkitMsiProperty {
    <#
    .SYNOPSIS
        Reads a single property from an MSI's Property table (host-side, via the WindowsInstaller COM API).
    .DESCRIPTION
        Used to recover the version-stable UpgradeCode (and ProductName / ProductCode / ProductVersion) of an
        MSI so the update requirement rule can gate on "any version of this MSI installed" (see
        Get-Win32ToolkitRequirementRule). Returns '' if the file is missing, the property is absent, or the
        COM read fails — callers treat '' as "no value". The COM object is always released.

        The Property name is restricted by ValidateSet, so the interpolated SQL query cannot be influenced by
        untrusted input.
    .PARAMETER Path
        Full path to the .msi file.
    .PARAMETER Property
        Which MSI property to read.
    .EXAMPLE
        Get-Win32ToolkitMsiProperty -Path 'C:\...\App.msi' -Property UpgradeCode
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet('UpgradeCode', 'ProductCode', 'ProductName', 'ProductVersion')]
        [string]$Property
    )

    if (-not (Test-Path -LiteralPath $Path)) { return '' }

    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db   = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$Property'"))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($record) {
            return [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
        }
        return ''
    }
    catch {
        Write-Verbose "Get-Win32ToolkitMsiProperty($Property) failed for '$Path': $($_.Exception.Message)"
        return ''
    }
    finally {
        if ($installer) { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
    }
}
