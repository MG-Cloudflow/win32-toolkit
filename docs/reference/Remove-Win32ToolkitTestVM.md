# Remove-Win32ToolkitTestVM

## SYNOPSIS
Tears down the Hyper-V test VM (stop, remove checkpoints + VM, optionally delete the VHDX).

## SYNTAX

```
Remove-Win32ToolkitTestVM [[-Name] <String>] [-RemoveVhdx] [-ProgressAction <ActionPreference>] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
HOST-ONLY cleanup.
Turns the VM off, removes all its checkpoints and the VM config, and - with
-RemoveVhdx - deletes its virtual disks.
Each step is best-effort so partial state still cleans.

The removal holds the test VM's lease, the lock every win32-toolkit process takes before it changes the VM:
while another PowerShell session uses the VM it waits, up to HyperVLeaseWaitMinutes (default 60), and then
stops with the error W32T.HyperVLeaseTimeout before anything is removed.

## EXAMPLES

### Example 1
```powershell
PS C:\> {{ Add example code here }}
```

{{ Add example description here }}

## PARAMETERS

### -Name
VM name (default: the session's test VM: W32T_HYPERV_VM, else the stored HyperVVMName, else 'win32tk-golden').

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: ((Get-Win32ToolkitHyperVTarget).VMName)
Accept pipeline input: False
Accept wildcard characters: False
```

### -RemoveVhdx
Also delete the VM's VHDX file(s).

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

## NOTES

## RELATED LINKS
