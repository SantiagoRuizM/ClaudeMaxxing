// Statistics for the ClaudeMaxxing window: when and how much you work with Claude Code, read from Claude
// Code's own transcripts (~/.claude/projects/<project>/<session>.jsonl, subagents in <session>/subagents).
// Lines are not fully parsed (there are hundreds of MB): a few anchored regexes take the fields needed.
// Each file's summary is cached by size and write time, so later scans only read what changed. The cache is
// also the history: Claude Code deletes transcripts after 30 days (cleanupPeriodDays), and the summaries of
// deleted files are kept, so "all time" keeps growing.
// Active time: the gaps between consecutive events of a session, when shorter than IdleGap; a lone event
// counts one minute. Times are local. Keep this file ASCII.
// Consumption: tokens per hour and model; the API-equivalent cost is computed when summarizing, with the
// price table Ponytail ships (github.com/DietrichGebert/ponytail, MIT; read from its installed plugin
// when there is one, see lib\forecast.ps1) or the copy below. A reply without token counts adds the cost
// Claude Code wrote down for it (costUSD, or the session's cost-state total when nothing else is there).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace ClaudeMaxxing
{
    public class DayStats
    {
        public int Seconds;
        public int Prompts;
        public int Responses;
        public int ToolCalls;
        public Dictionary<string, int> Tools = new Dictionary<string, int>();
        // model -> messages, input, output, cache read, cache write
        public Dictionary<string, long[]> Models = new Dictionary<string, long[]>();
    }

    public class FileStats
    {
        public int Version;
        public string Path;
        public long Length;
        public long Stamp;
        public bool Subagent;
        public string Project;
        public string First;
        public string Last;
        public int Seconds;
        public int Prompts;
        public int Responses;
        public Dictionary<string, DayStats> Days = new Dictionary<string, DayStats>();
        // "yyyy-MM-dd HH" -> seconds, prompts
        public Dictionary<string, int[]> Hours = new Dictionary<string, int[]>();
        // active stretches as unix seconds [start, end], to count wall-clock time across parallel sessions
        public List<long[]> Spans = new List<long[]>();
        // "yyyy-MM-dd HH|model" -> messages, input, output, cache read, cache write, of which 1-hour cache write
        public Dictionary<string, long[]> HourModels = new Dictionary<string, long[]>();
        // "yyyy-MM-dd HH" -> USD Claude Code recorded for replies that have no token counts
        public Dictionary<string, double> HourCost = new Dictionary<string, double>();
    }

    public static class Stats
    {
        public const int IdleGap = 15 * 60;
        // Bump when FileStats changes: cached summaries of another version are read again while their
        // transcript exists; those of deleted transcripts are kept as they are (they are the only history).
        const int FormatVersion = 3;
        const int OldestVersion = 2;
        const int LoneEvent = 60;

        static readonly Regex Kind = new Regex("\"type\":\"(assistant|user)\",\"(?:message|uuid)\"", RegexOptions.Compiled);
        static readonly Regex StampRx = new Regex("\"uuid\":\"[^\"]*\",\"timestamp\":\"([^\"]+)\"", RegexOptions.Compiled);
        static readonly Regex AnyStamp = new Regex("\"timestamp\":\"(\\d{4}-\\d\\d-\\d\\dT[^\"]+)\"", RegexOptions.Compiled);
        static readonly Regex CwdRx = new Regex("\"cwd\":\"((?:[^\"\\\\]|\\\\.)*)\"", RegexOptions.Compiled);
        static readonly Regex ModelRx = new Regex("\"model\":\"([^\"]+)\"", RegexOptions.Compiled);
        static readonly Regex MsgIdRx = new Regex("\"id\":\"(msg_[^\"]+)\"", RegexOptions.Compiled);
        static readonly Regex ToolRx = new Regex("\"type\":\"tool_use\",\"id\":\"[^\"]*\",\"name\":\"([^\"]+)\"", RegexOptions.Compiled);
        static readonly Regex[] UsageRx = {
            new Regex("\"input_tokens\":(\\d+)", RegexOptions.Compiled),
            new Regex("\"output_tokens\":(\\d+)", RegexOptions.Compiled),
            new Regex("\"cache_read_input_tokens\":(\\d+)", RegexOptions.Compiled),
            new Regex("\"cache_creation_input_tokens\":(\\d+)", RegexOptions.Compiled),
            new Regex("\"ephemeral_1h_input_tokens\":(\\d+)", RegexOptions.Compiled)
        };
        static readonly Regex CostRx = new Regex("\"costUSD\":([0-9.eE+-]+)", RegexOptions.Compiled);
        static readonly Regex TotalCostRx = new Regex("\"totalCostUSD\":([0-9.eE+-]+)", RegexOptions.Compiled);
        static readonly Regex StartTimeRx = new Regex("\"startTime\":(\\d{12,})", RegexOptions.Compiled);

        // USD per million tokens: input, 5-minute cache write, 1-hour cache write, cache read, output.
        // Copied from Ponytail's hooks/ponytail-band-import.js (prices checked 2026-10-17); SetPrices replaces
        // it with the table of the installed Ponytail.
        static Dictionary<string, double[]> prices = DefaultPrices();
        static Dictionary<string, double[]> DefaultPrices()
        {
            var opus = new double[] { 5, 6.25, 10, 0.5, 25 };
            return new Dictionary<string, double[]>(StringComparer.OrdinalIgnoreCase) {
                { "claude-fable-5-1", new double[] { 10, 12.5, 20, 0.25, 50 } }, { "claude-fable-5", new double[] { 10, 12.5, 20, 1, 50 } },
                { "claude-opus-5-5", new double[] { 4, 5, 8, 0.2, 20 } }, { "claude-opus-5", opus }, { "claude-opus-4-8", opus },
                { "claude-opus-4-7", opus }, { "claude-opus-4-6", opus }, { "claude-opus-4-5", opus },
                { "claude-sonnet-5-5", new double[] { 2, 2.5, 4, 0.1, 10 } }, { "claude-sonnet-5", new double[] { 2, 2.5, 4, 0.2, 10 } },
                { "claude-sonnet-4-6", new double[] { 3, 3.75, 6, 0.3, 15 } }, { "claude-sonnet-4-5", new double[] { 3, 3.75, 6, 0.3, 15 } },
                { "claude-haiku-5-5", new double[] { 0.1, 0.125, 0.2, 0.01, 0.5 } }, { "claude-haiku-4-5", new double[] { 1, 1.25, 2, 0.1, 5 } }
            };
        }
        public static string PriceSource = "integrada";

        // A JSON object { "model": [5 numbers] } (from Ponytail) replaces the built-in table; returns the models read.
        public static int SetPrices(string json, string source)
        {
            try
            {
                var raw = NewSerializer().Deserialize<Dictionary<string, object>>(json);
                var table = new Dictionary<string, double[]>(StringComparer.OrdinalIgnoreCase);
                foreach (var pair in raw)
                {
                    var list = pair.Value as System.Collections.ArrayList;
                    if (list == null || list.Count != 5) continue;
                    table[pair.Key] = list.Cast<object>().Select(v => Convert.ToDouble(v, CultureInfo.InvariantCulture)).ToArray();
                }
                if (table.Count == 0) return 0;
                prices = table;
                PriceSource = source;
                return table.Count;
            }
            catch { return 0; }
        }

        // "claude-opus-5-5[1m]" or "claude-sonnet-4-5-20250929" -> the table's id.
        static string ModelId(string model)
        {
            return Regex.Replace(Regex.Replace(model ?? "", "\\[.*\\]$", ""), "-\\d{8}$", "");
        }

        // A message group's price, or -1 when the model has no price. u: messages, input, output, read, write, write 1h.
        public static double Price(string model, long[] u)
        {
            double[] p;
            if (!prices.TryGetValue(ModelId(model), out p)) return -1;
            long write1h = u.Length > 5 ? u[5] : 0;
            long write5m = Math.Max(0, u[4] - write1h);
            return (u[1] * p[0] + write5m * p[1] + write1h * p[2] + u[3] * p[3] + u[2] * p[4]) / 1e6;
        }

        static JavaScriptSerializer NewSerializer()
        {
            var s = new JavaScriptSerializer();
            s.MaxJsonLength = int.MaxValue;
            s.RecursionLimit = 64;
            return s;
        }

        // Scans in the background; the task's result is the stats JSON (also written to outPath).
        public static Task<string> ScanAsync(string projectsDir, string cachePath, string outPath)
        {
            return Task.Run(() => Scan(projectsDir, cachePath, outPath));
        }

        public static string Scan(string projectsDir, string cachePath, string outPath)
        {
            var started = DateTime.Now;
            var serializer = NewSerializer();
            var cache = new Dictionary<string, FileStats>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (File.Exists(cachePath))
                {
                    var list = serializer.Deserialize<List<FileStats>>(File.ReadAllText(cachePath, Encoding.UTF8));
                    if (list != null) foreach (var f in list) if (f != null && f.Path != null && f.Version >= OldestVersion && f.Version <= FormatVersion) cache[f.Path] = f;
                }
            }
            catch { cache.Clear(); }

            var files = new List<FileStats>();
            int read = 0;
            if (Directory.Exists(projectsDir))
            {
                foreach (var path in Directory.EnumerateFiles(projectsDir, "*.jsonl", SearchOption.AllDirectories))
                {
                    FileInfo info;
                    try { info = new FileInfo(path); } catch { continue; }
                    FileStats stats;
                    if (!cache.TryGetValue(path, out stats) || stats.Version != FormatVersion || stats.Length != info.Length || stats.Stamp != info.LastWriteTimeUtc.Ticks)
                    {
                        try { stats = ReadFile(path, info); read++; } catch { continue; }
                    }
                    files.Add(stats);
                    cache.Remove(path);
                }
            }
            // What is left in the cache was deleted from disk: keep it.
            files.AddRange(cache.Values);
            try
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(cachePath));
                File.WriteAllText(cachePath + ".tmp", serializer.Serialize(files), new UTF8Encoding(false));
                if (File.Exists(cachePath)) File.Delete(cachePath);
                File.Move(cachePath + ".tmp", cachePath);
            }
            catch { }

            var now = DateTime.Now;
            var result = new Dictionary<string, object>();
            result["scannedAt"] = now.ToString("s");
            result["seconds"] = Math.Round((now - started).TotalSeconds, 1);
            result["files"] = files.Count;
            result["filesRead"] = read;
            result["all"] = Summarize(files, DateTime.MinValue, now);
            result["recent"] = Summarize(files, now.Date.AddDays(-29), now);
            result["priceSource"] = PriceSource;
            string json = serializer.Serialize(result);
            try
            {
                File.WriteAllText(outPath + ".tmp", json, new UTF8Encoding(false));
                if (File.Exists(outPath)) File.Delete(outPath);
                File.Move(outPath + ".tmp", outPath);
            }
            catch { }
            return json;
        }

        static string Unescape(string json)
        {
            try { return (string)NewSerializer().DeserializeObject("\"" + json + "\""); } catch { return json; }
        }

        static bool IsPrompt(string line)
        {
            if (line.Contains("\"isMeta\":true") || line.Contains("\"isCompactSummary\":true") || line.Contains("\"isSidechain\":true")) return false;
            if (line.Contains("\"type\":\"tool_result\"")) return false;
            int at = line.IndexOf("\"role\":\"user\",\"content\":", StringComparison.Ordinal);
            if (at < 0) return false;
            at += "\"role\":\"user\",\"content\":".Length;
            if (at >= line.Length) return false;
            if (line[at] == '[') return line.IndexOf("\"type\":\"text\"", at, StringComparison.Ordinal) >= 0;
            if (line[at] != '"') return false;
            string head = line.Substring(at + 1, Math.Min(40, line.Length - at - 1));
            return !(head.StartsWith("<local-command") || head.StartsWith("<bash-") || head.StartsWith("Caveat:"));
        }

        class Message { public string Day; public string Hour; public string Model; public long[] Usage = new long[5]; public bool HasUsage; public double Cost = -1; }

        public static FileStats ReadFile(string path, FileInfo info)
        {
            var stats = new FileStats { Version = FormatVersion, Path = path, Length = info.Length, Stamp = info.LastWriteTimeUtc.Ticks };
            stats.Subagent = path.Replace('/', '\\').IndexOf("\\subagents\\", StringComparison.OrdinalIgnoreCase) >= 0;
            var events = new List<DateTime>();
            var messages = new Dictionary<string, Message>();
            double stateCost = 0;
            DateTime? stateStart = null;
            var projects = new Dictionary<string, int>();
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new StreamReader(stream, Encoding.UTF8))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    // The session's running total; only used when no reply has token counts.
                    if (line.IndexOf("\"type\":\"cost-state\"", StringComparison.Ordinal) >= 0)
                    {
                        var total = TotalCostRx.Match(line);
                        var startTime = StartTimeRx.Match(line);
                        if (total.Success) double.TryParse(total.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out stateCost);
                        if (startTime.Success) stateStart = Epoch.AddMilliseconds(long.Parse(startTime.Groups[1].Value)).ToLocalTime();
                        continue;
                    }
                    var kind = Kind.Match(line);
                    if (!kind.Success) continue;
                    var stampMatch = StampRx.Match(line);
                    if (!stampMatch.Success) stampMatch = AnyStamp.Match(line);
                    DateTime at;
                    if (!stampMatch.Success || !DateTime.TryParse(stampMatch.Groups[1].Value, CultureInfo.InvariantCulture,
                        DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out at)) continue;
                    at = at.ToLocalTime();
                    events.Add(at);
                    string day = at.ToString("yyyy-MM-dd");
                    var dayStats = GetDay(stats, day);
                    var cwd = CwdRx.Match(line);
                    if (cwd.Success) { int n; projects.TryGetValue(cwd.Groups[1].Value, out n); projects[cwd.Groups[1].Value] = n + 1; }

                    if (kind.Groups[1].Value == "user")
                    {
                        if (!stats.Subagent && IsPrompt(line))
                        {
                            stats.Prompts++;
                            dayStats.Prompts++;
                            GetHour(stats, at)[1]++;
                        }
                        continue;
                    }
                    foreach (Match tool in ToolRx.Matches(line))
                    {
                        string name = tool.Groups[1].Value;
                        if (name.StartsWith("mcp__")) { var parts = name.Split(new[] { "__" }, StringSplitOptions.None); name = parts.Length > 1 ? "mcp: " + parts[1] : name; }
                        int n; dayStats.Tools.TryGetValue(name, out n); dayStats.Tools[name] = n + 1;
                        dayStats.ToolCalls++;
                    }
                    var id = MsgIdRx.Match(line);
                    string key = id.Success ? id.Groups[1].Value : "line" + events.Count;
                    Message message;
                    if (!messages.TryGetValue(key, out message)) { message = new Message { Day = day, Hour = at.ToString("yyyy-MM-dd HH") }; messages[key] = message; }
                    var model = ModelRx.Match(line);
                    if (model.Success) message.Model = model.Groups[1].Value;
                    int usageAt = line.IndexOf("\"usage\":{", StringComparison.Ordinal);
                    if (usageAt >= 0)
                    {
                        message.HasUsage = true;
                        for (int i = 0; i < 5; i++)
                        {
                            var m = UsageRx[i].Match(line, usageAt);
                            if (m.Success) message.Usage[i] = long.Parse(m.Groups[1].Value);
                        }
                    }
                    var cost = CostRx.Match(line);
                    double costValue;
                    if (cost.Success && double.TryParse(cost.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out costValue)) message.Cost = costValue;
                }
            }

            foreach (var message in messages.Values)
            {
                if (message.Model == null || message.Model.StartsWith("<")) continue;
                var dayStats = GetDay(stats, message.Day);
                dayStats.Responses++;
                stats.Responses++;
                long[] totals;
                if (!dayStats.Models.TryGetValue(message.Model, out totals)) { totals = new long[5]; dayStats.Models[message.Model] = totals; }
                totals[0]++;
                for (int i = 0; i < 4; i++) totals[i + 1] += message.Usage[i];
                if (message.HasUsage)
                {
                    string hourKey = message.Hour + "|" + message.Model;
                    long[] h;
                    if (!stats.HourModels.TryGetValue(hourKey, out h)) { h = new long[6]; stats.HourModels[hourKey] = h; }
                    h[0]++;
                    for (int i = 0; i < 5; i++) h[i + 1] += message.Usage[i];
                }
                else if (message.Cost > 0)
                {
                    double c; stats.HourCost.TryGetValue(message.Hour, out c); stats.HourCost[message.Hour] = c + message.Cost;
                }
            }
            if (stats.HourModels.Count == 0 && stats.HourCost.Count == 0 && stateCost > 0)
            {
                DateTime at = stateStart ?? (events.Count > 0 ? events.Min() : info.LastWriteTime);
                stats.HourCost[at.ToString("yyyy-MM-dd HH")] = stateCost;
            }
            if (projects.Count > 0) stats.Project = Unescape(projects.OrderByDescending(p => p.Value).First().Key);

            // Active time; subagents run inside their parent's time, so they add none.
            events.Sort();
            if (events.Count > 0)
            {
                stats.First = events[0].ToString("s");
                stats.Last = events[events.Count - 1].ToString("s");
            }
            if (!stats.Subagent)
            {
                for (int i = 0; i < events.Count; i++)
                {
                    int seconds = LoneEvent;
                    DateTime at = events[i];
                    if (i + 1 < events.Count)
                    {
                        double gap = (events[i + 1] - at).TotalSeconds;
                        if (gap <= IdleGap) seconds = (int)gap;
                    }
                    if (seconds <= 0) continue;
                    long start = Unix(at);
                    var last = stats.Spans.Count > 0 ? stats.Spans[stats.Spans.Count - 1] : null;
                    if (last != null && start <= last[1]) last[1] = Math.Max(last[1], start + seconds);
                    else stats.Spans.Add(new long[] { start, start + seconds });
                    stats.Seconds += seconds;
                    GetDay(stats, at.ToString("yyyy-MM-dd")).Seconds += seconds;
                    GetHour(stats, at)[0] += seconds;
                }
            }
            return stats;
        }

        static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        static long Unix(DateTime local) { return (long)(local.ToUniversalTime() - Epoch).TotalSeconds; }
        static DateTime Local(long unix) { return Epoch.AddSeconds(unix).ToLocalTime(); }

        // Wall-clock time: every session's active stretches merged, split by local day and hour.
        static void AddWallClock(List<FileStats> files, DateTime from, int[] heat, int[] hourly, int[] weekday, Dictionary<string, int> days)
        {
            long fromUnix = from == DateTime.MinValue ? long.MinValue : Unix(from);
            var spans = files.Where(f => !f.Subagent && f.Spans != null).SelectMany(f => f.Spans)
                .Where(sp => sp[1] > fromUnix).Select(sp => new long[] { Math.Max(sp[0], fromUnix), sp[1] }).OrderBy(sp => sp[0]).ToList();
            var merged = new List<long[]>();
            foreach (var sp in spans)
            {
                var last = merged.Count > 0 ? merged[merged.Count - 1] : null;
                if (last != null && sp[0] <= last[1]) last[1] = Math.Max(last[1], sp[1]);
                else merged.Add(new long[] { sp[0], sp[1] });
            }
            foreach (var sp in merged)
            {
                long t = sp[0];
                while (t < sp[1])
                {
                    DateTime at = Local(t);
                    DateTime nextHour = new DateTime(at.Year, at.Month, at.Day, at.Hour, 0, 0, DateTimeKind.Local).AddHours(1);
                    long end = Math.Min(sp[1], Math.Max(t + 1, Unix(nextHour)));
                    int seconds = (int)(end - t);
                    heat[Monday(at.DayOfWeek) * 24 + at.Hour] += seconds;
                    hourly[at.Hour] += seconds;
                    weekday[Monday(at.DayOfWeek)] += seconds;
                    string key = at.ToString("yyyy-MM-dd");
                    int n; days.TryGetValue(key, out n); days[key] = n + seconds;
                    t = end;
                }
            }
        }

        static DayStats GetDay(FileStats stats, string day)
        {
            DayStats d;
            if (!stats.Days.TryGetValue(day, out d)) { d = new DayStats(); stats.Days[day] = d; }
            return d;
        }

        static int[] GetHour(FileStats stats, DateTime at)
        {
            string key = at.ToString("yyyy-MM-dd HH");
            int[] h;
            if (!stats.Hours.TryGetValue(key, out h)) { h = new int[2]; stats.Hours[key] = h; }
            return h;
        }

        static DateTime ParseDay(string day) { return DateTime.ParseExact(day, "yyyy-MM-dd", CultureInfo.InvariantCulture); }

        static int Monday(DayOfWeek d) { return ((int)d + 6) % 7; }

        // Everything the Estadisticas section shows, for events on or after $from.
        public static Dictionary<string, object> Summarize(List<FileStats> files, DateTime from, DateTime now)
        {
            string fromDay = from == DateTime.MinValue ? "0000-00-00" : from.ToString("yyyy-MM-dd");
            var heat = new int[7 * 24];
            var hourly = new int[24];
            var hourlyPrompts = new int[24];
            var weekday = new int[7];
            var dayTotals = new SortedDictionary<string, int[]>(StringComparer.Ordinal); // seconds, prompts, responses
            var projects = new Dictionary<string, long[]>(StringComparer.OrdinalIgnoreCase); // seconds, prompts, sessions
            var models = new Dictionary<string, long[]>();
            var tools = new Dictionary<string, int>();
            long prompts = 0, responses = 0, toolCalls = 0, seconds = 0;
            int sessions = 0, subagents = 0;
            var sessionLengths = new List<int>();
            var sessionPrompts = new List<int>();
            Dictionary<string, object> longest = null;
            string firstDay = null;

            foreach (var f in files)
            {
                bool inRange = false;
                long fileSeconds = 0, filePrompts = 0;
                foreach (var pair in f.Days)
                {
                    if (string.CompareOrdinal(pair.Key, fromDay) < 0) continue;
                    inRange = true;
                    var d = pair.Value;
                    int[] t;
                    if (!dayTotals.TryGetValue(pair.Key, out t)) { t = new int[3]; dayTotals[pair.Key] = t; }
                    t[0] += d.Seconds; t[1] += d.Prompts; t[2] += d.Responses;
                    fileSeconds += d.Seconds; filePrompts += d.Prompts;
                    prompts += d.Prompts; responses += d.Responses; toolCalls += d.ToolCalls; seconds += d.Seconds;
                    foreach (var tool in d.Tools) { int n; tools.TryGetValue(tool.Key, out n); tools[tool.Key] = n + tool.Value; }
                    foreach (var model in d.Models)
                    {
                        long[] m;
                        if (!models.TryGetValue(model.Key, out m)) { m = new long[5]; models[model.Key] = m; }
                        for (int i = 0; i < 5 && i < model.Value.Length; i++) m[i] += model.Value[i];
                    }
                    if (firstDay == null || string.CompareOrdinal(pair.Key, firstDay) < 0) firstDay = pair.Key;
                }
                foreach (var pair in f.Hours)
                {
                    if (string.CompareOrdinal(pair.Key.Substring(0, 10), fromDay) < 0) continue;
                    hourlyPrompts[int.Parse(pair.Key.Substring(11, 2))] += pair.Value[1];
                }
                if (!inRange) continue;
                if (f.Subagent) { subagents++; continue; }
                if (filePrompts == 0 && fileSeconds < 120) continue;
                sessions++;
                string project = string.IsNullOrEmpty(f.Project) ? "(sin carpeta)" : f.Project;
                long[] p;
                if (!projects.TryGetValue(project, out p)) { p = new long[3]; projects[project] = p; }
                p[0] += fileSeconds; p[1] += filePrompts; p[2]++;
                sessionLengths.Add((int)fileSeconds);
                sessionPrompts.Add((int)filePrompts);
                if (longest == null || fileSeconds > Convert.ToInt64(longest["seconds"]))
                {
                    longest = new Dictionary<string, object> { { "seconds", fileSeconds }, { "prompts", filePrompts },
                        { "project", ProjectName(project) }, { "start", f.First } };
                }
            }

            var wallDays = new Dictionary<string, int>();
            AddWallClock(files, from, heat, hourly, weekday, wallDays);
            long wall = wallDays.Values.Sum(v => (long)v);
            foreach (var pair in wallDays)
            {
                int[] t;
                if (!dayTotals.TryGetValue(pair.Key, out t)) { t = new int[3]; dayTotals[pair.Key] = t; }
            }
            // From here on a day's time is wall-clock time.
            foreach (var key in dayTotals.Keys.ToList()) { int w; wallDays.TryGetValue(key, out w); dayTotals[key][0] = w; }

            // streaks use every active day (a day counts with at least 5 active minutes)
            var activeDays = new HashSet<string>();
            var allDays = new Dictionary<string, int>();
            AddWallClock(files, DateTime.MinValue, new int[7 * 24], new int[24], new int[7], allDays);
            foreach (var pair in allDays) if (pair.Value >= 300) activeDays.Add(pair.Key);
            int current = 0;
            var cursor = now.Date;
            if (!activeDays.Contains(cursor.ToString("yyyy-MM-dd"))) cursor = cursor.AddDays(-1);
            while (activeDays.Contains(cursor.ToString("yyyy-MM-dd"))) { current++; cursor = cursor.AddDays(-1); }
            int best = 0, run = 0;
            DateTime? previous = null;
            foreach (var day in activeDays.Select(ParseDay).OrderBy(d => d))
            {
                run = (previous.HasValue && (day - previous.Value).TotalDays == 1) ? run + 1 : 1;
                if (run > best) best = run;
                previous = day;
            }

            var r = new Dictionary<string, object>();
            r["from"] = firstDay;
            r["seconds"] = wall;
            r["sessionSeconds"] = seconds;
            r["parallel"] = wall > 0 ? Math.Round((double)seconds / wall, 2) : 0;
            r["prompts"] = prompts;
            r["responses"] = responses;
            r["toolCalls"] = toolCalls;
            r["sessions"] = sessions;
            r["subagents"] = subagents;
            r["activeDays"] = dayTotals.Count(p => p.Value[0] >= 300);
            r["streak"] = current;
            r["bestStreak"] = best;
            r["heat"] = heat;
            r["hourly"] = hourly;
            r["hourlyPrompts"] = hourlyPrompts;
            r["weekday"] = weekday;

            var busiest = dayTotals.OrderByDescending(p => p.Value[0]).FirstOrDefault();
            if (busiest.Key != null) r["busiestDay"] = new Dictionary<string, object> { { "day", busiest.Key }, { "seconds", busiest.Value[0] }, { "prompts", busiest.Value[1] } };
            if (longest != null) r["longestSession"] = longest;
            r["avgSessionSeconds"] = sessionLengths.Count > 0 ? (int)sessionLengths.Average() : 0;
            r["medianSessionSeconds"] = Median(sessionLengths);
            r["avgPromptsPerSession"] = sessionPrompts.Count > 0 ? Math.Round(sessionPrompts.Average(), 1) : 0;
            int activeDayCount = dayTotals.Count(p => p.Value[0] >= 300);
            r["avgSecondsPerActiveDay"] = activeDayCount > 0 ? (int)(dayTotals.Where(p => p.Value[0] >= 300).Sum(p => (long)p.Value[0]) / activeDayCount) : 0;

            // the last 30 days and the weeks since the first one with data (8 to 26, Monday first), empty days included
            var daily = new List<object>();
            for (int i = 29; i >= 0; i--)
            {
                string key = now.Date.AddDays(-i).ToString("yyyy-MM-dd");
                int[] t; dayTotals.TryGetValue(key, out t);
                daily.Add(new Dictionary<string, object> { { "day", key }, { "seconds", t == null ? 0 : t[0] }, { "prompts", t == null ? 0 : t[1] } });
            }
            r["daily"] = daily;
            var weekStart = now.Date.AddDays(-Monday(now.DayOfWeek));
            int weeks = 26;
            if (firstDay != null)
            {
                var firstWeek = ParseDay(firstDay);
                firstWeek = firstWeek.AddDays(-Monday(firstWeek.DayOfWeek));
                weeks = Math.Max(8, Math.Min(26, (int)((weekStart - firstWeek).TotalDays / 7) + 1));
            }
            var weekly = new List<object>();
            for (int i = weeks - 1; i >= 0; i--)
            {
                var start = weekStart.AddDays(-7 * i);
                long s = 0, pr = 0;
                for (int d = 0; d < 7; d++)
                {
                    int[] t;
                    if (dayTotals.TryGetValue(start.AddDays(d).ToString("yyyy-MM-dd"), out t)) { s += t[0]; pr += t[1]; }
                }
                weekly.Add(new Dictionary<string, object> { { "week", start.ToString("yyyy-MM-dd") }, { "seconds", s }, { "prompts", pr } });
            }
            r["weekly"] = weekly;
            r["today"] = SumDays(dayTotals, now.Date, now.Date);
            r["thisWeek"] = SumDays(dayTotals, weekStart, now.Date);
            r["lastWeek"] = SumDays(dayTotals, weekStart.AddDays(-7), weekStart.AddDays(-1));

            r["projects"] = projects.OrderByDescending(p => p.Value[0]).Take(8).Select(p => (object)new Dictionary<string, object> {
                { "name", ProjectName(p.Key) }, { "path", p.Key }, { "seconds", p.Value[0] }, { "prompts", p.Value[1] }, { "sessions", p.Value[2] } }).ToList();
            r["projectCount"] = projects.Count;
            r["models"] = models.OrderByDescending(p => p.Value[2] + p.Value[1] + p.Value[3] + p.Value[4]).Take(6).Select(p => (object)new Dictionary<string, object> {
                { "name", p.Key }, { "messages", p.Value[0] }, { "input", p.Value[1] }, { "output", p.Value[2] }, { "cacheRead", p.Value[3] }, { "cacheWrite", p.Value[4] } }).ToList();
            long[] tokenTotals = new long[4];
            foreach (var m in models.Values) for (int i = 0; i < 4; i++) tokenTotals[i] += m[i + 1];
            r["tokens"] = new Dictionary<string, object> { { "input", tokenTotals[0] }, { "output", tokenTotals[1] }, { "cacheRead", tokenTotals[2] }, { "cacheWrite", tokenTotals[3] } };
            r["tools"] = tools.OrderByDescending(p => p.Value).Take(10).Select(p => (object)new Dictionary<string, object> { { "name", p.Key }, { "count", p.Value } }).ToList();
            r["toolKinds"] = tools.Count;
            r["usage"] = SummarizeUsage(files, fromDay, now);
            return r;
        }

        // Session of a transcript: its file name, or for a subagent the folder of the session it belongs to.
        static string SessionOf(FileStats f)
        {
            string path = f.Path.Replace('/', '\\');
            int at = path.IndexOf("\\subagents\\", StringComparison.OrdinalIgnoreCase);
            if (at > 0) return System.IO.Path.GetFileName(path.Substring(0, at));
            return System.IO.Path.GetFileNameWithoutExtension(path);
        }

        static double StdDev(List<double> values)
        {
            if (values.Count < 2) return 0;
            double avg = values.Average();
            return Math.Sqrt(values.Sum(v => (v - avg) * (v - avg)) / values.Count);
        }

        static Dictionary<string, object> Spread(List<double> values)
        {
            var sorted = values.OrderBy(v => v).ToList();
            double avg = sorted.Count > 0 ? sorted.Average() : 0;
            return new Dictionary<string, object> {
                { "count", sorted.Count }, { "avg", avg }, { "median", sorted.Count > 0 ? sorted[sorted.Count / 2] : 0 },
                { "min", sorted.Count > 0 ? sorted[0] : 0 }, { "max", sorted.Count > 0 ? sorted[sorted.Count - 1] : 0 },
                { "p90", sorted.Count > 0 ? sorted[Math.Min(sorted.Count - 1, (int)Math.Ceiling(sorted.Count * 0.9) - 1)] : 0 },
                { "cv", avg > 0 ? StdDev(sorted) / avg : 0 } };
        }

        // Consumption: by hour of day, by 5-hour window (rebuilt as Claude does: a window starts on the hour of
        // the first activity after the previous one ended) and by Claude Code session. Subagents count too:
        // they spend from the same plan.
        static Dictionary<string, object> SummarizeUsage(List<FileStats> files, string fromDay, DateTime now)
        {
            var hours = new SortedDictionary<string, double[]>(StringComparer.Ordinal); // tokens, cost, output, unpriced tokens
            var sessions = new Dictionary<string, double[]>(StringComparer.OrdinalIgnoreCase); // tokens, cost
            double directCost = 0;
            foreach (var f in files)
            {
                if (f.HourModels == null) continue;
                string session = SessionOf(f);
                foreach (var pair in f.HourModels)
                {
                    string hour = pair.Key.Substring(0, 13);
                    if (string.CompareOrdinal(hour.Substring(0, 10), fromDay) < 0) continue;
                    var u = pair.Value;
                    double tokens = u[1] + u[2] + u[3] + u[4];
                    double price = Price(pair.Key.Substring(14), u);
                    double[] h;
                    if (!hours.TryGetValue(hour, out h)) { h = new double[4]; hours[hour] = h; }
                    h[0] += tokens; h[2] += u[2];
                    if (price >= 0) h[1] += price; else h[3] += tokens;
                    double[] s;
                    if (!sessions.TryGetValue(session, out s)) { s = new double[2]; sessions[session] = s; }
                    s[0] += tokens; if (price > 0) s[1] += price;
                }
                foreach (var pair in f.HourCost)
                {
                    if (string.CompareOrdinal(pair.Key.Substring(0, 10), fromDay) < 0) continue;
                    double[] h;
                    if (!hours.TryGetValue(pair.Key, out h)) { h = new double[4]; hours[pair.Key] = h; }
                    h[1] += pair.Value;
                    directCost += pair.Value;
                    double[] s;
                    if (!sessions.TryGetValue(session, out s)) { s = new double[2]; sessions[session] = s; }
                    s[1] += pair.Value;
                }
            }

            var hourlyTokens = new double[24];
            var hourlyCost = new double[24];
            var hourDays = new int[24];
            var days = new HashSet<string>();
            foreach (var pair in hours)
            {
                int hod = int.Parse(pair.Key.Substring(11, 2));
                hourlyTokens[hod] += pair.Value[0];
                hourlyCost[hod] += pair.Value[1];
                hourDays[hod]++;
                days.Add(pair.Key.Substring(0, 10));
            }

            // 5-hour windows
            var windows = new List<double[]>(); // start (unix), tokens, cost, output, active hours
            DateTime windowEnd = DateTime.MinValue;
            foreach (var pair in hours)
            {
                DateTime at = DateTime.ParseExact(pair.Key, "yyyy-MM-dd HH", CultureInfo.InvariantCulture);
                if (at >= windowEnd)
                {
                    windows.Add(new double[] { Unix(at), 0, 0, 0, 0 });
                    windowEnd = at.AddHours(5);
                }
                var w = windows[windows.Count - 1];
                w[1] += pair.Value[0]; w[2] += pair.Value[1]; w[3] += pair.Value[2]; w[4]++;
            }
            // The window still open now is not finished: it stays out of the averages.
            var closed = windows.Where(w => Local((long)w[0]).AddHours(5) <= now).ToList();
            var byStart = new double[24];
            var byStartCount = new int[24];
            foreach (var w in closed) { int hod = Local((long)w[0]).Hour; byStart[hod] += w[2]; byStartCount[hod]++; }

            var u2 = new Dictionary<string, object>();
            u2["hours"] = hours.Count;
            u2["days"] = days.Count;
            u2["tokens"] = hours.Values.Sum(h => h[0]);
            u2["cost"] = hours.Values.Sum(h => h[1]);
            u2["outputTokens"] = hours.Values.Sum(h => h[2]);
            u2["unpricedTokens"] = hours.Values.Sum(h => h[3]);
            u2["directCost"] = directCost;
            u2["hourlyTokens"] = hourlyTokens;
            u2["hourlyCost"] = hourlyCost;
            u2["hourlyDays"] = hourDays;
            u2["windowCost"] = Spread(closed.Select(w => w[2]).ToList());
            u2["windowTokens"] = Spread(closed.Select(w => w[1]).ToList());
            u2["windowsByStartHour"] = Enumerable.Range(0, 24).Select(i => byStartCount[i] > 0 ? byStart[i] / byStartCount[i] : 0).ToArray();
            u2["windowsByStartHourCount"] = byStartCount;
            u2["windows"] = windows.Skip(Math.Max(0, windows.Count - 30)).Select(w => (object)new Dictionary<string, object> {
                { "start", Local((long)w[0]).ToString("s") }, { "tokens", w[1] }, { "cost", w[2] }, { "output", w[3] }, { "activeHours", w[4] } }).ToList();
            var sessionList = sessions.Values.Where(v => v[0] > 0 || v[1] > 0).ToList();
            u2["sessionCost"] = Spread(sessionList.Select(v => v[1]).ToList());
            u2["sessionTokens"] = Spread(sessionList.Select(v => v[0]).ToList());
            // The last two days hour by hour, so the window that is open now can be measured against the plan.
            string recentFrom = now.AddHours(-48).ToString("yyyy-MM-dd HH");
            u2["recentHours"] = hours.Where(p => string.CompareOrdinal(p.Key, recentFrom) >= 0)
                .ToDictionary(p => p.Key, p => (object)new double[] { p.Value[0], p.Value[1] });
            return u2;
        }

        static int Median(List<int> values)
        {
            if (values.Count == 0) return 0;
            var sorted = values.OrderBy(v => v).ToList();
            return sorted[sorted.Count / 2];
        }

        static Dictionary<string, object> SumDays(SortedDictionary<string, int[]> days, DateTime from, DateTime to)
        {
            long s = 0, p = 0;
            for (var d = from; d <= to; d = d.AddDays(1))
            {
                int[] t;
                if (days.TryGetValue(d.ToString("yyyy-MM-dd"), out t)) { s += t[0]; p += t[1]; }
            }
            return new Dictionary<string, object> { { "seconds", s }, { "prompts", p } };
        }

        static string ProjectName(string path)
        {
            try
            {
                string name = System.IO.Path.GetFileName(path.TrimEnd('\\', '/'));
                return string.IsNullOrEmpty(name) ? path : name;
            }
            catch { return path; }
        }
    }
}
