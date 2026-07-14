function Wait-Win32ToolkitUploadState {
    <#
    .SYNOPSIS
        Polls an Intune mobileAppContentFile until it reaches a target uploadState, with bounded
        exponential back-off and a caller-supplied timeout.
    .DESCRIPTION
        Two steps of the Win32 LOB upload sequence are asynchronous on Intune's side: the Azure Storage
        SAS URI request, and the file commit. Both are observed the same way — GET the file entry and
        look at its `uploadState` — so both go through this single helper and cannot drift apart.

        Previously each step ran its own `for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Seconds 3 ... }`
        loop, i.e. a hard 60-second ceiling with no way to raise it. A slow tenant, or the commit of a
        large (200 MB+) package, routinely needs longer than that — and the failure landed AFTER the
        blob had already been uploaded, throwing the whole upload away.

        Behaviour:
        - Sleeps BEFORE the first poll (Intune never answers instantly).
        - Back-off: InitialDelaySeconds, doubling, capped at MaxDelaySeconds. A slow tenant is polled
          patiently instead of 20 times in a minute.
        - The final delay is clamped so the total time slept never exceeds TimeoutSeconds.
        - Any uploadState containing 'Error' / 'Fail' throws immediately (no point waiting it out).
        - On timeout the message quotes the ACTUAL elapsed seconds and the configured timeout.
    .PARAMETER FileUri
        Graph URI of the mobileAppContentFile entry (…/contentVersions/{v}/files/{id}).
    .PARAMETER TargetState
        The uploadState that means success, e.g. 'azureStorageUriRequestSuccess' or 'commitFileSuccess'.
    .PARAMETER Activity
        Human-readable name of what is being waited for, used in the messages. Phrase it so it reads
        after "waiting for" — e.g. 'the Azure Storage SAS URI'.
    .PARAMETER TimeoutSeconds
        Total seconds to wait before giving up.
    .PARAMETER InitialDelaySeconds
        First back-off delay (default 2 s).
    .PARAMETER MaxDelaySeconds
        Upper bound the doubling back-off saturates at (default 15 s).
    .OUTPUTS
        [pscustomobject] the Graph file entry as returned by the poll that reached TargetState.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FileUri,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetState,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Activity,

        [ValidateRange(5, 7200)]
        [int]$TimeoutSeconds = 300,

        [ValidateRange(1, 60)]
        [int]$InitialDelaySeconds = 2,

        [ValidateRange(1, 300)]
        [int]$MaxDelaySeconds = 15
    )

    $delay     = [math]::Min($InitialDelaySeconds, $MaxDelaySeconds)
    $elapsed   = 0
    $lastState = '(none)'

    while ($true) {
        # Clamp so the total slept time can never overshoot the configured timeout.
        if (($elapsed + $delay) -gt $TimeoutSeconds) { $delay = $TimeoutSeconds - $elapsed }

        Start-Sleep -Seconds $delay
        $elapsed += $delay

        $poll = Invoke-MgGraphRequest -Method GET -Uri $FileUri -OutputType PSObject
        if ($poll -and $poll.uploadState) { $lastState = [string]$poll.uploadState } else { $lastState = '(unknown)' }

        if ($lastState -eq $TargetState) { return $poll }

        if ($lastState -like '*Error*' -or $lastState -like '*Fail*') {
            throw "Intune reported a failure while waiting for $Activity. Upload state: $lastState"
        }

        if ($elapsed -ge $TimeoutSeconds) { break }

        Write-Verbose "  Waiting... (state: $lastState, ${elapsed}s / ${TimeoutSeconds}s)"
        $delay = [math]::Min($delay * 2, $MaxDelaySeconds)
    }

    throw ("Timed out after $elapsed s waiting for $Activity (configured timeout: $TimeoutSeconds s; " +
           "last upload state: $lastState). The content may still be uploading on Intune's side — " +
           'raise -TimeoutSeconds for large packages or a slow tenant.')
}
