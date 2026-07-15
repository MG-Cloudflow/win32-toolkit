function Set-Win32ToolkitIconSource {
    <#
    .SYNOPSIS
        Records where a project's Assets\AppIcon.png came from ('winget' | 'manual' | 'captured').
    .DESCRIPTION
        The icon can be set from three places that run at different times: the winget IconUrl download and a
        manual -IconPath both run at scaffold time, while the icon extracted from the install run is promoted
        later, in the finalize tail. A tiny marker file (Assets\.iconsource) lets the finalize reconcile
        (Import-Win32ToolkitCapturedIcon) honor precedence — an authoritative 'winget'/'manual' icon is never
        overwritten by the captured one (the winget-primary decision).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateSet('winget', 'manual', 'captured')]
        [string]$Source
    )

    $assets = Join-Path $ProjectPath 'Assets'
    if (-not (Test-Path -LiteralPath $assets)) {
        New-Item -ItemType Directory -Path $assets -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $assets '.iconsource') -Value $Source -Encoding ASCII -NoNewline -Force
}
