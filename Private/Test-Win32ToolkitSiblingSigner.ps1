function Test-Win32ToolkitSiblingSigner {
    <#
    .SYNOPSIS
        Cross-checks the signer of a sibling installer technology against the package's own installer.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.8 rule 8; design 7.12.5 "Signer cross-check"; precedent
        Assert-Win32ToolkitTrustedBinary). A winget manifest error can attribute another vendor's product to the same
        package id; the Authenticode signers tell. Only HOST-verified signatures count (the capture guest has just run
        that vendor's installer, so its own verdict is information only): the sibling installer the host downloaded,
        the main program the guest copied out (read on the host, never run), and the package's own installer (and its
        own main program when the caller has one).

        SignerMismatch when any of:
          - the sibling installer or the package installer is not Valid (unsigned, broken, unreadable) or has no subject;
          - their subjects differ (ordinal, ignoring case);
          - the sibling's main program was copied out (its Status is not '') and is not Valid, or its subject is not
            the package main program's (when given) or else the package installer's.
        A main program that was not copied out is not compared (no MainExe already makes a proposal Block-only).
        Pure: no file access.
    .PARAMETER SiblingInstaller
        The sibling installer's signature: @{ Status; Subject } (the record's HostChecks.InstallerSigner).
    .PARAMETER SiblingMain
        The sibling main program's signature (HostChecks.MainSigner); Status '' when it was not copied out.
    .PARAMETER PackageInstaller
        The package installer's signature (Get-AuthenticodeSignature on Files\<Installer.FileName>).
    .PARAMETER PackageMain
        The package's own main program's signature, when known.
    .OUTPUTS
        [pscustomobject] Mismatch ([bool]), Reasons ([string[]]).
    .EXAMPLE
        Test-Win32ToolkitSiblingSigner -SiblingInstaller $rec.HostChecks.InstallerSigner -SiblingMain $rec.HostChecks.MainSigner -PackageInstaller @{ Status = 'Valid'; Subject = 'CN=Contoso' }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object]$SiblingInstaller,

        [AllowNull()]
        [object]$SiblingMain,

        [AllowNull()]
        [object]$PackageInstaller,

        [AllowNull()]
        [object]$PackageMain
    )

    $read = {
        param($Signer, [string]$Name)
        if ($null -eq $Signer) { return '' }
        if ($Signer -is [System.Collections.IDictionary]) { if ($Signer.Contains($Name) -and $null -ne $Signer[$Name]) { return [string]$Signer[$Name] }; return '' }
        if ($Signer.PSObject.Properties[$Name] -and $null -ne $Signer.$Name) { return [string]$Signer.$Name }
        return ''
    }
    $same = { param([string]$A, [string]$B) $A -and $B -and [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase) }
    $reasons = [System.Collections.Generic.List[string]]::new()

    $sStatus = & $read $SiblingInstaller 'Status'; $sSubject = & $read $SiblingInstaller 'Subject'
    $pStatus = & $read $PackageInstaller 'Status'; $pSubject = & $read $PackageInstaller 'Subject'
    if ($sStatus -cne 'Valid' -or -not $sSubject) { $reasons.Add("the sibling installer is not validly signed (status: $(if ($sStatus) { $sStatus } else { 'unknown' }))") }
    if ($pStatus -cne 'Valid' -or -not $pSubject) { $reasons.Add("the package installer is not validly signed (status: $(if ($pStatus) { $pStatus } else { 'unknown' }))") }
    if ($reasons.Count -eq 0 -and -not (& $same $sSubject $pSubject)) { $reasons.Add('the sibling installer and the package installer have different signers') }

    $mStatus = & $read $SiblingMain 'Status'; $mSubject = & $read $SiblingMain 'Subject'
    if ($mStatus) {
        $want = & $read $PackageMain 'Subject'
        if (-not $want -or (& $read $PackageMain 'Status') -cne 'Valid') { $want = $pSubject }
        if ($mStatus -cne 'Valid' -or -not $mSubject) { $reasons.Add("the sibling's main program is not validly signed (status: $mStatus)") }
        elseif (-not (& $same $mSubject $want)) { $reasons.Add("the sibling's main program has another signer than the package") }
    }
    return [pscustomobject]@{ Mismatch = ($reasons.Count -gt 0); Reasons = [string[]]$reasons.ToArray() }
}
