function Get-Win32ToolkitSiblingAttributionScript {
    <#
    .SYNOPSIS
        The one attribution text: which new uninstall entry of a sibling capture is the sibling installer's own.
    .DESCRIPTION
        Installer-identity PR 3b (spec 2.14.6, 2.14.8 rule 1, SV1, SV16). A sibling installer run in a clean guest leaves
        new uninstall entries; only ONE is its own registration (the "primary"), the others are products it installed next
        to it or noise of the guest (Edge, WebView2 updates). The SAME text decides this in the capture guest (Windows
        PowerShell 5.1, the provisional primary) and on the host (Get-Win32ToolkitSiblingAttribution, the proposals), with
        the same inputs (the candidates, the manifest facts, the package's publisher from the data file) except the
        signer subjects, which only the host has and only for the guest's primary - so the two can never disagree: the
        guest script embeds the text verbatim, the host creates its scriptblock from it.

        The text defines $w32tScAttribute = { param($Candidates, $Manifest, $Own, $PackagePublisher, $NewRoots) }, which
        returns @{ Primary; PrimaryView; Rank 'High'|'Medium'|''; Reason; SameKey; CoInstalled; Unattributed }:
          - candidates: the entries with a publisher and without SystemComponent = 1; a 'Microsoft*' publisher is never
            ranked unless the package's publisher is Microsoft too;
          - High: the key equals a manifest installer-level or Apps and Features ProductCode ('ProductCode'); or the
            DisplayName (exactly, or with its own DisplayVersion read as {v}) and the Publisher equal an Apps and Features
            entry's ('AppsAndFeatures');
          - Medium: the normalised DisplayName and Publisher equal the manifest's PackageName and Publisher, InstallDir
            equals the manifest's DefaultInstallLocation (both tokenised: C:\Program Files (x86) and %ProgramFiles(x86)%
            -> %ProgramFiles(x86)%, C:\Program Files, %ProgramW6432% and %ProgramFiles% -> %ProgramFiles%, '/' -> '\') or
            has the leaf of the new root that holds the entry (its uninstaller or InstallLocation), and the uninstaller's
            or main program's signer subject equals the sibling installer's ('PackageNameSigner'; the guest has no signer
            data, so it never ranks Medium). NOT REACHABLE in PR 3b: the guest copies out only its own provisional
            primary's uninstaller and main program, and the host verifies signers on those copies only - an entry the
            guest ranked High (High wins) or none at all - so no capture reaches Medium. The rank stays in this text for
            the follow-up that copies out the single Medium-shaped candidate (knowledge-base TODO);
          - one candidate at the best rank is the Primary; none or several -> Primary '' ('NoPrimary' / 'Ambiguous');
          - CoInstalled (spec 2.14.8 rule 1): with a primary, the other candidates whose uninstaller or InstallLocation
            lies in a new root (any folder the capture created: a co-product such as a maintenance service in its own
            folder), except a Microsoft entry of a non-Microsoft package (guest noise); Unattributed: the rest (all of
            them when there is no primary). Both are lists of @{ Key; View }.
        Windows PowerShell 5.1-safe, ASCII, no here-string, every variable named w32t*; it reads its inputs and nothing
        else (no registry, no file, no network).
    .OUTPUTS
        [string] the text (LF line ends).
    .EXAMPLE
        $sb = [scriptblock]::Create((Get-Win32ToolkitSiblingAttributionScript)); . $sb
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $text = @'
## win32-toolkit sibling attribution (installer-identity PR 3b, SV1). The same text runs in the sibling-capture guest
## (Windows PowerShell 5.1) and on the host: which new uninstall entry is the sibling installer's own registration.
## Data only: it reads its arguments, nothing else.
$w32tScAttribute = {
    param($Candidates, $Manifest, $Own, $PackagePublisher, $NewRoots)
    $w32tScStr = {
        param($w32tO, $w32tN)
        if ($null -eq $w32tO) { return '' }
        if ($w32tO -is [System.Collections.IDictionary]) {
            if ($w32tO.Contains($w32tN) -and $null -ne $w32tO[$w32tN]) { return [string]$w32tO[$w32tN] }
            return ''
        }
        $w32tP = $w32tO.PSObject.Properties[$w32tN]
        if ($w32tP -and $null -ne $w32tP.Value) { return [string]$w32tP.Value }
        return ''
    }
    $w32tScList = {
        param($w32tO, $w32tN)
        $w32tV = $null
        if ($w32tO -is [System.Collections.IDictionary]) { if ($w32tO.Contains($w32tN)) { $w32tV = $w32tO[$w32tN] } }
        elseif ($null -ne $w32tO -and $w32tO.PSObject.Properties[$w32tN]) { $w32tV = $w32tO.PSObject.Properties[$w32tN].Value }
        $w32tOut = New-Object System.Collections.ArrayList
        foreach ($w32tI in @($w32tV)) { if ($null -ne $w32tI) { [void]$w32tOut.Add($w32tI) } }
        return ,$w32tOut
    }
    $w32tScSame = { param($w32tA, $w32tB) return ($w32tA -and $w32tB -and [string]::Equals([string]$w32tA, [string]$w32tB, [System.StringComparison]::OrdinalIgnoreCase)) }
    $w32tScTemplate = {
        param($w32tName, $w32tVersion)
        $w32tN = [string]$w32tName
        if ($w32tVersion -and $w32tN.IndexOf([string]$w32tVersion, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $w32tAt = $w32tN.IndexOf([string]$w32tVersion, [System.StringComparison]::OrdinalIgnoreCase)
            $w32tN = $w32tN.Substring(0, $w32tAt) + '{v}' + $w32tN.Substring($w32tAt + ([string]$w32tVersion).Length)
        }
        return $w32tN.ToLowerInvariant()
    }
    $w32tScNorm = {
        param($w32tText, $w32tVersion)
        $w32tT = ([string]$w32tText).ToLowerInvariant()
        if ($w32tVersion) { $w32tT = $w32tT.Replace(([string]$w32tVersion).ToLowerInvariant(), ' ') }
        $w32tT = [regex]::Replace($w32tT, '\([^)]*\)', ' ')
        $w32tT = [regex]::Replace($w32tT, '\b(x64|x86|arm64|amd64|64-bit|32-bit)\b', ' ')
        return [regex]::Replace($w32tT, '[^a-z0-9+]', '')
    }
    $w32tScPath = { param($w32tP) return ([string]$w32tP).Replace('/', '\').TrimEnd('\').ToLowerInvariant() }
    $w32tScInside = {
        param($w32tP, $w32tRoot)
        $w32tA = & $w32tScPath $w32tP
        $w32tB = & $w32tScPath $w32tRoot
        if (-not $w32tA -or -not $w32tB) { return $false }
        return ($w32tA -eq $w32tB -or $w32tA.StartsWith($w32tB + '\'))
    }
    $w32tScLeaf = { param($w32tP) $w32tQ = & $w32tScPath $w32tP; $w32tI = $w32tQ.LastIndexOf('\'); if ($w32tI -ge 0) { return $w32tQ.Substring($w32tI + 1) }; return $w32tQ }
    $w32tScTokenise = {
        param($w32tP)
        $w32tT = & $w32tScPath $w32tP
        foreach ($w32tPair in @(@('%programfiles(x86)%', '%programfiles(x86)%'), @('c:\program files (x86)', '%programfiles(x86)%'), @('%programw6432%', '%programfiles%'), @('%programfiles%', '%programfiles%'), @('c:\program files', '%programfiles%'))) {
            if ($w32tT -eq $w32tPair[0] -or $w32tT.StartsWith($w32tPair[0] + '\')) { return $w32tPair[1] + $w32tT.Substring($w32tPair[0].Length) }
        }
        return $w32tT
    }
    $w32tScRoots = New-Object System.Collections.ArrayList
    foreach ($w32tR in @($NewRoots)) { if ([string]$w32tR) { [void]$w32tScRoots.Add([string]$w32tR) } }
    $w32tScRootOf = {
        param($w32tC)
        foreach ($w32tR in $w32tScRoots) {
            if ((& $w32tScInside (& $w32tScStr $w32tC 'UninstallerPath') $w32tR) -or (& $w32tScInside (& $w32tScStr $w32tC 'InstallLocation') $w32tR)) { return $w32tR }
        }
        return ''
    }

    $w32tCodes = New-Object System.Collections.ArrayList
    foreach ($w32tC in (& $w32tScList $Manifest 'ProductCodes')) { if ([string]$w32tC) { [void]$w32tCodes.Add([string]$w32tC) } }
    $w32tAfe = & $w32tScList $Manifest 'Afe'
    foreach ($w32tA in $w32tAfe) { $w32tC = & $w32tScStr $w32tA 'ProductCode'; if ($w32tC) { [void]$w32tCodes.Add($w32tC) } }
    $w32tPkgName = & $w32tScStr $Manifest 'PackageName'
    $w32tPkgPublisher = & $w32tScStr $Manifest 'Publisher'
    $w32tDefault = & $w32tScStr $Manifest 'DefaultInstallLocation'
    $w32tInstallerSigner = & $w32tScStr $Manifest 'InstallerSignerSubject'
    $w32tMsAllowed = ([string]$PackagePublisher) -like 'Microsoft*'
    $w32tOwnKeys = New-Object System.Collections.ArrayList
    foreach ($w32tK in (& $w32tScList $Own 'ArpKeys')) { $w32tKey = & $w32tScStr $w32tK 'Key'; if (-not $w32tKey -and $w32tK -is [string]) { $w32tKey = $w32tK }; if ($w32tKey) { [void]$w32tOwnKeys.Add($w32tKey) } }
    foreach ($w32tK in (& $w32tScList $Own 'ProductCodes')) { if ([string]$w32tK) { [void]$w32tOwnKeys.Add([string]$w32tK) } }

    $w32tRanked = New-Object System.Collections.ArrayList
    foreach ($w32tCand in @($Candidates)) {
        if ($null -eq $w32tCand) { continue }
        $w32tPub = & $w32tScStr $w32tCand 'Publisher'
        if (-not $w32tPub.Trim()) { continue }
        if ((& $w32tScStr $w32tCand 'SystemComponent') -eq 'True' -or (& $w32tScStr $w32tCand 'SystemComponent') -eq '1') { continue }
        $w32tKey = & $w32tScStr $w32tCand 'Key'
        $w32tName = & $w32tScStr $w32tCand 'DisplayName'
        $w32tVer = & $w32tScStr $w32tCand 'DisplayVersion'
        $w32tRank = ''; $w32tWhy = ''
        if ($w32tPub -like 'Microsoft*' -and -not $w32tMsAllowed) { $w32tRank = '' }
        else {
            foreach ($w32tC in $w32tCodes) { if (& $w32tScSame $w32tKey $w32tC) { $w32tRank = 'High'; $w32tWhy = 'ProductCode' } }
            if (-not $w32tRank) {
                foreach ($w32tA in $w32tAfe) {
                    $w32tAName = & $w32tScStr $w32tA 'DisplayName'
                    $w32tAPub = & $w32tScStr $w32tA 'Publisher'
                    if (-not $w32tAName -or -not (& $w32tScSame $w32tAPub $w32tPub)) { continue }
                    if ((& $w32tScSame $w32tAName $w32tName) -or ((& $w32tScTemplate $w32tAName (& $w32tScStr $w32tA 'DisplayVersion')) -eq (& $w32tScTemplate $w32tName $w32tVer))) { $w32tRank = 'High'; $w32tWhy = 'AppsAndFeatures' }
                }
            }
            if (-not $w32tRank -and $w32tPkgName -and $w32tPkgPublisher -and $w32tInstallerSigner) {
                $w32tNameOk = (& $w32tScNorm $w32tName $w32tVer) -eq (& $w32tScNorm $w32tPkgName '') -and (& $w32tScNorm $w32tPub '') -eq (& $w32tScNorm $w32tPkgPublisher '')
                $w32tDir = & $w32tScStr $w32tCand 'InstallDir'
                $w32tDirOk = $false
                if ($w32tDir -and $w32tDefault -and (& $w32tScTokenise $w32tDir) -eq (& $w32tScTokenise $w32tDefault)) { $w32tDirOk = $true }
                $w32tRoot = & $w32tScRootOf $w32tCand
                if ($w32tDir -and $w32tRoot -and (& $w32tScLeaf $w32tRoot) -eq (& $w32tScLeaf $w32tDir)) { $w32tDirOk = $true }
                $w32tSignOk = (& $w32tScSame (& $w32tScStr $w32tCand 'UninstallerSignerSubject') $w32tInstallerSigner) -or (& $w32tScSame (& $w32tScStr $w32tCand 'MainSignerSubject') $w32tInstallerSigner)
                if ($w32tNameOk -and $w32tDirOk -and $w32tSignOk) { $w32tRank = 'Medium'; $w32tWhy = 'PackageNameSigner' }
            }
        }
        [void]$w32tRanked.Add(@{ Candidate = $w32tCand; Key = $w32tKey; View = (& $w32tScStr $w32tCand 'View'); Rank = $w32tRank; Why = $w32tWhy })
    }

    $w32tBest = ''
    if (@($w32tRanked | Where-Object { $_.Rank -eq 'High' }).Count -gt 0) { $w32tBest = 'High' }
    elseif (@($w32tRanked | Where-Object { $_.Rank -eq 'Medium' }).Count -gt 0) { $w32tBest = 'Medium' }
    $w32tTop = @($w32tRanked | Where-Object { $w32tBest -and $_.Rank -eq $w32tBest })
    $w32tPrimary = $null
    $w32tReason = 'NoPrimary'
    if ($w32tTop.Count -eq 1) { $w32tPrimary = $w32tTop[0]; $w32tReason = $w32tPrimary.Why }
    elseif ($w32tTop.Count -gt 1) { $w32tReason = 'Ambiguous' }

    $w32tCo = New-Object System.Collections.ArrayList
    $w32tUn = New-Object System.Collections.ArrayList
    foreach ($w32tE in $w32tRanked) {
        if ($null -ne $w32tPrimary -and [object]::ReferenceEquals($w32tE, $w32tPrimary)) { continue }
        # Installed alongside the primary: inside a folder the capture created (a new root). Without a primary nothing is
        # "alongside"; a Microsoft entry of a non-Microsoft package is guest noise (Edge, OneDrive), never co-installed.
        $w32tIn = $null -ne $w32tPrimary -and (& $w32tScRootOf $w32tE.Candidate) -and -not ((& $w32tScStr $w32tE.Candidate 'Publisher') -like 'Microsoft*' -and -not $w32tMsAllowed)
        $w32tItem = @{ Key = $w32tE.Key; View = $w32tE.View }
        if ($w32tIn) { [void]$w32tCo.Add($w32tItem) } else { [void]$w32tUn.Add($w32tItem) }
    }
    $w32tSameKey = $false
    if ($null -ne $w32tPrimary) { foreach ($w32tK in $w32tOwnKeys) { if (& $w32tScSame $w32tK $w32tPrimary.Key) { $w32tSameKey = $true } } }
    $w32tResult = @{ Primary = ''; PrimaryView = ''; Rank = ''; Reason = $w32tReason; SameKey = $w32tSameKey; CoInstalled = @($w32tCo.ToArray()); Unattributed = @($w32tUn.ToArray()) }
    if ($null -ne $w32tPrimary) { $w32tResult.Primary = $w32tPrimary.Key; $w32tResult.PrimaryView = $w32tPrimary.View; $w32tResult.Rank = $w32tPrimary.Rank }
    return $w32tResult
}
'@
    return ($text -replace "`r`n", "`n")
}
