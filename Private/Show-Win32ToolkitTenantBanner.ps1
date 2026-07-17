function Show-Win32ToolkitTenantBanner {
    <#
    .SYNOPSIS
        Prints WHICH TENANT the current Graph session is for.

    .DESCRIPTION
        The tenant NAME leads, deliberately, and is the largest thing on screen. The account is shown
        but never alone: a consultant's UPN (mg@cloudflow.be) reads identically in every customer
        tenant they are a guest in, so an account line answers "who am I" while leaving "whose Intune
        am I about to write to" unanswered. The tenant answers both.

        Read-only. Never blocks.
    #>
    [CmdletBinding()]
    param(
        # Show the org template's pinned tenant alongside, and whether it matches.
        [string]$ExpectedTenantId,
        [string]$TemplateName
    )

    $ctx = try { Get-MgContext } catch { $null }
    if (-not $ctx) {
        if (Get-Command Write-SpectreHost -ErrorAction SilentlyContinue) {
            Write-SpectreHost '[grey]Not connected to Microsoft Intune.[/]'
        } else {
            Write-Host 'Not connected to Microsoft Intune.' -ForegroundColor DarkGray
        }
        return
    }

    $info  = Get-Win32ToolkitTenantInfo
    $name  = if ($info -and $info.DisplayName) { $info.DisplayName } else { '(name unavailable)' }
    $dom   = if ($info -and $info.DefaultDomain) { $info.DefaultDomain } else { '' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Tenant    : $name")
    if ($dom) { $lines.Add("Domain    : $dom") }
    $lines.Add("Tenant ID : $($ctx.TenantId)")
    $lines.Add("Account   : $($ctx.Account)")
    if ($TemplateName) {
        $match = if (-not $ExpectedTenantId) { 'not pinned' }
                 elseif ("$($ctx.TenantId)" -ieq "$ExpectedTenantId") { 'matches' }
                 else { "MISMATCH - template expects $ExpectedTenantId" }
        $lines.Add("Template  : $TemplateName ($match)")
    }
    $lines.Add("Scopes    : $(@($ctx.Scopes) -join ', ')")
    $lines.Add("Session   : $($ctx.ContextScope) / $($ctx.AuthType)")

    $body = $lines -join "`n"
    if (Get-Command Format-SpectrePanel -ErrorAction SilentlyContinue) {
        $colour = if ($ExpectedTenantId -and "$($ctx.TenantId)" -ine "$ExpectedTenantId") { 'Red' } else { 'Blue' }
        Format-SpectrePanel -Data (Get-SpectreEscapedText -Text $body) -Header "Microsoft Intune connection" -Border Rounded -Color $colour
    } else {
        Write-Host $body -ForegroundColor Cyan
    }
}
