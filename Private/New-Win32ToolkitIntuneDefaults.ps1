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

    # minimumSupportedWindowsRelease is a Graph enum — an unrecognized token 400s the whole publish, so
    # validate it here (as we do the restart enum). Fall back to the safe '1607' floor with a warning
    # rather than let a bad value reach the app body. Match case-insensitively, emit the canonical token.
    $validReleases = @(
        '1607', '1703', '1709', '1803', '1809', '1903', '1909', '2004', '20H2', '21H1', '21H2', '22H2'
        'Windows11_21H2', 'Windows11_22H2', 'Windows11_23H2', 'Windows11_24H2'
    )
    $release = [string](& $get 'MinimumWindowsRelease' '1607')
    $canon = $validReleases | Where-Object { $_ -ieq $release } | Select-Object -First 1
    if ($canon) { $release = $canon }
    else {
        Write-Warning "IntuneDefaults MinimumWindowsRelease '$release' is not a recognized Intune release token — using '1607'."
        $release = '1607'
    }

    return [pscustomobject]@{
        MinimumWindowsRelease  = $release
        DeviceRestartBehavior  = $restart
        MaxRuntimeMinutes      = $runtime
        DescriptionBoilerplate = [string](& $get 'DescriptionBoilerplate' '')
        PrivacyUrl             = [string](& $get 'PrivacyUrl'             '')
    }
}
