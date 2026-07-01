function Set-Win32ToolkitAppConfig {
    <#
    .SYNOPSIS
        Writes a project's data-driven deployment config to SupportFiles\AppConfig.json.
    .DESCRIPTION
        Serialises the supplied config object to SupportFiles\AppConfig.json with ConvertTo-Json.
        The serializer escapes every string value correctly, so untrusted winget/registry values
        (silent args, uninstall strings, display names, ...) are stored as DATA and are never in a
        code position — this is the durable alternative to hand-escaping generated code. See
        knowledge-base/designs/data-driven-generation.md.

        Callers read the current config with Get-Win32ToolkitAppConfig, set/replace their own
        section, then write it back here (read-modify-write), so sections written at different
        pipeline stages are preserved.
    .PARAMETER ProjectPath
        Full path to the PSADT project folder (the folder that contains Invoke-AppDeployToolkit.ps1).
    .PARAMETER Config
        The configuration object (PSCustomObject/hashtable) to serialise.
    .EXAMPLE
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $p
        $cfg | Add-Member -NotePropertyName Uninstall -NotePropertyValue $uninstall -Force
        Set-Win32ToolkitAppConfig -ProjectPath $p -Config $cfg
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [psobject]$Config
    )

    $supportFiles = Join-Path $ProjectPath 'SupportFiles'
    if (-not (Test-Path -LiteralPath $supportFiles)) {
        if ($PSCmdlet.ShouldProcess($supportFiles, 'Create SupportFiles directory')) {
            New-Item -ItemType Directory -Path $supportFiles -Force | Out-Null
        }
    }

    $configPath = Join-Path $supportFiles 'AppConfig.json'
    if ($PSCmdlet.ShouldProcess($configPath, 'Write AppConfig.json')) {
        $json = $Config | ConvertTo-Json -Depth 8
        # Write BOM-less UTF-8 (Set-Content -Encoding UTF8 emits a BOM on Windows PowerShell 5.1).
        [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $configPath
}
