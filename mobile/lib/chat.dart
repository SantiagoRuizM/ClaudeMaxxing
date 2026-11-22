// A session's conversation drawn as a chat: my bubbles on the right, Claude's on the left, the hour under each, a
// day between days and each run of tool calls folded into one line. Pinch to change the text size; the palette and
// the size are chosen in showChatStyleSheet (chat_style.dart).
import 'package:flutter/material.dart';

import 'chat_style.dart';
import 'logic.dart';
import 'strings.dart';
import 'voices.dart';

IconData attachmentIcon(String name) => switch (name.split('.').last.toLowerCase()) {
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'bmp' || 'heic' || 'heif' => Icons.image_outlined,
      'mp3' || 'wav' || 'm4a' || 'aac' || 'ogg' || 'opus' || 'flac' || 'amr' => Icons.audiotrack,
      'pdf' => Icons.picture_as_pdf_outlined,
      'doc' || 'docx' || 'odt' || 'rtf' || 'txt' => Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };

String _two(int n) => n.toString().padLeft(2, '0');

String timeLabel(Object? at) {
  final t = DateTime.tryParse('${at ?? ''}')?.toLocal();
  return t == null ? '' : '${_two(t.hour)}:${_two(t.minute)}';
}

String dayLabel(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return S.today;
  if (day == today.subtract(const Duration(days: 1))) return S.yesterday;
  return '${day.day}/${day.month}/${day.year}';
}

/// One message bubble; [first] when the one before is not from the same side (more space, the corner tail).
Widget chatBubble(BuildContext context, Map<String, dynamic> item, ChatPalette p, double size, {bool first = true}) {
  final user = item['role'] == 'user';
  final fg = user ? p.mineText : p.theirsText;
  final base = TextStyle(color: fg, fontSize: size, height: 1.35);
  final codeBg = fg.withOpacity(0.12);
  final parts = splitAttachments('${item['text']}');
  final time = timeLabel(item['at']);
  const r = Radius.circular(18);
  final tail = first ? const Radius.circular(4) : r;
  return Align(
    alignment: user ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      margin: EdgeInsets.only(top: first ? 10 : 3, left: user ? 48 : 0, right: user ? 0 : 32),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: user ? p.mine : p.theirs,
        borderRadius: BorderRadius.only(topLeft: user ? r : tail, topRight: user ? tail : r, bottomLeft: r, bottomRight: r),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (parts.textLines.join('\n').trim().isNotEmpty) ..._rich(parts.textLines.join('\n'), base, codeBg),
        for (final name in parts.attachments)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Chip(avatar: Icon(attachmentIcon(name), size: 18), label: Text(name, overflow: TextOverflow.ellipsis)),
          ),
        if (time.isNotEmpty)
          Align(alignment: Alignment.centerRight, child: Text(time, style: TextStyle(color: fg.withOpacity(0.7), fontSize: size * 0.7))),
      ]),
    ),
  );
}

// Light Markdown: fenced code in a box that scrolls sideways, headings and **bold** in bold, `code`, bullets.
List<Widget> _rich(String text, TextStyle base, Color codeBg) => [
      for (final block in splitCodeBlocks(text))
        block.code
            ? Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: codeBg, borderRadius: BorderRadius.circular(8)),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(block.text, style: base.copyWith(fontFamily: 'monospace', fontSize: base.fontSize! * 0.85)),
                ),
              )
            : SelectableText.rich(TextSpan(style: base, children: [
                for (final (i, line) in block.text.split('\n').indexed) ..._line(line, base, codeBg, i > 0),
              ])),
    ];

List<InlineSpan> _line(String line, TextStyle base, Color codeBg, bool newline) {
  final md = markdownLine(line);
  final style = md.heading ? base.copyWith(fontWeight: FontWeight.w700) : base;
  return [
    if (newline) const TextSpan(text: '\n'),
    for (final m in inlineMarks(md.text))
      TextSpan(
        text: m.text,
        style: m.code
            ? style.copyWith(fontFamily: 'monospace', backgroundColor: codeBg)
            : m.bold
                ? style.copyWith(fontWeight: FontWeight.w700)
                : style,
      ),
  ];
}

