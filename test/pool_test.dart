// The Pool and its tab, tested through the real stack: a plan pasted and
// accepted into Drift, a pool seeded at the seam, and both read back onto the
// third tab.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is in
// paste_confirm_flow_test.dart; read that file's header before writing any
// test that pumps the app.
//
// The pool is seeded through `bootstrapApp(photos:)` rather than written to.
// The write path exists now — capture owns it, and
// `capture_flow_test.dart`'s "what you keep is what the Pool draws" is where
// the two meet over one real store. These tests stay on a seeded pool
// deliberately: a fixture of a known shape is how the *drawing* is exercised
// (bytes here and bytes not here, a day the plan does not claim, a date still
// open), and walking capture to build each of those would be testing capture
// twice and the Pool not at all.
//
// Two things about the container shape these tests, as they shape
// trail_and_shell_test.dart: every tab stays alive in the tree but the ones
// you are not looking at are *offstage*, and Flutter's finders skip offstage
// widgets — so a plain `find.byKey` sees only the tab you are standing on,
// and a tap only reaches it. Every test walks in through the tab bar.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn_model/cairn_model.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/photo_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';

/// Three dated days over four dates: 16 June is a gap the plan skips.
/// (14 June 2027 really is a Monday, 15 a Tuesday, 17 a Thursday.)
const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Thu 17 June 2027 - Osaka
- Dotonbori
''';

/// Days with no dates anywhere: the plan is real, the calendar is open.
const dateOpenPaste = '''
Day 1 - Tokyo
- Senso-ji

