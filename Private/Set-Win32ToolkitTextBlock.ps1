function Set-TextBlock {
    <#
    .SYNOPSIS
        Replaces the first regex match in a string using index maths (avoids $ capture-group issues).
    .DESCRIPTION
        Returns the input string with the first match of -Pattern replaced by -Replacement. The
        replacement is inserted literally via Substring index maths, so a '$' in the replacement text
        is never treated as a backreference.

        A pattern miss is a silent no-op by design (returns the input unchanged). When -Label is
        supplied, a miss emits a warning — that warning is the drift signal: it means the installed
        PSADT template no longer matches what we expect.

        Promoted out of Apply-OrgTemplate to file scope so it is dot-sourced by the module loader.
    #>
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Replacement,
        [switch]$Multiline,
        [string]$Label
    )
    $opts = if ($Multiline) { [System.Text.RegularExpressions.RegexOptions]::Singleline } `
                            else { [System.Text.RegularExpressions.RegexOptions]::None }
    $m = [regex]::Match($Text, $Pattern, $opts)
    if (-not $m.Success) {
        if ($Label) { Write-Warning "Org template: '$Label' pattern not found — section skipped (PSADT template drift?)." }
        return $Text
    }
    $Text.Substring(0, $m.Index) + $Replacement + $Text.Substring($m.Index + $m.Length)
}
