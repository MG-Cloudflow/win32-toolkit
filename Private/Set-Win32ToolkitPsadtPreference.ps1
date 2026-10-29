function Set-Win32ToolkitPsadtPreference {
    <#
    .SYNOPSIS
        Saves the PSAppDeployToolkit version for new projects (the PreferredPsadtVersion registry value) after checking it.
    .DESCRIPTION
        Menu selectors design P5 (knowledge-base/designs/menu-selectors.md). The value is '' (no pin: the newest supported
        version that is installed), a major.minor ('4.1') or an exact version text ('4.1.8', '4.2.0-rc2'). A non-empty
        value is saved only when Select-Win32ToolkitPsadtModule -PreferredVersion <value> returns Selected (installed and
        in range), so the menu can never save a pin that stops project creation. Free text that is neither form throws
        W32T.PsadtPreferenceRefused, and so does a value the selector cannot use.

        The write passes -ErrorAction Stop to Set-Win32ToolkitConfigValue (a blocked write becomes its warning, not red
        error text), then the value is read back: the result says what is really saved. The environment variable
        W32T_PSADT_VERSION is never set or cleared (it belongs to its window). Nothing is installed or imported.
    .PARAMETER Value
        '' to clear the pin, or the Value of a Get-Win32ToolkitPsadtChoice row.
    .OUTPUTS
        [pscustomobject] Requested, Saved (the value read back, '' = no pin), Ok ([bool] Saved equals Requested).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $want = $Value.Trim()
    if ($want) {
        $safe = ConvertTo-Win32ToolkitSafeText -Text $want -MaxLength 40
        $why = $null
        if ($want -notmatch '^\d{1,9}\.\d{1,9}$' -and $want -notmatch '^\d{1,9}\.\d{1,9}\.\d{1,9}(\.\d{1,9})?(-[0-9A-Za-z][0-9A-Za-z.-]{0,40})?$') {
            $why = 'it is not a version such as 4.1, 4.1.8 or 4.2.0-rc2.'
        }
        else {
            $check = Select-Win32ToolkitPsadtModule -PreferredVersion $want
            if ($check.Status -ne 'Selected') { $why = "no supported, installed PSAppDeployToolkit matches it ($($script:PsadtSupportedRange.Display))." }
        }
        if ($why) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("PreferredPsadtVersion '$safe' was not saved: $why"),
                'W32T.PsadtPreferenceRefused', [System.Management.Automation.ErrorCategory]::InvalidArgument, $safe)
        }
    }

    Set-Win32ToolkitConfigValue -Name 'PreferredPsadtVersion' -Value $want -ErrorAction Stop
    $saved = ([string](Get-Win32ToolkitConfigValue -Name 'PreferredPsadtVersion' -Default '')).Trim()
    [pscustomobject]@{
        Requested = $want
        Saved     = $saved
        Ok        = [string]::Equals($saved, $want, [System.StringComparison]::OrdinalIgnoreCase)
    }
}
