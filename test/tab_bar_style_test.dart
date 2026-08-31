// The container's skin, pinned to frame 5b's tokens (the drawn tab bar in
// docs/design/2026-08-22-handoff.zip): the sticker pill, the washed active
// tab, the muted rest, and the one coral dot that marks where you stand.
// Navigation behaviour is trail_and_shell_test.dart's business; this file
// only holds the styled states to the design record.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is
// in paste_confirm_flow_test.dart; read that header before touching setup.
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/screens/house_style.dart';
import 'package:cairn/storage/drift/app_database.dart';

const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
''';

void main() {
  late AppDatabase db;

  setUp(
    () => db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    ),
  );
  tearDown(() => db.close());

  /// Paste and accept a one-day plan, landing on the container's Today tab.
  Future<void> arrive(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(database: db, today: DateTime.utc(2027, 6, 14)),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('paste-input')), tripPaste);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
  }

  /// The decorated box a tab's pill (or its absence) is drawn by.
  Container tabContainer(WidgetTester tester, String slug) =>
      tester.widget<Container>(find.byKey(Key('tab-$slug')));

  Text tabLabel(WidgetTester tester, String label) => tester.widget<Text>(
    find.descendant(
      of: find.byKey(Key('tab-${label.toLowerCase()}')),
      matching: find.text(label),
    ),
  );

  testWidgets('the bar is frame 5b\'s sticker pill', (tester) async {
    await arrive(tester);

    final bar = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byKey(const Key('tab-bar')),
            matching: find.byType(DecoratedBox),
            matchRoot: true,
          )
          .first,
    );
    final decoration = bar.decoration as BoxDecoration;
    expect(decoration.color, houseSticker);
    expect(decoration.borderRadius, BorderRadius.circular(18));
    expect(decoration.boxShadow, const [
      BoxShadow(color: houseStickerShadow, offset: Offset(0, 1), blurRadius: 4),
    ]);
  });

  testWidgets('the tab you stand on is washed, inked and dotted; '
      'the others are bare and muted', (tester) async {
    await arrive(tester);

    // Opens on Today: its pill carries the wash and the coral dot.
    final today = tabContainer(tester, 'today');
    final todayPill = today.decoration as BoxDecoration?;
    expect(todayPill?.color, houseWash);
    expect(todayPill?.borderRadius, BorderRadius.circular(12));
    expect(find.byKey(const Key('tab-today-dot')), findsOneWidget);
    expect(
      tester
          .widget<DecoratedBox>(find.byKey(const Key('tab-today-dot')))
          .decoration,
      const BoxDecoration(color: houseCoral, shape: BoxShape.circle),
    );
    expect(tabLabel(tester, 'Today').style?.color, houseInk);

    // The other two carry no pill, no dot, and the muted ink.
    for (final slug in ['trail', 'pool']) {
      expect(tabContainer(tester, slug).decoration, isNull);
      expect(find.byKey(Key('tab-$slug-dot')), findsNothing);
    }
    expect(tabLabel(tester, 'Trail').style?.color, houseMuted);
    expect(tabLabel(tester, 'Pool').style?.color, houseMuted);
  });

  testWidgets('the wash and the dot follow a tab switch', (tester) async {
    await arrive(tester);

    await tester.tap(find.byKey(const Key('tab-pool')));
    await tester.pumpAndSettle();

    expect(
      (tabContainer(tester, 'pool').decoration as BoxDecoration?)?.color,
      houseWash,
    );
    expect(find.byKey(const Key('tab-pool-dot')), findsOneWidget);
    expect(tabContainer(tester, 'today').decoration, isNull);
    expect(find.byKey(const Key('tab-today-dot')), findsNothing);
    expect(tabLabel(tester, 'Pool').style?.color, houseInk);
    expect(tabLabel(tester, 'Today').style?.color, houseMuted);
  });

  testWidgets('labels are set in the house text face at 5b\'s size', (
    tester,
  ) async {
    await arrive(tester);

    for (final label in ['Today', 'Trail', 'Pool']) {
      final style = tabLabel(tester, label).style;
      expect(style?.fontFamily, houseTextFamily);
      expect(style?.fontWeight, FontWeight.w700);
      expect(style?.fontSize, 10.5);
    }
  });
}