class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.items, required this.controller, required this.sessionColor, required this.emptyText});

  final List<Map<String, dynamic>> items;
  final ScrollController controller;
  final Color sessionColor;
  final String emptyText;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  // The pinch, from raw pointers: a Listener takes no part in the gesture arena, so the list still scrolls.
  final _pointers = <int, Offset>{};
  double? _pinchSpan;
  double _pinchFont = 15;
  final _openTools = <String>{};

  double get _span {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      _pinchSpan = _span;
      _pinchFont = chatStyle.value.fontSize;
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final start = _pinchSpan;
    if (_pointers.length == 2 && start != null && start > 0) setChatStyle(fontSize: _pinchFont * _span / start, save: false);
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pinchSpan != null && _pointers.length < 2) {
      _pinchSpan = null;
      saveChatStyle();
    }
  }

  Widget _tools(List<Map<String, dynamic>> tools, ChatPalette p, double size) {
    final key = '${tools.first['at']}|${tools.first['text']}';
    final open = _openTools.contains(key);
    final many = tools.length > 1;
    final style = TextStyle(color: p.muted, fontSize: size * 0.78, fontFamily: 'monospace');
    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 32),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: many ? () => setState(() => open ? _openTools.remove(key) : _openTools.add(key)) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (many)
              Row(children: [
                Icon(Icons.build_outlined, size: size * 0.85, color: p.muted),
                const SizedBox(width: 6),
                Text(S.toolRuns(tools.length), style: style.copyWith(fontFamily: null)),
                Icon(open ? Icons.expand_less : Icons.expand_more, size: size, color: p.muted),
              ]),
            for (final t in open || !many ? tools : [tools.last])
              Text('› ${t['text']}', maxLines: open ? 4 : 2, overflow: TextOverflow.ellipsis, style: style),
          ]),
        ),
      ),
    );
  }

  Widget _day(DateTime day, ChatPalette p, double size) => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 14, bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(color: p.theirs, borderRadius: BorderRadius.circular(12)),
          child: Text(dayLabel(day, DateTime.now()), style: TextStyle(color: p.muted, fontSize: size * 0.75)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ChatStyle>(
      valueListenable: chatStyle,
      builder: (context, style, _) {
        final p = style.palette.forSession(widget.sessionColor);
        final size = style.fontSize;
        final entries = chatEntries(widget.items);
        return Listener(
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: Container(
            color: p.background,
            child: entries.isEmpty
                ? Center(child: Text(widget.emptyText, style: TextStyle(color: p.muted, fontSize: size)))
                : ListView.builder(
                    controller: widget.controller,
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
                    itemCount: entries.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                          child: Text(S.fromPhoneNote, textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: size * 0.72)),
                        );
                      }
                      final e = entries[i - 1];
                      if (e.day != null) return _day(e.day!, p, size);
                      if (e.tools) return _tools(e.items, p, size);
                      final before = i > 1 ? entries[i - 2] : null;
                      final first = before == null || before.day != null || before.tools || before.items.first['role'] != e.items.first['role'];
                      final note = e.items.first['note'];
                      if (note is VoiceNote) return VoiceBubble(note: note, palette: p, size: size, first: first);
                      return chatBubble(context, e.items.first, p, size, first: first);
                    },
                  ),
          ),
        );
      },
    );
  }
}

/// Estilo del chat: a preview, the text size and the palettes, applied as they are touched.
Future<void> showChatStyleSheet(BuildContext context, Color sessionColor) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ValueListenableBuilder<ChatStyle>(
        valueListenable: chatStyle,
        builder: (context, style, _) {
          final theme = Theme.of(context);
          final p = style.palette.forSession(sessionColor);
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(S.chatStyle, style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  decoration: BoxDecoration(color: p.background, borderRadius: BorderRadius.circular(14)),
                  child: Column(children: [
                    chatBubble(context, {'role': 'assistant', 'text': S.previewTheirs, 'at': DateTime.now().toIso8601String()}, p, style.fontSize),
                    chatBubble(context, {'role': 'user', 'text': S.previewMine, 'at': DateTime.now().toIso8601String()}, p, style.fontSize),
                  ]),
                ),
                const SizedBox(height: 16),
                Text(S.textSize, style: theme.textTheme.titleSmall),
                Row(children: [
                  IconButton(
                    tooltip: S.smallerText,
                    onPressed: style.fontSize > chatFontMin ? () => setChatStyle(fontSize: style.fontSize - 1) : null,
                    icon: const Icon(Icons.text_decrease),
                  ),
                  Expanded(
                    child: Slider(
                      min: chatFontMin,
                      max: chatFontMax,
                      value: style.fontSize,
                      label: style.fontSize.round().toString(),
                      onChanged: (v) => setChatStyle(fontSize: v, save: false),
                      onChangeEnd: (_) => saveChatStyle(),
                    ),
                  ),
                  IconButton(
                    tooltip: S.largerText,
                    onPressed: style.fontSize < chatFontMax ? () => setChatStyle(fontSize: style.fontSize + 1) : null,
                    icon: const Icon(Icons.text_increase),
                  ),
                ]),
                Text(S.pinchHint, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                Text(S.colors, style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  for (final palette in chatPalettes)
                    _Swatch(palette: palette.forSession(sessionColor), selected: palette.id == style.palette.id, onTap: () => setChatStyle(palette: palette)),
                ]),
              ]),
            ),
          );
        },
      ),
    );

class _Swatch extends StatelessWidget {
  const _Swatch({required this.palette, required this.selected, required this.onTap});

  final ChatPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget pill(Color c, Alignment a) => Align(
          alignment: a,
          child: Container(width: 34, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(5))),
        );
    return Semantics(
      selected: selected,
      button: true,
      label: palette.name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 76,
          child: Column(children: [
            Container(
              height: 52,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: palette.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 3 : 1),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                pill(palette.theirs, Alignment.centerLeft),
                pill(palette.mine, Alignment.centerRight),
              ]),
            ),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: Text(palette.name, textAlign: TextAlign.center, maxLines: 2, style: Theme.of(context).textTheme.bodySmall),
            ),
          ]),
        ),
      ),
    );
  }
}
