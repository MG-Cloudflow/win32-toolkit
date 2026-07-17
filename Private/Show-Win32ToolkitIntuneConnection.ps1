function Show-Win32ToolkitIntuneConnection {
    <#
    .SYNOPSIS
        TUI screen: see the current Microsoft Intune connection, connect (per template), or sign out.
    .DESCRIPTION
        Exists so the tenant you are about to write to is something you can SEE and choose, instead of
        a side effect of whatever you were connected to last. See knowledge-base/designs/tui.md.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BasePath)

    while ($true) {
        Clear-Host
        Write-SpectreRule -Title 'Microsoft Intune connection' -Color Blue

        Show-Win32ToolkitTenantBanner

        # NOT [bool](try { ... } catch { ... }): try/catch is a STATEMENT. Assigning from one is fine,
        # but wrapping it in ( ) makes PowerShell parse 'try' as a COMMAND NAME. That still parses, so
        # a syntax check passes, and it only fails at runtime with "The term 'try' is not recognized".
        $ctxNow    = try { Get-MgContext } catch { $null }
        $connected = [bool]$ctxNow

        $choices = [System.Collections.Generic.List[object]]::new()
        $choices.Add([pscustomobject]@{ Key = 'connect'; Label = 'Connect using an org template''s tenant' })
        $choices.Add([pscustomobject]@{ Key = 'tenant';  Label = 'Connect to a tenant by id or domain' })
        if ($connected) { $choices.Add([pscustomobject]@{ Key = 'disconnect'; Label = 'Sign out' }) }
        $choices.Add([pscustomobject]@{ Key = 'back'; Label = 'Back to the main menu' })

        $sel = Read-SpectreSelection -Message 'Intune connection' -Choices $choices -ChoiceLabelProperty 'Label' -Color Blue

        switch ($sel.Key) {
            'connect' {
                $templatesDir = (Get-Win32ToolkitPaths -BasePath $BasePath).Templates
                $files = if (Test-Path $templatesDir) { @(Get-ChildItem $templatesDir -Filter *.json -ErrorAction SilentlyContinue) } else { @() }
                if ($files.Count -eq 0) {
                    Write-SpectreHost '[yellow]No org templates yet. Create one first, and pin its tenant.[/]'
                    Read-SpectrePause -AnyKey | Out-Null; break
                }
                $lookup = [ordered]@{}
                $labels = foreach ($f in $files) {
                    $t = try { Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
                    if (-not $t) { continue }
                    $pin = if ($t.PSObject.Properties['TenantId'] -and $t.TenantId) { $t.TenantId } else { 'not pinned' }
                    $label = Get-SpectreEscapedText -Text ("{0}  ({1})" -f $t.TemplateName, $pin)
                    $lookup[$label] = $t
                    $label
                }
                $chosen = Read-SpectreSelection -Message 'Which customer?' -Choices @($labels) -Color Blue -PageSize 12
                $tpl = $lookup[$chosen]
                if ($tpl) {
                    try { Connect-Win32ToolkitIntune -Template $tpl.TemplateName -BasePath $BasePath | Out-Null }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Connect failed' -Border Rounded -Color Red }
                }
                Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
            }
            'tenant' {
                $t = Read-SpectreText -Message 'Tenant id or domain'
                if ($t) {
                    try { Connect-Win32ToolkitIntune -TenantId $t.Trim() | Out-Null }
                    catch { Format-SpectrePanel -Data "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" -Header 'Connect failed' -Border Rounded -Color Red }
                }
                Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
            }
            'disconnect' {
                try { Disconnect-Win32ToolkitIntune -Confirm:$false | Out-Null }
                catch { Write-SpectreHost "[red]$(Get-SpectreEscapedText -Text $_.Exception.Message)[/]" }
                Read-SpectrePause -Message 'Press any key to continue' -AnyKey | Out-Null
            }
            'back'  { return }
            default { return }
        }
    }
}
