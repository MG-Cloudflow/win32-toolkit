function New-Win32ToolkitIntuneDefaults {
    <#
    .SYNOPSIS
        Builds the validated IntuneDefaults object persisted into AppConfig from an org template (D2/D3).

    .DESCRIPTION
        Reads the template's IntuneDefaults defensively (any field may be missing/blank on an older
        template) and returns a fully-populated, Graph-valid object. Publish reads it back from AppConfig
        so it can honor org defaults even when invoked standalone (no template loaded).

        Validation is defence-in-depth on top of the wizard: DeviceRestartBehavior is forced to a valid
        win32LobApp enum, MaxRuntimeMinutes to a positive integer — a bad value here would make Graph
        reject the whole app body at publish time.

    .OUTPUTS
        [pscustomobject] MinimumWindowsRelease / DeviceRestartBehavior / MaxRuntimeMinutes /
        DescriptionBoilerplate / PrivacyUrl.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [PSCustomObject]$Template
    )

    $id = if ($Template -and $Template.PSObject.Properties['IntuneDefaults']) { $Template.IntuneDefaults } else { $null }
    $get = {
        param($name, $fallback)
        if ($id -and $id.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$id.$name)) { $id.$name } else { $fallback }
    }

    $restart = [string](& $get 'DeviceRestartBehavior' 'suppress')
    if ($restart -notin @('suppress', 'allow', 'force', 'basedOnReturnCode')) { $restart = 'suppress' }

    $runtime = 60
    [void][int]::TryParse([string](& $get 'MaxRuntimeMinutes' 60), [ref]$runtime)
    if ($runtime -le 0) { $runtime = 60 }

    return [pscustomobject]@{
        MinimumWindowsRelease  = [string](& $get 'MinimumWindowsRelease'  '1607')
        DeviceRestartBehavior  = $restart
        MaxRuntimeMinutes      = $runtime
        DescriptionBoilerplate = [string](& $get 'DescriptionBoilerplate' '')
        PrivacyUrl             = [string](& $get 'PrivacyUrl'             '')
    }
}
