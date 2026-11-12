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
    }
}
