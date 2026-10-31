# Export-Win32ToolkitDocumentation

## SYNOPSIS
Writes a one-page summary of a packaged app for your customer.

## SYNTAX

```
Export-Win32ToolkitDocumentation [-ProjectPath] <String> [[-OutputPath] <String>] [-IncludeIntuneIds]
 [<CommonParameters>]
```

## DESCRIPTION
Export-Win32ToolkitDocumentation writes a one-page summary of a project in a Markdown file.
It describes the app, how Intune installs and detects it, what it installs, the tests that
were run and the uninstall.
If a part is missing, for example when no test was run, the
summary says so and the command continues.

Use it when you give a package to your customer.
In the menu: Work with an existing
project \> Generate customer documentation.
The menu then asks "Include the Intune app id +
portal link?
(only if the customer owns the tenant)".
The default is No.

By default, the summary holds no tenant ID and no Intune app ID.
From the install capture
(the record of what the installer changed), it shows only counts and the program name,
never file paths.

The command writes one file and replaces an older one.
By default, this is Documentation.md
in the project folder.
Documentation.md never goes into the package: the build leaves it
out.

## EXAMPLES

### EXAMPLE 1
```
Export-Win32ToolkitDocumentation -ProjectPath 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'
```

This writes Documentation.md in the project folder, without Intune IDs.

### EXAMPLE 2
```
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
Export-Win32ToolkitDocumentation -ProjectPath $project -IncludeIntuneIds
```

This adds the Intune app ID and the link to the app.
Do this only when the customer owns
the tenant.

### EXAMPLE 3
```
$project = 'C:\Win32Apps\Projects\Contoso\Git_x64_2.53.0'   # your project folder
$copy = 'C:\Temp\Git_x64_2.53.0_internal.md'
Export-Win32ToolkitDocumentation -ProjectPath $project -OutputPath $copy -IncludeIntuneIds
```

This writes an internal copy with the Intune IDs to C:\Temp.
The Documentation.md in the
project does not change.

## PARAMETERS

### -ProjectPath
The project folder: \<base folder\>\Projects\\\<template\>\\\<project\>.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -OutputPath
The file to write.
Default: Documentation.md in the project folder.
The command creates the
folder if it does not exist.
Use it to keep an internal copy apart from the customer's copy.

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

### -IncludeIntuneIds
Adds an Intune section with the app ID and the link to the app in the Intune admin center.
It lists the app of every tenant that this project was published to.
Use it only for your
own copy, or when the customer owns the tenant.
A project that was never published gets no
Intune section.

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

### The full path of the file that was written.
## NOTES
Time: seconds.
The command needs no sign-in and no network.

## RELATED LINKS

[https://win32toolkit.com/reference/Export-Win32ToolkitDocumentation/](https://win32toolkit.com/reference/Export-Win32ToolkitDocumentation/)

[https://win32toolkit.com/publishing/](https://win32toolkit.com/publishing/)

