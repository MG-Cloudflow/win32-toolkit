# Disconnect-Win32ToolkitIntune

## SYNOPSIS
Signs out of the Intune session that win32-toolkit uses.

## SYNTAX

```
Disconnect-Win32ToolkitIntune [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Disconnect-Win32ToolkitIntune ends the Microsoft Graph session that win32-toolkit uses for
Intune, and prints the tenant that you signed out of.
The next connect or publish starts a new
sign-in.

Use it when you finish the work for a customer.
In the menu: Microsoft Intune connection \>
Sign out.
The menu shows Sign out only when you are connected.

Your browser stays signed in to Microsoft Entra, so the next connect may not ask you to sign
in.
It can land on the same tenant again.
Signing out is a convenience, not a safety control.
The tenant ID on each org template keeps customers apart.
Also, by default a sign-in with
Connect-Win32ToolkitIntune ends when you close the PowerShell window.

If you are not connected, the command prints "Not connected to Microsoft Intune." and changes
nothing.
If the sign-out fails, it shows a warning that starts with "Disconnect failed:" and
does not stop.

## EXAMPLES

### EXAMPLE 1
```
Disconnect-Win32ToolkitIntune
```

This signs out and prints the tenant.
Your browser stays signed in.

### EXAMPLE 2
```
Disconnect-Win32ToolkitIntune -WhatIf
```

This shows the tenant that the command would sign out of, and changes nothing.

## PARAMETERS

### -WhatIf
Shows what would happen if the cmdlet runs.
The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

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

### An object with Disconnected, TenantId and DisplayName.
### Disconnected is False when you were not connected, when the sign-out failed, or with -WhatIf.
## NOTES

## RELATED LINKS

[https://win32toolkit.com/reference/Disconnect-Win32ToolkitIntune/](https://win32toolkit.com/reference/Disconnect-Win32ToolkitIntune/)

[https://win32toolkit.com/intune-connection/](https://win32toolkit.com/intune-connection/)

