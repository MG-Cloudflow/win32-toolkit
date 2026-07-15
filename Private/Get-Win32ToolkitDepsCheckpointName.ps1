function Get-Win32ToolkitDepsCheckpointName {
    <#
    .SYNOPSIS
        Computes the deterministic 'clean-base+deps-<key>' checkpoint name for a project's staged deps.
    .DESCRIPTION
        The key is a SHA256 (first 12 hex chars) over everything that makes the dependency layer what it
        is — so a change in ANY of these yields a different name, and the stale checkpoint is simply
        never matched again:
          * the staged dependencies.json content (ids, order, silent args),
          * the SHA256 of every staged installer/PSADT payload file (a version bump of an unpinned
            'latest' dependency changes the bytes => new key),
          * the PARENT checkpoint's identity (InstanceId + creation time): a deps checkpoint must never
            outlive the clean-base image it was built on. (In practice VM maintenance deletes all
            checkpoints anyway — this key component is belt-and-braces per the design review.)
        Returns $null when the project has no staged dependencies (no manifest), when the parent
        checkpoint cannot be resolved, or on any error — callers treat $null as "feature not applicable".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$VMName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ParentCheckpointName
    )

    try {
        $manifest = Join-Path $ProjectPath 'Sandbox\Dependencies\dependencies.json'
        if (-not (Test-Path -LiteralPath $manifest)) { return $null }

        $parent = Get-VMCheckpoint -VMName $VMName -Name $ParentCheckpointName -ErrorAction SilentlyContinue
        if (-not $parent) { return $null }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append((Get-Content -LiteralPath $manifest -Raw))
        [void]$sb.Append("|parent:$($parent.Id)|$($parent.CreationTime.ToString('o'))")

        # Every staged payload file, in a deterministic order.
        $depRoot = Join-Path $ProjectPath 'Sandbox\Dependencies'
        $files = @(Get-ChildItem -LiteralPath $depRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'dependencies.json' } | Sort-Object FullName)
        foreach ($f in $files) {
            $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            [void]$sb.Append("|$($f.FullName.Substring($depRoot.Length))=$h")
        }

        $bytes  = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $sha    = [System.Security.Cryptography.SHA256]::Create()
        try { $keyHex = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 12).ToLowerInvariant() }
        finally { $sha.Dispose() }

        return "clean-base+deps-$keyHex"
    }
    catch {
        Write-Verbose "Deps-checkpoint key unavailable: $($_.Exception.Message)"
        return $null
    }
}
