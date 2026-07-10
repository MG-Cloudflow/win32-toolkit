function Set-Win32ToolkitGuestCredential {
    <#
    .SYNOPSIS
        Persists the Hyper-V guest local-admin credential (username plain, password DPAPI-protected).
    .DESCRIPTION
        PowerShell Direct needs a credential for the golden image's local-admin account every run. The
        username is stored as-is; the password is protected with ConvertFrom-SecureString, i.e. DPAPI
        scoped to the CURRENT WINDOWS USER — it can only be decrypted by the same user on the same
        machine, and is never written to the repo. See knowledge-base/designs/hyperv-backend-plan.md.
    .PARAMETER Credential
        The guest local-admin credential to store.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscredential]$Credential
    )

    Set-Win32ToolkitConfigValue -Name 'HyperVGuestUser'   -Value $Credential.UserName
    # DPAPI (current-user scope) — no -Key, so only this user on this machine can decrypt it.
    $protected = $Credential.Password | ConvertFrom-SecureString
    Set-Win32ToolkitConfigValue -Name 'HyperVGuestSecret' -Value $protected
}
