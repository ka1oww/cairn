// The reworked paste box (design round 4, Screen 1): the whole-plan copy,
// the ghost sample, the one green button, and the two soft pills — "Try an
// example" filling the box with the sample plan and reading it end-to-end,
// "Build it by hand" landing on the confirm screen with one empty day.
//
// closeStreamsSynchronously is load-bearing — see the header comment in
// paste_confirm_flow_test.dart for the mechanism.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/screens/paste_screen.dart';
import 'package:cairn/storage/drift/app_database.dart';

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

  Future<void> launch(WidgetTester tester) async {
    // Tall viewport so the whole confirmation ListView builds without
    // scroll choreography in every test.
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(database: db, today: DateTime.utc(2027, 6, 15)),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the paste box teaches: the copy, the ghost sample, the one '
      'green button and the two soft pills', (tester) async {
    await launch(tester);

    expect(find.text('Drop your itinerary here.'), findsOneWidget);
    expect(find.text("We'll split it into days for you."), findsOneWidget);

    // The ghost sample is the box's hint, so it shows before any typing.
    final field = tester.widget<TextField>(
      find.byKey(const Key('paste-input')),
    );
    expect(field.decoration?.hintText, sampleItinerary);

    // One primary action, two soft pills under it.
    expect(find.byKey(const Key('read-button')), findsOneWidget);
    expect(find.text('Read my plan'), findsOneWidget);
    expect(find.text('Read it'), findsNothing);
    expect(find.byKey(const Key('try-example')), findsOneWidget);
    expect(find.byKey(const Key('build-by-hand')), findsOneWidget);

    // Both pills are finger-sized: at least 44pt tall.
    expect(
      tester.getSize(find.byKey(const Key('try-example'))).height,
      greaterThanOrEqualTo(44),
    );
    expect(
      tester.getSize(find.byKey(const Key('build-by-hand'))).height,
      greaterThanOrEqualTo(44),
    );
  });

  testWidgets('"Try an example" fills the box, and the green button reads '
      'the sample end-to-end', (tester) async {
    await launch(tester);

    await tester.tap(find.byKey(const Key('try-example')));
    await tester.pump();

    final field = tester.widget<TextField>(
      find.byKey(const Key('paste-input')),
    );
    expect(field.controller?.text, sampleItinerary);

    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();

    // The confirm screen, holding the sample's five days.
    expect(find.byKey(const Key('paste-input')), findsNothing);
    for (var day = 1; day <= 5; day++) {
      expect(find.byKey(Key('day-card-$day')), findsOneWidget);
    }
  });

  testWidgets('"Build it by hand" lands on the confirm screen with one '
      'empty day', (tester) async {
    await launch(tester);

    await tester.tap(find.byKey(const Key('build-by-hand')));
    await tester.pump();

    expect(find.byKey(const Key('paste-input')), findsNothing);
    expect(find.byKey(const Key('day-card-1')), findsOneWidget);
    expect(find.byKey(const Key('day-card-2')), findsNothing);
  });
}
