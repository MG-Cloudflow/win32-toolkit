function Get-Win32ToolkitGuestCredentialInteractive {
    <#
    .SYNOPSIS
        Prompts for the guest local-admin credential, entering the password TWICE and confirming the two
        entries match (and are non-blank) before returning a [pscredential].
    .DESCRIPTION
        Guards against the classic "typed the wrong password during setup" mistake: the password is baked
        into the golden image (unattend LocalAccount/AutoLogon + Winlogon DefaultPassword), so a single
        mistyped entry produces an image whose password nobody knows — PowerShell Direct AND AutoLogon
        then fail and the only fix is a full rebuild. Loops until the two entries match and are non-blank.
        HOST-ONLY, interactive (Read-Host). Callers that already have a credential pass it explicitly and
        never reach this.
    .PARAMETER UserName
        Default account name offered at the prompt (Enter accepts it). Default 'w32admin'.
    .PARAMETER Message
        Optional heading shown once above the prompts.
    .OUTPUTS
        [pscredential] with a confirmed, non-blank password.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$UserName = 'w32admin',

        [string]$Message = 'Guest local-admin credential for the test VM (enter the password twice to confirm).'
    )

    if ($Message) { Write-Host $Message -ForegroundColor Cyan }

    while ($true) {
        $u = Read-Host "  User name [$UserName]"
        if ([string]::IsNullOrWhiteSpace($u)) { $u = $UserName }

        $p1 = Read-Host "  Password for $u"         -AsSecureString
        $p2 = Read-Host "  Confirm password for $u" -AsSecureString

        # Compare in plaintext (the password already lands in the unattend/Winlogon for this lab VM, so
        # there is nothing extra to protect here), then drop the copies.
        $s1 = [System.Net.NetworkCredential]::new('', $p1).Password
        $s2 = [System.Net.NetworkCredential]::new('', $p2).Password
        $blank    = [string]::IsNullOrEmpty($s1)
        $mismatch = $s1 -ne $s2
        $s1 = $null; $s2 = $null

        if ($blank) {
            Write-Warning 'The password must not be blank — PowerShell Direct and AutoLogon both fail on a blank password. Try again.'
            continue
        }
        if ($mismatch) {
            Write-Warning 'The two passwords do not match. Try again.'
            continue
        }

        return [pscredential]::new($u, $p1)
    }
}
