import 'package:claudemaxxing/chat.dart';
import 'package:claudemaxxing/chat_style.dart';
import 'package:claudemaxxing/logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chatEntries: a day before each day, tool runs folded into one entry', () {
    final entries = chatEntries([
      {'role': 'user', 'text': 'hola', 'at': '2026-11-20T10:00:00'},
      {'role': 'tool', 'text': 'Read a', 'at': '2026-11-20T10:00:01'},
      {'role': 'tool', 'text': 'Edit b', 'at': '2026-11-20T10:00:02'},
      {'role': 'assistant', 'text': 'listo', 'at': '2026-11-21T09:00:00'},
      {'role': 'assistant', 'text': 'sin hora'},
    ]);
    expect(entries.map((e) => e.day != null ? 'day' : e.tools ? 'tools${e.items.length}' : e.items.first['role']).toList(),
        ['day', 'user', 'tools2', 'day', 'assistant', 'assistant']);
  });

  test('splitCodeBlocks: fenced code apart, kept as written', () {
    final blocks = splitCodeBlocks('Mira:\n```dart\n  var x = 1;\n```\nfin');
    expect(blocks.map((b) => '${b.code}:${b.text}').toList(), ['false:Mira:', 'true:  var x = 1;', 'false:fin']);
  });

  test('markdownLine and inlineMarks', () {
    expect(markdownLine('## Plan').heading, true);
    expect(markdownLine('## Plan').text, 'Plan');
    expect(markdownLine('  - uno').text, '  • uno');
    expect(markdownLine('**no** es lista').text, '**no** es lista');
    expect(inlineMarks('a **b** `c` d').map((m) => '${m.text}${m.bold ? '!' : ''}${m.code ? '#' : ''}').join('|'), 'a |b!| |c#| d');
  });

  test('a session palette picks the text that reads on the session color', () {
    final session = chatPalettes.firstWhere((p) => p.id == 'session');
    expect(session.forSession(const Color(0xFFFFEB3B)).mineText, Colors.black);
    expect(session.forSession(const Color(0xFF1565C0)).mineText, Colors.white);
  });

  testWidgets('the chat draws every palette, at the smallest and largest text', (tester) async {
    final items = [
      {'role': 'user', 'text': 'Revisa los tests\n[phone attachment] C:\\u\\foto.png', 'at': '2026-11-20T10:00:00'},
      {'role': 'tool', 'text': 'Bash npm test ' * 10, 'at': '2026-11-20T10:00:01'},
      {'role': 'tool', 'text': 'Read package.json', 'at': '2026-11-20T10:00:02'},
      {'role': 'assistant', 'text': '# Listo\n- **todo** pasa\n```\n${'x' * 300}\n```', 'at': '2026-11-20T10:01:00'},
    ];
    for (final palette in chatPalettes) {
      for (final size in [chatFontMin, chatFontMax]) {
        setChatStyle(palette: palette, fontSize: size, save: false);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ChatView(items: items, controller: ScrollController(), sessionColor: Colors.teal, emptyText: '')),
        ));
        expect(tester.takeException(), isNull, reason: '${palette.id} at $size');
      }
    }
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(find.textContaining('Read package.json'), findsOneWidget);
  });

  testWidgets('the chat style sheet shows the preview, the size and every palette', (tester) async {
    setChatStyle(palette: chatPalettes.first, fontSize: chatFontMax, save: false);
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () => showChatStyleSheet(context, Colors.teal), child: const Text('open')))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Slider), findsOneWidget);
    for (final palette in chatPalettes) {
      expect(find.text(palette.name), findsOneWidget);
    }
  });
}
