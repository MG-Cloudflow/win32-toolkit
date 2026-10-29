# Remove-Win32ToolkitTestVM

## SYNOPSIS
Deletes the Hyper-V test VM and, if you ask, its disk files.

## SYNTAX

```
Remove-Win32ToolkitTestVM [[-Name] <String>] [-RemoveVhdx] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Remove-Win32ToolkitTestVM turns the Hyper-V test VM off and deletes its checkpoints and
the VM itself.
With -RemoveVhdx it also deletes the virtual disk files of the VM.
There is
no confirmation question, so check the VM name first or use -WhatIf.

Use it when you no longer need the VM.
You do not need it before a rebuild:
New-Win32ToolkitTestVM -Force deletes the old VM first.
In the menu: Settings \> Hyper-V
test VM \> Remove the test VM.
The menu asks first (the default answer is No) and always
deletes the disk files.

Your settings stay, including your default test machine.
If it is still the Hyper-V test VM,
tests warn that the VM is not found and use Windows Sandbox.
Set the default back to
Windows Sandbox in the menu.
After -RemoveVhdx, check the \<base folder\>\HyperV\Golden
folder: the base virtual disk can stay there, and you can delete it by hand.

If the VM does not exist, the command warns "VM '\<name\>' not found" and changes nothing.
W32T.HyperVLeaseTimeout means that another PowerShell window kept the VM for too long.

## EXAMPLES

### EXAMPLE 1
```
Remove-Win32ToolkitTestVM -RemoveVhdx
```

This deletes your test VM, its checkpoints and its disk files, without a question.
Check
the C:\Win32Apps\HyperV\Golden folder afterwards.

### EXAMPLE 2
```
Remove-Win32ToolkitTestVM
```

This deletes the VM and its checkpoints, and keeps the virtual disk files.

### EXAMPLE 3
```
Remove-Win32ToolkitTestVM -RemoveVhdx -WhatIf
```

This shows which VM the command would delete, and deletes nothing.

## PARAMETERS

### -Name
The VM to delete.
Default: the VM in the W32T_HYPERV_VM environment variable if it is set,
else your saved test VM (win32tk-golden unless you chose another name).

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

### -RemoveVhdx
Also deletes the virtual disk files that the VM uses.
Without it, the files stay on disk.
If you built the VM on your own virtual disk, this can delete your file.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### None. A line in green says that the VM was removed.
### If one step fails, the command does not stop and still shows the green line.
### If you are not sure, check with Get-VM.
## NOTES
Needs: PowerShell 7 run as administrator.
Time: seconds to a minute.
Only one PowerShell
window at a time can use the test VM.

## RELATED LINKS

[https://win32toolkit.com/reference/Remove-Win32ToolkitTestVM/](https://win32toolkit.com/reference/Remove-Win32ToolkitTestVM/)

[https://win32toolkit.com/hyperv-vm-care/](https://win32toolkit.com/hyperv-vm-care/)

