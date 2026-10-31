function Test-Win32ToolkitWingetNoApplicableInstaller {
    <#
    .SYNOPSIS
        True when a winget exit code means "no applicable installer" (0x8A150010).
    .DESCRIPTION
        winget returns APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER (HRESULT 0x8A150010, -1978335216 as the
        process exit code) when the package exists but none of its installers matches the requested filters
        (--installer-type, --scope, --architecture, --locale). That is the only code a family pin may treat
        as "try the next type of the family"; every other code (download failed 0x8A150008, no package found
        0x8A150014, ...) is a real failure (installer-identity PR 1, spec 2.2a, V30).
    .PARAMETER ExitCode
        The winget exit code ($LASTEXITCODE).
    .OUTPUTS
        [bool]
    .EXAMPLE
        & winget download --id X --installer-type wix ...
        if (Test-Win32ToolkitWingetNoApplicableInstaller -ExitCode $LASTEXITCODE) { continue }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [int]$ExitCode
    )

    # 0x8A150010 = -1978335216 (an HRESULT reported as a signed 32-bit exit code).
    return ($ExitCode -eq -1978335216)
}
