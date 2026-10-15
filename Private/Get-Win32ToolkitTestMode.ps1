function Get-Win32ToolkitTestMode {
    <#
    .SYNOPSIS
        Resolves the effective test mode ('Interactive' | 'Unattended') for a test backend.
    .DESCRIPTION
        One resolver for both backends so their precedence can't drift:
          1. An explicit -Unattended switch always wins.
          2. The per-backend config value (HyperVTestMode / SandboxTestMode) — 'Unattended' opts in.
          3. A NON-INTERACTIVE host forces Unattended with a loud warning: Interactive mode blocks on
             Read-Host pauses (which THROW under pwsh -NonInteractive and hang forever on redirected
             stdin) and shows GUIs/countdowns no operator will ever see. The warning is loud because
             this changes WHAT is tested (Sandbox: PSADT runs -DeployMode Silent; Hyper-V: the install,
             uninstall and update run as the Intune-parity phase; either way no human verification window)
             — and the mode is recorded in the test outcome, so the change is visible in the docs.
          4. Otherwise: Interactive (the human-in-the-loop default, unchanged).
    .PARAMETER Backend
        'Sandbox' or 'HyperV' — selects which config value applies.
    .PARAMETER Unattended
        The caller's explicit switch (highest precedence).
    .OUTPUTS
        [string] 'Interactive' or 'Unattended'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Sandbox', 'HyperV')]
        [string]$Backend,

        [switch]$Unattended
    )

    if ($Unattended) { return 'Unattended' }

    $configName = if ($Backend -eq 'HyperV') { 'HyperVTestMode' } else { 'SandboxTestMode' }
    if ((Get-Win32ToolkitConfigValue -Name $configName -Default 'Interactive') -eq 'Unattended') {
        return 'Unattended'
    }

    # Interactive requested (or defaulted) — but only honor it when a human can actually interact.
    if (Test-Win32ToolkitHostNonInteractive) {
        # What Unattended means differs per backend: Sandbox runs PSADT silently, Hyper-V runs the
        # Intune-parity phases (Sandbox\Invoke-PsadtPackage.ps1 -IntuneParity, built by Test-Win32ToolkitProject).
        $whatRuns = if ($Backend -eq 'HyperV') {
            'the install, uninstall and update run as the Intune-parity phase (the published command line from a 32-bit parent, as SYSTEM)'
        }
        else { 'PSADT runs -DeployMode Silent' }
        Write-Warning "The host session is non-interactive — running the $Backend test UNATTENDED instead of Interactive. This changes what is tested: $whatRuns, with no operator verification window. Pass -Unattended (or set $configName=Unattended) to make this explicit."
        return 'Unattended'
    }

    return 'Interactive'
}
