// ClaudeMaxxing for the phone (lib\mobile.ps1): the HTTPS server the app talks to, and the QR it pairs with.
//
// MobileGate: a TCP listener (IPv4 and IPv6) that only takes connections from loopback, private networks and
// Tailscale, wraps each one in TLS with this PC's self-signed certificate (the app pins its SHA-256 from the QR),
// reads one HTTP/1.1 request and queues it. The tray drains the queue on its UI thread (MobileTimer), where the
// hub's functions live, and answers; the worker thread writes the answer and closes the connection.
//
// QrCode: byte-mode QR codes, versions 1 to 40, after Project Nayuki's QR Code generator (MIT License,
// Copyright (c) Project Nayuki, https://www.nayuki.io/page/qr-code-generator-library). Mask penalty without the
// finder-like rule: any mask decodes, the penalty only picks a cleaner one.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ClaudeTray
{
    public sealed class MobileRequest
    {
        public string Method = "";
        public string Path = "";
        public string Query = "";
        public string Body = "";
        // The raw body of an upload (Content-Type application/octet-stream); Body stays empty then.
        public byte[] BodyBytes = new byte[0];
        public string Remote = "";
        public string Token = "";
        internal TaskCompletionSource<string[]> Done = new TaskCompletionSource<string[]>();

        // Status and JSON body; the worker thread sends them.
        public void Answer(int status, string json) { Done.TrySetResult(new string[] { status.ToString(), json ?? "{}" }); }
    }

    // The dark screen (lib\mobile.ps1): asks Windows to keep the PC and its display on, so Modern Standby never
    // pauses the sessions. Per thread: called on and off from the tray's UI thread.
    public static class MobilePower
    {
        [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
        // ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED, or ES_CONTINUOUS alone to let go.
        public static void KeepAwake(bool on) { SetThreadExecutionState(on ? 0x80000003u : 0x80000000u); }
    }

    public static class MobileGate
    {
        const int MaxHeaderBytes = 16 * 1024;
        const int MaxBodyBytes = 1024 * 1024;
        const int MaxUploadBytes = 25 * 1024 * 1024;
        const int IoTimeoutMs = 15000;
        const int AnswerTimeoutMs = 30000;

        static TcpListener listener;
        static X509Certificate2 certificate;
        static readonly ConcurrentQueue<MobileRequest> queue = new ConcurrentQueue<MobileRequest>();
        static volatile bool running;
        static int active;
        public static string LastError = "";

        public static bool Running { get { return running; } }

        public static void Start(int port, X509Certificate2 cert)
        {
            Stop();
            certificate = cert;
            var l = new TcpListener(IPAddress.IPv6Any, port);
            l.Server.SetSocketOption(SocketOptionLevel.IPv6, SocketOptionName.IPv6Only, false);
            l.Start();
            listener = l;
            running = true;
            LastError = "";
            var thread = new Thread(AcceptLoop);
            thread.IsBackground = true;
            thread.Name = "ClaudeMaxxing mobile";
            thread.Start(l);
        }

        public static void Stop()
        {
            running = false;
            var l = listener;
            listener = null;
            if (l != null) { try { l.Stop(); } catch { } }
            MobileRequest pending;
            while (queue.TryDequeue(out pending)) pending.Answer(503, "{\"error\":\"stopped\"}");
        }

        // The next request for the tray, or null.
        public static MobileRequest Next()
        {
            MobileRequest r;
            return queue.TryDequeue(out r) ? r : null;
        }

        static void AcceptLoop(object state)
        {
            var l = (TcpListener)state;
            while (running && listener == l)
            {
                TcpClient client;
                try { client = l.AcceptTcpClient(); }
                catch (Exception e) { if (running && listener == l) LastError = e.Message; return; }
                // A flood of connections must not pile up threads.
                if (Interlocked.Increment(ref active) > 16) { Interlocked.Decrement(ref active); client.Close(); continue; }
                ThreadPool.QueueUserWorkItem(Serve, client);
            }
        }

        // Loopback, 10/8, 172.16/12, 192.168/16, 169.254/16, Tailscale's 100.64/10; IPv6 loopback, link-local, ULA.
        public static bool IsAllowed(IPAddress address)
        {
            if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
            if (IPAddress.IsLoopback(address)) return true;
            byte[] b = address.GetAddressBytes();
            if (address.AddressFamily == AddressFamily.InterNetwork)
            {
                return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) ||
                    (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
            }
            if (address.AddressFamily == AddressFamily.InterNetworkV6)
            {
                return address.IsIPv6LinkLocal || (b[0] & 0xFE) == 0xFC;
            }
            return false;
        }

        static void Serve(object state)
        {
            var client = (TcpClient)state;
            try
            {
                var remote = (IPEndPoint)client.Client.RemoteEndPoint;
                if (!IsAllowed(remote.Address)) return;
                client.ReceiveTimeout = IoTimeoutMs;
                client.SendTimeout = IoTimeoutMs;
                using (var ssl = new SslStream(client.GetStream(), false))
                {
                    ssl.ReadTimeout = IoTimeoutMs;
                    ssl.WriteTimeout = IoTimeoutMs;
                    ssl.AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false);
                    var request = ReadRequest(ssl);
                    string[] answer;
                    if (request == null) answer = new string[] { "400", "{\"error\":\"bad request\"}" };
                    else
                    {
                        request.Remote = remote.Address.IsIPv4MappedToIPv6 ? remote.Address.MapToIPv4().ToString() : remote.Address.ToString();
                        queue.Enqueue(request);
                        answer = request.Done.Task.Wait(AnswerTimeoutMs) ? request.Done.Task.Result : new string[] { "503", "{\"error\":\"busy\"}" };
                    }
                    Write(ssl, int.Parse(answer[0]), answer[1]);
                }
            }
            catch { }
            finally
            {
                try { client.Close(); } catch { }
                Interlocked.Decrement(ref active);
            }
        }

        static MobileRequest ReadRequest(Stream stream)
        {
            var head = new MemoryStream();
            int matched = 0;
            while (matched < 4)
            {
                int b = stream.ReadByte();
                if (b < 0 || head.Length >= MaxHeaderBytes) return null;
                head.WriteByte((byte)b);
                matched = (b == (matched % 2 == 0 ? '\r' : '\n')) ? matched + 1 : (b == '\r' ? 1 : 0);
            }
            string[] lines = Encoding.ASCII.GetString(head.ToArray()).Split(new string[] { "\r\n" }, StringSplitOptions.None);
            string[] first = lines[0].Split(' ');
            if (first.Length < 3) return null;
            var request = new MobileRequest();
            request.Method = first[0].ToUpperInvariant();
            string target = first[1];
            int q = target.IndexOf('?');
            request.Path = q < 0 ? target : target.Substring(0, q);
            request.Query = q < 0 ? "" : target.Substring(q + 1);
            int length = 0;
            bool binary = false;
            string lengthText = null;
            for (int i = 1; i < lines.Length; i++)
            {
                int colon = lines[i].IndexOf(':');
                if (colon <= 0) continue;
                string name = lines[i].Substring(0, colon).Trim().ToLowerInvariant();
                string value = lines[i].Substring(colon + 1).Trim();
                if (name == "content-length") lengthText = value;
                if (name == "content-type" && value.StartsWith("application/octet-stream", StringComparison.OrdinalIgnoreCase)) binary = true;
                if (name == "authorization" && value.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) request.Token = value.Substring(7).Trim();
            }
            // JSON up to 1 MB; a file the phone sends, up to 25 MB.
            if (lengthText != null && (!int.TryParse(lengthText, out length) || length < 0 || length > (binary ? MaxUploadBytes : MaxBodyBytes))) return null;
            if (length > 0)
            {
                var body = new byte[length];
                int read = 0;
                while (read < length)
                {
                    int n = stream.Read(body, read, length - read);
                    if (n <= 0) return null;
                    read += n;
                }
                if (binary) request.BodyBytes = body; else request.Body = Encoding.UTF8.GetString(body);
            }
            return request;
        }

        static void Write(Stream stream, int status, string json)
        {
            byte[] body = Encoding.UTF8.GetBytes(json);
            string reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : status == 400 ? "Bad Request" : "Error";
            string head = "HTTP/1.1 " + status + " " + reason + "\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: " +
                body.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
            byte[] h = Encoding.ASCII.GetBytes(head);
            stream.Write(h, 0, h.Length);
            stream.Write(body, 0, body.Length);
            stream.Flush();
        }

        // Writes one line to a Claude Code session's cross-session inbox (a named pipe): the auth line, then the message.
        public static void SendToInbox(string pipePath, string authLine, string messageLine)
        {
            const string prefix = @"\\.\pipe\";
            if (!pipePath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("not a named pipe: " + pipePath);
            using (var pipe = new System.IO.Pipes.NamedPipeClientStream(".", pipePath.Substring(prefix.Length), System.IO.Pipes.PipeDirection.InOut))
            {
                pipe.Connect(3000);
                byte[] data = new UTF8Encoding(false).GetBytes(authLine + "\n" + messageLine + "\n");
                pipe.Write(data, 0, data.Length);
                pipe.Flush();
            }
        }
    }

    public sealed class QrCode
    {
        // Error correction: 0 = L, 1 = M, 2 = Q, 3 = H.
        static readonly int[,] EccCodewordsPerBlock = {
            { -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
            { -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
            { -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
            { -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 } };
        static readonly int[,] NumErrorCorrectionBlocks = {
            { -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
            { -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
            { -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
            { -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 } };
        static readonly int[] FormatBits = { 1, 0, 3, 2 };

        int version, size, ecl;
        bool[,] modules, isFunction;

        // The dark modules of the QR for Text (UTF-8, byte mode): [y, x], true = dark. Ecc 0..3 = L, M, Q, H.
        public static bool[,] Encode(string text, int ecc)
        {
            byte[] data = new UTF8Encoding(false).GetBytes(text);
            int ver = 1;
            for (; ; ver++)
            {
                if (ver > 40) throw new ArgumentException("text too long for a QR code");
                int countBits = ver <= 9 ? 8 : 16;
                if (4 + countBits + data.Length * 8 <= NumDataCodewords(ver, ecc) * 8) break;
            }
            var bits = new List<bool>();
            AppendBits(bits, 4, 4);
            AppendBits(bits, data.Length, ver <= 9 ? 8 : 16);
            foreach (byte b in data) AppendBits(bits, b, 8);
            int capacity = NumDataCodewords(ver, ecc) * 8;
            AppendBits(bits, 0, Math.Min(4, capacity - bits.Count));
            AppendBits(bits, 0, (8 - bits.Count % 8) % 8);
            for (int pad = 0xEC; bits.Count < capacity; pad ^= 0xEC ^ 0x11) AppendBits(bits, pad, 8);
            var codewords = new byte[bits.Count / 8];
            for (int i = 0; i < bits.Count; i++) if (bits[i]) codewords[i >> 3] |= (byte)(1 << (7 - (i & 7)));
            var qr = new QrCode();
            qr.Build(ver, ecc, codewords);
            return qr.modules;
        }

        static void AppendBits(List<bool> bits, int value, int length)
        {
            for (int i = length - 1; i >= 0; i--) bits.Add(((value >> i) & 1) != 0);
        }

        static int NumRawDataModules(int ver)
        {
            int result = (16 * ver + 128) * ver + 64;
            if (ver >= 2)
            {
                int numAlign = ver / 7 + 2;
                result -= (25 * numAlign - 10) * numAlign - 55;
                if (ver >= 7) result -= 36;
            }
            return result;
        }

        static int NumDataCodewords(int ver, int ecc)
        {
            return NumRawDataModules(ver) / 8 - EccCodewordsPerBlock[ecc, ver] * NumErrorCorrectionBlocks[ecc, ver];
        }

        void Build(int ver, int ecc, byte[] data)
        {
            version = ver; ecl = ecc; size = ver * 4 + 17;
            modules = new bool[size, size];
            isFunction = new bool[size, size];
            DrawFunctionPatterns();
            DrawCodewords(AddEccAndInterleave(data));
            int best = 0;
            long bestPenalty = long.MaxValue;
            for (int mask = 0; mask < 8; mask++)
            {
                ApplyMask(mask);
                DrawFormatBits(mask);
                long penalty = Penalty();
                if (penalty < bestPenalty) { best = mask; bestPenalty = penalty; }
                ApplyMask(mask);
            }
            ApplyMask(best);
            DrawFormatBits(best);
        }

        void SetFunction(int x, int y, bool dark) { modules[y, x] = dark; isFunction[y, x] = true; }

        void DrawFunctionPatterns()
        {
            for (int i = 0; i < size; i++) { SetFunction(6, i, i % 2 == 0); SetFunction(i, 6, i % 2 == 0); }
            DrawFinder(3, 3); DrawFinder(size - 4, 3); DrawFinder(3, size - 4);
            int[] align = AlignmentPositions();
            int n = align.Length;
            for (int i = 0; i < n; i++)
                for (int j = 0; j < n; j++)
                    if (!((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0))) DrawAlignment(align[i], align[j]);
            DrawFormatBits(0);
            DrawVersion();
        }

        void DrawFinder(int x, int y)
        {
            for (int dy = -4; dy <= 4; dy++)
                for (int dx = -4; dx <= 4; dx++)
                {
                    int dist = Math.Max(Math.Abs(dx), Math.Abs(dy));
                    int xx = x + dx, yy = y + dy;
                    if (xx >= 0 && xx < size && yy >= 0 && yy < size) SetFunction(xx, yy, dist != 2 && dist != 4);
                }
        }

        void DrawAlignment(int x, int y)
        {
            for (int dy = -2; dy <= 2; dy++)
                for (int dx = -2; dx <= 2; dx++) SetFunction(x + dx, y + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
        }

        int[] AlignmentPositions()
        {
            if (version == 1) return new int[0];
            int numAlign = version / 7 + 2;
            int step = (version * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4) * 2;
            var result = new int[numAlign];
            result[0] = 6;
            for (int i = numAlign - 1, pos = size - 7; i >= 1; i--, pos -= step) result[i] = pos;
            return result;
        }

        static bool Bit(int value, int i) { return ((value >> i) & 1) != 0; }

        void DrawFormatBits(int mask)
        {
            int data = FormatBits[ecl] << 3 | mask;
            int rem = data;
            for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) * 0x537);
            int bits = (data << 10 | rem) ^ 0x5412;
            for (int i = 0; i <= 5; i++) SetFunction(8, i, Bit(bits, i));
            SetFunction(8, 7, Bit(bits, 6));
            SetFunction(8, 8, Bit(bits, 7));
            SetFunction(7, 8, Bit(bits, 8));
            for (int i = 9; i < 15; i++) SetFunction(14 - i, 8, Bit(bits, i));
            for (int i = 0; i < 8; i++) SetFunction(size - 1 - i, 8, Bit(bits, i));
            for (int i = 8; i < 15; i++) SetFunction(8, size - 15 + i, Bit(bits, i));
            SetFunction(8, size - 8, true);
        }

        void DrawVersion()
        {
            if (version < 7) return;
            int rem = version;
            for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
            int bits = version << 12 | rem;
            for (int i = 0; i < 18; i++)
            {
                bool bit = Bit(bits, i);
                int a = size - 11 + i % 3, b = i / 3;
                SetFunction(a, b, bit);
                SetFunction(b, a, bit);
            }
        }

        byte[] AddEccAndInterleave(byte[] data)
        {
            int numBlocks = NumErrorCorrectionBlocks[ecl, version];
            int blockEccLen = EccCodewordsPerBlock[ecl, version];
            int rawCodewords = NumRawDataModules(version) / 8;
            int numShortBlocks = numBlocks - rawCodewords % numBlocks;
            int shortBlockLen = rawCodewords / numBlocks;
            byte[] divisor = ReedSolomonDivisor(blockEccLen);
            var blocks = new List<byte[]>();
            for (int i = 0, k = 0; i < numBlocks; i++)
            {
                int datLen = shortBlockLen - blockEccLen + (i < numShortBlocks ? 0 : 1);
                var dat = new byte[datLen];
                Array.Copy(data, k, dat, 0, datLen);
                k += datLen;
                byte[] ecc = ReedSolomonRemainder(dat, divisor);
                var block = new byte[shortBlockLen + 1];
                Array.Copy(dat, 0, block, 0, datLen);
                // Short blocks get a placeholder byte after the data so every block has the same length.
                Array.Copy(ecc, 0, block, block.Length - blockEccLen, blockEccLen);
                blocks.Add(block);
            }
            var result = new List<byte>(rawCodewords);
            for (int i = 0; i < blocks[0].Length; i++)
                for (int j = 0; j < blocks.Count; j++)
                    if (i != shortBlockLen - blockEccLen || j >= numShortBlocks) result.Add(blocks[j][i]);
            return result.ToArray();
        }

        static byte[] ReedSolomonDivisor(int degree)
        {
            var result = new byte[degree];
            result[degree - 1] = 1;
            int root = 1;
            for (int i = 0; i < degree; i++)
            {
                for (int j = 0; j < degree; j++)
                {
                    result[j] = (byte)Multiply(result[j], root);
                    if (j + 1 < degree) result[j] ^= result[j + 1];
                }
                root = Multiply(root, 0x02);
            }
            return result;
        }

        static byte[] ReedSolomonRemainder(byte[] data, byte[] divisor)
        {
            var result = new byte[divisor.Length];
            foreach (byte b in data)
            {
                int factor = b ^ result[0];
                Array.Copy(result, 1, result, 0, result.Length - 1);
                result[result.Length - 1] = 0;
                for (int i = 0; i < result.Length; i++) result[i] ^= (byte)Multiply(divisor[i], factor);
            }
            return result;
        }

        static int Multiply(int x, int y)
        {
            int z = 0;
            for (int i = 7; i >= 0; i--)
            {
                z = (z << 1) ^ ((z >> 7) * 0x11D);
                z ^= ((y >> i) & 1) * x;
            }
            return z & 0xFF;
        }

        void DrawCodewords(byte[] data)
        {
            int i = 0;
            for (int right = size - 1; right >= 1; right -= 2)
            {
                if (right == 6) right = 5;
                for (int vert = 0; vert < size; vert++)
                    for (int j = 0; j < 2; j++)
                    {
                        int x = right - j;
                        bool upward = ((right + 1) & 2) == 0;
                        int y = upward ? size - 1 - vert : vert;
                        if (!isFunction[y, x] && i < data.Length * 8)
                        {
                            modules[y, x] = ((data[i >> 3] >> (7 - (i & 7))) & 1) != 0;
                            i++;
                        }
                    }
            }
        }

        void ApplyMask(int mask)
        {
            for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                {
                    bool invert;
                    switch (mask)
                    {
                        case 0: invert = (x + y) % 2 == 0; break;
                        case 1: invert = y % 2 == 0; break;
                        case 2: invert = x % 3 == 0; break;
                        case 3: invert = (x + y) % 3 == 0; break;
                        case 4: invert = (x / 3 + y / 2) % 2 == 0; break;
                        case 5: invert = x * y % 2 + x * y % 3 == 0; break;
                        case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0; break;
                        default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0; break;
                    }
                    if (invert && !isFunction[y, x]) modules[y, x] = !modules[y, x];
                }
        }

        long Penalty()
        {
            long result = 0;
            for (int pass = 0; pass < 2; pass++)
                for (int a = 0; a < size; a++)
                {
                    int run = 0;
                    bool color = false;
                    for (int b = 0; b < size; b++)
                    {
                        bool m = pass == 0 ? modules[a, b] : modules[b, a];
                        if (b > 0 && m == color) { run++; if (run == 5) result += 3; else if (run > 5) result++; }
                        else { color = m; run = 1; }
                    }
                }
            int dark = 0;
            for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                {
                    if (modules[y, x]) dark++;
                    if (x < size - 1 && y < size - 1)
                    {
                        bool c = modules[y, x];
                        if (c == modules[y, x + 1] && c == modules[y + 1, x] && c == modules[y + 1, x + 1]) result += 3;
                    }
                }
            int total = size * size;
            int k = (Math.Abs(dark * 20 - total * 10) + total - 1) / total - 1;
            result += Math.Max(0, k) * 10;
            return result;
        }
    }
}
