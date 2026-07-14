function Find-Win32ToolkitIntuneApp {
    <#
    .SYNOPSIS
        Finds published Win32 apps in the Intune tenant — by display name, by the winget id the toolkit
        stamps into `notes`, or simply lists them (for the TUI "pick a dependency from Intune" picker).
    .DESCRIPTION
        The dependency target of a mobileAppDependency must be an existing win32LobApp, referenced by its
        Intune app id — so a declared dependency has to be looked up in the tenant before it can be
        related. This is the module's only tenant read.

        Two subtleties:

        * ODATA STRING ESCAPING — a single quote in a $filter must be DOUBLED ('O''Reilly'). The repo
          already carries hostile apostrophe fixtures, and a naive filter breaks (or worse, injects) on
          an app called "O'Reilly Toolkit".

        * THE '(Update)' TWIN — the toolkit publishes an optional second "<name> (Update)" app whose
          requirement rule restricts it to devices that ALREADY have the app. Depending on that would
          produce a dependency that can never be satisfied on a clean device, so it is always excluded.
          Toolkit-published apps are identifiable by the `notes` stamp: 'win32-toolkit; [update;] [<wingetId>]'.
    .PARAMETER DisplayName
        Exact display name to match (server-side $filter).
    .PARAMETER WingetId
        Match the winget id the toolkit stamped into `notes` (client-side — `notes` is not reliably
        filterable server-side).
    .PARAMETER All
        Return every Win32 app (used by the TUI picker).
    .PARAMETER BaseUri
        Graph base. Defaults to the /beta deviceAppManagement root used elsewhere.
    .OUTPUTS
        PSCustomObject[]: Id, DisplayName, DisplayVersion, Publisher, Notes. Empty array if nothing matched.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [string]$DisplayName,
        [string]$WingetId,
        [switch]$All,
        [string]$BaseUri = 'https://graph.microsoft.com/beta/deviceAppManagement'
    )

    $select = 'id,displayName,displayVersion,publisher,notes'
    $uri    = "$BaseUri/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')&`$select=$select"

    if ($DisplayName) {
        # OData: double every single quote. Without this, "O'Reilly" is a malformed (injectable) filter.
        $escaped = $DisplayName -replace "'", "''"
        $uri     = "$BaseUri/mobileApps?`$filter=isof('microsoft.graph.win32LobApp') and displayName eq '$escaped'&`$select=$select"
    }

    $found = [System.Collections.Generic.List[object]]::new()
    while ($uri) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
        foreach ($a in @($resp.value)) {
            $found.Add([pscustomobject]@{
                Id             = $a.id
                DisplayName    = $a.displayName
                DisplayVersion = $a.displayVersion
                Publisher      = $a.publisher
                Notes          = [string]$a.notes
            })
        }
        $uri = $resp.'@odata.nextLink'
    }

    # Never depend on the "(Update)" twin — its requirement rule gates it to devices that already have
    # the app, so as a dependency it could never be satisfied on a clean device.
    $result = @($found | Where-Object {
        -not ($_.DisplayName -like '* (Update)') -and ($_.Notes -notmatch '(^|;\s*)update(\s*;|$)')
    })

    if ($WingetId) {
        # `notes` carries 'win32-toolkit; <wingetId>' for toolkit-published apps — the only winget-id
        # breadcrumb that exists in the tenant. Match the whole segment, not a substring.
        $result = @($result | Where-Object {
            @($_.Notes -split ';' | ForEach-Object { $_.Trim() }) -contains $WingetId
        })
    }

    return @($result)
}
