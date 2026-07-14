function New-CountdownScript {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ProjectPath)

    $sandboxPath = Join-Path $ProjectPath 'Sandbox'
    if (-not (Test-Path $sandboxPath)) {
        New-Item -ItemType Directory -Path $sandboxPath -Force | Out-Null
    }

    $countdownScript = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "INSTALLATION COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "The application has been installed." -ForegroundColor White
Write-Host "You can now test the application functionality." -ForegroundColor Cyan

# Create a countdown form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Uninstallation Countdown"
$form.Size = New-Object System.Drawing.Size(500,250)
$form.StartPosition = "CenterScreen"
$form.Topmost = $true
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

# Title label
$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Location = New-Object System.Drawing.Point(30,20)
$titleLabel.Size = New-Object System.Drawing.Size(440,30)
$titleLabel.Font = New-Object System.Drawing.Font("Arial",14,[System.Drawing.FontStyle]::Bold)
$titleLabel.Text = "Installation Completed Successfully!"
$titleLabel.ForeColor = [System.Drawing.Color]::Green
$titleLabel.TextAlign = "MiddleCenter"
$form.Controls.Add($titleLabel)

# Instructions label
$instructionLabel = New-Object System.Windows.Forms.Label
$instructionLabel.Location = New-Object System.Drawing.Point(30,60)
$instructionLabel.Size = New-Object System.Drawing.Size(440,40)
$instructionLabel.Font = New-Object System.Drawing.Font("Arial",10)
$instructionLabel.Text = "Please test the application now.`nUninstallation will begin automatically in 2 minutes."
$instructionLabel.TextAlign = "MiddleCenter"
$form.Controls.Add($instructionLabel)

# Countdown label
$countdownLabel = New-Object System.Windows.Forms.Label
$countdownLabel.Location = New-Object System.Drawing.Point(30,120)
$countdownLabel.Size = New-Object System.Drawing.Size(440,40)
$countdownLabel.Font = New-Object System.Drawing.Font("Arial",16,[System.Drawing.FontStyle]::Bold)
$countdownLabel.Text = "Time remaining: 02:00"
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
$secondsRemaining = 120  # 2 minutes
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

    $countdownPath = Join-Path $sandboxPath 'Countdown.ps1'
    # UTF-8 WITH BOM: this runs under Windows PowerShell 5.1 inside the sandbox, which decodes a BOM-less
    # file as ANSI (PS7's Set-Content -Encoding UTF8 writes no BOM) — non-ASCII text would mojibake.
    [System.IO.File]::WriteAllText($countdownPath, $countdownScript, (New-Object System.Text.UTF8Encoding($true)))

    return $countdownPath
}
