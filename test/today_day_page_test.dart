// Today, tested through the real stack: a plan pasted and accepted, then
// read back out of Drift onto the day page — the same widget for today and
// for any other date, because Cairn has one day screen and no separate day
// detail.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is
// in paste_confirm_flow_test.dart; read that file's header before writing
// any test that pumps the app.
//
// `today` is pinned through bootstrapApp on every launch. The day page
// derives today from the device date in this slice (no trip clock is stored
// yet), so a test that let the real clock through would assert one thing in
// 2026 and another in June 2027.
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:cairn/app_state/day_view.dart';
import 'package:cairn/app_state/capture_flow.dart';
import 'package:cairn/app_state/ping_schedule.dart';
import 'package:cairn/app_state/trip_providers.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/membership_repository.dart';
import 'package:cairn/repositories/photo_repository.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/screens/day_page.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn_model/cairn_model.dart';

/// Three dated days over four dates: 16 June is a gap the plan skips.
/// Day 1 carries a starred stop, an unstarred one, and a hedged time the
/// parser refuses to star — the row that must show no time at all.
/// (14 June 2027 really is a Monday, 15 a Tuesday, 17 a Thursday.)
const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- 09:30 Skytree
- maybe around 15:00 coffee somewhere

Tue 15 June 2027 - Kyoto
- 10:12 Train to Kyoto
- Fushimi Inari

Thu 17 June 2027 - Osaka
- Dotonbori
''';

/// A day of the trip with nothing under it, accepted on purpose.
const restDayPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Hakone
''';

/// Days with no dates anywhere: the plan is real, the calendar is open.
const dateOpenPaste = '''
Day 1 - Tokyo
- Senso-ji
- 09:30 Skytree

Day 2 - Kyoto
- Fushimi Inari
''';

