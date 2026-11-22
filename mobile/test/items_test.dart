import 'package:claudemaxxing/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the symbol list shows the pictures of each option and fits a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int? step;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ItemsView(
          items: const [
            {
              't': 'choice', 'id': 'symbol', 'label': 'Símbolo de las sesiones', 'current': 'egg', 'preview': '#D97757',
              'options': [{'k': 'egg', 'label': 'Huevo'}, {'k': 'drop', 'label': 'Gota'}],
            },
            {
              't': 'choice', 'id': 'other', 'label': 'Otra', 'current': 'a',
              'options': [{'k': 'a', 'label': 'A'}],
            },
          ],
          onAction: (id, arg) async => step = arg,
          optionPreview: (key, color) => SizedBox(key: ValueKey('preview-$key-$color'), width: 60, height: 28),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('preview-a-#D97757'), skipOffstage: false), findsNothing);

    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preview-egg-#D97757')), findsWidgets);
    expect(find.byKey(const ValueKey('preview-drop-#D97757')), findsWidgets);
    await tester.tap(find.text('Gota').last);
    await tester.pumpAndSettle();
    expect(step, 1);
    expect(tester.takeException(), isNull);
  });
}
