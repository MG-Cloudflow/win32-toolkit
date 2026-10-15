function Test-Win32ToolkitOrgTemplateText {
    <#
    .SYNOPSIS
        Checks org-template text that PSAppDeployToolkit expands at runtime and returns one violation
        object per problem (none = valid).

    .DESCRIPTION
        PSADT runs template text through PowerShell string expansion on the device: the config.psd1
        values (CompanyName, LogPath) at Open-ADTSession on 4.1 and 4.2, and on 4.2 the whole strings
        table every time a dialog command binds its parameters - even in Silent mode. A '$Name', '$(...)'
        or '${...}' sequence or a stray backtick in that text therefore fails every deployment (exit
        60001 / 60008) instead of showing a dialog. The toolkit REJECTS such text instead of escaping it:
        PSADT 4.1 does not expand the strings table, so an escape would show up there as a literal
        backtick (impact analysis D9, SCF-04 / ORG-06; SWP-05 for the whitespace and countdown rules).

        Rules (one violation per field and rule):
          Dollar      text fields              '$' followed by a letter, digit, '_', '{', '(', ':' or '?'
                                               ('US$ 5' and a trailing '$' stay legal)
          Backtick    text fields + LogPath    any backtick
          Whitespace  text fields              non-empty but whitespace only (PSADT 4.2 rejects it -
                                               leave the field empty instead)
          LogPath     LogPath                  a '$' that is not part of $env:Name, ${env:Name} or a PSADT
                                               $envName variable (4.2 refuses $(...) and ${provider:...})
          Countdown   WelcomeDialog / UninstallWelcomeDialog .CloseProcessesCountdown
                                               not a whole number from 0 to 86400 (0 = off; 4.2 cap)
          Language    LanguageOverride         set (not blank) and not a culture name such as nl, fr-FR,
                                               zh-Hans: ^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$ . It is a
                                               config.psd1 string, so PSADT expands it ('nl$(1+1)' runs
                                               code on 4.1, fails every deployment on 4.2) and then casts
                                               it to [CultureInfo]. Blank = auto-detect (not written).
                                               Additive to spec 2.12, same class as D9.

        Text fields: CompanyName; ProgressMessage, ProgressMessageDetail and BalloonComplete .Install /
        .Repair / .Uninstall; ProgressDialog.StatusMessage / .StatusMessageDetail;
        CompletionPrompt.Message / .ButtonRightText.

        A field that is missing (older template schema) or $null produces no violation. AppScriptAuthor
        is not checked: it travels as data in AppConfig.json and PSADT never expands it.

    .PARAMETER Template
        The org-template object (New-OrgTemplate schema, or a template read from JSON). Every field in
        the list above is checked.

    .PARAMETER Field
        One field to check, as a dotted path (e.g. 'ProgressMessage.Install'); used by the template
        wizard to validate each answer as it is typed.

    .PARAMETER Value
        The value of -Field.

    .OUTPUTS
        [pscustomobject] Field / Rule / Message, one per violation; nothing when the text is valid.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Template')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Template')]
        [PSCustomObject]$Template,

        [Parameter(Mandatory, ParameterSetName = 'Field')]
        [ValidateSet('CompanyName', 'LogPath',
            'ProgressMessage.Install', 'ProgressMessage.Repair', 'ProgressMessage.Uninstall',
            'ProgressMessageDetail.Install', 'ProgressMessageDetail.Repair', 'ProgressMessageDetail.Uninstall',
            'BalloonComplete.Install', 'BalloonComplete.Repair', 'BalloonComplete.Uninstall',
            'ProgressDialog.StatusMessage', 'ProgressDialog.StatusMessageDetail',
            'CompletionPrompt.Message', 'CompletionPrompt.ButtonRightText',
            'WelcomeDialog.CloseProcessesCountdown', 'UninstallWelcomeDialog.CloseProcessesCountdown',
            'LanguageOverride')]
        [string]$Field,

        [Parameter(Mandatory, ParameterSetName = 'Field')]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value
    )

    # Text PSADT expands (strings.psd1 dialog text + the CompanyName config value).
    $textFields = @(
        'CompanyName'
        'ProgressMessage.Install', 'ProgressMessage.Repair', 'ProgressMessage.Uninstall'
        'ProgressMessageDetail.Install', 'ProgressMessageDetail.Repair', 'ProgressMessageDetail.Uninstall'
        'BalloonComplete.Install', 'BalloonComplete.Repair', 'BalloonComplete.Uninstall'
        'ProgressDialog.StatusMessage', 'ProgressDialog.StatusMessageDetail'
        'CompletionPrompt.Message', 'CompletionPrompt.ButtonRightText'
    )
    $countdownFields = @('WelcomeDialog.CloseProcessesCountdown', 'UninstallWelcomeDialog.CloseProcessesCountdown')

    # Writes one violation object to the output.
    function Write-Violation {
        param([string]$Name, [string]$Rule, [string]$Message)
        [pscustomobject]@{ Field = $Name; Rule = $Rule; Message = $Message }
    }

    # Whole number of seconds in 0..86400. Accepts integral numbers (JSON gives Int64), integral
    # floating values and digit strings (a hand-edited JSON); anything else - bool, text, 1.5 - fails.
    function Test-CountdownValue {
        param($v)
        $n = $null
        $code = [Type]::GetTypeCode($v.GetType())
        if ($code -in 'SByte', 'Byte', 'Int16', 'UInt16', 'Int32', 'UInt32', 'Int64', 'UInt64') {
            $n = [decimal]$v
        }
        elseif ($code -in 'Single', 'Double', 'Decimal') {
            $d = [double]$v
            if (-not [double]::IsNaN($d) -and -not [double]::IsInfinity($d) -and [math]::Floor($d) -eq $d) { $n = $d }
        }
        elseif ($code -eq 'String') {
            $l = [long]0
            if ([long]::TryParse(([string]$v).Trim(), [System.Globalization.NumberStyles]::Integer,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$l)) { $n = $l }
        }
        return ($null -ne $n -and $n -ge 0 -and $n -le 86400)
    }

    # Rules for one field value. $null = not set -> nothing to check.
    function Test-FieldValue {
        param([string]$Name, $v)
        if ($null -eq $v) { return }

        if ($Name -in $countdownFields) {
            if (-not (Test-CountdownValue $v)) {
                Write-Violation $Name 'Countdown' ('{0}: ''{1}'' is not a whole number of seconds from 0 to 86400 (0 = no countdown; PSAppDeployToolkit 4.2 rejects larger values).' -f $Name, $v)
            }
            return
        }

        if ($Name -eq 'LanguageOverride') {
            # A culture name only ('\z', not '$': '$' would also accept a trailing newline). Blank is "not
            # set": the sparse config omits it and PSADT auto-detects the user's language.
            $lang = [string]$v
            if (-not [string]::IsNullOrWhiteSpace($lang) -and $lang -notmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*\z') {
                Write-Violation $Name 'Language' ('LanguageOverride: ''{0}'' is not a language name such as nl, fr-FR or zh-Hans. PSAppDeployToolkit expands this config value on the device and then reads it as a culture, so anything else can run code or fail every deployment - use a culture name, or leave it empty to auto-detect.' -f $lang)
            }
            return
        }

        $s = [string]$v
        if ($s.Contains([string][char]0x60)) {
            Write-Violation $Name 'Backtick' ('{0}: ''{1}'' contains a backtick. PowerShell treats it as an escape character, so PSAppDeployToolkit can fail the deployment when it expands this text - remove it.' -f $Name, $s)
        }

        if ($Name -eq 'LogPath') {
            # The allow-list of PSADT 4.2's own unsafe-expansion check, narrowed to environment variables:
            # ${env:Name}, $env:Name and PSADT's $envName. Any other '$' ($(...), ${C:\x}, $var) is refused.
            $rest = $s -replace '\$\{env:\w+\}|\$env:\w+|\$env\w+', ''
            if ($rest.Contains('$')) {
                Write-Violation $Name 'LogPath' ('LogPath: ''{0}'' may only use the variables $envName (PSADT), $env:Name or ${{env:Name}}. PSAppDeployToolkit refuses $(...) and ${{provider:...}} and the deployment fails - use a literal path or one of those forms.' -f $s)
            }
            return
        }

        $m = [regex]::Match($s, '\$[\w{(:?]')
        if ($m.Success) {
            $token = [regex]::Match($s.Substring($m.Index), '^\$(\w+|.)').Value
            Write-Violation $Name 'Dollar' ('{0}: ''{1}'' contains ''{2}'', which PSAppDeployToolkit expands as a variable or expression - the deployment fails. Remove the ''$'' or put a space after it (e.g. ''US$ 5'').' -f $Name, $s, $token)
        }
        if ($s.Length -gt 0 -and [string]::IsNullOrWhiteSpace($s)) {
            Write-Violation $Name 'Whitespace' ('{0}: contains only whitespace, which PSAppDeployToolkit 4.2 rejects - leave the field empty instead.' -f $Name)
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Field') {
        Test-FieldValue $Field $Value
        return
    }

    # Defensive read of a dotted path: a missing level (older schema) yields $null, never an error.
    # Templates come from New-OrgTemplate or ConvertFrom-Json (PSCustomObject); a hashtable also works.
    function Get-FieldValue {
        param($Object, [string]$Path)
        $cur = $Object
        foreach ($part in $Path.Split('.')) {
            if ($null -eq $cur) { return $null }
            if ($cur -is [System.Collections.IDictionary]) {
                $cur = if ($cur.Contains($part)) { $cur[$part] } else { $null }
            }
            elseif ($cur.PSObject.Properties[$part]) { $cur = $cur.$part }
            else { return $null }
        }
        return $cur
    }

    foreach ($name in @($textFields + 'LogPath' + $countdownFields + 'LanguageOverride')) {
        Test-FieldValue $name (Get-FieldValue $Template $name)
    }
}
