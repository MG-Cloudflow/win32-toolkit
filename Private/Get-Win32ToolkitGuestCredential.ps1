function Get-Win32ToolkitGuestCredential {
    <#
    .SYNOPSIS
        Returns the stored Hyper-V guest credential as a PSCredential, or $null if not set/decryptable.
    .DESCRIPTION
        Reads the username + DPAPI-protected password written by Set-Win32ToolkitGuestCredential and
        rebuilds a PSCredential. Returns $null (with a warning) if either value is missing or the
        password cannot be decrypted — e.g. it was stored by a different Windows user (DPAPI is
        current-user scoped).
    .OUTPUTS
        [pscredential] or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param()

    $user      = Get-Win32ToolkitConfigValue -Name 'HyperVGuestUser'
    $protected = Get-Win32ToolkitConfigValue -Name 'HyperVGuestSecret'
    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($protected)) {
        return $null
    }

    try {
        $secure = ConvertTo-SecureString $protected -ErrorAction Stop
        return [pscredential]::new($user, $secure)
    }
    catch {
        Write-Warning "Stored Hyper-V guest credential could not be decrypted (it may have been saved by a different Windows user): $($_.Exception.Message)"
        return $null
    }
}
