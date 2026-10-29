# New-Win32ToolkitTestVM

## SYNOPSIS
Builds the Hyper-V test VM once, from a Windows 11 ISO or your own virtual disk.

## SYNTAX

```
New-Win32ToolkitTestVM [[-IsoPath] <String>] [[-VhdxPath] <String>] [[-Name] <String>]
 [[-Credential] <PSCredential>] [[-MemoryStartupBytes] <UInt64>] [[-ProcessorCount] <Int32>]
 [[-SwitchName] <String>] [[-CheckpointName] <String>] [[-ImageIndex] <Int32>] [[-Edition] <String>]
 [[-EnableTPM] <Boolean>] [-Recheckpoint] [-Force] [-Unattended] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
New-Win32ToolkitTestVM builds the Hyper-V test VM, a Windows 11 virtual machine (VM) on
your PC, from a Windows 11 ISO or your own virtual disk.
Tests can then use it instead of
Windows Sandbox.

After the first start, the command opens the VM window if it can, and waits.
In the VM,
run Windows Update until nothing is left and let every restart finish.
Then press Enter in
PowerShell to take the checkpoint clean-base: a saved state of the signed-in desktop that
every test starts from.

In the menu: Settings \> Hyper-V test VM \> Provision the test VM from a Windows 11 ISO.
The
menu uses the default name and edition.
If a VM or its disk already exists, the menu asks
"Delete it and rebuild from scratch?" and the default answer is Yes.

From an ISO, the disk goes to \<base folder\>\HyperV\Golden\\\<name\>.vhdx.
Unless
W32T_HYPERV_VM pins this VM, the command saves the VM and checkpoint names, processors,
memory and password in your settings.
It does not make the VM your default test machine
and changes nothing in Intune.

## EXAMPLES

### EXAMPLE 1
```
New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso'
```

This builds the test VM from the ISO, asks for a user name and password, and pauses so
that you can update Windows in the VM.
It does not make the VM your default test machine.

### EXAMPLE 2
```
New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso' -MemoryStartupBytes 8GB
```

This builds the test VM with 8 GB of memory.
The command saves 8 GB as your default for
the next build.

### EXAMPLE 3
```
New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso' -Edition 'Enterprise'
```

This builds the test VM with the first Enterprise edition of the ISO.
If the ISO has no
Enterprise edition, the command takes the first edition and warns.

### EXAMPLE 4
```
New-Win32ToolkitTestVM -VhdxPath 'D:\VM\Win11-base.vhdx' -Credential (Get-Credential)
```

This builds the test VM on your own prepared disk: the VM runs on that file, not on a copy.
Get-Credential asks for the user name and password of the administrator account on the
disk.

### EXAMPLE 5
```
New-Win32ToolkitTestVM -IsoPath 'C:\ISO\Win11_x64.iso' -Force
```

This deletes the existing VM, its checkpoints and its disk, and builds them again from the
ISO.
It takes the full build time again.

## PARAMETERS

### -IsoPath
The Windows 11 x64 ISO file to build the VM from.
Give -IsoPath or -VhdxPath, not both.
A
path in double quotes, as Copy as path gives it, also works.

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

### -VhdxPath
Your own Windows virtual disk (.vhdx) to build the VM on.
It must start in a Generation 2
VM, with Windows setup done, a local administrator and automatic sign-in.
The VM uses and
changes this file, so copy it first if you need the original.
Command line only: the menu
does not offer this.

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

### -Name
The name of the VM in Hyper-V.
Default: win32tk-golden, even when your saved test VM has
another name.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: win32tk-golden
Accept pipeline input: False
Accept wildcard characters: False
```

### -Credential
The user name and password of the administrator account in the VM.
Without it, the
command asks: press Enter for the user name w32admin, then type the password twice.
The
password must not be blank.
Use a lab-only password: the VM stores it in clear text.

```yaml
Type: PSCredential
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -MemoryStartupBytes
The memory of the VM, for example 8GB.
The VM holds all of it while it runs.
Default: the
last value that this command or Set-Win32ToolkitTestVMResource saved, else 4 GB.
Give the
VM 6 to 8 GB if your PC has the memory.

```yaml
Type: UInt64
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: 4294967296
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProcessorCount
The number of virtual processors of the VM, from 1 to 64.
Default: the last value that
this command or Set-Win32ToolkitTestVMResource saved, else 2.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: 2
Accept pipeline input: False
Accept wildcard characters: False
```

### -SwitchName
The Hyper-V virtual switch that connects the VM to the network.
Default: Default Switch,
which shares the internet connection of your PC.
Use another switch only if your PC has no
Default Switch.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: Default Switch
Accept pipeline input: False
Accept wildcard characters: False
```

### -CheckpointName
The name of the clean checkpoint.
Default: clean-base.
Keep the default.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: clean-base
Accept pipeline input: False
Accept wildcard characters: False
```

### -ImageIndex
The number of the Windows edition in the ISO.
It wins over -Edition.
If the number does not
exist, the error lists every edition of the ISO with its number.
Command line only: the
menu does not offer this.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 9
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Edition
Part of the Windows edition name, for example 'Enterprise'.
Without it, the command tries
Windows 11 Pro, then Windows 10 Pro, then Enterprise, then Pro.
If nothing matches, it
takes the first edition of the ISO (this can be Home) and warns.
Command line only: the
menu does not offer this.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 10
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -EnableTPM
Adds a virtual Trusted Platform Module (TPM), the security chip that Windows 11 expects.
Default: $true.
Keep the default.

```yaml
Type: Boolean
Parameter Sets: (All)
Aliases:

Required: False
Position: 11
Default value: True
Accept pipeline input: False
Accept wildcard characters: False
```

### -Recheckpoint
This switch does not re-take the checkpoint of an existing VM.
Do not use it.
To re-take the
checkpoint, use the Hyper-V commands in the guide.
More: https://win32toolkit.com/hyperv-vm/#re-take-the-checkpoint

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

### -Force
Deletes an existing VM with this name and all its checkpoints, then builds the VM again.
With -IsoPath it also builds the virtual disk again.
Without -Force, an existing VM with
its checkpoint is used again, and the command saves the password you typed without
testing it.

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

### -Unattended
Takes the checkpoint right after the first start, with no pause to update Windows.
It opens
no VM window and does not check the internet in the VM.
Use it for automation only.
Command line only: the menu does not offer this.

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

### The VM object from Hyper-V, as Get-VM shows it.
## NOTES
Needs: PowerShell 7 run as administrator, and Hyper-V with its PowerShell module (Windows
Home does not have Hyper-V).
Time: about 30 to 60 minutes, plus Windows Update time.
Only
one PowerShell window at a time can use the test VM.

## RELATED LINKS

[https://win32toolkit.com/reference/New-Win32ToolkitTestVM/](https://win32toolkit.com/reference/New-Win32ToolkitTestVM/)

[https://win32toolkit.com/hyperv-vm/](https://win32toolkit.com/hyperv-vm/)

[https://win32toolkit.com/hyperv-vm-care/](https://win32toolkit.com/hyperv-vm-care/)

