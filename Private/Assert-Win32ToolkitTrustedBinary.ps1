function Assert-Win32ToolkitTrustedBinary {
    <#
    .SYNOPSIS
        Fails CLOSED unless an executable carries a valid Authenticode signature from the expected publisher.
    .DESCRIPTION
        The toolkit downloads IntuneWinAppUtil.exe and then RUNS it on the packaging host. The download had
        no integrity check at all, and its fallback URL pointed at a MUTABLE ref
        (raw.githubusercontent.com/.../master/IntuneWinAppUtil.exe) — so whatever that ref pointed at today
        was fetched and executed.

        Authenticode is a better control here than a pinned SHA-256: the real binary is Microsoft-signed, the
        check survives version bumps (a pinned hash would have to be updated for every release, and a stale
        one either blocks upgrades or gets removed in frustration), and it verifies PUBLISHER + INTEGRITY
        rather than "this is the exact file someone once looked at".

        Verifies BOTH on download AND on reuse of an already-present copy — a binary sitting in Tools\ from a
        previous run (or dropped there by something else) is not trusted just because it exists.
    .PARAMETER Path
        The executable to verify.
    .PARAMETER ExpectedSubject
        Substring the signing certificate's subject must contain (e.g. 'Microsoft Corporation').
    .PARAMETER RemoveOnFailure
        Delete the file when verification fails, so a bad binary can never be reused by a later run.
    .OUTPUTS
        None. Throws if the binary is unsigned, tampered with, or signed by anyone else.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedSubject,

        [switch]$RemoveOnFailure
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Cannot verify '$Path' — the file does not exist." }

    $fail = {
        param([string]$Because)
        if ($RemoveOnFailure) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
        throw @"
Refusing to use '$Path' — $Because
This executable is RUN on this machine, so it is not used unless it carries a valid Authenticode signature
from '$ExpectedSubject'. Download it yourself from the official source and place it in the Tools folder.
"@
    }

    $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop

    if ($sig.Status -ne 'Valid') {
        & $fail "its Authenticode signature is not valid (status: $($sig.Status))."
    }
    if (-not $sig.SignerCertificate) {
        & $fail 'it has no signing certificate.'
    }
    if ($sig.SignerCertificate.Subject -notlike "*$ExpectedSubject*") {
        & $fail "it is signed by '$($sig.SignerCertificate.Subject)', not '$ExpectedSubject'."
    }

    Write-Verbose "Authenticode OK for '$Path' (signed by $($sig.SignerCertificate.Subject))."
}
