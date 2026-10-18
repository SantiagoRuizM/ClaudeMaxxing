// Statistics for the ClaudeMaxxing window: when and how much you work with Claude Code, read from Claude
// Code's own transcripts (~/.claude/projects/<project>/<session>.jsonl, subagents in <session>/subagents).
// Lines are not fully parsed (there are hundreds of MB): a few anchored regexes take the fields needed.
// Each file's summary is cached by size and write time, so later scans only read what changed.
// Active time: the gaps between consecutive events of a session, when shorter than IdleGap; a lone event
// counts one minute. Times are local. Keep this file ASCII.
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
    }

    public static class Stats
    {
        public const int IdleGap = 15 * 60;
        // Bump when FileStats changes: cached summaries of another version are read again.
        const int FormatVersion = 2;
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
            new Regex("\"cache_creation_input_tokens\":(\\d+)", RegexOptions.Compiled)
        };

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
                    if (list != null) foreach (var f in list) if (f != null && f.Path != null && f.Version == FormatVersion) cache[f.Path] = f;
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
                    if (!cache.TryGetValue(path, out stats) || stats.Length != info.Length || stats.Stamp != info.LastWriteTimeUtc.Ticks)
                    {
                        try { stats = ReadFile(path, info); read++; } catch { continue; }
                    }
                    files.Add(stats);
                }
            }
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

        class Message { public string Day; public string Model; public long[] Usage = new long[4]; }

        public static FileStats ReadFile(string path, FileInfo info)
        {
            var stats = new FileStats { Version = FormatVersion, Path = path, Length = info.Length, Stamp = info.LastWriteTimeUtc.Ticks };
            stats.Subagent = path.Replace('/', '\\').IndexOf("\\subagents\\", StringComparison.OrdinalIgnoreCase) >= 0;
            var events = new List<DateTime>();
            var messages = new Dictionary<string, Message>();
            var projects = new Dictionary<string, int>();
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new StreamReader(stream, Encoding.UTF8))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
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
                    if (!messages.TryGetValue(key, out message)) { message = new Message { Day = day }; messages[key] = message; }
                    var model = ModelRx.Match(line);
                    if (model.Success) message.Model = model.Groups[1].Value;
                    int usageAt = line.IndexOf("\"usage\":{", StringComparison.Ordinal);
                    if (usageAt >= 0)
                    {
                        for (int i = 0; i < 4; i++)
                        {
                            var m = UsageRx[i].Match(line, usageAt);
                            if (m.Success) message.Usage[i] = long.Parse(m.Groups[1].Value);
                        }
                    }
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
            return r;
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
