function Test-Win32ToolkitProductCode {
    # Strict MSI product-code (GUID) validation, e.g. {0F1B2C3D-4E5F-6789-ABCD-0123456789AB}.
    # Used to reject malformed/untrusted product codes before they are emitted into
    # generated uninstall / requirement scripts. See knowledge-base/07-security-review.md.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    return [bool]($Value -match '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$')
}
