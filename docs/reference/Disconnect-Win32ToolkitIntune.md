# Disconnect-Win32ToolkitIntune

## SYNOPSIS
Signs out of Microsoft Intune (Entra) for this toolkit's Graph session.

## SYNTAX

```
Disconnect-Win32ToolkitIntune [-ProgressAction <ActionPreference>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Clears the Microsoft Graph token this session was using, so the next publish must sign in again
rather than silently reusing whichever customer you were last connected to.

BE CLEAR ABOUT WHAT THIS DOES NOT DO.
It signs out of the Graph SDK, not out of Entra.
Your
BROWSER (or Windows account manager) is still signed in, so the next connect can complete with no
prompt and land straight back on the same tenant.
That is a property of the identity provider, not
something this command can revoke.

So do not treat disconnect as the thing that keeps customers apart.
The controls that actually do
that are pinning a tenant on the org template (which publish then verifies and refuses to violate)
and connecting with -ContextScope Process so no token outlives the session.
This command is an
honest convenience, not a security boundary.

## EXAMPLES

### EXAMPLE 1
```
Disconnect-Win32ToolkitIntune
```

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

### [pscustomobject] Disconnected (bool) / TenantId / DisplayName of the session that was ended.
## NOTES

## RELATED LINKS
