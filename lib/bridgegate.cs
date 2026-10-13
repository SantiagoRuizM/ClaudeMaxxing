// ClaudeMaxxing gate: the forced command (authorized_keys command=) of every paired PC's key.
// It runs as the signed-in user, inside the session sshd opened, before anything the client asked for:
//   1. lets the PC in if it has an "allow for 1 hour" grant (grants.txt), otherwise drops a request in
//      requests\ and waits for the tray on this PC to answer it (the user sees a dialog), up to timeout=;
//   2. records the session in sessions\ so the tray can show and end it;
//   3. runs, with this process's own console or pipes, an interactive shell (no command), the trusted
//      sftp-server (sftp and scp), or the command through cmd.exe /c, as the stock Windows sshd does.
// Usage: cmx-gate.exe <peer id>. The bridge folder is the parent of the folder holding this exe.
// Messages are Spanish without accents on purpose: the client terminal's code page is unknown.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class ClaudeMaxxingGate
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    delegate bool ConsoleHandler(int type);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags,
        IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(ConsoleHandler handler, bool add);

    const int STARTF_USESTDHANDLES = 0x100;
    static ConsoleHandler keepHandler;
    static string sessionFile;

    public static int Main(string[] args)
    {
        string home = Path.GetDirectoryName(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\'));
        if (args.Length != 1 || !IsId(args[0])) { Say("ClaudeMaxxing: argumentos invalidos."); return 1; }
        string peer = args[0];
        var conf = ReadConf(Path.Combine(home, "gate.conf"));
        string name = Get(conf, "name", Environment.MachineName);

        // Ctrl+C typed in the remote terminal reaches every process on its console: this one must survive it
        // (a handler, not SetConsoleCtrlHandler(null, true), whose "ignore" the shell would inherit). When the
        // console closes, the session record goes with it.
        keepHandler = type =>
        {
            if (type == 0 || type == 1) return true;
            DeleteQuietly(sessionFile);
            return false;
        };
        SetConsoleCtrlHandler(keepHandler, true);

        string original = Environment.GetEnvironmentVariable("SSH_ORIGINAL_COMMAND") ?? "";
        string kind = original.Length == 0 ? "shell" : IsSftp(original) ? "sftp" : "exec";
        string client = (Environment.GetEnvironmentVariable("SSH_CLIENT") ?? "").Split(' ')[0];
        string id = Guid.NewGuid().ToString("N");
        string record = "{\"id\":" + Json(id) + ",\"peer\":" + Json(peer) + ",\"kind\":" + Json(kind) +
            ",\"command\":" + Json(kind == "exec" ? original : "") + ",\"client\":" + Json(client) +
            ",\"pid\":" + System.Diagnostics.Process.GetCurrentProcess().Id +
            ",\"at\":" + Json(DateTime.Now.ToString("o")) + "}";

        if (!HasGrant(Path.Combine(home, "grants.txt"), peer))
        {
            int timeout;
            if (!int.TryParse(Get(conf, "timeout", "60"), out timeout)) timeout = 60;
            string answer = AskTray(Path.Combine(home, "requests"), id, record, timeout);
            if (answer == null) { Say("ClaudeMaxxing: nadie respondio en " + name + " (" + timeout + " s); conexion cerrada."); return 1; }
            if (answer != "allow") { Say("ClaudeMaxxing: " + name + " no permitio esta conexion."); return 1; }
        }

        string sessions = Path.Combine(home, "sessions");
        Directory.CreateDirectory(sessions);
        sessionFile = Path.Combine(sessions, id + ".json");
        WriteAtomically(sessionFile, record);
        try
        {
            string commandLine;
            if (kind == "shell") commandLine = Get(conf, "shell", "powershell.exe -NoLogo");
            else if (kind == "sftp") commandLine = Quote(Get(conf, "sftp", "sftp-server.exe"));
            else commandLine = "cmd.exe /s /c \"" + original + "\"";
            return Run(commandLine);
        }
        finally { DeleteQuietly(sessionFile); }
    }

    // Waits for requests\<id>.answer ("allow" or "deny"); null when nobody answers in time. The waiting
    // note shows only if the tray did not answer at once.
    static string AskTray(string dir, string id, string record, int timeout)
    {
        Directory.CreateDirectory(dir);
        string request = Path.Combine(dir, id + ".json"), answerFile = Path.Combine(dir, id + ".answer");
        WriteAtomically(request, record);
        try
        {
            DateTime start = DateTime.UtcNow;
            bool told = false;
            while ((DateTime.UtcNow - start).TotalSeconds < timeout)
            {
                if (File.Exists(answerFile))
                {
                    try { return File.ReadAllText(answerFile).Trim(); } catch (IOException) { }
                }
                if (!told && (DateTime.UtcNow - start).TotalMilliseconds > 1500)
                {
                    Say("ClaudeMaxxing: esperando que alguien permita la conexion en el otro PC...");
                    told = true;
                }
                Thread.Sleep(200);
            }
            return null;
        }
        finally { DeleteQuietly(request); DeleteQuietly(answerFile); }
    }

    static int Run(string commandLine)
    {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = GetStdHandle(-10);
        si.hStdOutput = GetStdHandle(-11);
        si.hStdError = GetStdHandle(-12);
        PROCESS_INFORMATION pi;
        if (!CreateProcess(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true, 0, IntPtr.Zero, null, ref si, out pi))
        {
            Say("ClaudeMaxxing: no se pudo iniciar " + commandLine + " (error " + Marshal.GetLastWin32Error() + ").");
            return 1;
        }
        CloseHandle(pi.hThread);
        WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
        uint code;
        GetExitCodeProcess(pi.hProcess, out code);
        CloseHandle(pi.hProcess);
        return (int)code;
    }

    // sshd hands a subsystem request over as its configured command; only the trusted path from gate.conf runs.
    static bool IsSftp(string command)
    {
        return command.Trim().Trim('"').EndsWith("sftp-server.exe", StringComparison.OrdinalIgnoreCase);
    }

    static bool HasGrant(string path, string peer)
    {
        try
        {
            if (!File.Exists(path)) return false;
            long now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            foreach (string line in File.ReadAllLines(path))
            {
                string[] parts = line.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                long until;
                if (parts.Length == 2 && parts[0] == peer && long.TryParse(parts[1], out until) && until > now) return true;
            }
        }
        catch (IOException) { }
        return false;
    }

    static Dictionary<string, string> ReadConf(string path)
    {
        var conf = new Dictionary<string, string>();
        try
        {
            foreach (string line in File.ReadAllLines(path))
            {
                int eq = line.IndexOf('=');
                if (eq > 0) conf[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
            }
        }
        catch (IOException) { }
        return conf;
    }

    static string Get(Dictionary<string, string> conf, string key, string fallback)
    {
        string value;
        return conf.TryGetValue(key, out value) && value.Length > 0 ? value : fallback;
    }

    static bool IsId(string value)
    {
        if (value.Length != 12) return false;
        foreach (char c in value) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        return true;
    }

    static string Quote(string path) { return path.Contains(" ") ? "\"" + path + "\"" : path; }

    static string Json(string value)
    {
        var sb = new StringBuilder("\"");
        foreach (char c in value)
        {
            if (c == '"' || c == '\\') sb.Append('\\').Append(c);
            else if (c < 0x20 || c > 0x7e) sb.AppendFormat("\\u{0:x4}", (int)c);
            else sb.Append(c);
        }
        return sb.Append('"').ToString();
    }

    static void WriteAtomically(string path, string text)
    {
        string tmp = path + ".tmp";
        File.WriteAllText(tmp, text, new UTF8Encoding(false));
        File.Move(tmp, path);
    }

    static void DeleteQuietly(string path)
    {
        try { if (path != null && File.Exists(path)) File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    static void Say(string text) { Console.Error.WriteLine(text); }
}
