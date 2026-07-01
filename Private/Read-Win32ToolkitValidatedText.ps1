function Read-Win32ToolkitValidatedText {
    <#
    .SYNOPSIS
        Spectre text input that re-prompts until a validator passes (Read-SpectreText has no
        built-in validator). See knowledge-base/designs/tui.md.
    .PARAMETER Message
        The prompt text.
    .PARAMETER Validator
        Scriptblock receiving the entered value; return $true to accept.
    .PARAMETER ErrorMessage
        Shown (red) when validation fails, before re-prompting.
    .PARAMETER DefaultAnswer
        Optional default.
    .PARAMETER AllowEmpty
        Allow an empty answer (returns '').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Message,
        [scriptblock]$Validator,
        [string]$ErrorMessage = 'Invalid input — please try again.',
        [string]$DefaultAnswer,
        [switch]$AllowEmpty
    )

    while ($true) {
        $params = @{ Message = $Message }
        if ($PSBoundParameters.ContainsKey('DefaultAnswer')) { $params.DefaultAnswer = $DefaultAnswer }
        if ($AllowEmpty) { $params.AllowEmpty = $true }
        $value = Read-SpectreText @params

        if ($AllowEmpty -and [string]::IsNullOrWhiteSpace($value)) { return '' }
        if (-not $Validator) { return $value }

        $ok = $false
        try { $ok = [bool](& $Validator $value) } catch { $ok = $false }
        if ($ok) { return $value }

        Write-SpectreHost "[red]$(Get-SpectreEscapedText -Text $ErrorMessage)[/]"
    }
}
