@{
    RootModule        = 'win32-toolkit.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '87252f46-6d9c-4d65-b2ec-6af8e915b40c'
    Author            = 'IT Packaging Team'
    CompanyName       = 'Your Organisation'
    Copyright         = '(c) 2026. All rights reserved.'
    Description       = 'End-to-end Win32 app packaging automation: Winget discovery, download, PSADT V4 project creation, and Intune requirement script generation.'
    PowerShellVersion = '5.1'

    # Only the single entry-point command is exported to the caller.
    # All helper functions in Private\ remain invisible outside the module.
    FunctionsToExport = @('Invoke-Win32Toolkit')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Intune', 'PSADT', 'Win32', 'Winget', 'Packaging')
            ProjectUri = ''
        }
    }
}
