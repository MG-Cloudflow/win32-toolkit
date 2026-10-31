function Write-Win32ToolkitPackageAdvisory {
    <#
    .SYNOPSIS
        Prints the package advisory (failed Update tests, technology switches, identity checks, unsafe
        cleanup paths) once per project and top-level action.
    .DESCRIPTION
        Installer-identity PR 1, spec 2.13 (D1, L20). Calls Get-Win32ToolkitPackageAdvisory and prints every
        Warning finding with Write-Warning and every Info finding with Write-Verbose, prefixed with
        '<project folder>: ' (-Context Export) or "Publishing '<AppLabel>': " (-Context Publish). It only
        warns: it never blocks, never writes a file and never throws (an unexpected error becomes one
        warning 'Could not check the Update test and identity warnings: ...').

        Run scope: Export-Win32ToolkitIntuneWin, Publish-Win32ToolkitIntuneApp and the TUI publish action
        open $script:W32TAdvisoryRun (a hashtable) when none is open and close it when they finish. Inside
        an open scope a project is shown once: a later call for the same project (Export -> Publish ->
        Publish -AsUpdate) prints nothing and returns $null. Without an open scope every call prints.
    .PARAMETER ProjectPath
        The PSADT project folder. A relative, '~' or PSDrive path is resolved against the current PowerShell
        location (not the process directory).
    .PARAMETER Context
        Export or Publish (the message prefix and the UNSAFE-CLEANUP check, which runs at Publish only).
    .PARAMETER AppLabel
        The Intune display name shown in the Publish prefix (default: the project folder name).
    .PARAMETER ProbeIfMissing
        Allow one sibling-probe request when no matching probe is stored (memoised per process).
    .OUTPUTS
        [pscustomobject] the advisory, or $null when the project was already shown in this run scope (or
        the check failed).
    .EXAMPLE
        $null = Write-Win32ToolkitPackageAdvisory -ProjectPath $ProjectPath -Context Export -ProbeIfMissing
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateSet('Export', 'Publish')]
        [string]$Context,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$AppLabel = '',

        [switch]$ProbeIfMissing
    )

    try {
        # Absolute first, against the PowerShell location ('.', '..\x', '~', PSDrive paths): GetFullPath alone
        # resolves against the process directory. The same full path is the run-scope key (the TUI marks a
        # project with GetFullPath of its absolute path), the prefix leaf and what the advisory reads.
        $ProjectPath = [System.IO.Path]::GetFullPath($PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath))
        $key = $ProjectPath.TrimEnd('\')
        # -ErrorAction Ignore, not SilentlyContinue: no run scope yet must not leave a VariableNotFound record in
        # $Error or in a caller's -ErrorVariable.
        $run = Get-Variable -Name W32TAdvisoryRun -Scope Script -ValueOnly -ErrorAction Ignore
        if ($run -is [hashtable] -and $run.ContainsKey($key)) {
            Write-Verbose "Package advisory for '$key' already shown in this run."
            return $null
        }

        $advisory = Get-Win32ToolkitPackageAdvisory -ProjectPath $ProjectPath -Context $Context -ProbeIfMissing:$ProbeIfMissing

        $leaf = ConvertTo-Win32ToolkitSafeText -Text (Split-Path -Path $key -Leaf) -MaxLength 128
        $prefix = if ($Context -eq 'Publish') {
            $label = ConvertTo-Win32ToolkitSafeText -Text $AppLabel -MaxLength 128
            "Publishing '{0}': " -f $(if ($label) { $label } else { $leaf })
        } else {
            '{0}: ' -f $leaf
        }
        foreach ($finding in @($advisory.Findings)) {
            if (-not $finding) { continue }
            if ($finding.Severity -eq 'Warning') { Write-Warning ($prefix + [string]$finding.Message) }
            else { Write-Verbose ($prefix + [string]$finding.Message) }
        }

        if ($run -is [hashtable]) { $run[$key] = $true }
        return $advisory
    } catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning "Could not check the Update test and identity warnings: $($_.Exception.Message)"
        return $null
    }
}
