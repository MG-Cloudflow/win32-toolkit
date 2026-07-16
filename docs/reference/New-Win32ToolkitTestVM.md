# New-Win32ToolkitTestVM

## SYNOPSIS
Provisions the Hyper-V test VM: build (or attach) a golden VHDX, create a Gen2 VM, first-boot,
wait for PowerShell Direct, and take a warm 'clean-base' standard checkpoint.

## SYNTAX

```
New-Win32ToolkitTestVM [[-IsoPath] <String>] [[-VhdxPath] <String>] [[-Name] <String>]
 [[-Credential] <PSCredential>] [[-MemoryStartupBytes] <UInt64>] [[-ProcessorCount] <Int32>]
 [[-SwitchName] <String>] [[-CheckpointName] <String>] [[-ImageIndex] <Int32>] [[-Edition] <String>]
 [[-EnableTPM] <Boolean>] [-Recheckpoint] [-Force] [-Unattended] [-ProgressAction <ActionPreference>] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
One-time setup for the Hyper-V test backend.
HOST-ONLY - requires an elevated session and the
Hyper-V PowerShell module.
Two sources: build from a Windows 11 ISO (-IsoPath) or attach an
existing bootable Gen2 VHDX (-VhdxPath, BYO).
The VM is created with Secure Boot + a vTPM (Win11
requirements), started, and driven to readiness (Wait-Win32ToolkitVMReady).
Then - unless
-Unattended - it PAUSES and hands you the VM console so you can sign in, run Windows Update and
let all reboots finish; once you confirm, it freezes a STANDARD (memory-state) checkpoint so later
runs revert to that warm, fully-patched, logged-in desktop with no boot.
The VM name, checkpoint
name, and guest credential are saved to config for the resolver/provider.

## EXAMPLES

### EXAMPLE 1
```
New-Win32ToolkitTestVM -IsoPath 'C:\iso\Win11_x64.iso'
```

### EXAMPLE 2
```
New-Win32ToolkitTestVM -VhdxPath 'D:\vm\win11-base.vhdx' -Credential (Get-Credential)
```

## PARAMETERS

### -IsoPath
Build the golden VHDX from this Windows 11 x64 ISO.
Mutually exclusive with -VhdxPath.

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
Attach this existing bootable Gen2 VHDX (BYO).
Mutually exclusive with -IsoPath.

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
VM name (default 'win32tk-golden').

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: Win32tk-golden
Accept pipeline input: False
Accept wildcard characters: False
```

### -Credential
Guest local-admin credential (baked into the unattend when building; used for PowerShell Direct).
Prompted if omitted.

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
Static startup memory for the VM (default 4 GB; accepts size literals like 8GB).
Saved to config
so a re-provision keeps your choice.

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
Virtual processor count (default 2).
Saved to config so a re-provision keeps your choice.

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
Hyper-V virtual switch to connect (default 'Default Switch', NAT).

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
Warm checkpoint name (default 'clean-base').

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: Clean-base
Accept pipeline input: False
Accept wildcard characters: False
```

### -ImageIndex
Explicit edition index when building from ISO.
Overrides -Edition.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 9
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -Edition
Edition name substring to pick when building from ISO (e.g.
'Pro', 'Enterprise', 'Home').
When
omitted, the default preference is used: Windows 11 Pro first, Enterprise as a fallback.
Pro is
the right choice for a consumer multi-edition ISO (which has no Enterprise).

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
Attach a virtual TPM (default $true - Windows 11 requires it).

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
Re-take the checkpoint on an existing VM.

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
Overwrite an existing VHDX / rebuild an existing VM.

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
Skip the manual-prep pause and checkpoint the fresh first-boot desktop automatically (CI /
automation).
By default provisioning STOPS before the checkpoint, opens the VM console, and lets
you sign in, run Windows Update, and finish all reboots - then asks you to confirm, so 'clean-base'
captures a fully-patched, idle desktop instead of a bare first boot.

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

### System.Object
## NOTES

## RELATED LINKS
