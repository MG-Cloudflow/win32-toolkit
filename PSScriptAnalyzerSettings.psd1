@{
    # PSScriptAnalyzer settings for win32-toolkit.
    # Run:  Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Interactive wizards (Invoke-Win32Toolkit, Show-*Selection, etc.) legitimately
        # print to the host. Remove this exclusion once the Write-Host UX layer is migrated
        # to Write-Verbose/Write-Information (tracked in knowledge-base/TODO.md, P2).
        'PSAvoidUsingWriteHost'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.2')
        }
    }
}
