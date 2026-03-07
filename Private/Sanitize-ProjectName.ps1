function Sanitize-ProjectName {
    param([string]$Name)
    
    # Remove or replace invalid characters for folder names
    $sanitized = $Name -replace '[<>:"/\\|?*]', '_'
    $sanitized = $sanitized -replace '\s+', '_'  # Replace spaces with underscores
    $sanitized = $sanitized -replace '_+', '_'   # Replace multiple underscores with single
    $sanitized = $sanitized.Trim('_')            # Remove leading/trailing underscores
    
    return $sanitized
}