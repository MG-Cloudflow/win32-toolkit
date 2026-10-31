function Get-Win32ToolkitMsiExecutableName {
    <#
    .SYNOPSIS
        The program names (without .exe) in an MSI's File table: the processes PSADT's Zero-Config MSI mode closes.
    .DESCRIPTION
        Installer-identity PR 3 live checks (OP-CONTROL, HOOK-BUILD, GOAL-CAPTURE, 2026-10-26). A PSADT session with an
        empty AppName installs the first MSI in Files (Zero-Config) and, unless DisableDefaultMsiProcessList is set, adds
        the executables of that MSI's File table to AppProcessesToClose before it resolves the Auto deploy mode (PSADT
        4.1.8 logs 'MSI Executable List [notepad++, GUP]'). This reads the same column host-side (WindowsInstaller COM,
        read-only): the long file name of each FileName value ('SHORT~1.EXE|long name.exe' -> 'long name'), every one
        that ends in .exe, without duplicates (case-insensitive), at most 200. Returns nothing when the file is missing
        or cannot be read (Write-Verbose); the COM object is always released.
    .PARAMETER Path
        Full path to the .msi file.
    .OUTPUTS
        [string[]] the program names, in File-table order.
    .EXAMPLE
        @(Get-Win32ToolkitMsiExecutableName -Path 'C:\...\Files\npp.8.9.8.1.Installer.x64.msi')   # notepad++, GUP
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $installer = $null
    $db = $null
    $view = $null
    $names = [System.Collections.Generic.List[string]]::new()
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('SELECT `FileName` FROM `File`'))
        $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        for ($i = 0; $i -lt 100000 -and $names.Count -lt 200; $i++) {
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($null -eq $record) { break }
            $fileName = [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
            $long = if ($fileName.Contains('|')) { $fileName.Substring($fileName.IndexOf('|') + 1) } else { $fileName }
            if ($long -notmatch '\.exe\z') { continue }
            $name = $long.Substring(0, $long.Length - 4)
            if ($name -and @($names | Where-Object { [string]::Equals($_, $name, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { $names.Add($name) }
        }
        $null = $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Verbose "Get-Win32ToolkitMsiExecutableName failed for '$Path': $($_.Exception.Message)"
        return
    }
    finally {
        # Every COM object is released, so the MSI is never left open (the caller may move or delete it).
        foreach ($com in @($view, $db, $installer)) { if ($null -ne $com) { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) } }
    }
    $names.ToArray()
}
