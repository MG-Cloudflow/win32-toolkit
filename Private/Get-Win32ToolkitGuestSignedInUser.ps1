function Get-Win32ToolkitGuestSignedInUser {
    <#
    .SYNOPSIS
        Tells whether a user is signed in to the Hyper-V test VM the way PSADT 4.1 shows its dialogs to one.
    .DESCRIPTION
        Installer-identity PR 2, spec 2.5(b) (L19). Never throws.

        Runs ONE fixed, read-only scriptblock in the guest over the given PowerShell Direct session (guest
        Windows PowerShell 5.1; no -ArgumentList, no host value is sent): the console user name is
        present (Win32_ComputerSystem.UserName), the sessions that run explorer.exe (Win32_Process), and
        the connect state of every session (WTSEnumerateSessions through a constant Add-Type). No account
        name leaves the guest and no text is scraped (locale-free).

        SignedIn mirrors whom PSADT 4.1 shows UI to: the console user, or a user session (explorer) whose
        connect state is Active (0) or Connected (1). A disconnected session (4) does not count.
        SessionCount = the number of such sessions, or 1 when only the console user was seen.

        Checked is $false (Reason says why) when the call throws (the remote errors are terminating:
        -ErrorAction Stop) or when the result is not exactly one object carrying ConsoleUser,
        ExplorerSessionIds and UiSessionIds: a missing or partial answer is never read as "nobody".
    .PARAMETER Session
        An open PowerShell Direct PSSession to the test VM (New-Win32ToolkitHyperVSession).
    .OUTPUTS
        [pscustomobject] Checked [bool], SignedIn [bool], SessionCount [int], Reason [string].
    .EXAMPLE
        (Get-Win32ToolkitGuestSignedInUser -Session $s).SignedIn
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session
    )

    $checked = $false; $signedIn = $false; $count = 0; $reason = ''
    try {
        # C-11: guest Windows PowerShell 5.1, fixed text (no host value, no here-string), read-only,
        # every variable it assigns named $w32t*, ASCII only.
        $answer = @(Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
                $ErrorActionPreference = 'Stop'
                $w32tExplorer = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" |
                        Where-Object { $_.SessionId -gt 0 } | ForEach-Object { [int]$_.SessionId } | Sort-Object -Unique)
                $w32tConsole = -not [string]::IsNullOrEmpty([string](Get-CimInstance -ClassName Win32_ComputerSystem).UserName)
                if (-not ('W32TGuestWts' -as [type])) {
                    Add-Type -TypeDefinition ('using System; using System.Collections.Generic; using System.Runtime.InteropServices; ' +
                        'public static class W32TGuestWts { ' +
                        '[StructLayout(LayoutKind.Sequential)] private struct SessionInfo { public int SessionId; public IntPtr WinStationName; public int State; } ' +
                        '[DllImport("wtsapi32.dll", SetLastError = true)] private static extern bool WTSEnumerateSessions(IntPtr server, int reserved, int version, out IntPtr info, out int count); ' +
                        '[DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr memory); ' +
                        'public static int[][] Sessions() { IntPtr info; int count; List<int[]> rows = new List<int[]>(); ' +
                        'if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out info, out count)) { throw new System.ComponentModel.Win32Exception(); } ' +
                        'try { int size = Marshal.SizeOf(typeof(SessionInfo)); for (int i = 0; i < count; i++) { ' +
                        'SessionInfo s = (SessionInfo)Marshal.PtrToStructure(new IntPtr(info.ToInt64() + (long)i * size), typeof(SessionInfo)); ' +
                        'rows.Add(new int[] { s.SessionId, s.State }); } } finally { WTSFreeMemory(info); } return rows.ToArray(); } }')
                }
                $w32tState = @{}
                foreach ($w32tRow in [W32TGuestWts]::Sessions()) { $w32tState[[int]$w32tRow[0]] = [int]$w32tRow[1] }
                [pscustomobject]@{
                    ConsoleUser        = $w32tConsole
                    ExplorerSessionIds = [int[]]$w32tExplorer
                    UiSessionIds       = [int[]]@($w32tExplorer | Where-Object { $w32tState.ContainsKey($_) -and $w32tState[$_] -le 1 })
                }
            })
        $names = 'ConsoleUser', 'ExplorerSessionIds', 'UiSessionIds'
        $answer = @($answer | Where-Object { $null -ne $_ })
        if ($answer.Count -eq 0) { $reason = 'the guest returned no answer' }
        elseif ($answer.Count -gt 1) { $reason = "the guest returned $($answer.Count) answers instead of one" }
        elseif (@($names | Where-Object { -not $answer[0].PSObject.Properties[$_] }).Count -gt 0) {
            $reason = 'the guest answer is missing ' + (@($names | Where-Object { -not $answer[0].PSObject.Properties[$_] }) -join ', ')
        }
        else {
            $console = [bool]$answer[0].ConsoleUser
            $ui = @(@($answer[0].UiSessionIds) | Where-Object { $null -ne $_ })
            $checked = $true
            $signedIn = $console -or $ui.Count -gt 0
            $count = if ($ui.Count -gt 0) { $ui.Count } elseif ($console) { 1 } else { 0 }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'W32T.*') { throw }
        $reason = ConvertTo-Win32ToolkitSafeText -Text ([string]$_.Exception.Message) -MaxLength 256
    }

    [pscustomobject]@{
        Checked      = [bool]$checked
        SignedIn     = [bool]$signedIn
        SessionCount = [int]$count
        Reason       = $reason
    }
}
