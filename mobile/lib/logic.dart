// The pure parts of the app, tested in test\logic_test.dart.

/// The page to show after the session list changed: the same session if it is still open, else the panel (0).
/// Page 0 is the panel; page i is sessions[i - 1].
int pageAfterChange(List<String> before, List<String> after, int page) {
  if (page <= 0 || page > before.length) return 0;
  final i = after.indexOf(before[page - 1]);
  return i < 0 ? 0 : i + 1;
}

/// The chat after a /messages answer: replaced when the PC read the transcript's tail again, else appended.
/// At most [max] items are kept.
List<Map<String, dynamic>> mergeMessages(List<Map<String, dynamic>> current, Map<String, dynamic> answer, {int max = 300}) {
  final items = (answer['items'] as List? ?? []).cast<Map<String, dynamic>>();
  final merged = answer['reset'] == true ? [...items] : [...current, ...items];
  return merged.length > max ? merged.sublist(merged.length - max) : merged;
}

/// The chat with the voice notes in their place by time: each [voices] item (role voice, with its at) goes before the
/// first message said after it. Messages without a time keep their place.
List<Map<String, dynamic>> withVoices(List<Map<String, dynamic>> items, List<Map<String, dynamic>> voices) {
  if (voices.isEmpty) return items;
  DateTime? at(Map<String, dynamic> m) => DateTime.tryParse('${m['at'] ?? ''}');
  final pending = [...voices]..sort((a, b) => (at(a) ?? DateTime(0)).compareTo(at(b) ?? DateTime(0)));
  final out = <Map<String, dynamic>>[];
  var v = 0;
  for (final item in items) {
    final t = at(item);
    while (t != null && v < pending.length && !(at(pending[v]) ?? DateTime(0)).isAfter(t)) {
      out.add(pending[v++]);
    }
    out.add(item);
  }
  out.addAll(pending.skip(v));
  return out;
}

/// The step a hub dropdown takes to go from [current] to [target] (lib\mobile.ps1 MChoice); for an absolute choice,
/// the target's place in the list.
int choiceStep(List<String> keys, String current, String target, {bool absolute = false}) {
  final t = keys.indexOf(target);
  if (absolute) return t;
  final c = keys.indexOf(current);
  return c < 0 ? t : t - c;
}

/// The recognizer locale for dictation: the phone's language and region when offered (es_CO for es-CO), else its
/// language in any region, else the phone's own tag (the recognizer may list no languages and still take it), and
/// the recognizer's default only without a phone language.
String? pickDictationLocale(List<String> available, String phoneTag, String? fallback) {
  String norm(String id) => id.replaceAll('-', '_').toLowerCase();
  final phone = norm(phoneTag);
  final language = phone.split('_').first;
  for (final id in available) {
    if (norm(id) == phone) return id;
  }
  for (final id in available) {
    if (norm(id).split('_').first == language) return id;
  }
  return phoneTag.isNotEmpty && phoneTag != 'und' ? phoneTag : fallback;
}

final _attachmentLine = RegExp(r'^\[phone attachment\]\s+(.+)$');
final _attachmentTimestamp = RegExp(r'^\d{8}-\d{6}-');

/// Separates transcript text from the display names of phone attachments.
({List<String> textLines, List<String> attachments}) splitAttachments(String text) {
  final textLines = <String>[];
  final attachments = <String>[];
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final path = _attachmentLine.firstMatch(line)?.group(1)?.trim();
    final name = path?.split(RegExp(r'[/\\]')).last.replaceFirst(_attachmentTimestamp, '');
    if (name == null || name.isEmpty) {
      textLines.add(line);
    } else {
      attachments.add(name);
    }
  }
  return (textLines: textLines, attachments: attachments);
}

/// What the chat draws: a day before the first message of each day, each message, and each run of tool calls as
/// one entry (folded into a line until tapped).
class ChatEntry {
  ChatEntry.day(DateTime this.day) : tools = false, items = const [];
  ChatEntry(this.tools, this.items) : day = null;

  final DateTime? day;
  final bool tools;
  final List<Map<String, dynamic>> items;
}

List<ChatEntry> chatEntries(List<Map<String, dynamic>> items) {
  final out = <ChatEntry>[];
  DateTime? lastDay;
  for (final item in items) {
    final at = DateTime.tryParse('${item['at'] ?? ''}')?.toLocal();
    if (at != null) {
      final day = DateTime(at.year, at.month, at.day);
      if (day != lastDay) out.add(ChatEntry.day(day));
      lastDay = day;
    }
    final tool = item['role'] == 'tool';
    if (tool && out.isNotEmpty && out.last.tools) {
      out.last.items.add(item);
    } else {
      out.add(ChatEntry(tool, [item]));
    }
  }
  return out;
}

