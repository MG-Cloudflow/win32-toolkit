function New-CountdownScript {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$ProjectPath,

        # Countdown duration. The 120 s default is the WATCHED-mode human verification window and is
        # deliberately unchanged; unattended runs simply omit Countdown.ps1 from the chain entirely.
        [ValidateRange(5, 3600)]
        [int]$Seconds = 120
    )

    $sandboxPath = Join-Path $ProjectPath 'Sandbox'
    if (-not (Test-Path $sandboxPath)) {
        New-Item -ItemType Directory -Path $sandboxPath -Force | Out-Null
    }

    # Human-readable duration + initial mm:ss for the generated WinForms labels.
    $durationText = if ($Seconds % 60 -eq 0) { "$([int]($Seconds / 60)) minute$(if ($Seconds -ne 60) { 's' })" } else { "$Seconds seconds" }
    $initialLabel = '{0:00}:{1:00}' -f [math]::Floor($Seconds / 60), ($Seconds % 60)

    # The banner and the form title report the REAL install outcome (Get-W32tInstallVerdict reads the guest
    # runner's Sandbox\Logs\PsadtExitCodes.log) instead of always claiming success. Value-free, 5.1-safe;
    # the countdown and the following uninstall still run on a failure (the operator watches it).

    $countdownScript = @'
# Verdict of the install that just ran, read from the guest runner's exit-code log
# (Sandbox\Invoke-PsadtPackage.ps1 appends '[<UTC time>Z] <label> <type> parent=<p> exit=<n> result=<r>').
# The LAST 'Install' line of the current run wins (any label - in the Update scenario that is the baseline):
# the host starts each run with a '[<UTC time>Z] -- test run <name> --' line, and the legs of an Update
# '-BaselineInstallerType Both' run share the log, so only the lines after the last such line count.
# Only the numeric exit code and the one-word result class are taken from the log. Windows PowerShell 5.1-safe.
function Get-W32tInstallVerdict {
    param([string]$LogPath = 'C:\PSADT\Sandbox\Logs\PsadtExitCodes.log')
    $verdict = @{ Known = $false; Ok = $false; Exit = $null; Result = '' }
    if (-not (Test-Path -LiteralPath $LogPath)) { return $verdict }
    $last = $null
    foreach ($line in @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)) {
        if ("$line" -match '^\[[^\]]*\]\s+-- test run ') { $last = $null; continue }
        if ("$line" -match '^\[[^\]]*\]\s+\S+\s+Install\s') { $last = "$line" }
    }
    if (-not $last) { return $verdict }
    if ($last -match 'exit=(-?\d+)') { $verdict.Exit = [long]$Matches[1] }
    if ($last -match 'result=(\w+)') { $verdict.Result = $Matches[1] }
    $verdict.Known = $true
    $verdict.Ok = (@('Success', 'SoftReboot', 'HardReboot') -contains $verdict.Result)
    return $verdict
}

