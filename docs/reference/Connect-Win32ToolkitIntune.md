# Connect-Win32ToolkitIntune

## SYNOPSIS
Signs in to Intune and shows which tenant you are connected to.

## SYNTAX

```
Connect-Win32ToolkitIntune [[-TenantId] <String>] [[-Template] <String>] [[-ContextScope] <String>]
 [-UseDeviceAuthentication] [[-Scopes] <String[]>] [[-BasePath] <String>] [-Force]
 [<CommonParameters>]
```

## DESCRIPTION
Connect-Win32ToolkitIntune signs you in to Microsoft Intune and shows a banner with the tenant
name, the tenant ID and your account.
You see the tenant before anything is written.
If you
are already signed in to that tenant, the command uses that sign-in.
If your account may not
read the tenant name, the banner shows "(name unavailable)" and the tenant ID.

Use it before you publish, and always when you work for more than one customer.
Publishing
can sign in by itself, but it then saves the sign-in on disk.
In the menu: Microsoft Intune
connection \> Connect using an org template's tenant.

The command writes nothing to Intune.
By default the sign-in is kept in this PowerShell window
only.
If the sign-in lands on another tenant than the one you asked for, the command signs you
out again and stops.

Use the tenant ID, not a domain name.
win32-toolkit compares tenant IDs, so a domain name never
matches.

## EXAMPLES

### EXAMPLE 1
```
Connect-Win32ToolkitIntune -Template 'Contoso'
```

This signs in to the tenant ID saved on the Contoso org template and shows the tenant banner.

### EXAMPLE 2
```
Connect-Win32ToolkitIntune -TenantId '11111111-2222-3333-4444-555555555555'
```

This signs in to one tenant by its tenant ID, without an org template.

### EXAMPLE 3
```
Connect-Win32ToolkitIntune -Template 'Contoso' -UseDeviceAuthentication
```

This signs in with a device code, on a PC without a browser.

### EXAMPLE 4
```
Connect-Win32ToolkitIntune -Template 'Contoso' -Force -ErrorAction Stop
```

This is the form for scripts.
A connect error does not stop a script unless you add
-ErrorAction Stop.

## PARAMETERS

### -TenantId
The tenant ID to connect to.
If you also give -Template, this value wins.

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
The org template whose tenant ID you connect to.
This is the recommended way to connect.
If
the template has no tenant ID, the command warns and signs in without one.

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
Where the sign-in is kept.
Default: Process (this PowerShell window only).
Use CurrentUser only
if you work for one tenant: the sign-in is then saved on disk for later windows.

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
Signs in with a code that you enter on a web page on any device.
Use it when this PC has no
browser, or when the browser keeps signing in to the wrong tenant.

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
The Graph permissions to ask for.
Default: DeviceManagementApps.ReadWrite.All.
Leave it
unchanged.

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
The base folder to read the org template from, for this command only.
Default: your saved base
folder.

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
Installs the Microsoft.Graph.Authentication module without asking.
Use it in scripts.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### An object with TenantId, DisplayName, Account and Scopes.
### If the connect fails, the command returns nothing.
### The error that it writes starts with "Connect failed:".
## NOTES

## RELATED LINKS

[https://win32toolkit.com/reference/Connect-Win32ToolkitIntune/](https://win32toolkit.com/reference/Connect-Win32ToolkitIntune/)

[https://win32toolkit.com/intune-connection/](https://win32toolkit.com/intune-connection/)

