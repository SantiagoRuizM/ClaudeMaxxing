# Win32 calls for placing session windows. Every call that reads monitors or moves windows runs with a
# per-monitor DPI context, so coordinates are physical pixels on mixed-DPI setups.
# Add-Type compiles with csc on every run (1-2 s on PowerShell 5.1), so the assembly is compiled once
# into $BinDir, named by a hash of the source so an edited source never loads a stale copy.

$WinApiSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class ClaudeTrayWin
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags; }

    delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr clip, IntPtr data);
    delegate bool WindowEnumProc(IntPtr hwnd, IntPtr data);

    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] static extern bool EnumWindows(WindowEnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBox(IntPtr hwnd, string text, string caption, uint type);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);

    static readonly IntPtr PerMonitorAwareV2 = new IntPtr(-4);
    const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    const int SW_RESTORE = 9;
    const uint SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;
    const uint MB_ICONINFORMATION = 0x40, MB_SETFOREGROUND = 0x10000, MB_TOPMOST = 0x40000;

    // Work area (screen minus taskbar) of each monitor: { left, top, right, bottom }.
    public static int[][] GetWorkAreas()
    {
        IntPtr previous = SetThreadDpiAwarenessContext(PerMonitorAwareV2);
        try
        {
            var areas = new List<int[]>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (monitor, hdc, clip, data) =>
            {
                var info = new MONITORINFO();
                info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                if (GetMonitorInfo(monitor, ref info))
                    areas.Add(new[] { info.rcWork.Left, info.rcWork.Top, info.rcWork.Right, info.rcWork.Bottom });
                return true;
            }, IntPtr.Zero);
            return areas.ToArray();
        }
        finally { SetThreadDpiAwarenessContext(previous); }
    }

    static string ClassOf(IntPtr hwnd)
    {
        var name = new StringBuilder(256);
        GetClassName(hwnd, name, name.Capacity);
        return name.ToString();
    }

    // Visible top-level windows whose class is one of the given ones.
    public static long[] GetVisibleWindows(string[] classes)
    {
        var found = new List<long>();
        EnumWindows((hwnd, data) =>
        {
            if (IsWindowVisible(hwnd) && Array.IndexOf(classes, ClassOf(hwnd)) >= 0) found.Add(hwnd.ToInt64());
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    // A handle can be reused by another window, and Windows Terminal may hide a window instead of
    // destroying it, so a live session needs an existing, visible window of the expected class.
    public static bool IsLiveWindow(long hwnd, string[] classes)
    {
        var handle = new IntPtr(hwnd);
        return IsWindow(handle) && IsWindowVisible(handle) && Array.IndexOf(classes, ClassOf(handle)) >= 0;
    }

    // Moves the window so its visible frame (without the invisible resize border) fills the rect.
    // Windows Terminal rescales itself when it lands on a monitor with another DPI and may resize once
    // its content loads, so the frame is re-read and corrected until it holds twice in a row.
    // Returns the last visible frame read: { left, top, right, bottom }.
    public static int[] Place(long hwnd, int x, int y, int width, int height, int attempts)
    {
        var handle = new IntPtr(hwnd);
        IntPtr previous = SetThreadDpiAwarenessContext(PerMonitorAwareV2);
        try
        {
            if (IsZoomed(handle) || IsIconic(handle)) ShowWindow(handle, SW_RESTORE);
            RECT window, frame = new RECT();
            int matches = 0;
            for (int i = 0; i < attempts; i++)
            {
                GetWindowRect(handle, out window);
                if (DwmGetWindowAttribute(handle, DWMWA_EXTENDED_FRAME_BOUNDS, out frame, Marshal.SizeOf(typeof(RECT))) != 0) frame = window;
                if (frame.Left == x && frame.Top == y && frame.Right == x + width && frame.Bottom == y + height)
                {
                    if (++matches >= 2) break;
                }
                else
                {
                    matches = 0;
                    int left = frame.Left - window.Left, top = frame.Top - window.Top;
                    int right = window.Right - frame.Right, bottom = window.Bottom - frame.Bottom;
                    SetWindowPos(handle, IntPtr.Zero, x - left, y - top, width + left + right, height + top + bottom, SWP_NOZORDER | SWP_NOACTIVATE);
                }
                Thread.Sleep(250);
            }
            return new[] { frame.Left, frame.Top, frame.Right, frame.Bottom };
        }
        finally { SetThreadDpiAwarenessContext(previous); }
    }

    public static void Activate(long hwnd) { SetForegroundWindow(new IntPtr(hwnd)); }

    // Topmost so it shows above Explorer even though this process was started in the background.
    public static void Notify(string text, string caption)
    {
        MessageBox(IntPtr.Zero, text, caption, MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST);
    }
}
'@

function Import-WinApi {
    if ('ClaudeTrayWin' -as [type]) { return }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($WinApiSource))[0..5] | ForEach-Object { $_.ToString('x2') })
    $dll = Join-Path $BinDir "ClaudeTrayWin-$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        if (-not (Test-Path -LiteralPath $BinDir)) { New-Item -ItemType Directory -Force -Path $BinDir | Out-Null }
        # Compile to a private name first so a concurrent run never loads a half-written file.
        $tmp = Join-Path $BinDir "ClaudeTrayWin-$hash-$PID.dll"
        Add-Type -TypeDefinition $WinApiSource -OutputAssembly $tmp -OutputType Library
        try { Move-Item -LiteralPath $tmp -Destination $dll -ErrorAction Stop } catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        Get-ChildItem -LiteralPath $BinDir -Filter 'ClaudeTrayWin-*.dll' | Where-Object { $_.FullName -ne $dll } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    }
    if (-not ('ClaudeTrayWin' -as [type])) { Add-Type -Path $dll }
}

function Get-WorkAreas {
    foreach ($area in [ClaudeTrayWin]::GetWorkAreas()) {
        [pscustomobject]@{ Left = $area[0]; Top = $area[1]; Right = $area[2]; Bottom = $area[3] }
    }
}
