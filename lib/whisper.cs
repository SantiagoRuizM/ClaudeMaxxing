// Claude Whisper native side: audio capture (WASAPI), streaming speech-to-text, and the claude process.
// Everything that runs off the UI thread lives here; it only pushes strings into queues that the
// WinForms timer in whisper.ps1 drains. C# 5 only: PowerShell 5.1 compiles it with the .NET Framework csc.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ClaudeWhisper
{
    // ------------------------------------------------------------------ Core Audio interop

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumeratorCom { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        int NotUsed_EnumAudioEndpoints();
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int NotUsed_OpenPropertyStore();
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioClient
    {
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
    internal interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out int frames, out int flags, out long devicePosition, out long qpcPosition);
        [PreserveSig] int ReleaseBuffer(int frames);
        [PreserveSig] int GetNextPacketSize(out int frames);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionManager2
    {
        int NotUsed_GetAudioSessionControl();
        int NotUsed_GetSimpleAudioVolume();
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl2
    {
        [PreserveSig] int GetState(out int state);
        int NotUsed_GetDisplayName();
        int NotUsed_SetDisplayName();
        int NotUsed_GetIconPath();
        int NotUsed_SetIconPath();
        int NotUsed_GetGroupingParam();
        int NotUsed_SetGroupingParam();
        int NotUsed_RegisterAudioSessionNotification();
        int NotUsed_UnregisterAudioSessionNotification();
        int NotUsed_GetSessionIdentifier();
        int NotUsed_GetSessionInstanceIdentifier();
        [PreserveSig] int GetProcessId(out int pid);
    }

    // ------------------------------------------------------------------ capture

    // One WASAPI shared-mode stream (the speakers in loopback, or the microphone), turned into 16 kHz mono
    // PCM16 and handed out in 100 ms chunks. Runs on its own MTA thread; the COM objects never leave it.
    public sealed class AudioCapture
    {
        const int ERender = 0, ECapture = 1, EConsole = 0;
        const int LoopbackFlag = 0x00020000;
        const int SilentFlag = 0x2;
        public const int ChunkBytes = 3200; // 100 ms at 16 kHz, 16-bit mono

        readonly bool loopback;
        readonly Action<byte[]> onChunk;
        readonly Action<string> onStatus;
        Thread thread;
        volatile bool running;
        volatile float level;
        public float Level { get { return level; } }
        public string DeviceError { get; private set; }

        // Resampler state: box filter decimation from the mix rate to 16 kHz.
        double step, phase, sum;
        int count;
        readonly MemoryStream pending = new MemoryStream();

        public AudioCapture(bool loopback, Action<byte[]> onChunk, Action<string> onStatus)
        {
            this.loopback = loopback;
            this.onChunk = onChunk;
            this.onStatus = onStatus;
        }

        public void Start()
        {
            if (running) return;
            running = true;
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.SetApartmentState(ApartmentState.MTA);
            thread.Start();
        }

        public void Stop()
        {
            running = false;
            if (thread != null) thread.Join(2000);
            thread = null;
            level = 0;
        }

        void Run()
        {
            while (running)
            {
                string error = null;
                try { CaptureLoop(); }
                catch (Exception e) { error = e.Message; }
                if (!running) break;
                DeviceError = error;
                if (error != null) onStatus("device-error " + error);
                // Device gone or changed (headphones plugged in): wait a moment and open the new default.
                for (int i = 0; i < 10 && running; i++) Thread.Sleep(100);
            }
        }

        static void Check(int hr, string what)
        {
            if (hr < 0) throw new COMException(what + " failed (0x" + hr.ToString("X8") + ")", hr);
        }

        void CaptureLoop()
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            IMMDevice device;
            Check(enumerator.GetDefaultAudioEndpoint(loopback ? ERender : ECapture, EConsole, out device), "GetDefaultAudioEndpoint");
            string deviceId;
            device.GetId(out deviceId);
            Guid iidClient = typeof(IAudioClient).GUID;
            object o;
            Check(device.Activate(ref iidClient, 1 /* CLSCTX_INPROC_SERVER */, IntPtr.Zero, out o), "Activate");
            var client = (IAudioClient)o;
            IntPtr format;
            Check(client.GetMixFormat(out format), "GetMixFormat");
            int channels, rate, bits;
            bool isFloat;
            ReadFormat(format, out channels, out rate, out bits, out isFloat);
            Check(client.Initialize(0, loopback ? LoopbackFlag : 0, 2000000, 0, format, IntPtr.Zero), "Initialize");
            Marshal.FreeCoTaskMem(format);
            Guid iidCapture = typeof(IAudioCaptureClient).GUID;
            Check(client.GetService(ref iidCapture, out o), "GetService");
            var capture = (IAudioCaptureClient)o;
            step = rate / 16000.0; phase = 0; sum = 0; count = 0;
            pending.SetLength(0);
            Check(client.Start(), "Start");
            DeviceError = null;
            onStatus("device-ok " + rate + "Hz " + channels + "ch");

            var clock = Stopwatch.StartNew();
            long lastData = 0, lastDeviceCheck = 0;
            int bytesPerFrame = channels * bits / 8;
            try
            {
                while (running)
                {
                    int packet;
                    Check(capture.GetNextPacketSize(out packet), "GetNextPacketSize");
                    bool got = false;
                    while (packet > 0)
                    {
                        IntPtr data; int frames, flags; long pos, qpc;
                        Check(capture.GetBuffer(out data, out frames, out flags, out pos, out qpc), "GetBuffer");
                        Consume(data, frames, flags, channels, bits, isFloat, bytesPerFrame);
                        capture.ReleaseBuffer(frames);
                        got = true;
                        Check(capture.GetNextPacketSize(out packet), "GetNextPacketSize");
                    }
                    long now = clock.ElapsedMilliseconds;
                    if (got) lastData = now;
                    else if (loopback && now - lastData >= 100)
                    {
                        // Loopback sends nothing while nothing plays; the speech service needs a steady stream.
                        EmitSilence(1600);
                        lastData += 100;
                    }
                    if (now - lastDeviceCheck > 2000)
                    {
                        lastDeviceCheck = now;
                        IMMDevice current;
                        string currentId = null;
                        if (enumerator.GetDefaultAudioEndpoint(loopback ? ERender : ECapture, EConsole, out current) >= 0)
                        {
                            current.GetId(out currentId);
                            Marshal.ReleaseComObject(current);
                        }
                        if (currentId != null && currentId != deviceId) { onStatus("device-changed"); break; }
                    }
                    Thread.Sleep(10);
                }
            }
            finally
            {
                client.Stop();
                Marshal.ReleaseComObject(capture);
                Marshal.ReleaseComObject(client);
                Marshal.ReleaseComObject(device);
                Marshal.ReleaseComObject(enumerator);
            }
        }

        static void ReadFormat(IntPtr format, out int channels, out int rate, out int bits, out bool isFloat)
        {
            int tag = (ushort)Marshal.ReadInt16(format, 0);
            channels = (ushort)Marshal.ReadInt16(format, 2);
            rate = Marshal.ReadInt32(format, 4);
            bits = (ushort)Marshal.ReadInt16(format, 14);
            isFloat = tag == 3;
            if (tag == 0xFFFE)
            {
                // WAVEFORMATEXTENSIBLE: the SubFormat GUID starts at byte 24; its first field is the format tag.
                int sub = Marshal.ReadInt32(format, 24);
                isFloat = sub == 3;
            }
        }

        void Consume(IntPtr data, int frames, int flags, int channels, int bits, bool isFloat, int bytesPerFrame)
        {
            if (frames <= 0) return;
            bool silent = (flags & SilentFlag) != 0 || data == IntPtr.Zero;
            byte[] raw = null;
            if (!silent)
            {
                raw = new byte[frames * bytesPerFrame];
                Marshal.Copy(data, raw, 0, raw.Length);
            }
            for (int f = 0; f < frames; f++)
            {
                double mono = 0;
                if (!silent)
                {
                    int offset = f * bytesPerFrame;
                    for (int c = 0; c < channels; c++)
                    {
                        int at = offset + c * (bits / 8);
                        double s;
                        if (isFloat && bits == 32) s = BitConverter.ToSingle(raw, at);
                        else if (bits == 16) s = BitConverter.ToInt16(raw, at) / 32768.0;
                        else if (bits == 24) s = ((raw[at] << 8 | raw[at + 1] << 16 | raw[at + 2] << 24) >> 8) / 8388608.0;
                        else if (bits == 32) s = BitConverter.ToInt32(raw, at) / 2147483648.0;
                        else s = 0;
                        mono += s;
                    }
                    mono /= channels;
                }
                sum += mono; count++;
                phase += 1;
                if (phase >= step)
                {
                    phase -= step;
                    double v = count > 0 ? sum / count : 0;
                    sum = 0; count = 0;
                    WriteSample(v);
                }
            }
        }

        void EmitSilence(int samples)
        {
            for (int i = 0; i < samples; i++) WriteSample(0);
        }

        double levelAcc;
        int levelCount;

        void WriteSample(double v)
        {
            if (v > 1) v = 1; else if (v < -1) v = -1;
            short s = (short)(v * 32767);
            pending.WriteByte((byte)(s & 0xFF));
            pending.WriteByte((byte)((s >> 8) & 0xFF));
            levelAcc += v * v; levelCount++;
            if (pending.Length >= ChunkBytes)
            {
                level = (float)Math.Sqrt(levelAcc / Math.Max(1, levelCount));
                levelAcc = 0; levelCount = 0;
                byte[] chunk = pending.ToArray();
                pending.SetLength(0);
                onChunk(chunk);
            }
        }

        // Names of the processes that are recording from the default microphone right now (a meeting app).
        public static string[] MicrophoneUsers()
        {
            var names = new List<string>();
            try
            {
                var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
                IMMDevice device;
                if (enumerator.GetDefaultAudioEndpoint(ECapture, EConsole, out device) < 0) return names.ToArray();
                Guid iid = typeof(IAudioSessionManager2).GUID;
                object o;
                if (device.Activate(ref iid, 1, IntPtr.Zero, out o) < 0) return names.ToArray();
                var manager = (IAudioSessionManager2)o;
                IAudioSessionEnumerator sessions;
                if (manager.GetSessionEnumerator(out sessions) < 0) return names.ToArray();
                int n;
                sessions.GetCount(out n);
                int self = Process.GetCurrentProcess().Id;
                for (int i = 0; i < n; i++)
                {
                    IAudioSessionControl2 session;
                    if (sessions.GetSession(i, out session) < 0) continue;
                    int state, pid;
                    session.GetState(out state);
                    session.GetProcessId(out pid);
                    if (state == 1 && pid != 0 && pid != self)
                    {
                        try
                        {
                            string name = Process.GetProcessById(pid).ProcessName;
                            if (!names.Contains(name)) names.Add(name);
                        }
                        catch { }
                    }
                    Marshal.ReleaseComObject(session);
                }
            }
            catch { }
            return names.ToArray();
        }
    }

    // ------------------------------------------------------------------ speech to text

    // Streaming speech-to-text through the service Claude Code's voice dictation uses, signed in with
    // Claude Code's own OAuth token. That service is built for hold-to-talk: it streams a growing transcript
    // of everything since the connection opened and only finalizes on CloseStream. So utterances are cut
    // here: a voice detector commits the new words after a pause, and every minute or so (at a pause) the
    // connection is swapped for a fresh one and the old one is closed with CloseStream, whose final text
    // completes the last utterance. Reconnects on its own.
    // Events go to the shared queue as "source<TAB>kind<TAB>text", kind = interim | final | status | error.
    public sealed class SttStream
    {
        public const string DefaultBaseUrl = "wss://api.anthropic.com";
        const string Path = "/api/ws/speech_to_text/voice_stream";
        const string KeepAlive = "{\"type\":\"KeepAlive\"}";
        const string CloseStream = "{\"type\":\"CloseStream\"}";
        public int PauseMs = 800;         // silence that ends an utterance
        public int RotateWords = 60;      // swap the connection at the next pause after this many words...
        public int RotateSeconds = 90;    // ...or after this long
        public int StableMs = 1400;       // or when the transcript stops changing for this long
        public int MaxLineWords = 45;     // music never pauses: commit a line once it has this many new words
        public int HardRotateSeconds = 150; // and swap the connection after this long even without a pause
        public bool Trace;                // emit the detector's level for every chunk (troubleshooting)

        sealed class Conn
        {
            public ClientWebSocket Ws;
            public string Text = "";
            public int Committed;
            public bool Closing;
            public readonly Stopwatch Age = Stopwatch.StartNew();
            public readonly ManualResetEvent Ended = new ManualResetEvent(false);
        }

        readonly string source;
        readonly string language;
        readonly string keyterms;
        readonly string credentialsPath;
        readonly ConcurrentQueue<string> events;
        readonly BlockingCollection<byte[]> audio = new BlockingCollection<byte[]>(new ConcurrentQueue<byte[]>());
        readonly object gate = new object();
        Thread thread;
        volatile bool running;
        Conn active;
        public string BaseUrl = DefaultBaseUrl;
        public volatile bool Connected;

        // Voice detector: an adaptive noise floor, speech when a chunk is clearly above it.
        double floor = 0.003;
        int speechChunks, silenceChunks;
        bool inSpeech;
        readonly Stopwatch textClock = Stopwatch.StartNew();
        long textChangedAt;
        long runStartedAt = -1;           // when this side started its current stretch of continuous text
        volatile bool fatal;              // the service refused the stream for good (unsupported language)

        public SttStream(string source, string language, string keyterms, string credentialsPath, ConcurrentQueue<string> events)
        {
            this.source = source;
            this.language = string.IsNullOrEmpty(language) ? "es" : language;
            this.keyterms = keyterms ?? "";
            this.credentialsPath = credentialsPath;
            this.events = events;
        }

        void Emit(string kind, string text)
        {
            events.Enqueue(source + "\t" + kind + "\t" + (text ?? "").Replace("\t", " ").Replace("\r", " ").Replace("\n", " "));
        }

        public void Push(byte[] chunk)
        {
            if (!running) return;
            audio.Add(chunk);
            // While reconnecting, keep at most ~3 s of audio; older speech is lost rather than replayed late.
            byte[] dropped;
            while (audio.Count > 30 && audio.TryTake(out dropped)) { }
        }

        public void Start()
        {
            if (running) return;
            running = true;
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
        }

        public void Stop()
        {
            running = false;
            if (thread != null) thread.Join(4000);
            thread = null;
        }

        public static string ReadToken(string credentialsPath)
        {
            try
            {
                string json = File.ReadAllText(credentialsPath);
                Match m = Regex.Match(json, "\"claudeAiOauth\"\\s*:\\s*\\{[^}]*?\"accessToken\"\\s*:\\s*\"([^\"]+)\"");
                return m.Success ? m.Groups[1].Value : null;
            }
            catch { return null; }
        }

        // Same rules as Claude Code: printable ASCII, no commas inside a term, at most 1024 characters.
        public static string CleanKeyterms(string list)
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var parts = new List<string>();
            int total = 0;
            foreach (string item in (list ?? "").Split(new[] { ',', '\n' }))
            {
                string t = Regex.Replace(Regex.Replace(item, "[^\\x20-\\x7E]", ""), "\\s+", " ").Trim();
                if (t.Length == 0 || seen.Contains(t)) continue;
                int add = t.Length + (parts.Count > 0 ? 1 : 0);
                if (total + add > 1024) break;
                seen.Add(t); parts.Add(t); total += add;
            }
            return string.Join(",", parts);
        }

        static string[] Words(string text)
        {
            return (text ?? "").Split(new[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        }

        // The words of the connection's transcript after the ones already committed.
        static string Uncommitted(Conn c)
        {
            string[] words = Words(c.Text);
            if (c.Committed >= words.Length) return "";
            return string.Join(" ", words, c.Committed, words.Length - c.Committed);
        }

        void Commit(Conn c)
        {
            string tail;
            lock (gate)
            {
                tail = Uncommitted(c);
                c.Committed = Math.Max(c.Committed, Words(c.Text).Length);
            }
            if (tail.Length > 0) Emit("final", tail);
        }

        string BuildUrl()
        {
            return BaseUrl.TrimEnd('/') + Path + "?encoding=linear16&sample_rate=16000&channels=1&endpointing_ms=300&utterance_end_ms=1000&language="
                + Uri.EscapeDataString(language) + "&use_conversation_engine=true";
        }

        Conn Open()
        {
            string token = ReadToken(credentialsPath);
            if (token == null) throw new UnauthorizedAccessException("auth");
            var ws = new ClientWebSocket();
            ws.Options.SetRequestHeader("Authorization", "Bearer " + token);
            ws.Options.SetRequestHeader("x-app", "cli");
            ws.Options.SetRequestHeader("anthropic-client-platform", "claude_code");
            string terms = CleanKeyterms(keyterms);
            if (terms.Length > 0) ws.Options.SetRequestHeader("x-config-keyterms", terms);
            try { ws.ConnectAsync(new Uri(BuildUrl()), CancellationToken.None).Wait(15000); }
            catch (AggregateException e)
            {
                ws.Dispose();
                string message = e.InnerException != null ? e.InnerException.Message : e.Message;
                if (message.Contains("401") || message.Contains("403")) throw new UnauthorizedAccessException("auth");
                throw new Exception(message);
            }
            if (ws.State != WebSocketState.Open) { ws.Dispose(); throw new Exception("could not connect"); }
            var c = new Conn();
            c.Ws = ws;
            Send(c, KeepAlive);
            Task.Factory.StartNew(delegate { ReceiveLoop(c); }, TaskCreationOptions.LongRunning);
            return c;
        }

        void Run()
        {
            int failures = 0;
            var keepAlive = Stopwatch.StartNew();
            while (running)
            {
                if (fatal) { Wait(500); continue; }
                if (active == null || active.Ended.WaitOne(0))
                {
                    if (active != null) { Retire(active, false); active = null; }
                    Connected = false;
                    try
                    {
                        Emit("status", "connecting");
                        active = Open();
                        failures = 0;
                        Connected = true;
                        Emit("status", "open");
                    }
                    catch (UnauthorizedAccessException) { Emit("error", "auth"); failures++; }
                    catch (Exception e) { Emit("error", e.Message); failures++; }
                    if (active == null) { Wait(Math.Min(10000, 500 + 1500 * failures)); continue; }
                }

                byte[] chunk;
                if (audio.TryTake(out chunk, 200))
                {
                    if (!Send(active, chunk)) continue;
                    if (Detect(chunk)) { EndOfUtterance(); continue; }
                }
                if (StableText()) EndOfUtterance();
                else if (LongLine()) EndOfUtterance();
                else if (active != null && !active.Closing && active.Age.ElapsedMilliseconds > HardRotateSeconds * 1000L) Rotate(active);
                if (active != null && keepAlive.ElapsedMilliseconds > 8000) { keepAlive.Restart(); Send(active, KeepAlive); }
            }
            if (active != null) Retire(active, true);
            active = null;
            Connected = false;
            Emit("status", "stopped");
        }

        // True once per utterance, when a pause follows enough speech.
        bool Detect(byte[] chunk)
        {
            double acc = 0;
            int n = chunk.Length / 2;
            for (int i = 0; i + 1 < chunk.Length; i += 2)
            {
                double s = (short)(chunk[i] | chunk[i + 1] << 8) / 32768.0;
                acc += s * s;
            }
            double rms = Math.Sqrt(acc / Math.Max(1, n));
            bool speech = rms > Math.Max(0.006, floor * 3);
            if (Trace) Emit("trace", rms.ToString("0.0000", System.Globalization.CultureInfo.InvariantCulture) + (speech ? " speech" : " quiet") + " floor=" + floor.ToString("0.0000", System.Globalization.CultureInfo.InvariantCulture));
            if (!speech) floor = floor * 0.95 + rms * 0.05;
            else floor = Math.Min(floor * 1.002, 0.05);
            if (speech) { speechChunks++; silenceChunks = 0; if (speechChunks >= 2) inSpeech = true; return false; }
            silenceChunks++;
            if (!inSpeech) { speechChunks = 0; return false; }
            if (silenceChunks * 100 >= PauseMs) { inSpeech = false; speechChunks = 0; return true; }
            return false;
        }

        // For when the detector never hears a pause (music or noise under the voice): the transcript has
        // new words and stopped changing.
        bool StableText()
        {
            Conn c = active;
            if (c == null) return false;
            lock (gate)
            {
                if (Uncommitted(c).Length == 0) return false;
                return textClock.ElapsedMilliseconds - textChangedAt > StableMs;
            }
        }

        // A line that keeps growing without a pause (lyrics over music): commit it anyway.
        bool LongLine()
        {
            Conn c = active;
            if (c == null) return false;
            lock (gate) { return Words(Uncommitted(c)).Length >= MaxLineWords; }
        }

        // Milliseconds since this side's transcript last changed (someone is talking right now when small).
        public long MsSinceText
        {
            get { lock (gate) { return textChangedAt == 0 ? long.MaxValue : textClock.ElapsedMilliseconds - textChangedAt; } }
        }

        // How long this side has been producing text without a 2 s break (long when music with lyrics plays).
        public long MsTalking
        {
            get
            {
                lock (gate)
                {
                    if (runStartedAt < 0 || textClock.ElapsedMilliseconds - textChangedAt > 2000) return 0;
                    return textClock.ElapsedMilliseconds - runStartedAt;
                }
            }
        }

        void EndOfUtterance()
        {
            Conn c = active;
            if (c == null) return;
            Commit(c);
            int words;
            lock (gate) { words = Words(c.Text).Length; }
            if (words < RotateWords && c.Age.ElapsedMilliseconds < RotateSeconds * 1000L) return;
            Rotate(c);
        }

        // The new connection takes the audio from here on; the old one finalizes in the background and adds
        // any words it still had.
        void Rotate(Conn c)
        {
            Conn next;
            try { next = Open(); }
            catch { return; }
            active = next;
            Retire(c, false);
        }

        // Closes a connection after CloseStream, emitting whatever it still had uncommitted.
        void Retire(Conn c, bool wait)
        {
            lock (gate) { if (c.Closing) return; c.Closing = true; }
            Send(c, CloseStream);
            var job = Task.Factory.StartNew(delegate
            {
                c.Ended.WaitOne(3000);
                Commit(c);
                try { if (c.Ws.State == WebSocketState.Open) c.Ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None).Wait(1000); } catch { }
                try { c.Ws.Dispose(); } catch { }
            });
            if (wait) job.Wait(4500);
        }

        void Wait(int ms)
        {
            for (int waited = 0; waited < ms && running; waited += 100) Thread.Sleep(100);
        }

        static bool Send(Conn c, byte[] data, WebSocketMessageType type)
        {
            try
            {
                if (c.Ws.State != WebSocketState.Open) return false;
                lock (c) { c.Ws.SendAsync(new ArraySegment<byte>(data), type, true, CancellationToken.None).Wait(5000); }
                return true;
            }
            catch { return false; }
        }

        static bool Send(Conn c, byte[] audioChunk) { return Send(c, audioChunk, WebSocketMessageType.Binary); }
        static bool Send(Conn c, string text) { return Send(c, Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text); }

        void ReceiveLoop(Conn c)
        {
            var buffer = new byte[65536];
            var message = new MemoryStream();
            var json = new JavaScriptSerializer();
            json.MaxJsonLength = int.MaxValue;
            try
            {
                while (c.Ws.State == WebSocketState.Open)
                {
                    var result = c.Ws.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None).Result;
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        // 1003: "provider does not support the requested language". Reconnecting cannot fix it.
                        if (running && c.Ws.CloseStatus.HasValue && (int)c.Ws.CloseStatus.Value == 1003)
                        {
                            fatal = true;
                            Emit("error", "language " + c.Ws.CloseStatusDescription);
                            break;
                        }
                        if (running && !c.Closing && c.Ws.CloseStatus != WebSocketCloseStatus.NormalClosure)
                            Emit("error", "closed " + (c.Ws.CloseStatus.HasValue ? ((int)c.Ws.CloseStatus.Value).ToString() : "") + " " + c.Ws.CloseStatusDescription);
                        break;
                    }
                    message.Write(buffer, 0, result.Count);
                    if (!result.EndOfMessage) continue;
                    string text = Encoding.UTF8.GetString(message.ToArray());
                    message.SetLength(0);
                    if (Handle(c, json, text)) break;
                }
            }
            catch (Exception e)
            {
                if (running && !c.Closing) Emit("error", e.InnerException != null ? e.InnerException.Message : e.Message);
            }
            c.Ended.Set();
        }

        // Returns true when the connection is done.
        bool Handle(Conn c, JavaScriptSerializer json, string text)
        {
            Dictionary<string, object> m;
            try { m = json.Deserialize<Dictionary<string, object>>(text); } catch { return false; }
            if (m == null || !m.ContainsKey("type")) return false;
            switch (m["type"] as string)
            {
                case "TranscriptInterim":
                case "TranscriptText":
                    {
                        string data = m.ContainsKey("data") ? m["data"] as string : null;
                        if (string.IsNullOrEmpty(data)) return false;
                        string tail;
                        bool closing;
                        lock (gate)
                        {
                            if (data != c.Text)
                            {
                                long now = textClock.ElapsedMilliseconds;
                                if (runStartedAt < 0 || now - textChangedAt > 2000) runStartedAt = now;
                                textChangedAt = now;
                            }
                            c.Text = data;
                            tail = Uncommitted(c);
                            closing = c.Closing;
                        }
                        if (tail.Length > 0 && !closing) Emit("interim", tail);
                        return false;
                    }
                case "TranscriptEndpoint":
                    if (c.Closing) return true;
                    Commit(c);
                    return false;
                case "TranscriptError":
                    Emit("error", m.ContainsKey("description") ? Convert.ToString(m["description"]) : "transcription error");
                    return false;
                case "error":
                    Emit("error", m.ContainsKey("message") ? Convert.ToString(m["message"]) : "server error");
                    return false;
            }
            return false;
        }
    }

    // ------------------------------------------------------------------ engine

    // Wires the two captures to their speech streams. "them" is what the PC plays (the other side of the
    // call), "me" is the microphone. Without headphones the mic hears the speakers, so while the other side
    // is talking the mic sends silence instead (half duplex).
    public sealed class Engine
    {
        public readonly ConcurrentQueue<string> Events = new ConcurrentQueue<string>();
        AudioCapture system, mic;
        SttStream them, me;
        volatile bool micGate = true;
        Thread simulator;
        volatile bool simulating;
        public string BaseUrl = SttStream.DefaultBaseUrl;
        public int GateMs = 1500;
        public int MaxGateMs = 6000;   // mute the mic only while the other side's text is a normal turn, not music
        public int PauseMs = 800, RotateWords = 60, RotateSeconds = 90;
        public bool Trace;

        public float SystemLevel { get { return system != null ? system.Level : 0; } }
        public float MicLevel { get { return mic != null ? mic.Level : 0; } }
        public bool ThemConnected { get { return them != null && them.Connected; } }
        public bool MeConnected { get { return me != null && me.Connected; } }
        public bool Running { get { return them != null; } }

        SttStream NewStream(string source, string language, string keyterms, string credentialsPath)
        {
            var s = new SttStream(source, language, keyterms, credentialsPath, Events);
            s.BaseUrl = BaseUrl;
            s.PauseMs = PauseMs;
            s.RotateWords = RotateWords;
            s.RotateSeconds = RotateSeconds;
            s.Trace = Trace;
            s.Start();
            return s;
        }

        public void Start(string language, string keyterms, bool useMic, bool gateMic, string credentialsPath)
        {
            Stop();
            micGate = gateMic;
            them = NewStream("them", language, keyterms, credentialsPath);
            system = new AudioCapture(true, OnSystemChunk, delegate(string s) { Events.Enqueue("them\tdevice\t" + s); });
            system.Start();
            if (useMic)
            {
                me = NewStream("me", language, keyterms, credentialsPath);
                mic = new AudioCapture(false, OnMicChunk, delegate(string s) { Events.Enqueue("me\tdevice\t" + s); });
                mic.Start();
            }
        }

        // Feeds a 16 kHz mono 16-bit WAV as the other side, in real time, instead of the speakers (tests).
        public void StartSimulation(string wavPath, string language, string keyterms, string credentialsPath)
        {
            Stop();
            them = NewStream("them", language, keyterms, credentialsPath);
            byte[] wav = File.ReadAllBytes(wavPath);
            simulating = true;
            simulator = new Thread(delegate()
            {
                var silence = new byte[AudioCapture.ChunkBytes];
                var sw = Stopwatch.StartNew();
                long sent = 0;
                int pos = 44;
                while (simulating)
                {
                    byte[] chunk;
                    if (pos < wav.Length)
                    {
                        int n = Math.Min(AudioCapture.ChunkBytes, wav.Length - pos);
                        chunk = new byte[AudioCapture.ChunkBytes];
                        Array.Copy(wav, pos, chunk, 0, n);
                        pos += n;
                    }
                    else chunk = silence;
                    if (them != null) them.Push(chunk);
                    sent += 100;
                    long ahead = sent - sw.ElapsedMilliseconds;
                    if (ahead > 0) Thread.Sleep((int)ahead);
                }
            });
            simulator.IsBackground = true;
            simulator.Start();
        }

        void OnSystemChunk(byte[] chunk)
        {
            var s = them;
            if (s != null) s.Push(chunk);
        }

        // Gated on the other side's transcript, not on the speaker level: music playing on the PC must not
        // mute the mic, only someone talking does. Lyrics are transcript too, so after MaxGateMs of continuous
        // text (a song, not a turn in a conversation) the mic opens again; echo lines are dropped later.
        void OnMicChunk(byte[] chunk)
        {
            var s = me;
            if (s == null) return;
            var t = them;
            if (micGate && t != null && t.MsSinceText < GateMs && t.MsTalking < MaxGateMs) s.Push(new byte[chunk.Length]);
            else s.Push(chunk);
        }

        public void Stop()
        {
            simulating = false;
            if (simulator != null) { simulator.Join(1000); simulator = null; }
            if (system != null) { system.Stop(); system = null; }
            if (mic != null) { mic.Stop(); mic = null; }
            var a = them; var b = me;
            them = null; me = null;
            if (a != null) a.Stop();
            if (b != null) b.Stop();
        }
    }

    // ------------------------------------------------------------------ claude -p

    // A long-lived `claude -p` in stream-json mode: one process for the whole call, so every answer keeps
    // the conversation and skips the start-up time. stdout lines go to Lines; stderr is drained so a full
    // pipe can never stall it.
    public sealed class ClaudeProcess
    {
        public readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
        readonly Queue<string> errors = new Queue<string>();
        Process process;
        StreamWriter input;

        public int Pid { get { return process != null ? process.Id : 0; } }
        public bool HasExited { get { try { return process == null || process.HasExited; } catch { return true; } } }

        public void Start(string fileName, string arguments, string workingDirectory, string[] removeEnv, string[] setEnv)
        {
            var psi = new ProcessStartInfo(fileName, arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;
            psi.WorkingDirectory = workingDirectory;
            if (removeEnv != null)
                foreach (string name in removeEnv)
                    if (psi.EnvironmentVariables.ContainsKey(name)) psi.EnvironmentVariables.Remove(name);
            psi.EnvironmentVariables["CLAUDEVOICE"] = "off";
            if (setEnv != null)
                for (int i = 0; i + 1 < setEnv.Length; i += 2) psi.EnvironmentVariables[setEnv[i]] = setEnv[i + 1];
            process = new Process();
            process.StartInfo = psi;
            process.EnableRaisingEvents = true;
            process.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) Lines.Enqueue(e.Data); };
            process.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data == null) return;
                lock (errors) { errors.Enqueue(e.Data); while (errors.Count > 20) errors.Dequeue(); }
            };
            process.Start();
            input = new StreamWriter(process.StandardInput.BaseStream, new UTF8Encoding(false));
            input.AutoFlush = true;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }

        public bool Send(string line)
        {
            try { input.WriteLine(line); return true; } catch { return false; }
        }

        public string LastErrors()
        {
            lock (errors) { return string.Join("\n", errors.ToArray()); }
        }

        public void Kill()
        {
            if (process == null) return;
            try { input.Close(); } catch { }
            try { if (!process.WaitForExit(1500)) process.Kill(); } catch { }
            try { process.Dispose(); } catch { }
            process = null;
        }
    }

    // ------------------------------------------------------------------ hotkeys

    // Global hotkeys through a hidden window on the UI thread; pressed ids go to Pressed.
    public sealed class Hotkeys : NativeWindow, IDisposable
    {
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        public readonly ConcurrentQueue<int> Pressed = new ConcurrentQueue<int>();
        readonly List<int> ids = new List<int>();

        public Hotkeys() { CreateHandle(new CreateParams()); }

        // mods: 1 Alt, 2 Ctrl, 4 Shift, 8 Win. 0x4000 = no auto-repeat.
        public bool Register(int id, uint mods, uint vk)
        {
            bool ok = RegisterHotKey(Handle, id, mods | 0x4000, vk);
            if (ok) ids.Add(id);
            return ok;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312) Pressed.Enqueue(m.WParam.ToInt32());
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            foreach (int id in ids) UnregisterHotKey(Handle, id);
            ids.Clear();
            DestroyHandle();
        }
    }

    // ------------------------------------------------------------------ small UI helpers

    public static class Ui
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

        // Grey hint text shown in an empty text box (EM_SETCUEBANNER).
        public static void SetCueBanner(TextBox box, string text)
        {
            SendMessage(box.Handle, 0x1501, (IntPtr)1, text);
        }
    }
}
