function Get-Win32ToolkitPriorConflict {
    <#
    .SYNOPSIS
        Finds the tenant's Win32 apps that would fight a package which removes a prior install.
    .DESCRIPTION
        Installer-identity PR 3 (spec 2.11 Publish, D23, D29, L29, SV11). Called by Publish-Win32ToolkitIntuneApp after
        the sign-in and the tenant check, before the app shell is created, and only for a package with Enforce rules.
        One read of the tenant's Win32 apps (paged; the query is a constant, nothing captured is spliced into it):

            GET <BaseUri>/mobileApps?$filter=isof('microsoft.graph.win32LobApp')&$expand=assignments

        No $select: Graph checks $select against the BASE type microsoft.graph.mobileApp (isof() filters the collection,
        it does not cast it), and detectionRules is a win32LobApp property, so selecting it is a hard 400 ("Could not
        find a property named 'detectionRules' on type 'microsoft.graph.mobileApp'", the same live 400 as
        Find-Win32ToolkitIntuneApp's displayVersion) and the check would never run. Matched on the host:
          DetectsPrior         an app with a Required assignment whose registry detection rule's keyPath ends in
                               \Uninstall\<Key> (either view, case-insensitive), or whose script detection, decoded,
                               contains \Uninstall\<Key>: it reinstalls the prior this package removes, so devices
                               fight (69110 after the first removal). The rules are detectionRules plus the
                               'detection' items of rules (a requirement rule never reinstalls anything);
          PredecessorRequired  an app this template's earlier versions of the app recorded in Intune\Publications.json
                               that still has a Required assignment: a version-equal tattoo makes it reinstall.
        Fail-open: a Graph error gives one result of Kind 'Unchecked' ("could not check ..."); Required apps whose listing
        carries no detection rule (the detection set above is empty: a property missing, an empty detectionRules, a rules
        list of requirement items only) give one more 'Unchecked' result that counts them and names the first 10 (display
        name and id) for the operator to check by hand. An Intune Win32 app needs a detection rule (Publish refuses none
        without -AllowNoDetectionRule), so an empty set means the listing did not carry them. The publish goes on.
        Display names and ids pass ConvertTo-Win32ToolkitSafeText.
    .PARAMETER ProjectPath
        The PSADT project folder being published.
    .PARAMETER BaseUri
        The Graph deviceAppManagement root.
    .PARAMETER MaxPages
        At most this many pages are read (a warning names a cut-off list).
    .OUTPUTS
        [pscustomobject[]] Kind (DetectsPrior | PredecessorRequired | Unchecked), AppId, DisplayName, Key, Message.
    .EXAMPLE
        foreach ($c in @(Get-Win32ToolkitPriorConflict -ProjectPath $p)) { Write-Warning $c.Message }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [string]$BaseUri = 'https://graph.microsoft.com/beta/deviceAppManagement',

        [ValidateRange(1, 1000)]
        [int]$MaxPages = 50
    )

    $safe = { param($Value, [int]$Max = 256) ConvertTo-Win32ToolkitSafeText -Text ([string]$Value) -MaxLength $Max }
    $prop = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } return $null }
        if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
        return $null
    }
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $cfg = Get-Win32ToolkitAppConfig -ProjectPath $ProjectPath
        $keys = @(@(& $prop (& $prop $cfg 'PriorInstalls') 'Entries') | Where-Object { $null -ne $_ -and [string](& $prop $_ 'Mode') -ceq 'Enforce' } |
                ForEach-Object { [string](& $prop $_ 'Key') } | Where-Object { $_ } | Select-Object -Unique)
        if ($keys.Count -eq 0) { return [object[]]@() }

        # The earlier versions of this app in the same template that recorded a publication.
        $predecessorIds = @{}
        $app = & $prop $cfg 'App'
        $display = [string](& $prop $app 'DisplayName'); if (-not $display) { $display = [string](& $prop $app 'Name') }
        $prev = Get-Win32ToolkitPreviousProject -TemplateDirectory (Split-Path -Path $ProjectPath.TrimEnd('\') -Parent) -Version ([string](& $prop $app 'Version')) -WingetId ([string](& $prop (& $prop $cfg 'Source') 'WingetId')) `
            -Vendor ([string](& $prop $app 'Vendor')) -DisplayName $display -ExcludePath $ProjectPath.TrimEnd('\')
        foreach ($m in @(@($prev.Matches) | Where-Object { $_.Published })) {
            foreach ($pub in @(Get-Win32ToolkitPublication -ProjectPath $m.Path)) {
                $aid = [string](& $prop $pub 'AppId')
                if ($aid -match '^[0-9a-fA-F-]{36}$') { $predecessorIds[$aid.ToLowerInvariant()] = $m.Name }
            }
        }

        # No $select (see the help): detectionRules is a win32LobApp property, and $select is checked against mobileApp.
        $uri = "$BaseUri/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')&`$expand=assignments"
        $apps = [System.Collections.Generic.List[object]]::new()
        $pages = 0
        while ($uri -and $pages -lt $MaxPages) {
            $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
            $pages++
            foreach ($a in @(& $prop $resp 'value')) { if ($null -ne $a) { $apps.Add($a) } }
            $next = [string](& $prop $resp '@odata.nextLink')
            # Only Graph's own continuation links are followed.
            $uri = if ($next -and $next.StartsWith('https://graph.microsoft.com/', [StringComparison]::OrdinalIgnoreCase)) { $next } else { $null }
        }
        if ($uri) { Write-Warning "Only the first $MaxPages page(s) of the tenant's Win32 apps were checked for apps that detect the prior install." }

        # The Required apps whose detection rules the listing did not carry, as "'<name>' (<id>)", in listing order.
        $unreadable = [System.Collections.Generic.List[string]]::new()
        $namedCap = 10
        foreach ($a in $apps) {
            $id = [string](& $prop $a 'id')
            $name = & $safe (& $prop $a 'displayName') 128
            $required = @(@(& $prop $a 'assignments') | Where-Object { $null -ne $_ -and [string](& $prop $_ 'intent') -eq 'required' }).Count -gt 0
            if (-not $required) { continue }
            if ($id -and $predecessorIds.ContainsKey($id.ToLowerInvariant())) {
                $results.Add([pscustomobject]@{ Kind = 'PredecessorRequired'; AppId = $id; DisplayName = $name; Key = ''
                        Message = "Intune app '$name' ($id), published from $(& $safe $predecessorIds[$id.ToLowerInvariant()] 128), is still assigned Required: unassign it before you assign this one, or a version-equal tattoo makes the old app reinstall." })
            }
            # The detection set: detectionRules, plus the detection items of the newer rules list (its requirement rules
            # decide where the app applies and never reinstall anything). Every Intune Win32 app has at least one
            # detection rule, so an empty set (no property, an empty list, requirement items only) means the listing did
            # not carry them: the app cannot be checked, and is named in the 'could not read' result.
            $rules = @(@(& $prop $a 'detectionRules') + @(@(& $prop $a 'rules') | Where-Object { $null -ne $_ -and [string](& $prop $_ 'ruleType') -eq 'detection' }) |
                    Where-Object { $null -ne $_ })
            if ($rules.Count -eq 0) { $unreadable.Add("'$name' ($(& $safe $id 64))"); continue }
            foreach ($key in $keys) {
                $needle = "\Uninstall\$key"
                $hit = $false
                foreach ($r in $rules) {
                    $type = [string](& $prop $r '@odata.type')
                    $keyPath = [string](& $prop $r 'keyPath')
                    if ($keyPath -and $keyPath.TrimEnd('\').EndsWith($needle, [StringComparison]::OrdinalIgnoreCase)) { $hit = $true; break }
                    $script = [string](& $prop $r 'scriptContent')
                    if ($type -match 'PowerShellScript' -and $script) {
                        $text = ''
                        try { $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script)) }
                        catch { $text = '' }
                        if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
                    }
                }
                if ($hit) {
                    $results.Add([pscustomobject]@{ Kind = 'DetectsPrior'; AppId = $id; DisplayName = $name; Key = $key
                            Message = "Intune app '$name' ($id) detects the prior install $(& $safe $key) and is assigned Required: devices will fight - this package removes it, that app reinstalls it (69110 after the first removal). Unassign or retire it first." })
                }
            }
        }
        if ($unreadable.Count -gt 0) {
            $named = @($unreadable | Select-Object -First $namedCap) -join ', '
            if ($unreadable.Count -gt $namedCap) { $named += " and $($unreadable.Count - $namedCap) more" }
            $results.Add([pscustomobject]@{ Kind = 'Unchecked'; AppId = ''; DisplayName = ''; Key = ''
                    Message = "Could not read the detection rules of $($unreadable.Count) Required Win32 app(s) of the tenant (the listing did not include them): $named. Check by hand that none of them reinstalls the prior install $((@($keys | ForEach-Object { & $safe $_ }) -join ', '))." })
        }
        return [object[]]$results.ToArray()
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        return [object[]]@([pscustomobject]@{ Kind = 'Unchecked'; AppId = ''; DisplayName = ''; Key = ''
                Message = "Could not check the tenant for apps that detect the prior install ($(& $safe $_.Exception.Message 200)): make sure no Required app reinstalls it." })
    }
}
