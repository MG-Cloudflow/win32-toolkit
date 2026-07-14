function Set-Win32ToolkitAppRelationships {
    <#
    .SYNOPSIS
        Attaches mobileAppDependency relationships to a published Win32 app, WITHOUT destroying the app's
        existing relationships.
    .DESCRIPTION
        Intune has no "add one dependency" API. The only write is

            POST /beta/deviceAppManagement/mobileApps/{id}/updateRelationships   -> 204
            { "relationships": [ { "@odata.type": "#microsoft.graph.mobileAppDependency",
                                   "targetId": "<guid>", "dependencyType": "autoInstall" } ] }

        and it is a SET operation across BOTH dependencies AND supersedence. Posting only the new
        dependency therefore SILENTLY DELETES every supersedence rule an admin configured in the portal.
        So this is always read -> merge -> write.

        THREE traps this function exists to avoid:

        1. SUPERSEDENCE WIPE — see above. Existing relationships are read back and re-posted alongside ours.

        2. THE targetType='parent' TRAP — GET /relationships returns BOTH directions. Rows with
           targetType 'parent' are INBOUND (other apps that depend on / supersede THIS one). Re-posting
           them yields "A circular dependency was created while adding app relationships". We keep ONLY
           targetType 'child'. (This is the open bug in the community IntuneWin32App module, issue #171.)

        3. THE SINGLE-ELEMENT JSON COLLAPSE — ConvertTo-Json renders a 1-element array as a bare object,
           which Graph rejects with "Expected array for value of property: Collection(...)". The one
           dependency case IS the main use case, so the array is forced and asserted in tests.

        Only @odata.type / targetId / dependencyType are sent. Every other property on the relationship
        (targetType, sourceId, targetDisplayName, id, ...) is read-only; echoing them back is what
        produces the malformed / circular errors.
    .PARAMETER AppId
        The PARENT app — the one that NEEDS the dependencies.
    .PARAMETER Dependency
        Objects with TargetId + DependencyType ('autoInstall' | 'detect'). Pass an empty array to clear
        the app's dependencies (existing supersedence is still preserved).
    .PARAMETER BaseUri
        Graph base. Defaults to the /beta deviceAppManagement root the rest of the module uses.
    .OUTPUTS
        [int] the number of dependency relationships now attached.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AppId,

        [object[]]$Dependency = @(),

        [string]$BaseUri = 'https://graph.microsoft.com/beta/deviceAppManagement'
    )

    foreach ($d in @($Dependency)) {
        if ($d.TargetId -eq $AppId) { throw "An app cannot depend on itself (app id $AppId)." }
    }

    # ── READ ───────────────────────────────────────────────────────────────────────────────────────
    $existing = @()
    try {
        $resp = Invoke-MgGraphRequest -Method GET -Uri "$BaseUri/mobileApps/$AppId/relationships" -OutputType PSObject
        if ($resp -and $resp.value) { $existing = @($resp.value) }
    }
    catch {
        throw "Could not read the existing relationships of app $AppId (they must be preserved, or supersedence would be destroyed): $($_.Exception.Message)"
    }

    # ── MERGE ──────────────────────────────────────────────────────────────────────────────────────
    # AUTHORITY MODEL: the project's declared dependencies are the TRUTH for DEPENDENCIES — existing
    # dependency rows are replaced, so removing a dependency from the project actually removes it from
    # Intune on the next publish (otherwise a stale dependency could never be deleted). SUPERSEDENCE is
    # NOT managed by the toolkit, so it is read back and re-posted verbatim; dropping it here is what
    # would silently destroy an admin's supersedence configuration.
    $rels = [System.Collections.Generic.List[object]]::new()

    foreach ($e in $existing) {
        # Keep ONLY outbound rows. Inbound ('parent') rows re-posted => "circular dependency" error.
        if ($e.targetType -ne 'child') { continue }
        if ([string]$e.'@odata.type' -notmatch 'mobileAppSupersedence') { continue }

        $rels.Add([ordered]@{
            '@odata.type'      = '#microsoft.graph.mobileAppSupersedence'
            'targetId'         = $e.targetId
            'supersedenceType' = $e.supersedenceType
        })
    }

    # Dedupe our own declarations by targetId (a duplicate relationship is rejected by Graph).
    $seen = @{}
    foreach ($d in @($Dependency)) {
        if ($seen.ContainsKey($d.TargetId)) { continue }
        $seen[$d.TargetId] = $true
        $rels.Add([ordered]@{
            '@odata.type'    = '#microsoft.graph.mobileAppDependency'
            'targetId'       = $d.TargetId
            'dependencyType' = if ($d.DependencyType) { $d.DependencyType } else { 'autoInstall' }
        })
    }

    # ── WRITE ──────────────────────────────────────────────────────────────────────────────────────
    # [object[]] + -Depth: force a JSON ARRAY even for a single element (Graph rejects a bare object).
    $body = ConvertTo-Json -InputObject @{ relationships = [object[]]@($rels) } -Depth 6
    if ($body -notmatch '"relationships"\s*:\s*\[') {
        throw "Refusing to POST: the relationships payload did not serialize as a JSON array (Graph would reject it). Body: $body"
    }

    if (-not $PSCmdlet.ShouldProcess($AppId, "Set $($rels.Count) relationship(s) — $(@($Dependency).Count) dependency(ies)")) {
        return @($Dependency).Count
    }

    try {
        Invoke-MgGraphRequest -Method POST -Uri "$BaseUri/mobileApps/$AppId/updateRelationships" `
            -Body $body -ContentType 'application/json' | Out-Null
    }
    catch {
        # Never advise "re-publish": Publish always CREATES A NEW app (there is no update path), so that
        # would duplicate the app and leave the assigned one without its dependency.
        # Sync-Win32ToolkitAppDependency updates the app that is already in the tenant.
        $m   = $_.Exception.Message
        $fix = "The app IS published, just without its dependency relationship. Fix the cause, then run Sync-Win32ToolkitAppDependency -ProjectPath <project> to attach it to THIS app (do NOT re-publish — that creates a second app)."
        if ($m -match '403|Forbidden') {
            throw "Intune refused the relationship write (403). A correct Graph scope is not enough: your admin account also needs the Intune RBAC 'Relate' permission (Mobile apps category). $fix ($m)"
        }
        throw "Failed to attach dependencies to app $AppId. $fix ($m)"
    }

    return @($Dependency).Count
}
