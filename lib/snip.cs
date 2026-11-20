// Native side of Captura a Claude Code (lib\snip.ps1, lib\snipcapture.ps1, lib\sniprecord.ps1): the Win+Alt+C
// hotkey, the darkened copy of the frozen screen, the windows and screens to snip, and the screen recorder (Media
// Foundation's sink writer: H.264 video and an AAC track from the speakers and the microphone, in MP4). Compiled once into the tray's bin folder by Initialize-SnipNative.
// Coordinates are physical pixels: the callers run with per-monitor DPI awareness, and so does the recorder thread.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace ClaudeTray {

// A global hotkey on a hidden window; Pressed fires on the UI thread.
public sealed class SnipHotkey : NativeWindow, IDisposable {
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public event EventHandler Pressed;
    public readonly bool Registered;
    // mods: 1 Alt, 2 Ctrl, 4 Shift, 8 Win; 0x4000, no auto-repeat.
    public SnipHotkey(uint mods, uint vk) {
        CreateHandle(new CreateParams());
        Registered = RegisterHotKey(Handle, 1, mods | 0x4000, vk);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
    public void Dispose() {
        if (Registered) UnregisterHotKey(Handle, 1);
        DestroyHandle();
    }
}

// The frozen screen ready to paint: the clear copy and the one under the 60 % black veil (40 % of each color), as
// GDI bitmaps in memory DCs. A BitBlt from them costs a few milliseconds where GDI+ needs tens for a full screen.
public sealed class SnipCanvas : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct BITMAPINFOHEADER {
        public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER info, int usage, out IntPtr bits, IntPtr section, int offset);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dest, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);

    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    readonly IntPtr[] dcs = new IntPtr[2], bitmaps = new IntPtr[2], previous = new IntPtr[2], bits = new IntPtr[2];
    public readonly int Width, Height;
    // The clear copy as a GDI+ bitmap over the same memory (no copy): for crops, the magnifier and the OCR. Valid
    // while the canvas lives.
    public readonly Bitmap Clear;

    // The screen from (X, Y), read straight into the clear copy.
    public static SnipCanvas FromScreen(int x, int y, int width, int height) { return new SnipCanvas(null, x, y, width, height); }

    // A picture already taken (previews and tests).
    public SnipCanvas(Bitmap shot) : this(shot, 0, 0, shot.Width, shot.Height) { }

    SnipCanvas(Bitmap shot, int x, int y, int width, int height) {
        Width = width; Height = height;
        Make(0);
        Make(1);
        if (shot == null) {
            IntPtr screen = GetDC(IntPtr.Zero);
            try { BitBlt(dcs[0], 0, 0, Width, Height, screen, x, y, 0x00CC0020); } finally { ReleaseDC(IntPtr.Zero, screen); }
        } else {
            using (Graphics g = Graphics.FromHdc(dcs[0])) g.DrawImage(shot, new Rectangle(0, 0, Width, Height), new Rectangle(0, 0, Width, Height), GraphicsUnit.Pixel);
        }
        Clear = new Bitmap(Width, Height, Width * 4, PixelFormat.Format32bppRgb, bits[0]);
        // The veil, a band of rows per core (32 bpp: the stride is the width, no padding).
        // The clear copy also made opaque: GDI leaves the alpha byte at 0, and a 32-bit target would take it.
        int[] px = new int[Width * Height], dim = new int[Width * Height];
        Marshal.Copy(bits[0], px, 0, px.Length);
        int parts = Environment.ProcessorCount;
        System.Threading.Tasks.Parallel.For(0, parts, part => {
            int from = (int)((long)px.Length * part / parts), to = (int)((long)px.Length * (part + 1) / parts);
            for (int i = from; i < to; i++) {
                int c = px[i];
                px[i] = c | unchecked((int)0xFF000000);
                dim[i] = unchecked((int)0xFF000000) | (((c >> 16) & 255) * 2 / 5 << 16) | (((c >> 8) & 255) * 2 / 5 << 8) | ((c & 255) * 2 / 5);
            }
        });
        Marshal.Copy(px, 0, bits[0], px.Length);
        Marshal.Copy(dim, 0, bits[1], dim.Length);
    }

    void Make(int which) {
        BITMAPINFOHEADER info = new BITMAPINFOHEADER();
        info.biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER));
        info.biWidth = Width; info.biHeight = -Height; info.biPlanes = 1; info.biBitCount = 32;  // top-down
        bitmaps[which] = CreateDIBSection(IntPtr.Zero, ref info, 0, out bits[which], IntPtr.Zero, 0);
        if (bitmaps[which] == IntPtr.Zero) throw new OutOfMemoryException("CreateDIBSection");
        dcs[which] = CreateCompatibleDC(IntPtr.Zero);
        previous[which] = SelectObject(dcs[which], bitmaps[which]);
    }

    // Paints Area of the clear (Clear) or veiled copy onto G at the same place.
    public void Draw(Graphics g, Rectangle area, bool clear) {
        area.Intersect(new Rectangle(0, 0, Width, Height));
        if (area.Width <= 0 || area.Height <= 0) return;
        IntPtr hdc = g.GetHdc();
        try { BitBlt(hdc, area.X, area.Y, area.Width, area.Height, dcs[clear ? 0 : 1], area.X, area.Y, 0x00CC0020); }
        finally { g.ReleaseHdc(hdc); }
    }

    public void Dispose() {
        Clear.Dispose();
        for (int i = 0; i < 2; i++) {
            if (dcs[i] == IntPtr.Zero) continue;
            SelectObject(dcs[i], previous[i]);
            DeleteObject(bitmaps[i]);
            DeleteDC(dcs[i]);
            dcs[i] = IntPtr.Zero;
        }
    }
}

