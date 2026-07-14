function Test-WingetInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $null = Get-Command winget -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}