function Write-Win32ToolkitNotConfiguredMarker {
    <#
    .SYNOPSIS
        Marks a half-built project as not configured (TUI audit G4, S10-F2): Documentation\NotConfigured.json.
    .DESCRIPTION
        Invoke-Win32Toolkit and New-Win32ToolkitManualApp call it from the catch of their marking span (from right
        after a successful Create-PSADTProject to the end of the configure step) for EVERY error there: the folder
        is kept, but it has no working installer configuration or org template. Export-Win32ToolkitIntuneWin and
        Publish-Win32ToolkitIntuneApp refuse a marked project (W32T.ProjectNotConfigured) until it is re-created.

        The file is data only, never executed, and never ships (Documentation\ is a non-shipping folder). UTF-8
        without BOM (host-only data):
            { "SchemaVersion": "1.0", "Stage": "Configure", "ErrorId": "W32T.OrgExtensionInvalid",
              "Reason": "...", "TimestampUtc": "2026-10-23T10:15:00.0000000Z" }
        Reason passes ConvertTo-Win32ToolkitSafeText (at most 1024 characters).

        Never throws: a write failure becomes one warning telling the operator not to package or publish the
        project. Its catch starts with the W32T.* re-throw (the CLAUDE.md rule; nothing it calls raises one).
    .PARAMETER ProjectPath
        The project folder.
    .PARAMETER Stage
        Download (the installer step: winget pin + download + rename, or the manual copy + detection) or
        Configure (everything from the configure step on).
    .PARAMETER ErrorId
        The error's FullyQualifiedErrorId when it is a W32T.* id; empty for any other error.
    .PARAMETER Reason
        The error message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][ValidateSet('Download', 'Configure')][string]$Stage,
        [AllowEmptyString()][string]$ErrorId = '',
        [AllowEmptyString()][string]$Reason = ''
    )

    $markerPath = Join-Path $ProjectPath 'Documentation\NotConfigured.json'
    try {
        $docDir = Split-Path -Path $markerPath -Parent
        if (-not (Test-Path -LiteralPath $docDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $docDir -Force -ErrorAction Stop }
        $data = [ordered]@{
            SchemaVersion = '1.0'
            Stage         = $Stage
            ErrorId       = $(if ($ErrorId -like 'W32T.*') { ConvertTo-Win32ToolkitSafeText -Text $ErrorId -MaxLength 128 } else { '' })
            Reason        = ConvertTo-Win32ToolkitSafeText -Text $Reason -MaxLength 1024
            TimestampUtc  = [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $json = $data | ConvertTo-Json -Depth 2
        # Absolute path: [System.IO.File] resolves a relative path against the process directory.
        $full = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($markerPath)
        [System.IO.File]::WriteAllText($full, $json, [System.Text.UTF8Encoding]::new($false))
        Write-Verbose "Marked '$ProjectPath' as not configured ($Stage): $markerPath"
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        Write-Warning "Could not mark '$ProjectPath' as not configured ($($_.Exception.Message)): do not package or publish it; package the app again to re-create it."
    }
}
