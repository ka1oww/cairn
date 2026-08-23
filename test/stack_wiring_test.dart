// The scaffold's one claim, tested: a value read from Drift through a
// Riverpod provider onto a screen, and written back through the same stack.
// The database is in-memory; everything else is the real wiring from
// bootstrap.dart.
//
// closeStreamsSynchronously is load-bearing, not a nicety. When the widget
// tree unmounts at the end of a testWidgets body, the provider's stream
// subscription detaches inside the test's fake-async zone; without this
// flag drift defers the stream's shutdown by one event-loop timer, which is
// scheduled in that zone and can never fire once the test body returns —
// and tearDown's db.close() then waits on it forever. This hang is silent
// (0% CPU, no timeout: testWidgets ignores --timeout) and was found the
// hard way; drift documents the flag for exactly this situation.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      )));
  tearDown(() => db.close());

  testWidgets('reads the empty state from Drift through Riverpod',
      (tester) async {
    await tester.pumpWidget(bootstrapApp(database: db));
    await tester.pump();

    expect(find.text('No trip yet.'), findsOneWidget);
  });

  testWidgets('a write through the seam reaches the screen via the stream',
      (tester) async {
    await tester.pumpWidget(bootstrapApp(database: db));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Kyoto, October');
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<Text>(find.byKey(const Key('trip-name'))).data,
      'Kyoto, October',
    );
  });

  testWidgets('a second save overwrites the single draft row',
      (tester) async {
    await tester.pumpWidget(bootstrapApp(database: db));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'First name');
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Second name');
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump();

    expect(find.text('Second name'), findsOneWidget);
    expect(find.text('First name'), findsNothing);
  });
}
