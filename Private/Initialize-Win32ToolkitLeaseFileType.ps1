function Initialize-Win32ToolkitLeaseFileType {
    <#
    .SYNOPSIS
        Compiles the type W32TLeaseFileV2 once per process: the lease file's no-follow open and its handle checks.
    .DESCRIPTION
        Moved unchanged out of Enter-Win32ToolkitHyperVLease (menu selectors design section 4.3, D6), so the read-only lease
        probe (Get-Win32ToolkitHyperVLeaseState) applies the very checks the lease applies. The type name stays
        W32TLeaseFileV2: a process that compiled it keeps it, and the definition is the same. Emits nothing; an Add-Type
        failure throws.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    # The no-follow open and the handle checks (a constant type; no value of this call is compiled). TryOpenLock: read+write,
    # OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT (a link at the file's own name is opened as the link, then refused), no
    # security attributes (not inheritable), never FILE_FLAG_DELETE_ON_CLOSE; a refused open returns null and the Win32
    # error code instead of throwing (a .NET exception per busy attempt would be an error record in $Error and in the
    # caller's -ErrorVariable, live V3). OpenError: the exception for any other code. Describe: attributes, number of
    # names, owner SID and final path of an open handle, or of a path opened without following a link at it ($null:
    # missing). V2 in the name: a process that compiled the earlier type (OpenLock only) keeps it, so this one must differ.
    if (-not ('W32TLeaseFileV2' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition ('using System; using System.ComponentModel; using System.IO; using System.Runtime.InteropServices; ' +
            'using System.Security.Principal; using System.Text; using Microsoft.Win32.SafeHandles; ' +
            'public static class W32TLeaseFileV2 { ' +
            '[StructLayout(LayoutKind.Sequential)] private struct HandleInfo { public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, VolumeSerial, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; } ' +
            '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template); ' +
            '[DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out HandleInfo info); ' +
            '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags); ' +
            '[DllImport("advapi32.dll")] private static extern uint GetSecurityInfo(SafeFileHandle handle, int type, uint info, out IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl, out IntPtr descriptor); ' +
            '[DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory); ' +
            'private static Exception Fail(int code, string path) { string m = new Win32Exception(code).Message + " (" + path + ")"; ' +
            'if (code == 5) { return new UnauthorizedAccessException(m); } return new IOException(m, unchecked((int)0x80070000) | code); } ' +
            'public static Exception OpenError(int code, string path) { return Fail(code, path); } ' +
            'public static SafeFileHandle TryOpenLock(string path, int share, out int error) { ' +
            'SafeFileHandle h = CreateFileW(path, 0xC0000000, (uint)share, IntPtr.Zero, 4, 0x80 | 0x00200000, IntPtr.Zero); ' +
            'if (h.IsInvalid) { error = Marshal.GetLastWin32Error(); h.Dispose(); return null; } error = 0; return h; } ' +
            'public static object[] Describe(string path) { ' +
            'SafeFileHandle h = CreateFileW(path, 0x00020080, 7, IntPtr.Zero, 3, 0x02000000 | 0x00200000, IntPtr.Zero); ' +
            'if (h.IsInvalid) { int code = Marshal.GetLastWin32Error(); h.Dispose(); if (code == 2 || code == 3) { return null; } throw Fail(code, path); } ' +
            'using (h) { return Describe(h); } } ' +
            'public static object[] Describe(SafeFileHandle handle) { HandleInfo info; ' +
            'if (!GetFileInformationByHandle(handle, out info)) { throw new Win32Exception(Marshal.GetLastWin32Error()); } ' +
            'IntPtr owner, descriptor; uint rc = GetSecurityInfo(handle, 1, 1, out owner, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out descriptor); ' +
            'if (rc != 0) { throw new Win32Exception((int)rc); } string sid; ' +
            'try { sid = new SecurityIdentifier(owner).Value; } finally { LocalFree(descriptor); } ' +
            'StringBuilder sb = new StringBuilder(1024); uint n = GetFinalPathNameByHandleW(handle, sb, (uint)sb.Capacity, 0); ' +
            'if (n >= (uint)sb.Capacity) { sb = new StringBuilder((int)n + 1); n = GetFinalPathNameByHandleW(handle, sb, (uint)sb.Capacity, 0); } ' +
            'if (n == 0 || n >= (uint)sb.Capacity) { throw new Win32Exception(Marshal.GetLastWin32Error()); } ' +
            'return new object[] { (int)info.Attributes, (int)info.Links, sid, sb.ToString(0, (int)n) }; } }')
    }
}
