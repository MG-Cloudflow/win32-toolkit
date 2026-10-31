# Set-Win32ToolkitTestVMResource

## SYNOPSIS
Changes the processors and memory of the Hyper-V test VM and takes a new clean checkpoint.

## SYNTAX

```
Set-Win32ToolkitTestVMResource [[-ProcessorCount] <Int32>] [[-MemoryStartupBytes] <UInt64>] [[-Name] <String>]
 [[-CheckpointName] <String>] [[-Credential] <PSCredential>] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
Set-Win32ToolkitTestVMResource changes the processors, the memory, or both, of the Hyper-V
test VM.
It turns the VM off and deletes all its checkpoints, including the ones you made
yourself.
Then it changes the hardware and starts the VM.
At the signed-in desktop, it takes a
new clean-base checkpoint: the saved state for every test.

Use it when tests are slow or an installer needs more memory.
Reset the VM first with
Reset-Win32ToolkitTestVM: the new checkpoint keeps every disk change since the last reset.
In
the menu: Settings \> Hyper-V test VM \> Change VM resources.

It does not ask for confirmation and changes nothing in Intune.
It saves the new values as
the defaults for New-Win32ToolkitTestVM (not for a VM pinned with W32T_HYPERV_VM).

It stops before any change when a value is outside its limits, or when it has no VM password.
If the desktop does not appear within 10 minutes, the VM has no clean-base checkpoint.
Repair
it in the menu: Configure guest AutoLogon + re-checkpoint.
W32T.HyperVLeaseTimeout means that
another PowerShell window kept the VM too long.

## EXAMPLES

### EXAMPLE 1
```
Set-Win32ToolkitTestVMResource -ProcessorCount 4 -MemoryStartupBytes 8GB
```

This gives the test VM 4 processors and 8 GB of memory.
It deletes the checkpoints of the VM
and takes a new clean-base checkpoint.

### EXAMPLE 2
```
Set-Win32ToolkitTestVMResource -MemoryStartupBytes 6GB
```

This changes only the memory.
The number of processors stays the same.

### EXAMPLE 3
```
Reset-Win32ToolkitTestVM; Set-Win32ToolkitTestVMResource -MemoryStartupBytes 8GB
```

This puts the VM back to its clean checkpoint first, then gives it 8 GB of memory.
The new
checkpoint keeps no changes from earlier tests or from your own work.

### EXAMPLE 4
```
Set-Win32ToolkitTestVMResource -ProcessorCount 4 -WhatIf
```

This shows the current and the new size of the VM, and changes nothing.

## PARAMETERS

### -ProcessorCount
The new number of virtual processors, from 1 to 64 and not more than your PC has.
Without it,
the processors stay as they are.
Give -ProcessorCount, -MemoryStartupBytes or both.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -MemoryStartupBytes
The new memory of the VM, for example 8GB.
It must be at least 2 GB, and at most the memory of
your PC minus 2 GB.
Without it, the memory stays as it is.

```yaml
Type: UInt64
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Name
The VM to change.
Default: the VM in the W32T_HYPERV_VM environment variable if it is set,
else your saved test VM (win32tk-golden unless you chose another name).

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -CheckpointName
The name of the new clean checkpoint.
Default: the name in the W32T_HYPERV_CHECKPOINT
environment variable if it is set, else your saved checkpoint name (clean-base unless you
chose another name).

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Credential
The user name and password of the administrator account in the VM.
The command uses them to
check the desktop before the new checkpoint.
Default: the password that the toolkit saved for
the VM.
Use it when no password is saved.

```yaml
Type: PSCredential
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
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

### The VM object from Hyper-V, as Get-VM shows it.
### If the VM already has the values you give, the command says so and returns the VM unchanged.
### Otherwise -WhatIf returns nothing.
## NOTES
Needs: PowerShell 7 run as administrator.
Time: a few minutes.
Only one PowerShell window at a
time can use the test VM.

## RELATED LINKS

[https://win32toolkit.com/reference/Set-Win32ToolkitTestVMResource/](https://win32toolkit.com/reference/Set-Win32ToolkitTestVMResource/)

[https://win32toolkit.com/hyperv-vm-care/](https://win32toolkit.com/hyperv-vm-care/)

