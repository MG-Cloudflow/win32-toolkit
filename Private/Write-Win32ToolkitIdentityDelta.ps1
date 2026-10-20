function Write-Win32ToolkitIdentityDelta {
    <#
    .SYNOPSIS
        Runs the installer-identity checks for a project, stores them in Documentation\IdentityDelta.json and prints them.
    .DESCRIPTION
        Installer-identity PR 1, spec 2.9. Calls Get-Win32ToolkitIdentityDelta -ProjectPath (fresh predecessor
        lookup and sibling probe; the probe is memoised per process), writes the result to
        <ProjectPath>\Documentation\IdentityDelta.json (BOM-less UTF-8, host-only: Documentation\ never ships)
        and, unless -Quiet, prints every Warning finding with Write-Warning and every Info finding in grey.

        Fail-open, never blocks packaging: any failure becomes one warning 'Identity checks failed: ...' and
        $null is returned.
    .PARAMETER ProjectPath
        The project to check. A relative, '~' or PSDrive path is resolved against the current PowerShell
        location (the file always lands in that project's Documentation\ folder).
    .PARAMETER TenantId
        Only publications to this tenant anchor (default: AppConfig.Intune.TenantId).
    .PARAMETER Quiet
        Write the file without printing the findings.
    .OUTPUTS
        [pscustomobject] the delta, or $null on failure.
    .EXAMPLE
        $null = Write-Win32ToolkitIdentityDelta -ProjectPath $projectFullPath
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TenantId = '',

        [switch]$Quiet
    )

    try {
        # Absolute first: [System.IO.File]::WriteAllText resolves a relative path against the process
        # directory, not the PowerShell location.
        $ProjectPath = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath)
        $delta = Get-Win32ToolkitIdentityDelta -ProjectPath $ProjectPath -TenantId $TenantId

        $docDir = Join-Path $ProjectPath 'Documentation'
        if (-not (Test-Path -LiteralPath $docDir)) { New-Item -ItemType Directory -Path $docDir -Force | Out-Null }
        $json = $delta | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText((Join-Path $docDir 'IdentityDelta.json'), $json, [System.Text.UTF8Encoding]::new($false))

        if (-not $Quiet) {
            foreach ($f in @($delta.Findings)) {
                if ($f.Severity -eq 'Warning') { Write-Warning ([string]$f.Message) }
                else { Write-Host ([string]$f.Message) -ForegroundColor DarkGray }
            }
        }
        return $delta
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning "Identity checks failed: $($_.Exception.Message)"
        return $null
    }
}
