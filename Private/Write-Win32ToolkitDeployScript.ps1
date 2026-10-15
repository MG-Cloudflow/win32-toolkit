function Write-Win32ToolkitDeployScript {
    <#
    .SYNOPSIS
        Writes a generated Invoke-AppDeployToolkit.ps1 (UTF-8 with BOM) and proves it still parses, under
        the host parser AND under real Windows PowerShell 5.1; restores the original bytes otherwise.
    .DESCRIPTION
        The only writer of a generated deploy script (Set-PSADTDataDrivenScript, Apply-OrgTemplate,
        Add-Win32ToolkitOrgHooks). The script runs on the device under Windows PowerShell 5.1, which decodes
        a BOM-less file as ANSI, so the file is always written UTF-8 WITH BOM.

        After writing, the file is parsed by the host parser and by Test-Win32ToolkitPS51Syntax (real
        powershell.exe; fail-open when 5.1 is absent). On any parse error the ORIGINAL bytes are written
        back and W32T.GeneratedScriptInvalid is thrown, so a broken script never stays on disk.

        A no-op when the new bytes equal -OriginalBytes (idempotent re-renders do not touch the file).
    .PARAMETER Path
        Path of the deploy script (a relative path resolves against the PowerShell location).
    .PARAMETER Content
        The new script text (no BOM).
    .PARAMETER OriginalBytes
        The file's bytes as read before patching (restored on failure).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$OriginalBytes
    )

    # .NET file APIs resolve a relative path against the process directory, which Set-Location does not
    # move: resolve it against the PowerShell location first.
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)

    $encoding = New-Object System.Text.UTF8Encoding($true)
    $newBytes = [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($Content))
    if ($newBytes.Length -eq $OriginalBytes.Length -and [System.Linq.Enumerable]::SequenceEqual($newBytes, $OriginalBytes)) {
        Write-Verbose "  $Path unchanged"
        return
    }

    [System.IO.File]::WriteAllBytes($Path, $newBytes)

    $problem = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors -and @($errors).Count) {
        $first = @($errors)[0]
        $problem = "host parser, line $($first.Extent.StartLineNumber): $($first.Message)"
    }
    else {
        $ps51 = @(Test-Win32ToolkitPS51Syntax -Path $Path)
        if ($ps51.Count) { $problem = "Windows PowerShell 5.1 parser: $($ps51[0])" }
    }

    if ($problem) {
        [System.IO.File]::WriteAllBytes($Path, $OriginalBytes)
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new("The generated deploy script does not parse ($problem). $Path was restored to its previous content; nothing was changed."),
            'W32T.GeneratedScriptInvalid', [System.Management.Automation.ErrorCategory]::InvalidResult, $Path)
    }
    Write-Verbose "  $Path written (UTF-8 with BOM, host + 5.1 parse clean)"
}
