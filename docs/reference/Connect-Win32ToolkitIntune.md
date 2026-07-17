# Connect-Win32ToolkitIntune

## SYNOPSIS
Signs in to Microsoft Intune (Entra) and shows which tenant you are connected to.

## SYNTAX

```
Connect-Win32ToolkitIntune [[-TenantId] <String>] [[-Template] <String>] [[-ContextScope] <String>]
 [-UseDeviceAuthentication] [[-Scopes] <String[]>] [[-BasePath] <String>] [-Force]
 [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

## DESCRIPTION
Publishing already connects on demand, so this exists for the two things that flow could not do:
choose the tenant up front, and SEE which one you are on before anything is written.

That matters when you package for several customers.
The signed-in account is not identity: your
UPN looks the same in every tenant you are a guest in.
The tenant is what decides whose Intune
receives the app, so this command leads with the tenant name.

Pass -Template to connect to the tenant pinned on an org template.
That is the recommended way:
the same pin is then enforced at publish time, and a session for the wrong tenant is refused
rather than used.

The toolkit requests the least privilege it needs (DeviceManagementApps.ReadWrite.All).
The tenant
NAME shown in the banner comes from a directory read that your account may or may not be allowed;
when it is not, the GUID is shown instead and nothing else changes.

## EXAMPLES

### EXAMPLE 1
```
Connect-Win32ToolkitIntune -Template 'Contoso'
Connects to the tenant pinned on the Contoso template and prints the connection banner.
```

### EXAMPLE 2
```
Connect-Win32ToolkitIntune -TenantId 'contoso.onmicrosoft.com' -ContextScope CurrentUser
Connects to a named tenant and keeps the token for later sessions.
```

## PARAMETERS

### -TenantId
Tenant to connect to (GUID or domain).
The connection is verified afterwards: if it lands on a
different tenant, the command throws instead of leaving you signed in to the wrong one.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Template
Org template whose pinned TenantId to use.
Ignored if -TenantId is given.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ContextScope
'Process' (default) keeps the token in this session only.
'CurrentUser' caches it on disk for
later sessions, which is convenient for one tenant and risky across several.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: Process
Accept pipeline input: False
Accept wildcard characters: False
```

### -UseDeviceAuthentication
Use the device-code flow (no browser on this host).

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -Scopes
Override the requested delegated permissions.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: @('DeviceManagementApps.ReadWrite.All')
Accept pipeline input: False
Accept wildcard characters: False
```

### -BasePath
Base folder (registry-backed default), used to find the template.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Force
Install the Microsoft.Graph.Authentication prerequisite without prompting.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProgressAction
{{ Fill ProgressAction Description }}

```yaml
Type: ActionPreference
Parameter Sets: (All)
Aliases: proga

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### [pscustomobject] TenantId / DisplayName / Account / Scopes.
## NOTES

## RELATED LINKS