/// The day that is the trip's first, in UTC as the day page reads dates.
DateTime day(int dayOfJune) => DateTime.utc(2027, 6, dayOfJune);

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

  Future<void> launch(WidgetTester tester, {required DateTime today}) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(bootstrapApp(database: db, today: today));
    await tester.pump();
    await tester.pump();
  }

  /// Paste, accept, and land wherever the launch surface decides.
  Future<void> accept(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('paste-input')), text);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
  }

  /// The day page on its own, over the same store — the claim that Today is
  /// nothing but this widget handed today's date.
  ///
  /// The key is load-bearing. These tests pump the whole app first and this
  /// scope second, and Riverpod refuses to *update* a scope whose override
  /// count changed ("overrides cannot be removed/added"). Without a key
  /// Flutter reuses the element and hands it a shorter override list; the
  /// key makes it a new scope instead. It fails the moment `bootstrapApp`
  /// binds a provider this helper does not, which is exactly what happened
  /// when the Pool's seam arrived — and again when capture's did.
  Widget dayPageAt(
    DateTime date, {
    required DateTime today,
    Stream<List<PooledPhoto>>? photoStream,
  }) {
    final photos = PhotoStore(
      db,
      framePaths: FramePaths(() async => '/frames'),
    );
    return ProviderScope(
      key: UniqueKey(),
      overrides: [
        tripRepositoryProvider.overrideWithValue(TripRepository(db)),
        photoRepositoryProvider.overrideWithValue(photos),
        photoStoreProvider.overrideWithValue(photos),
        pendingCaptureStoreProvider.overrideWithValue(
          PendingCaptureStore(
            db,
            framePaths: FramePaths(() async => '/frames'),
          ),
        ),
        membershipRepositoryProvider.overrideWithValue(
          InMemoryMembership(null),
        ),
        tripTimeZoneProvider.overrideWithValue('Etc/UTC'),
        todayProvider.overrideWithValue(today),
        if (photoStream != null)
          tripPhotosProvider.overrideWith((ref) => photoStream),
      ],
      child: MaterialApp(home: DayPage(date: date)),
    );
  }

  /// The words under a key. Some keys sit on a `Text`, some on a small
  /// wrapper around one, so match either.
  String textOf(Key key) =>
      (find
                  .descendant(
                    of: find.byKey(key),
                    matching: find.byType(Text),
                    matchRoot: true,
                  )
                  .evaluate()
                  .first
                  .widget
              as Text)
          .data!;

  testWidgets('today is the day screen for today: identity, then the plan', (
    tester,
  ) async {
    await launch(tester, today: day(15));
    await accept(tester, tripPaste);

    // Which day of the trip, the day itself, its date.
    expect(textOf(const Key('day-eyebrow')), 'DAY 2 OF 3');
    expect(textOf(const Key('day-title')), 'Tuesday, Kyoto');
    expect(textOf(const Key('day-date')), '15 June');

    // Only this day's stops. The text is the line as pasted — the parser
    // never rewrites it and neither does the app, so a leading clock time
    // stays in the words as well as appearing as the stop's time.
    expect(find.text('10:12 Train to Kyoto'), findsOneWidget);
    expect(find.text('Fushimi Inari'), findsOneWidget);
    expect(find.text('Senso-ji'), findsNothing);
    expect(find.text('Dotonbori'), findsNothing);
  });

  testWidgets('a photo read failure remains visible on the day page', (
    tester,
  ) async {
    await launch(tester, today: day(14));
    await accept(tester, tripPaste);

    await tester.pumpWidget(
      dayPageAt(
        day(14),
        today: day(14),
        photoStream: Stream<List<PooledPhoto>>.error(
          StateError('photo read failed'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Failed to read: Bad state: photo read failed'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('day-photo-count')), findsNothing);
  });

  testWidgets(
    'today photos stream into the timeline and open only after I contribute',
    (tester) async {
      final frame = File(
        '${Directory.current.path}/ios/Runner/Assets.xcassets/'
        'AppIcon.appiconset/Icon-App-29x29@2x.png',
      );

      final photoStore = PhotoStore(
        db,
        framePaths: FramePaths(() async => '${Directory.current.path}/frames'),
        mintId: () => 'my-photo',
      );
      final roster = InMemoryMembership(
        TripMembership(
          tripId: TripId('00000000-0000-4000-8000-000000000001'),
          startedBy: MemberId('me'),
          timeZone: 'Etc/UTC',
          members: [
            Member(id: MemberId('me'), displayName: 'You', joinedOnDay: 1),
            Member(
              id: MemberId('co-member'),
              displayName: 'Mum',
              joinedOnDay: 1,
            ),
          ],
        ),
      );

      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        bootstrapApp(
          database: db,
          today: day(14),
          tripTimeZone: 'Etc/UTC',
          photos: photoStore,
          membership: roster,
        ),
      );
      await tester.pump();
      await tester.enterText(find.byKey(const Key('paste-input')), tripPaste);
      await tester.tap(find.byKey(const Key('read-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('accept-button')));
      await tester.pump();
      await tester.pump();

      // A co-member's row arriving in the existing local stream adds its mount
      // immediately, but a non-contributor receives no image widget or path.
      await db.insertPhoto((
        id: 'co-photo',
        dayNumber: 1,
        contributorId: 'co-member',
        takenAtUtcIso: DateTime.utc(2027, 6, 14, 11, 40).toIso8601String(),
        origin: 'pinged',
        word: null,
        filePath: frame.path,
        contentType: 'image/png',
      ));
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('day-photo-co-photo-withheld')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('day-photo-co-photo-image')), findsNothing);
      expect(find.text('Mum'), findsOneWidget);
      expect(find.text('11:40'), findsOneWidget);

      // Keeping today's capture writes through PhotoStore. The same shared gate
      // now opens both images, including the co-member's image already present.
      await photoStore.keep(
        dayNumber: 1,
        contributor: MemberId('me'),
        takenAt: DateTime.utc(2027, 6, 14, 9, 25),
        origin: PhotoOrigin.pinged,
        filePath: frame.path,
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('day-photo-co-photo-image')), findsOneWidget);
      expect(find.byKey(const Key('day-photo-my-photo-image')), findsOneWidget);
      expect(find.text('09:25'), findsOneWidget);
      expect(find.text('11:40'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('day-photo-my-photo-image'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const Key('day-photo-co-photo-image')))
              .dy,
        ),
      );
    },
  );

  testWidgets('a starred stop shows its star and its time; an unstarred one '
      'shows no time', (tester) async {
    await launch(tester, today: day(14));
    await accept(tester, tripPaste);

    // Stop 2 carried an unhedged clock time: star, and the only time on the
    // screen.
    expect(find.byIcon(Icons.star), findsOneWidget);
    expect(find.text('09:30'), findsOneWidget);
    expect(textOf(const Key('stop-time-2')), '09:30');

    // Stop 1 has no time to show, and stop 3's time was hedged, so the
    // parser never starred it — the row renders its words and no clock.
    expect(find.byKey(const Key('stop-time-1')), findsNothing);
    expect(find.byKey(const Key('stop-time-3')), findsNothing);
    expect(find.text('maybe around 15:00 coffee somewhere'), findsOneWidget);
  });

  testWidgets('stops render in pasted order, top to bottom', (tester) async {
    await launch(tester, today: day(14));
    await accept(tester, tripPaste);

    final positions = [
      for (final key in ['stop-1', 'stop-2', 'stop-3'])
        tester.getTopLeft(find.byKey(Key(key))).dy,
    ];
    expect(positions[0], lessThan(positions[1]));
    expect(positions[1], lessThan(positions[2]));

    // The gutter numbers every stop, and the star takes the number's place
    // without renumbering what follows.
    expect(find.text('01'), findsOneWidget);
    expect(find.text('02'), findsNothing);
    expect(find.text('03'), findsOneWidget);
  });

  testWidgets(
    'the same day page renders an arbitrary other date, in the past tense',
    (tester) async {
      await launch(tester, today: day(17));
      await accept(tester, tripPaste);

      // Today is day 3, present tense: a filled star, a plain time, no "was".
      expect(textOf(const Key('day-eyebrow')), 'DAY 3 OF 3');
      expect(find.textContaining('was '), findsNothing);

      // The very same widget, handed 14 June while today is still the 17th,
      // is day 1 — no second screen exists and none is needed.
      await tester.pumpWidget(dayPageAt(day(14), today: day(17)));
      await tester.pump();
      await tester.pump();

      expect(textOf(const Key('day-eyebrow')), 'DAY 1 OF 3');
      expect(textOf(const Key('day-title')), 'Monday, Tokyo');
      expect(find.text('Senso-ji'), findsOneWidget);

      // A day that is over keeps its star as an outline and its time reads
      // "was 09:30" — the record holds no opinion about what did not happen.
      expect(find.byIcon(Icons.star), findsNothing);
      expect(find.byIcon(Icons.star_border), findsOneWidget);
      expect(textOf(const Key('stop-time-2')), 'was 09:30');
    },
  );

  testWidgets('a future day of the trip is present tense, not past', (
    tester,
  ) async {
    await launch(tester, today: day(14));
    await accept(tester, tripPaste);

    await tester.pumpWidget(dayPageAt(day(17), today: day(14)));
    await tester.pump();
    await tester.pump();

    expect(textOf(const Key('day-eyebrow')), 'DAY 3 OF 3');
    expect(find.text('Dotonbori'), findsOneWidget);
    expect(find.textContaining('was '), findsNothing);
  });

  testWidgets('a day of the trip with no stops is a written state', (
    tester,
  ) async {
    await launch(tester, today: day(15));
    await tester.enterText(find.byKey(const Key('paste-input')), restDayPaste);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.text('leave it empty'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();

    expect(textOf(const Key('day-eyebrow')), 'DAY 2 OF 2');
    expect(textOf(const Key('day-title')), 'Tuesday, Hakone');
    expect(
      textOf(const Key('nothing-planned')),
      'Nothing planned. The best day of most trips.',
    );
  });

  testWidgets('a date the plan skips is a gap, not an error', (tester) async {
    await launch(tester, today: day(16));
    await accept(tester, tripPaste);

    // No day number, because 16 June is not one of the plan's numbered days.
    expect(find.byKey(const Key('day-eyebrow')), findsNothing);
    expect(find.byKey(const Key('gap-day')), findsOneWidget);
    expect(textOf(const Key('day-title')), 'Wednesday');
    expect(textOf(const Key('day-date')), '16 June');
    expect(find.byKey(const Key('nothing-planned')), findsOneWidget);
  });

  testWidgets('before the trip: how far away it is, and the day that is next', (
    tester,
  ) async {
    await launch(tester, today: day(10));
    await accept(tester, tripPaste);

    expect(find.byKey(const Key('pre-trip')), findsOneWidget);
    expect(find.text('Four days to go.'), findsOneWidget);
    expect(find.text('3 days planned'), findsOneWidget);

    // Next up is day one, in full.
    expect(textOf(const Key('day-eyebrow')), 'DAY 1 OF 3');
    expect(textOf(const Key('day-title')), 'Monday, Tokyo');
    expect(find.text('Senso-ji'), findsOneWidget);
    expect(find.text('09:30'), findsOneWidget);
  });

  testWidgets('the day before the trip reads "Tomorrow."', (tester) async {
    await launch(tester, today: day(13));
    await accept(tester, tripPaste);

    expect(find.text('Tomorrow.'), findsOneWidget);
  });

  testWidgets('after the trip: it is walked, and the last day is still here', (
    tester,
  ) async {
    await launch(tester, today: day(20));
    await accept(tester, tripPaste);

    expect(find.byKey(const Key('post-trip')), findsOneWidget);
    expect(find.text('The trip is walked.'), findsOneWidget);
    expect(
      find.text('3 days, ending 17 June. Every one of them is still here.'),
      findsOneWidget,
    );

    // The last day is past, so its stops read in the past tense.
    expect(textOf(const Key('day-eyebrow')), 'DAY 3 OF 3');
    expect(find.text('Dotonbori'), findsOneWidget);
  });

  testWidgets('a plan with no dates shows day one, its date open', (
    tester,
  ) async {
    await launch(tester, today: day(15));
    await accept(tester, dateOpenPaste);

    expect(textOf(const Key('day-eyebrow')), 'DAY 1 OF 2');
    expect(textOf(const Key('day-title')), 'Tokyo');
    // No date is invented: the page says the date is open, as design round 8
    // spells it on the confirmation screen.
    expect(textOf(const Key('day-date')), 'date open');
    expect(find.text('Senso-ji'), findsOneWidget);
    expect(find.text('09:30'), findsOneWidget);
  });

  testWidgets('a relaunch lands on Today, not on the paste box', (
    tester,
  ) async {
    await launch(tester, today: day(15));
    await accept(tester, tripPaste);

    // A fresh widget tree and fresh providers over the same database stand
    // in for killing and reopening the app.
    await tester.pumpWidget(bootstrapApp(database: db, today: day(15)));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('paste-input')), findsNothing);
    expect(textOf(const Key('day-eyebrow')), 'DAY 2 OF 3');
    expect(textOf(const Key('day-title')), 'Tuesday, Kyoto');
  });

  // The temporary way back moved off the day page and onto the trip's own
  // title when the container landed; it is tested in trail_and_shell_test.dart.
}
