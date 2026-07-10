function New-Win32ToolkitSandboxConfig {
    <#
    .SYNOPSIS
        Builds a Windows Sandbox .wsb <Configuration> document — the first Sandbox test-backend primitive.
    .DESCRIPTION
        Emits the exact .wsb skeleton the three test/capture flows share: VGpu Disable, Networking Enable,
        one <MappedFolder> per mount (host path XML-encoded), and a single <LogonCommand>. It replaces the
        triplicated here-strings in New-TargetedDocumentation and Test-Win32ToolkitProject so every flow
        builds the sandbox config one way — Phase 0 of the pluggable test-backend seam
        (knowledge-base/designs/hyperv-backend-plan.md).

        Untrusted-value contract (unchanged from the callers): HOST PATHS are XML-encoded here via
        ConvertTo-XmlEncoded. The caller remains responsible for XML-encoding anything it splices into
        -LogonCommandXml — that string is emitted verbatim inside <Command>...</Command>, exactly as the
        callers do today (the guest install command is XML-encoded by the caller before being passed in).
    .PARAMETER Mount
        One or more mapped folders, each a hashtable/object with HostPath, GuestPath and ReadOnly (bool).
        Order is preserved — the project mount is listed first, the read-only baseline (if any) second.
    .PARAMETER LogonCommandXml
        The already-XML-encoded inner text of <Command> (e.g. the powershell.exe one-liner the guest runs
        at logon).
    .OUTPUTS
        [string] the full <Configuration>…</Configuration> document (no trailing newline).
    .EXAMPLE
        New-Win32ToolkitSandboxConfig `
            -Mount @{ HostPath = $ProjectPath; GuestPath = 'C:\PSADT'; ReadOnly = $false } `
            -LogonCommandXml 'powershell.exe -NoExit -ExecutionPolicy Bypass -File C:\PSADT\SupportFiles\TargetedDocumentationScript.ps1'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object[]]$Mount,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogonCommandXml
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<Configuration>')
    [void]$sb.AppendLine('    <VGpu>Disable</VGpu>')
    [void]$sb.AppendLine('    <Networking>Enable</Networking>')
    [void]$sb.AppendLine('    <MappedFolders>')
    foreach ($m in $Mount) {
        if (-not $m.HostPath)  { throw 'Each -Mount needs a HostPath.' }
        if (-not $m.GuestPath) { throw 'Each -Mount needs a GuestPath.' }
        $readOnly = if ($m.ReadOnly) { 'true' } else { 'false' }
        [void]$sb.AppendLine('        <MappedFolder>')
        [void]$sb.AppendLine("            <HostFolder>$(ConvertTo-XmlEncoded $m.HostPath)</HostFolder>")
        [void]$sb.AppendLine("            <SandboxFolder>$($m.GuestPath)</SandboxFolder>")
        [void]$sb.AppendLine("            <ReadOnly>$readOnly</ReadOnly>")
        [void]$sb.AppendLine('        </MappedFolder>')
    }
    [void]$sb.AppendLine('    </MappedFolders>')
    [void]$sb.AppendLine('    <LogonCommand>')
    [void]$sb.AppendLine("        <Command>$LogonCommandXml</Command>")
    [void]$sb.AppendLine('    </LogonCommand>')
    [void]$sb.Append('</Configuration>')
    return $sb.ToString()
}
