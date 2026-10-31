function Assert-Win32ToolkitDependencyRef {
    <#
    .SYNOPSIS
        Refuses an invalid dependency reference before anything is written (shape, and self-dependency with -ProjectPath).
    .DESCRIPTION
        The one validator of declared dependency references (re-verification 2026-10-21, B3 r2.1).
        Set-Win32ToolkitAppDependency calls it before it writes AppConfig.json. Invoke-Win32Toolkit and
        New-Win32ToolkitManualApp call it for -DependsOn before anything is searched, prompted for, downloaded or
        created; their declaration after the scaffold is then a second line of defence.

        Each non-blank reference is parsed by ConvertTo-Win32ToolkitDependencyRef, which refuses an empty value, an
        'intune:' id that is not a GUID and a 'project:' reference without '\'. A 'project:' reference must then be
        exactly '<Template>\<ProjectName>' under Projects\ (test campaign 2026-10-21, S11-F5): two names, none empty,
        '.' or '..', not rooted, no name ending in '.' or ' ' (Windows drops it, so 'T.\App' is 'T\App'; B3 #2), and
        no character that is not allowed in a file name. With -ProjectPath (the project that declares; its folder
        need not exist yet), a 'project:' reference to that project itself is refused too, both by its
        '<Template>\<Leaf>' string and by the normalized full path (so an 8.3 alias is caught), ignoring case.

        Nothing is written; no network, no Graph. Every refusal is a terminating ErrorRecord with the
        FullyQualifiedErrorId 'W32T.InvalidDependencyReference' (category InvalidArgument). The messages are the
        ones Set-Win32ToolkitAppDependency used before.
    .PARAMETER Reference
        The references as given to -DependsOn ('winget:<id>', 'project:<Template>\<Name>', 'intune:<guid>' or a bare
        string). Blank entries are skipped.
    .PARAMETER DependencyType
        Stamped on each parsed reference: 'autoInstall' (default) or 'detect'.
    .PARAMETER ProjectPath
        The project that declares the dependencies, for the self-dependency check. Omit it for a shape-only check.
    .OUTPUTS
        PSCustomObject per reference, in order: Source, Ref, DependencyType.
    .EXAMPLE
        Assert-Win32ToolkitDependencyRef -Reference 'project:Contoso\VCRedist_x64_14.38' -ProjectPath 'D:\Pkg\Projects\Contoso\App_x64_1.0'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Reference,

        [ValidateSet('autoInstall', 'detect')]
        [string]$DependencyType = 'autoInstall',

        [string]$ProjectPath
    )

    $refuse = {
        param([string]$Message, [object]$Target)
        throw [System.Management.Automation.ErrorRecord]::new([System.ArgumentException]::new($Message),
            'W32T.InvalidDependencyReference', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Target)
    }

    $self = ''; $selfFull = ''; $projectsRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
        # This project's own 'project:' identity: an app cannot depend on itself (Intune rejects it too).
        $self         = '{0}\{1}' -f (Split-Path -Leaf (Split-Path -Parent $ProjectPath)), (Split-Path -Leaf $ProjectPath)
        $selfFull     = [System.IO.Path]::GetFullPath($PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath)).TrimEnd('\')
        $projectsRoot = Split-Path -Parent (Split-Path -Parent $selfFull)
    }

    foreach ($r in @($Reference)) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $parsed = ConvertTo-Win32ToolkitDependencyRef -Reference $r -DependencyType $DependencyType
        if ($parsed.Source -eq 'project') {
            # Exactly '<Template>\<ProjectName>' under Projects\: a rooted path, '..' or a third segment would be
            # joined onto Projects\ and resolve outside it when staged (test campaign 2026-10-21, S11-F5).
            $ref     = [string]$parsed.Ref
            $parts   = @($ref -split '\\')
            $invalid = [System.IO.Path]::GetInvalidFileNameChars()
            $bad     = @($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..' -or $_ -match '[. ]$' -or $_.IndexOfAny($invalid) -ge 0 })
            if ($parts.Count -ne 2 -or $bad.Count -gt 0 -or [System.IO.Path]::IsPathRooted($ref)) {
                # The parenthetical names the actual reason (B3 r1.3); the staging uses the same "a name ends in" wording.
                $why = if ([System.IO.Path]::IsPathRooted($ref) -or @($parts | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) { "not a full path or '..'" }
                       elseif (@($parts | Where-Object { $_ -match '[. ]$' }).Count -gt 0) { "a name ends in '.' or ' '" }
                       elseif (@($parts | Where-Object { $_.IndexOfAny($invalid) -ge 0 }).Count -gt 0) { 'a name holds a character that is not allowed in a file name' }
                       else { 'exactly two names, neither empty' }
                & $refuse "Dependency 'project:$ref' must be '<Template>\<ProjectName>' under Projects\ ($why)." "project:$ref"
            }
            if ($self) {
                $refFull = [System.IO.Path]::GetFullPath((Join-Path $projectsRoot $ref)).TrimEnd('\')
                if ($ref -eq $self -or $refFull.Equals($selfFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    & $refuse "An app cannot depend on itself ('$self')." "project:$ref"
                }
            }
        }
        $parsed
    }
}
