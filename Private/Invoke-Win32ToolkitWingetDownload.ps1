function Invoke-Win32ToolkitWingetDownload {
    <#
    .SYNOPSIS
        Runs one 'winget download'; when a configured source cannot authenticate, retries it once from the
        'winget' source.
    .DESCRIPTION
        Without '--source', 'winget download' asks EVERY configured source. A source that needs a sign-in and
        cannot get one (for example a private REST source behind Microsoft Entra ID whose token expired) then
        fails the whole download with APPINSTALLER_CLI_ERROR_AUTHENTICATION_FAILED (HRESULT 0x8A150075,
        -1978335115 as the exit code) or, depending on the sign-in token's state,
        APPINSTALLER_CLI_ERROR_AUTHENTICATION_INTERACTIVE_REQUIRED (0x8A150076, -1978335114), even for a package
        the 'winget' source has. 'winget search' and
        'winget show' only leave such a source out ("results will not be included", exit 0), so the package
        was selected from the other sources and only its download failed.

        This helper runs winget with -ArgumentList (an argument array; winget's console lines go to the host,
        never to the output stream). When winget exits with 0x8A150075 or 0x8A150076 and the arguments name no
        source, it writes ONE warning (naming the code) and runs the same arguments once more with
        '--source winget'. Any other exit code
        is returned unchanged, and so is the retry's exit code: the caller keeps its own handling (a family loop
        still moves on when the retry answers 0x8A150010, no applicable installer). It never signs in, never
        changes a winget source and never retries more than once. The other authentication codes (0x8A150073,
        0x8A150074, 0x8A150077, 0x8A150078) are not retried.
    .PARAMETER ArgumentList
        The winget arguments, starting with 'download'. Passed as an array, never parsed by a shell.
    .PARAMETER Label
        The package and version as the caller prints them (for the warning only).
    .OUTPUTS
        [pscustomobject] with ExitCode (winget's exit code: the retry's when a retry ran) and SourceFallback
        ($true when the retry ran). A caller that makes further attempts for the same package adds
        '--source winget' to them when SourceFallback is $true, so they need no retry and print no second warning.
    .EXAMPLE
        $attempt = Invoke-Win32ToolkitWingetDownload -ArgumentList $wingetArgs -Label 'Git (Git.Git)'
        if ($attempt.ExitCode -ne 0) { ... }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The arguments reach winget exactly as the caller built them (an empty value stays an empty argument).
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$ArgumentList,

        [string]$Label
    )

    # The source-authentication codes retried once with '--source winget' (winget-cli returnCodes.md;
    # 'winget error --input <code>' prints the same names):
    #   0x8A150075 = -1978335115  APPINSTALLER_CLI_ERROR_AUTHENTICATION_FAILED
    #   0x8A150076 = -1978335114  APPINSTALLER_CLI_ERROR_AUTHENTICATION_INTERACTIVE_REQUIRED
    # Field (test campaign 2026-10-21, S7/S10): the same interactive host gets 0x75 or 0x76 from a private Entra
    # source depending on its WAM token state, even across processes. 0x8A150073/74/77/78 are not retried (D-SRC-1).
    $sourceAuthCodes = @(-1978335115, -1978335114)

    & winget @ArgumentList | Out-Host
    $code = $LASTEXITCODE
    $namesSource = ($ArgumentList -contains '--source') -or ($ArgumentList -contains '-s')
    if ($code -notin $sourceAuthCodes -or $namesSource) {
        return [pscustomobject]@{ ExitCode = $code; SourceFallback = $false }
    }

    $what = if ($Label) { $Label } else { 'the package' }
    Write-Warning ("winget could not download {0}: a configured winget source failed to authenticate (0x{1:X8}, for example a private source that needs a Microsoft Entra sign-in). Retrying once from the 'winget' source only (--source winget). If the package comes from that private source, sign in to it and run again." -f $what, $code)
    & winget @ArgumentList '--source' 'winget' | Out-Host
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; SourceFallback = $true }
}