// The screens and the windows that can be snipped, as flat arrays of x, y, width, height.
public static class SnipDesktop {
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags; }
    delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);
    delegate bool WindowEnumProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] static extern bool EnumWindows(WindowEnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);

    // Each screen: its bounds, then its work area (8 numbers).
    public static int[] Screens() {
        List<int> list = new List<int>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (m, hdc, r, d) => {
            MONITORINFO info = new MONITORINFO();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (GetMonitorInfo(m, ref info)) {
                RECT b = info.rcMonitor, w = info.rcWork;
                list.AddRange(new int[] { b.Left, b.Top, b.Right - b.Left, b.Bottom - b.Top, w.Left, w.Top, w.Right - w.Left, w.Bottom - w.Top });
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    // The windows on screen, the top one first: visible, not minimized or cloaked (another virtual desktop, a
    // suspended app), not the desktop, not this process. Their visible frame, without the invisible resize border.
    public static int[] Windows(out string[] titles, out long[] handles) {
        List<int> list = new List<int>();
        List<string> names = new List<string>();
        List<long> ids = new List<long>();
        uint self = (uint)Process.GetCurrentProcess().Id;
        EnumWindows((hwnd, d) => {
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return true;
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid == self) return true;
            int cloaked;
            if (DwmGetWindowAttribute(hwnd, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
            if ((GetWindowLong(hwnd, -20) & 0x80) != 0) return true;  // WS_EX_TOOLWINDOW: tooltips, menus, overlays
            StringBuilder cls = new StringBuilder(64);
            GetClassName(hwnd, cls, 64);
            string c = cls.ToString();
            if (c == "Progman" || c == "WorkerW") return true;
            RECT r;
            if (DwmGetWindowAttribute(hwnd, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) return true;
            if (r.Right - r.Left < 40 || r.Bottom - r.Top < 40) return true;
            StringBuilder text = new StringBuilder(256);
            GetWindowText(hwnd, text, 256);
            list.AddRange(new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top });
            names.Add(text.ToString());
            ids.Add(hwnd.ToInt64());
            return true;
        }, IntPtr.Zero);
        titles = names.ToArray();
        handles = ids.ToArray();
        return list.ToArray();
    }

    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, int flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    // The window itself, also where other windows cover it, as the Windows snipping tool takes it: PrintWindow with
    // PW_RENDERFULLCONTENT (browsers and DirectX apps draw too), cut to its visible frame, opaque. Null when the
    // window does not draw itself (all black).
    public static Bitmap CaptureWindow(long handle) {
        IntPtr hwnd = new IntPtr(handle);
        RECT w, f;
        if (!GetWindowRect(hwnd, out w)) return null;
        if (DwmGetWindowAttribute(hwnd, 9, out f, Marshal.SizeOf(typeof(RECT))) != 0) f = w;
        int ww = w.Right - w.Left, wh = w.Bottom - w.Top;
        if (ww <= 0 || wh <= 0) return null;
        Rectangle crop = Rectangle.Intersect(new Rectangle(f.Left - w.Left, f.Top - w.Top, f.Right - f.Left, f.Bottom - f.Top), new Rectangle(0, 0, ww, wh));
        if (crop.Width <= 0 || crop.Height <= 0) return null;
        using (Bitmap full = new Bitmap(ww, wh, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(full)) {
                IntPtr hdc = g.GetHdc();
                bool ok;
                try { ok = PrintWindow(hwnd, hdc, 2); } finally { g.ReleaseHdc(hdc); }
                if (!ok) return null;
            }
            Bitmap shot = full.Clone(crop, PixelFormat.Format32bppArgb);
            BitmapData data = shot.LockBits(new Rectangle(0, 0, shot.Width, shot.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
            bool drawn = false;
            try {
                int[] px = new int[shot.Width * shot.Height];
                Marshal.Copy(data.Scan0, px, 0, px.Length);
                for (int i = 0; i < px.Length; i++) {
                    if ((px[i] & 0xFFFFFF) != 0) drawn = true;
                    px[i] |= unchecked((int)0xFF000000);
                }
                Marshal.Copy(px, 0, data.Scan0, px.Length);
            } finally { shot.UnlockBits(data); }
            if (!drawn) { shot.Dispose(); return null; }
            return shot;
        }
    }
}

public static class SnipWindow {
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);

    // Mouse clicks go through to what is under it.
    public static void ClickThrough(IntPtr hwnd) { SetWindowLong(hwnd, -20, GetWindowLong(hwnd, -20) | 0x80000 | 0x20); }

    // Left out of screen captures (WDA_EXCLUDEFROMCAPTURE, Windows 10 2004 and later): the recorder's own frame and bar.
    public static void HideFromCapture(IntPtr hwnd) { SetWindowDisplayAffinity(hwnd, 0x11); }
}

// ---------------------------------------------------------------- audio (WASAPI, like lib\whisper.cs)

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class SnipDeviceEnumerator { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISnipDeviceEnumerator {
    int NotUsed_EnumAudioEndpoints();
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out ISnipDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISnipDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
}

[ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISnipAudioClient {
    [PreserveSig] int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
    [PreserveSig] int GetBufferSize(out int frames);
    [PreserveSig] int GetStreamLatency(out long latency);
    [PreserveSig] int GetCurrentPadding(out int frames);
    [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
    [PreserveSig] int GetMixFormat(out IntPtr format);
    [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
    [PreserveSig] int Start();
    [PreserveSig] int Stop();
    [PreserveSig] int Reset();
    [PreserveSig] int SetEventHandle(IntPtr handle);
    [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
}

[ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISnipCaptureClient {
    [PreserveSig] int GetBuffer(out IntPtr data, out int frames, out int flags, out long devicePosition, out long qpcPosition);
    [PreserveSig] int ReleaseBuffer(int frames);
    [PreserveSig] int GetNextPacketSize(out int frames);
}

// One shared-mode endpoint (what the speakers play, in loopback, or the default microphone) captured on its own MTA
// thread and turned into 48 kHz stereo float, waiting for the recorder to mix it in.
sealed class SnipAudioSource {
    public const int Rate = 48000;
    readonly bool loopback;
    readonly List<float> buffer = new List<float>();
    readonly object gate = new object();
    Thread thread;
    volatile bool running;
    public string Error;
    // The linear resampler: the last input frame and where the next output falls after it.
    double step, position;
    float lastLeft, lastRight;

    public SnipAudioSource(bool loopback) { this.loopback = loopback; }

    public void Start() {
        running = true;
        thread = new Thread(Run);
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }

    public void Stop() {
        running = false;
        if (thread != null) thread.Join(2000);
    }

    // Adds up to Frames waiting frames into Mix (stereo, interleaved); what is missing stays silent.
    public void MixInto(float[] mix, int frames) {
        lock (gate) {
            int n = Math.Min(frames * 2, buffer.Count);
            for (int i = 0; i < n; i++) mix[i] += buffer[i];
            buffer.RemoveRange(0, n);
        }
    }

    // Keeps at most MaxFrames waiting (the newest), so a source that runs ahead never drifts far from the video.
    public void Trim(int maxFrames) {
        lock (gate) { if (buffer.Count > maxFrames * 2) buffer.RemoveRange(0, buffer.Count - maxFrames * 2); }
    }

    public void Clear() { lock (gate) buffer.Clear(); }

    static void Check(int hr, string what) { if (hr < 0) throw new COMException(what + " failed (0x" + hr.ToString("X8") + ")", hr); }

    void Run() {
        try { Loop(); } catch (Exception e) { Error = e.Message; }
    }

    void Loop() {
        ISnipDeviceEnumerator enumerator = (ISnipDeviceEnumerator)new SnipDeviceEnumerator();
        ISnipDevice device;
        Check(enumerator.GetDefaultAudioEndpoint(loopback ? 0 : 1, 0, out device), "GetDefaultAudioEndpoint");
        Guid iidClient = typeof(ISnipAudioClient).GUID;
        object o;
        Check(device.Activate(ref iidClient, 1, IntPtr.Zero, out o), "Activate");
        ISnipAudioClient client = (ISnipAudioClient)o;
        IntPtr format;
        Check(client.GetMixFormat(out format), "GetMixFormat");
        int tag = (ushort)Marshal.ReadInt16(format, 0);
        int channels = (ushort)Marshal.ReadInt16(format, 2);
        int rate = Marshal.ReadInt32(format, 4);
        int bits = (ushort)Marshal.ReadInt16(format, 14);
        // WAVEFORMATEXTENSIBLE: the SubFormat GUID starts at byte 24; its first field is the format tag.
        bool isFloat = tag == 3 || (tag == 0xFFFE && Marshal.ReadInt32(format, 24) == 3);
        Check(client.Initialize(0, loopback ? 0x00020000 : 0, 1000000, 0, format, IntPtr.Zero), "Initialize");
        Marshal.FreeCoTaskMem(format);
        Guid iidCapture = typeof(ISnipCaptureClient).GUID;
        Check(client.GetService(ref iidCapture, out o), "GetService");
        ISnipCaptureClient capture = (ISnipCaptureClient)o;
        step = rate / (double)Rate;
        position = 0;
        int bytesPerFrame = channels * bits / 8;
        Check(client.Start(), "Start");
        try {
            while (running) {
                int packet;
                Check(capture.GetNextPacketSize(out packet), "GetNextPacketSize");
                while (packet > 0) {
                    IntPtr data; int frames, flags; long pos, qpc;
                    Check(capture.GetBuffer(out data, out frames, out flags, out pos, out qpc), "GetBuffer");
                    Consume(data, frames, (flags & 2) != 0 || data == IntPtr.Zero, channels, bits, isFloat, bytesPerFrame);
                    capture.ReleaseBuffer(frames);
                    Check(capture.GetNextPacketSize(out packet), "GetNextPacketSize");
                }
                Thread.Sleep(5);
            }
        } finally {
            client.Stop();
            Marshal.ReleaseComObject(capture);
            Marshal.ReleaseComObject(client);
            Marshal.ReleaseComObject(device);
            Marshal.ReleaseComObject(enumerator);
        }
    }

    static float Read(byte[] raw, int at, int bits, bool isFloat) {
        if (isFloat && bits == 32) return BitConverter.ToSingle(raw, at);
        if (bits == 16) return BitConverter.ToInt16(raw, at) / 32768f;
        if (bits == 24) return ((raw[at] << 8 | raw[at + 1] << 16 | raw[at + 2] << 24) >> 8) / 8388608f;
        if (bits == 32) return BitConverter.ToInt32(raw, at) / 2147483648f;
        return 0;
    }

    void Consume(IntPtr data, int frames, bool silent, int channels, int bits, bool isFloat, int bytesPerFrame) {
        if (frames <= 0) return;
        byte[] raw = null;
        if (!silent) {
            raw = new byte[frames * bytesPerFrame];
            Marshal.Copy(data, raw, 0, raw.Length);
        }
        List<float> output = new List<float>((int)(frames / step) * 2 + 4);
        int size = bits / 8;
        for (int f = 0; f < frames; f++) {
            float left = 0, right = 0;
            if (!silent) {
                left = Read(raw, f * bytesPerFrame, bits, isFloat);
                right = channels > 1 ? Read(raw, f * bytesPerFrame + size, bits, isFloat) : left;
            }
            // The outputs between the last input frame and this one, at 48 kHz.
            while (position <= 1.0) {
                output.Add(lastLeft + (left - lastLeft) * (float)position);
                output.Add(lastRight + (right - lastRight) * (float)position);
                position += step;
            }
            position -= 1.0;
            lastLeft = left; lastRight = right;
        }
        lock (gate) buffer.AddRange(output);
    }
}

// ---------------------------------------------------------------- the recorder (Media Foundation)

[ComImport, Guid("2cd2d921-c447-44a7-a13c-4adabfc247e3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFAttributes { }

[ComImport, Guid("44ae0fa8-ea31-4109-8d2e-4cae4997c555"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFMediaType {
    // IMFAttributes, in vtable order; only the setters used here have their real signature.
    void GetItem(); void GetItemType(); void CompareItem(); void Compare(); void GetUINT32(); void GetUINT64(); void GetDouble();
    void GetGUID(); void GetStringLength(); void GetString(); void GetAllocatedString(); void GetBlobSize(); void GetBlob();
    void GetAllocatedBlob(); void GetUnknown(); void SetItem(); void DeleteItem(); void DeleteAllItems();
    void SetUINT32([In] ref Guid key, int value);
    void SetUINT64([In] ref Guid key, long value);
    void SetDouble();
    void SetGUID([In] ref Guid key, [In] ref Guid value);
}

[ComImport, Guid("045FA593-8799-42b8-BC8D-8968C6453507"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFMediaBuffer {
    void Lock(out IntPtr buffer, out int maxLength, out int currentLength);
    void Unlock();
    void GetCurrentLength(out int length);
    void SetCurrentLength(int length);
}

[ComImport, Guid("c40a00f2-b93a-4d80-ae8c-5a1c634f58e4"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFSample {
    void GetItem(); void GetItemType(); void CompareItem(); void Compare(); void GetUINT32(); void GetUINT64(); void GetDouble();
    void GetGUID(); void GetStringLength(); void GetString(); void GetAllocatedString(); void GetBlobSize(); void GetBlob();
    void GetAllocatedBlob(); void GetUnknown(); void SetItem(); void DeleteItem(); void DeleteAllItems(); void SetUINT32();
    void SetUINT64(); void SetDouble(); void SetGUID(); void SetString(); void SetBlob(); void SetUnknown(); void LockStore();
    void UnlockStore(); void GetCount(); void GetItemByIndex(); void CopyAllItems();
    void GetSampleFlags(); void SetSampleFlags(); void GetSampleTime();
    void SetSampleTime(long time);
    void GetSampleDuration();
    void SetSampleDuration(long duration);
    void GetBufferCount(); void GetBufferByIndex(); void ConvertToContiguousBuffer();
    void AddBuffer(IMFMediaBuffer buffer);
}

[ComImport, Guid("3137f1cd-fe5e-4805-a5d8-fb477448cb3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMFSinkWriter {
    void AddStream(IMFMediaType type, out int streamIndex);
    void SetInputMediaType(int streamIndex, IMFMediaType type, IMFAttributes encodingParameters);
    void BeginWriting();
    void WriteSample(int streamIndex, IMFSample sample);
    void SendStreamTick(); void PlaceMarker(); void NotifyEndOfSegment(); void Flush();
    void DoFinalize();
}

// Records a part of the screen, with the mouse pointer, to an MP4 file (H.264) on its own thread, and keeps a few
// frames as PNG (one every FrameEverySeconds, at most MaxFrames) for Claude, which reads images and not video.
public sealed class SnipRecorder {
    [DllImport("mfplat.dll")] static extern int MFStartup(int version, int flags);
    [DllImport("mfplat.dll")] static extern int MFShutdown();
    [DllImport("mfplat.dll")] static extern int MFCreateMediaType(out IMFMediaType type);
    [DllImport("mfplat.dll")] static extern int MFCreateSample(out IMFSample sample);
    [DllImport("mfplat.dll")] static extern int MFCreateMemoryBuffer(int length, out IMFMediaBuffer buffer);
    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)] static extern int MFCreateSinkWriterFromURL(string url, IntPtr byteStream, IntPtr attributes, out IMFSinkWriter writer);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public POINT pt; }
    [StructLayout(LayoutKind.Sequential)] struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public IntPtr hbmMask, hbmColor; }
    [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO info);
    [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr icon, out ICONINFO info);
    [DllImport("user32.dll")] static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr icon, int w, int h, int step, IntPtr brush, int flags);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);

    static Guid MajorType = new Guid("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    static Guid Subtype = new Guid("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    static Guid Video = new Guid("73646976-0000-0010-8000-00AA00389B71");
    static Guid H264 = new Guid("34363248-0000-0010-8000-00AA00389B71");
    static Guid Rgb32 = new Guid("00000016-0000-0010-8000-00AA00389B71");
    static Guid Bitrate = new Guid("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    static Guid Interlace = new Guid("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    static Guid FrameSize = new Guid("1652c33d-d6b2-4012-b834-72030849a37d");
    static Guid FrameRate = new Guid("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    static Guid AspectRatio = new Guid("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");

    static Guid Audio = new Guid("73647561-0000-0010-8000-00AA00389B71");
    static Guid Aac = new Guid("00001610-0000-0010-8000-00AA00389B71");
    static Guid Pcm = new Guid("00000001-0000-0010-8000-00AA00389B71");
    static Guid Channels = new Guid("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    static Guid SampleRate = new Guid("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    static Guid BitsPerSample = new Guid("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");
    static Guid BytesPerSecond = new Guid("1aab75c8-cfef-451c-ab95-ac034b8e1731");
    static Guid BlockAlign = new Guid("322de230-9eeb-43bd-ab7a-ff412251541d");

    public readonly string OutputPath;
    public readonly int X, Y, Width, Height, Fps;
    // What the speakers play and the microphone, mixed into an AAC track (set before Start).
    public bool SystemAudio, Microphone;
    public string AudioError;
    public int FrameEverySeconds = 2;
    public int MaxFrames = 8;
    public string Error;
    public readonly List<string> Frames = new List<string>();
    readonly string framePrefix;
    readonly Stopwatch clock = new Stopwatch();
    Thread thread;
    volatile bool stopping;

    // H.264 needs an even width and height: the area loses a pixel when it has an odd one.
    public SnipRecorder(int x, int y, int width, int height, string outputPath, string framePrefix, int fps) {
        X = x; Y = y; Width = Math.Max(2, width & ~1); Height = Math.Max(2, height & ~1);
        OutputPath = outputPath; this.framePrefix = framePrefix; Fps = Math.Max(1, fps);
    }

    public TimeSpan Elapsed { get { return clock.Elapsed; } }
    public bool Paused { get; private set; }
    public bool Running { get { return thread != null && thread.IsAlive; } }

    public void Start() {
        thread = new Thread(Run);
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }

    public void Pause(bool on) {
        Paused = on;
        if (on) clock.Stop(); else clock.Start();
    }

    // Finishes the file; false (and Error) when it could not be written.
    public bool Stop() {
        stopping = true;
        if (thread != null) thread.Join();
        return Error == null;
    }

    static void Check(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }

    IMFMediaType NewType(Guid subtype) {
        IMFMediaType type;
        Check(MFCreateMediaType(out type));
        type.SetGUID(ref MajorType, ref Video);
        type.SetGUID(ref Subtype, ref subtype);
        type.SetUINT32(ref Interlace, 2);  // progressive
        type.SetUINT64(ref FrameSize, ((long)Width << 32) | (uint)Height);
        type.SetUINT64(ref FrameRate, ((long)Fps << 32) | 1);
        type.SetUINT64(ref AspectRatio, (1L << 32) | 1);
        return type;
    }

    // 48 kHz stereo, 16 bits: the PCM handed in, or the AAC written (24 000 bytes a second, 192 kbit/s).
    static IMFMediaType NewAudioType(Guid subtype, bool compressed) {
        IMFMediaType type;
        Check(MFCreateMediaType(out type));
        type.SetGUID(ref MajorType, ref Audio);
        type.SetGUID(ref Subtype, ref subtype);
        type.SetUINT32(ref Channels, 2);
        type.SetUINT32(ref SampleRate, SnipAudioSource.Rate);
        type.SetUINT32(ref BitsPerSample, 16);
        type.SetUINT32(ref BytesPerSecond, compressed ? 24000 : SnipAudioSource.Rate * 4);
        if (!compressed) type.SetUINT32(ref BlockAlign, 4);
        return type;
    }

    // The audio up to Until (frames at 48 kHz), in chunks of up to 100 ms: the sources mixed, silence where they had
    // nothing (the speakers send nothing while nothing plays).
    static void WriteAudio(IMFSinkWriter writer, int stream, List<SnipAudioSource> sources, ref long written, long until) {
        while (written < until) {
            int frames = (int)Math.Min(SnipAudioSource.Rate / 10, until - written);
            float[] mix = new float[frames * 2];
            foreach (SnipAudioSource source in sources) {
                source.MixInto(mix, frames);
                source.Trim(SnipAudioSource.Rate * 3 / 10);
            }
            byte[] pcm = new byte[mix.Length * 2];
            for (int i = 0; i < mix.Length; i++) {
                int v = (int)Math.Round(Math.Max(-1f, Math.Min(1f, mix[i])) * 32767);
                pcm[2 * i] = (byte)v;
                pcm[2 * i + 1] = (byte)(v >> 8);
            }
            IMFMediaBuffer buffer;
            Check(MFCreateMemoryBuffer(pcm.Length, out buffer));
            IntPtr target; int max, current;
            buffer.Lock(out target, out max, out current);
            Marshal.Copy(pcm, 0, target, pcm.Length);
            buffer.Unlock();
            buffer.SetCurrentLength(pcm.Length);
            IMFSample sample;
            Check(MFCreateSample(out sample));
            sample.AddBuffer(buffer);
            sample.SetSampleTime(written * 10000000L / SnipAudioSource.Rate);
            sample.SetSampleDuration(frames * 10000000L / SnipAudioSource.Rate);
            writer.WriteSample(stream, sample);
            Marshal.ReleaseComObject(sample);
            Marshal.ReleaseComObject(buffer);
            written += frames;
        }
    }

    void Run() {
        // The thread reads the screen in physical pixels, like the overlay that chose the area.
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        IMFSinkWriter writer = null;
        bool started = false;
        List<SnipAudioSource> sources = new List<SnipAudioSource>();
        try {
            Check(MFStartup(0x20070, 0));
            started = true;
            Check(MFCreateSinkWriterFromURL(OutputPath, IntPtr.Zero, IntPtr.Zero, out writer));
            IMFMediaType output = NewType(H264);
            // About 0.1 bit per pixel per frame: sharp text without huge files.
            output.SetUINT32(ref Bitrate, Math.Max(1000000, (int)Math.Min(int.MaxValue, (long)Width * Height * Fps / 10)));
            int stream;
            writer.AddStream(output, out stream);
            writer.SetInputMediaType(stream, NewType(Rgb32), null);
            Marshal.ReleaseComObject(output);
            if (SystemAudio) sources.Add(new SnipAudioSource(true));
            if (Microphone) sources.Add(new SnipAudioSource(false));
            int audioStream = -1;
            if (sources.Count > 0) {
                IMFMediaType aac = NewAudioType(Aac, true);
                writer.AddStream(aac, out audioStream);
                writer.SetInputMediaType(audioStream, NewAudioType(Pcm, false), null);
                Marshal.ReleaseComObject(aac);
                foreach (SnipAudioSource source in sources) source.Start();
            }
            long audioWritten = 0;
            writer.BeginWriting();

            long frameTicks = 10000000L / Fps;
            long nextFrameAt = 0;
            int length = Width * Height * 4;
            using (Bitmap bitmap = new Bitmap(Width, Height, PixelFormat.Format32bppRgb))
            using (Graphics g = Graphics.FromImage(bitmap)) {
                clock.Start();
                long written = -1;
                while (!stopping) {
                    if (Paused) {
                        // What plays while paused is left out, like the picture.
                        foreach (SnipAudioSource source in sources) source.Clear();
                        Thread.Sleep(20);
                        continue;
                    }
                    long at = clock.Elapsed.Ticks;
                    g.CopyFromScreen(X, Y, 0, 0, new Size(Width, Height), CopyPixelOperation.SourceCopy);
                    DrawPointer(g);
                    if (at >= nextFrameAt && Frames.Count < MaxFrames) {
                        string file = framePrefix + "-" + (Frames.Count + 1) + ".png";
                        bitmap.Save(file, ImageFormat.Png);
                        Frames.Add(file);
                        nextFrameAt += FrameEverySeconds * 10000000L;
                    }
                    // Media Foundation's RGB32 is bottom-up: the rows go in reverse.
                    BitmapData data = bitmap.LockBits(new Rectangle(0, 0, Width, Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
                    IMFMediaBuffer buffer;
                    Check(MFCreateMemoryBuffer(length, out buffer));
                    IntPtr target; int max, current;
                    buffer.Lock(out target, out max, out current);
                    byte[] row = new byte[Width * 4];
                    for (int y = 0; y < Height; y++) {
                        Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, row.Length);
                        Marshal.Copy(row, 0, target + (Height - 1 - y) * Width * 4, row.Length);
                    }
                    buffer.Unlock();
                    bitmap.UnlockBits(data);
                    buffer.SetCurrentLength(length);
                    IMFSample sample;
                    Check(MFCreateSample(out sample));
                    sample.AddBuffer(buffer);
                    // Times only go forward, even when a frame is captured in the same tick as the last one.
                    long time = Math.Max(at, written + 1);
                    sample.SetSampleTime(time);
                    sample.SetSampleDuration(frameTicks);
                    writer.WriteSample(stream, sample);
                    written = time;
                    Marshal.ReleaseComObject(sample);
                    Marshal.ReleaseComObject(buffer);
                    // The audio trails the clock by 100 ms, so the sources have delivered what goes there.
                    if (audioStream >= 0) WriteAudio(writer, audioStream, sources, ref audioWritten, clock.Elapsed.Ticks * SnipAudioSource.Rate / 10000000L - SnipAudioSource.Rate / 10);
                    long wait = (clock.Elapsed.Ticks - at);
                    int sleep = (int)((frameTicks - wait) / 10000);
                    if (sleep > 0) Thread.Sleep(sleep);
                }
                clock.Stop();
                if (audioStream >= 0) {
                    Thread.Sleep(120);
                    WriteAudio(writer, audioStream, sources, ref audioWritten, clock.Elapsed.Ticks * SnipAudioSource.Rate / 10000000L);
                    foreach (SnipAudioSource source in sources) {
                        source.Stop();
                        if (source.Error != null) AudioError = source.Error;
                    }
                }
            }
            writer.DoFinalize();
        } catch (Exception e) {
            Error = e.Message;
        } finally {
            foreach (SnipAudioSource source in sources) source.Stop();
            if (writer != null) Marshal.ReleaseComObject(writer);
            if (started) MFShutdown();
        }
    }

    void DrawPointer(Graphics g) {
        CURSORINFO info = new CURSORINFO();
        info.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        if (!GetCursorInfo(ref info) || (info.flags & 1) == 0) return;
        ICONINFO icon;
        int hx = 0, hy = 0;
        if (GetIconInfo(info.hCursor, out icon)) {
            hx = icon.xHotspot; hy = icon.yHotspot;
            if (icon.hbmMask != IntPtr.Zero) DeleteObject(icon.hbmMask);
            if (icon.hbmColor != IntPtr.Zero) DeleteObject(icon.hbmColor);
        }
        IntPtr hdc = g.GetHdc();
        try { DrawIconEx(hdc, info.pt.X - X - hx, info.pt.Y - Y - hy, info.hCursor, 0, 0, 0, IntPtr.Zero, 3); }
        finally { g.ReleaseHdc(hdc); }
    }
}
}