$installVerdict = Get-W32tInstallVerdict
if (-not $installVerdict.Known) {
    $verdictText = 'INSTALLATION FINISHED (no exit code recorded)'
    $verdictColor = 'Yellow'
} elseif ($installVerdict.Ok) {
    $verdictText = 'INSTALLATION COMPLETED SUCCESSFULLY!'
    $verdictColor = 'Green'
} else {
    $verdictText = 'INSTALLATION FAILED (exit ' + $installVerdict.Exit + ', ' + $installVerdict.Result + ') - see C:\PSADT\Sandbox\Logs'
    $verdictColor = 'Red'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Write-Host "`n========================================" -ForegroundColor $verdictColor
Write-Host $verdictText -ForegroundColor $verdictColor
Write-Host "========================================" -ForegroundColor $verdictColor
if ($installVerdict.Known -and -not $installVerdict.Ok) {
    Write-Host "The installation did NOT succeed - check the logs. The uninstall still runs after the countdown." -ForegroundColor Red
} else {
    Write-Host "The installation has finished." -ForegroundColor White
    Write-Host "You can now test the application functionality." -ForegroundColor Cyan
}

# Create a countdown form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Uninstallation Countdown"
$form.Size = New-Object System.Drawing.Size(500,250)
$form.StartPosition = "CenterScreen"
$form.Topmost = $true
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

# Title label - the install verdict (a failure text is long: smaller font, two lines)
$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Location = New-Object System.Drawing.Point(30,15)
$titleLabel.Size = New-Object System.Drawing.Size(440,40)
if ($installVerdict.Known -and $installVerdict.Ok) {
    $titleLabel.Font = New-Object System.Drawing.Font("Arial",14,[System.Drawing.FontStyle]::Bold)
} else {
    $titleLabel.Font = New-Object System.Drawing.Font("Arial",9,[System.Drawing.FontStyle]::Bold)
}
$titleLabel.Text = $verdictText
if ($verdictColor -eq 'Green') { $titleLabel.ForeColor = [System.Drawing.Color]::Green }
elseif ($verdictColor -eq 'Red') { $titleLabel.ForeColor = [System.Drawing.Color]::Red }
else { $titleLabel.ForeColor = [System.Drawing.Color]::DarkOrange }
$titleLabel.TextAlign = "MiddleCenter"
$form.Controls.Add($titleLabel)

# Instructions label
$instructionLabel = New-Object System.Windows.Forms.Label
$instructionLabel.Location = New-Object System.Drawing.Point(30,60)
$instructionLabel.Size = New-Object System.Drawing.Size(440,40)
$instructionLabel.Font = New-Object System.Drawing.Font("Arial",10)
$instructionLabel.Text = "Please test the application now.`nUninstallation will begin automatically in __DURATION__."
$instructionLabel.TextAlign = "MiddleCenter"
$form.Controls.Add($instructionLabel)

# Countdown label
$countdownLabel = New-Object System.Windows.Forms.Label
$countdownLabel.Location = New-Object System.Drawing.Point(30,120)
$countdownLabel.Size = New-Object System.Drawing.Size(440,40)
$countdownLabel.Font = New-Object System.Drawing.Font("Arial",16,[System.Drawing.FontStyle]::Bold)
$countdownLabel.Text = "Time remaining: __INITIAL__"
$countdownLabel.ForeColor = [System.Drawing.Color]::Blue
$countdownLabel.TextAlign = "MiddleCenter"
$form.Controls.Add($countdownLabel)

# Skip button
$skipButton = New-Object System.Windows.Forms.Button
$skipButton.Location = New-Object System.Drawing.Point(200,170)
$skipButton.Size = New-Object System.Drawing.Size(100,30)
$skipButton.Text = "Skip Wait"
$skipButton.Font = New-Object System.Drawing.Font("Arial",10)
$form.Controls.Add($skipButton)

# Timer for countdown
$timer = New-Object System.Windows.Forms.Timer
$secondsRemaining = __SECONDS__
$timer.Interval = 1000  # 1 second

$timer.Add_Tick({
    $script:secondsRemaining--

    $minutes = [Math]::Floor($script:secondsRemaining / 60)
    $seconds = $script:secondsRemaining % 60

    $countdownLabel.Text = "Time remaining: $($minutes.ToString("00")):$($seconds.ToString("00"))"

    if ($script:secondsRemaining -le 0) {
        $timer.Stop()
        $form.Close()
    }

    # Change color as time runs out
    if ($script:secondsRemaining -le 30) {
        $countdownLabel.ForeColor = [System.Drawing.Color]::Red
    } elseif ($script:secondsRemaining -le 60) {
        $countdownLabel.ForeColor = [System.Drawing.Color]::Orange
    }
})

# Skip button click event
$skipButton.Add_Click({
    $timer.Stop()
    $form.Close()
})

# Start the timer and show the form
$timer.Start()
$form.ShowDialog()

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "STARTING UNINSTALLATION PROCESS" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
'@

    # Fill the duration placeholders (numeric literal + label texts — nothing untrusted).
    $countdownScript = $countdownScript -replace '__SECONDS__', $Seconds
    $countdownScript = $countdownScript -replace '__DURATION__', $durationText
    $countdownScript = $countdownScript -replace '__INITIAL__', $initialLabel

    $countdownPath = Join-Path $sandboxPath 'Countdown.ps1'
    # UTF-8 WITH BOM: this runs under Windows PowerShell 5.1 inside the sandbox, which decodes a BOM-less
    # file as ANSI (PS7's Set-Content -Encoding UTF8 writes no BOM) — non-ASCII text would mojibake.
    [System.IO.File]::WriteAllText($countdownPath, $countdownScript, (New-Object System.Text.UTF8Encoding($true)))

    return $countdownPath
}
