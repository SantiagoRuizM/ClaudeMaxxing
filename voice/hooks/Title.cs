using System;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeVoice
{
    // The terminal tab's title of a menu session, written by its hooks: Claude Code runs there with
    // CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1, so no spark or spinner goes before the name.
    public static class Title
    {
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(int pid);
        [DllImport("kernel32.dll")] static extern bool FreeConsole();
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteFile(IntPtr handle, byte[] buffer, int length, out int written, IntPtr overlapped);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

        // Writes the title (OSC 0) into the console of process $pid, the session's claude: its terminal shows it.
        // A hook has no console of its own worth keeping (its stdout is a pipe), so it leaves it for the moment.
        public static bool Set(int pid, string text)
        {
            StringBuilder clean = new StringBuilder();
            foreach (char c in text ?? "") { if (!char.IsControl(c)) clean.Append(c); }
            FreeConsole();
            if (!AttachConsole(pid)) return false;
            try
            {
                // GENERIC_READ | GENERIC_WRITE, shared, OPEN_EXISTING
                IntPtr handle = CreateFile("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
                if (handle == new IntPtr(-1)) return false;
                byte[] bytes = new UTF8Encoding(false).GetBytes("\u001b]0;" + clean + "\u0007");
                int written;
                bool ok = WriteFile(handle, bytes, bytes.Length, out written, IntPtr.Zero);
                CloseHandle(handle);
                return ok && written == bytes.Length;
            }
            finally { FreeConsole(); }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct ProcessEntry
        {
            public uint dwSize, cntUsage, th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID, cntThreads, th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
        }
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref ProcessEntry entry);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref ProcessEntry entry);

        // The nearest ancestor of $pid (itself included) whose exe starts with $prefix, or 0. One process snapshot
        // instead of a WMI query per level: hooks run this on every prompt, and WMI costs ~200 ms a level.
        public static int FindAncestor(int pid, string prefix, int depth)
        {
            var parents = new System.Collections.Generic.Dictionary<int, int>();
            var names = new System.Collections.Generic.Dictionary<int, string>();
            IntPtr snap = CreateToolhelp32Snapshot(2, 0);  // TH32CS_SNAPPROCESS
            if (snap == new IntPtr(-1)) return 0;
            try
            {
                var e = new ProcessEntry();
                e.dwSize = (uint)Marshal.SizeOf(typeof(ProcessEntry));
                for (bool ok = Process32FirstW(snap, ref e); ok; ok = Process32NextW(snap, ref e))
                {
                    parents[(int)e.th32ProcessID] = (int)e.th32ParentProcessID;
                    names[(int)e.th32ProcessID] = e.szExeFile ?? "";
                }
            }
            finally { CloseHandle(snap); }
            for (int i = 0; i < depth && pid > 0; i++)
            {
                string name;
                if (!names.TryGetValue(pid, out name)) return 0;
                if (name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return pid;
                pid = parents[pid];
            }
            return 0;
        }
    }
}
