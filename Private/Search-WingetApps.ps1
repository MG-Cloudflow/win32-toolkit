function Search-WingetApps {
    param([string]$SearchTerm)
    
    Write-Host "Searching for apps matching: $SearchTerm" -ForegroundColor Yellow
    
    # Run winget search and capture output
    $searchResults = winget search $SearchTerm --accept-source-agreements | Out-String
    
    # Parse the results (skip header lines)
    $lines = $searchResults -split "`n" | Where-Object { $_.Trim() -ne "" }
    $apps = @()
    
    # Find the separator line (dashes) to know where data starts; handle varying winget formats
    $dataStartIndex = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^[-\s]+$" -and $lines[$i] -match "-{2,}") {
            $dataStartIndex = $i + 1
            break
        }
    }
    
    # Parse each app line
    for ($i = $dataStartIndex; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -and
            $line -notmatch "^\d+\s+matches?\s+found" -and
            $line -notmatch "^More\s+than" -and
            $line -notmatch "^Name\s+Id\s+" ) {   # skip header row if separator detection missed it
            # Split by multiple spaces to separate columns
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 3) {
                $apps += [PSCustomObject]@{
                    Name    = $parts[0].Trim()
                    Id      = $parts[1].Trim()
                    Version = if ($parts.Count -gt 2) { $parts[2].Trim() } else { "" }
                    Source  = if ($parts.Count -gt 3) { $parts[$parts.Count - 1].Trim() } else { "winget" }
                }
            }
        }
    }
    
    return $apps
}