Day 2 - Kyoto
- Fushimi Inari
''';

DateTime day(int dayOfJune) => DateTime.utc(2027, 6, dayOfJune);

/// One photo on [onDay], taken at [hour] o'clock UTC. [path] is where its
/// bytes are on this phone, and null when they are not here — which is every
/// photo in the app today.
PooledPhoto photo(
  String id, {
  required int onDay,
  required int hour,
  String? path,
}) =>
    PooledPhoto(
      ref: PhotoRef(
        id: PhotoId(id),
        dayNumber: onDay,
        contributor: MemberId('anyone'),
        takenAt: DateTime.utc(2027, 6, 13 + onDay, hour),
        origin: PhotoOrigin.pinged,
      ),
      localPath: path,
    );

/// A real 1×1 PNG on disk, so a tile with bytes has bytes to point at.
File writeTinyPng() {
  final file = File(
    '${Directory.systemTemp.createTempSync('cairn_pool').path}/tile.png',
  );
  file.writeAsBytesSync(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
    'hQGAhKmMIQAAAABJRU5ErkJggg==',
  ));
  addTearDown(() => file.parent.deleteSync(recursive: true));
  return file;
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      )));
  tearDown(() => db.close());

  Future<void> launch(
    WidgetTester tester, {
    required DateTime today,
    List<PooledPhoto> pool = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(bootstrapApp(
      database: db,
      today: today,
      photos: InMemoryPhotoPool(pool),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> accept(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('paste-input')), text);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
  }

  Future<void> openPool(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('tab-pool')));
    await tester.pumpAndSettle();
  }

  /// Paste, accept, and stand in the Pool.
  Future<void> arriveInPool(
    WidgetTester tester, {
    required DateTime today,
    String paste = tripPaste,
    List<PooledPhoto> pool = const [],
  }) async {
    await launch(tester, today: today, pool: pool);
    await accept(tester, paste);
    await openPool(tester);
  }

  String textOf(Key key) => (find
          .descendant(
            of: find.byKey(key),
            matching: find.byType(Text),
            matchRoot: true,
          )
          .evaluate()
          .first
          .widget as Text)
      .data!;

  // ------------------------------------------------------------------ tab

  testWidgets('the Pool is the third tab, beside Today and the Trail',
      (tester) async {
    await launch(tester, today: day(15));
    await accept(tester, tripPaste);

    expect(find.byKey(const Key('tab-today')), findsOneWidget);
    expect(find.byKey(const Key('tab-trail')), findsOneWidget);
    expect(find.byKey(const Key('tab-pool')), findsOneWidget);

    // And it opens on the Pool rather than on anything else's screen.
    await openPool(tester);
    expect(textOf(const Key('pool-headline')), 'The Pool');
  });

  testWidgets('the Pool keeps its place when you leave the tab and come back',
      (tester) async {
    await arriveInPool(tester, today: day(15));
    expect(find.byKey(const Key('pool-empty')), findsOneWidget);

    await tester.tap(find.byKey(const Key('tab-trail')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pool-empty')), findsNothing);

    await openPool(tester);
    expect(find.byKey(const Key('pool-empty')), findsOneWidget);
  });

  // ---------------------------------------------------------- empty pool

  testWidgets('an empty pool is written, not an empty grid', (tester) async {
    await arriveInPool(tester, today: day(15));

    expect(
      textOf(const Key('pool-empty')),
      'Nothing in the pool yet. Everyone\'s photos land here.',
    );
    // No count of zero, and no day sections standing empty.
    expect(find.byKey(const Key('pool-count')), findsNothing);
    expect(find.byKey(const Key('pool-day-1')), findsNothing);
    expect(find.byKey(const Key('pool-day-2')), findsNothing);
    expect(find.byKey(const Key('pool-day-3')), findsNothing);
  });

  testWidgets('the pool is empty in the app as built — nothing writes to it',
      (tester) async {
    // The default binding, with no seeded pool: the state a phone is
    // actually in today.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(bootstrapApp(database: db, today: day(15)));
    await tester.pump();
    await tester.pump();
    await accept(tester, tripPaste);
    await openPool(tester);

    expect(find.byKey(const Key('pool-empty')), findsOneWidget);
  });

  // -------------------------------------------------------- photos in it

  testWidgets('every photo of the trip is here, grouped by its day',
      (tester) async {
    await arriveInPool(tester, today: day(15), pool: [
      photo('a', onDay: 1, hour: 10),
      photo('b', onDay: 1, hour: 8),
      photo('c', onDay: 2, hour: 9),
    ]);

    expect(textOf(const Key('pool-count')), '3 photos');
    expect(find.byKey(const Key('pool-empty')), findsNothing);

    expect(find.byKey(const Key('pool-day-1')), findsOneWidget);
    expect(find.byKey(const Key('pool-day-2')), findsOneWidget);
    // A day nobody photographed gets no section: the Pool is the photos,
    // not the plan.
    expect(find.byKey(const Key('pool-day-3')), findsNothing);

    for (final id in ['a', 'b', 'c']) {
      expect(find.byKey(Key('pool-photo-$id')), findsOneWidget);
    }
  });

  testWidgets('days read newest first, and the day names itself as the day '
      'page does', (tester) async {
    await arriveInPool(tester, today: day(15), pool: [
      photo('a', onDay: 1, hour: 10),
      photo('c', onDay: 2, hour: 9),
    ]);

    final newest = tester.getTopLeft(find.byKey(const Key('pool-day-2'))).dy;
    final older = tester.getTopLeft(find.byKey(const Key('pool-day-1'))).dy;
    expect(newest < older, isTrue);

    expect(textOf(const Key('pool-day-2-title')), 'Tuesday, Kyoto');
    expect(textOf(const Key('pool-day-2-date')), '15 June');
    expect(textOf(const Key('pool-day-1-title')), 'Monday, Tokyo');
    expect(textOf(const Key('pool-day-1-date')), '14 June');
  });

  testWidgets('a day says "today" where every other day counts its photos',
      (tester) async {
    await arriveInPool(tester, today: day(15), pool: [
      photo('a', onDay: 1, hour: 10),
      photo('b', onDay: 1, hour: 8),
      photo('c', onDay: 2, hour: 9),
    ]);

    expect(textOf(const Key('pool-day-2-detail')), 'today');
    expect(textOf(const Key('pool-day-1-detail')), '2 photos');
  });

  testWidgets('a day\'s photos are in the order they were taken',
      (tester) async {
    await arriveInPool(tester, today: day(15), pool: [
      photo('later', onDay: 1, hour: 17),
      photo('earlier', onDay: 1, hour: 8),
    ]);

    // Both sit in the same row of the grid, so the earlier one is to the
    // left. Oldest first is `cairn_model.DayPool`'s rule, not this screen's.
    final earlier = tester.getTopLeft(find.byKey(const Key('pool-photo-earlier')));
    final later = tester.getTopLeft(find.byKey(const Key('pool-photo-later')));
    expect(earlier.dx < later.dx, isTrue);
  });

  testWidgets('a tile shows the image when its bytes are on this phone, and '
      'says it is waiting when they are not', (tester) async {
    final file = writeTinyPng();
    await arriveInPool(tester, today: day(15), pool: [
      photo('mine', onDay: 1, hour: 8, path: file.path),
      photo('theirs', onDay: 1, hour: 9),
    ]);

    expect(find.byKey(const Key('pool-photo-mine-image')), findsOneWidget);
    expect(find.byKey(const Key('pool-photo-mine-awaiting')), findsNothing);

    expect(find.byKey(const Key('pool-photo-theirs-awaiting')), findsOneWidget);
    expect(find.byKey(const Key('pool-photo-theirs-image')), findsNothing);
  });

  testWidgets('a photo on a day the plan does not claim is still shown',
      (tester) async {
    // The plan holds three days; this photo says it belongs to a fourth.
    // Dropping it silently is the one thing the Pool must never do.
    await arriveInPool(tester, today: day(15), pool: [
      photo('orphan', onDay: 9, hour: 12),
    ]);

    expect(find.byKey(const Key('pool-photo-orphan')), findsOneWidget);
    expect(textOf(const Key('pool-day-9-title')), 'Day 9');
    expect(textOf(const Key('pool-day-9-date')), 'date open');
  });

  testWidgets('a day accepted with its date still open says so', (tester) async {
    await arriveInPool(
      tester,
      today: day(15),
      paste: dateOpenPaste,
      pool: [photo('a', onDay: 2, hour: 10)],
    );

    expect(textOf(const Key('pool-day-2-title')), 'Kyoto');
    expect(textOf(const Key('pool-day-2-date')), 'date open');
    // Nothing is today when nothing has a date, so the day counts instead.
    expect(textOf(const Key('pool-day-2-detail')), '1 photo');
  });
}