/// Light Markdown, the text apart from its fenced code blocks (``` lines).
List<({bool code, String text})> splitCodeBlocks(String text) {
  final out = <({bool code, String text})>[];
  final lines = <String>[];
  var code = false;
  void flush() {
    final block = lines.join('\n');
    if (code ? lines.isNotEmpty : block.trim().isNotEmpty) out.add((code: code, text: code ? block : block.trim()));
    lines.clear();
  }

  for (final line in text.split(RegExp(r'\r?\n'))) {
    if (line.trimLeft().startsWith('```')) {
      flush();
      code = !code;
    } else {
      lines.add(line);
    }
  }
  flush();
  return out;
}

/// A heading (# ...) without its marks, and a - or * bullet as •.
({String text, bool heading}) markdownLine(String line) {
  final h = RegExp(r'^\s{0,3}#{1,6}\s+').firstMatch(line);
  if (h != null) return (text: line.substring(h.end), heading: true);
  final b = RegExp(r'^(\s*)[-*]\s+').firstMatch(line);
  if (b != null) return (text: '${b.group(1)}• ${line.substring(b.end)}', heading: false);
  return (text: line, heading: false);
}

/// **bold** and `code` in a line, in order.
List<({String text, bool bold, bool code})> inlineMarks(String line) {
  final out = <({String text, bool bold, bool code})>[];
  var at = 0;
  for (final m in RegExp(r'\*\*(.+?)\*\*|`([^`]+)`').allMatches(line)) {
    if (m.start > at) out.add((text: line.substring(at, m.start), bold: false, code: false));
    out.add(m.group(1) != null ? (text: m.group(1)!, bold: true, code: false) : (text: m.group(2)!, bold: false, code: true));
    at = m.end;
  }
  if (at < line.length) out.add((text: line.substring(at), bold: false, code: false));
  return out;
}

/// The session's status line under its name, from what the PC read off its statusline: where it runs (folder, branch
/// with its worktree when it is in one, the environment on) and how it runs (model, effort apart, context, cost,
/// time). Null when the PC sent none (no statusline block, or no reply yet).
({String place, String model, String effort, String run})? statusParts(Object? status) {
  if (status is! Map) return null;
  String s(String k) => '${status[k] ?? ''}';
  final branch = s('branch').isEmpty ? '' : s('worktree').isEmpty ? s('branch') : '${s('branch')} (${s('worktree')})';
  final place = [s('folder'), branch, if (s('env').isNotEmpty) '◆ ${s('env')}'].where((p) => p.isNotEmpty).join(' · ');
  final context = status['context'];
  final cost = status['cost'];
  final run = [
    if (context is num) '${context.round()}%',
    if (cost is num) '\$${cost.toStringAsFixed(2)}',
    if (s('elapsed').isNotEmpty) s('elapsed'),
  ].join(' · ');
  return (place: place, model: s('model'), effort: s('effort'), run: run);
}

/// The version of GitHub's latest [release] when it is newer than [current] and has the APK, else null.
String? apkUpdate(Object? release, String current) {
  if (release is! Map) return null;
  List<int>? parts(String v) {
    final m = RegExp(r'^v?(\d{1,6})\.(\d{1,6})\.(\d{1,6})$').firstMatch(v);
    return m == null ? null : [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
  }

  final next = parts('${release['tag_name']}');
  final now = parts(current);
  final assets = release['assets'];
  if (next == null || now == null || assets is! List) return null;
  if (!assets.any((a) => a is Map && a['name'] == 'ClaudeMaxxing.apk')) return null;
  for (var i = 0; i < 3; i++) {
    if (next[i] != now[i]) return next[i] > now[i] ? next.join('.') : null;
  }
  return null;
}

/// What a call reads out of one of Claude's texts: its last 🔊 line, without Markdown, and whether it is a proposal
/// to accept or a question to answer. Null when the text has no such line: the turn is still going.
({String text, bool proposal, bool question})? callReply(String message) {
  final found = RegExp(r'^[ \t>*_]*🔊[ \t:*_]*(.+)$', multiLine: true, unicode: true).allMatches(message);
  if (found.isEmpty) return null;
  final text = speakable(found.last.group(1)!);
  if (text.isEmpty) return null;
  return (
    text: text,
    proposal: RegExp(r'^(propuesta|proposal)\s*:', caseSensitive: false).hasMatch(text),
    question: text.endsWith('?'),
  );
}

/// Text to be heard: no link addresses or Markdown marks, on one line, cut at [max].
String speakable(String text, [int max = 700]) {
  final plain = text
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'[`*#|>]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return plain.length <= max ? plain : '${plain.substring(0, max)}…';
}
