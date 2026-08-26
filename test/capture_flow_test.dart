// The capture flow: the ping, the window, the pause, the word — and the
// walk through the whole stack, from a pasted plan to a row in Drift.
//
// Three layers of claim, in order of how much they cost to run:
//
//  1. The window, as a pure function. Its edges are the design's numbers
//     (thirty minutes, the last two) and are the easiest thing in the flow
//     to get wrong by an off-by-one.
//  2. The schedule, over a plan. One ping per dated day, inside the waking
//     day, and never one for a day whose date is still open.
//  3. The flow itself, through the real screens and the real store.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is in
// paste_confirm_flow_test.dart; read that file's header before writing any
// test that pumps the app.
//
// The camera is faked, and that is the whole point of the seam: the flow
// under test is the same flow on a phone, on the simulator and here. What
// differs is only where the frame comes from.
//
// Two things a widget test here must not do, both found the hard way and both
// silent hangs at 0% CPU: await a drift *stream* (its shutdown is deferred by
// a timer the faked clock never fires — read the store with `readPhotos()`
// instead), and await real file I/O inside the fake camera.
import 'dart:io';

import 'package:cairn_model/cairn_model.dart'
    as model
    show TripId, TripStanding;
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import 'package:cairn/app_state/camera_source.dart';
import 'package:cairn/app_state/capture_flow.dart';
import 'package:cairn/app_state/ping_schedule.dart';
import 'package:cairn/app_state/stand_in_frame.dart';
import 'package:cairn/app_state/trip_providers.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';

/// Three dated days. (14 June 2027 really is a Monday.)
const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- 09:30 Skytree

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Wed 16 June 2027 - Osaka
- Dotonbori
''';

/// A dated first day and a second whose date was never given.
const halfDatedPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Day 2 - Kyoto
- Fushimi Inari
''';

DateTime day(int dayOfJune) => DateTime.utc(2027, 6, dayOfJune);

/// The trip id the flow's database is told to mint.
///
/// The app mints a fresh uuid for every trip it starts
/// (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md), and the ping is
/// a hash of it — so a test that wants to know which minute the app will
/// choose has to pin the mint, exactly as it pins the clock. Pinning it is
/// also the assertion that the id reaches the derivation at all: deal the app
/// a different id and every expectation below moves.
final testTripId = model.TripId.mint(List.filled(16, 0x5a));

/// The ping this phone is dealt on [date], computed the way the app computes
/// it. The instant is a hash of the trip, the party and the date, so a test
/// cannot choose it — it has to ask for it.
tm.Ping pingOn(DateTime date, {Duration utcOffset = Duration.zero}) => tm
    .dayAssignment(
      tripId: testTripId.value,
      party: tm.Party(const [localMemberId]),
      day: tm.TripDay(date: date, utcOffset: utcOffset),
    )
    .pingFor(localMemberId)!;

/// A camera that hands back a real image file without a device.
class FakeCamera implements CameraSource {
  FakeCamera(this.directory, {required this.takenAtUtc});

  final Directory directory;
  DateTime takenAtUtc;

  final List<String> taken = [];
  final List<String> discarded = [];

  @override
  Future<CapturedFrame> takeOne() async {
    // Written synchronously on purpose: a widget test's clock is faked, and
    // an awaited file write does not complete inside `pumpAndSettle`. The
    // real sources are async; this one only has to be a source.
    final path = '${directory.path}/frame-${taken.length + 1}.png';
    File(path).writeAsBytesSync(standInFrameBytes(taken.length + 1));
    taken.add(path);
    return CapturedFrame(path: path, takenAtUtc: takenAtUtc);
  }

  @override
  Future<void> discard(String path) async => discarded.add(path);
}

/// A camera that will not open — a denied permission, a lens in use.
class RefusingCamera implements CameraSource {
  @override
  Future<CapturedFrame> takeOne() async =>
      throw const CameraRefused('The camera would not open.');

  @override
  Future<void> discard(String path) async {}
}

void main() {
  // -------------------------------------------------------------------------
  group('the window', () {
    final ping = tm.Ping(
      memberId: localMemberId,
      slotIndex: 0,
      at: DateTime.utc(2027, 6, 14, 11, 40),
      localTimeOfDay: const Duration(hours: 11, minutes: 40),
    );

    CaptureCall callAt(
      DateTime now, {
      DateTime? answeredAt,
      tm.Ping? p,
      model.TripStanding standing = model.TripStanding.underway,
    }) => captureCallFor(
      ping: p ?? ping,
      now: now,
      answeredAt: answeredAt,
      utcOffset: Duration.zero,
      standing: standing,
    );

    test('no ping today is nothing asked of you', () {
      expect(
        captureCallFor(
          ping: null,
          now: DateTime.utc(2027, 6, 14, 11, 40),
          answeredAt: null,
          utcOffset: Duration.zero,
          standing: model.TripStanding.underway,
        ),
        isA<NoMomentHere>(),
      );
    });

    test('before your minute, the moment is ahead', () {
      expect(callAt(DateTime.utc(2027, 6, 14, 11, 39)), isA<MomentAhead>());
    });

    test('the window opens on the minute itself', () {
      final call = callAt(DateTime.utc(2027, 6, 14, 11, 40));
      expect(call, isA<MomentOpen>());
      expect((call as MomentOpen).isLastStretch, isFalse);
    });

    test('the last two minutes are the last stretch, and not before', () {
      expect(
        (callAt(
          DateTime.utc(2027, 6, 14, 12, 7, 59),
        ) as MomentOpen).isLastStretch,
        isFalse,
      );
      expect(
        (callAt(DateTime.utc(2027, 6, 14, 12, 8)) as MomentOpen).isLastStretch,
        isTrue,
      );
    });

    test('thirty minutes later the window is closed and the day is not', () {
      expect(callAt(DateTime.utc(2027, 6, 14, 12, 10)), isA<MomentLate>());
      // No lockout, ever: hours later is still the open door
      // (docs/decisions/2026-08-22-design-calls.md §7).
      expect(callAt(DateTime.utc(2027, 6, 14, 23, 40)), isA<MomentLate>());
    });

    test('having answered outranks a window that is still open', () {
      final call = callAt(
        DateTime.utc(2027, 6, 14, 11, 45),
        answeredAt: DateTime.utc(2027, 6, 14, 11, 42),
      );
      expect(call, isA<MomentAnswered>());
      expect((call as MomentAnswered).hourLabel, '11:42');
    });

    test('the hour is read in the trip\'s clock, not the phone\'s', () {
      final call = captureCallFor(
        ping: ping,
        now: DateTime.utc(2027, 6, 14, 12),
        answeredAt: DateTime.utc(2027, 6, 14, 2, 40),
        utcOffset: const Duration(hours: 9), // Tokyo
        standing: model.TripStanding.underway,
      );
      expect((call as MomentAnswered).hourLabel, '11:40');
    });
  });

  // -------------------------------------------------------------------------
  group('the schedule', () {
    final party = tm.Party(const [localMemberId]);

    TripPlan plan(List<DateTime?> dates) => TripPlan(
      days: [
        for (final (i, date) in dates.indexed)
          PlanDay(number: i + 1, date: date, stops: const []),
      ],
    );

    test('one ping per dated day, in time order', () {
      final pings = pingsForPlan(
        plan: plan([day(14), day(15), day(16)]),
        party: party,
        utcOffset: Duration.zero,
        memberId: localMemberId,
        tripId: testTripId,
      );
      expect(pings, hasLength(3));
      expect(
        pings.map((p) => p.at).toList(),
        [for (final p in pings) p.at]..sort(),
      );
    });

    test('a day whose date is still open gets no ping', () {
      // A ping is an instant, and nothing here guesses a date — the same
      // refusal the parser and the day page make.
      final pings = pingsForPlan(
        plan: plan([day(14), null]),
        party: party,
        utcOffset: Duration.zero,
        memberId: localMemberId,
        tripId: testTripId,
      );
      expect(pings, hasLength(1));
    });

    test('no plan is no schedule', () {
      expect(
        pingsForPlan(
          plan: null,
          party: party,
          utcOffset: Duration.zero,
          memberId: localMemberId,
          tripId: testTripId,
        ),
        isEmpty,
      );
    });

    test('every ping lands inside the waking day, 08:00 to 22:30', () {
      for (final ping in pingsForPlan(
        plan: plan([day(14), day(15), day(16), day(17), day(18)]),
        party: party,
        utcOffset: Duration.zero,
        memberId: localMemberId,
        tripId: testTripId,
      )) {
        expect(
          ping.localTimeOfDay,
          greaterThanOrEqualTo(const Duration(hours: 8)),
        );
        expect(
          ping.localTimeOfDay,
          lessThanOrEqualTo(const Duration(hours: 22, minutes: 30)),
        );
      }
    });

    test('the same inputs deal the same instants, every time', () {
      // The derivation is a compatibility contract: two phones on one trip
      // must agree without asking each other anything
      // (docs/architecture.md, invariant 4).
      List<DateTime> run() => [
        for (final p in pingsForPlan(
          plan: plan([day(14), day(15)]),
          party: party,
          utcOffset: Duration.zero,
          memberId: localMemberId,
          tripId: testTripId,
        ))
          p.at,
      ];
      expect(run(), run());
    });

    test('only the pings still to come are registered', () {
      final schedule = pingsForPlan(
        plan: plan([day(14), day(15), day(16)]),
        party: party,
        utcOffset: Duration.zero,
        memberId: localMemberId,
        tripId: testTripId,
      );
      final container = ProviderContainer(
        overrides: [
          pingScheduleProvider.overrideWithValue(schedule),
          nowProvider.overrideWithValue(day(15)),
        ],
      );
      addTearDown(container.dispose);

      final due = container.read(pingRegistrationProvider);
      expect(due, hasLength(2), reason: '14 June is behind us');

      final edge =
          container.read(notificationEdgeProvider) as RecordingNotificationEdge;
      expect(edge.registered, hasLength(2));
      expect(edge.registered.first.title, 'Cairn now');
      expect(
        edge.registered.map((p) => p.at).toList(),
        due.map((p) => p.at).toList(),
        reason:
            'the edge holds exactly the deal, never the deal plus an old '
            'one — two interruptions in a day is the one thing the mechanic '
            'promises never to do',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('the flow', () {
    late AppDatabase db;
    late Directory frames;

    setUp(() {
      db = AppDatabase(
        DatabaseConnection(
          NativeDatabase.memory(),
          closeStreamsSynchronously: true,
        ),
        // Pin the mint, so `pingOn` can predict the minute the app deals.
        mint: () => testTripId,
      );
      frames = Directory.systemTemp.createTempSync('cairn-frames');
    });
    tearDown(() async {
      await db.close();
      if (frames.existsSync()) frames.deleteSync(recursive: true);
    });

    Future<void> launch(
      WidgetTester tester, {
      required DateTime today,
      required DateTime now,
      CameraSource? camera,
    }) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        bootstrapApp(
          database: db,
          today: today,
          now: now,
          utcOffset: Duration.zero,
          camera: camera ?? FakeCamera(frames, takenAtUtc: now),
        ),
      );
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

    testWidgets('before your minute, today says so and asks for nothing', (
      tester,
    ) async {
      final ping = pingOn(day(14));
      await launch(
        tester,
        today: day(14),
        now: ping.at.subtract(const Duration(minutes: 1)),
      );
      await accept(tester, tripPaste);

      expect(
        textOf(const Key('capture-call')),
        'Your minute is somewhere in today.',
      );
      // It never says when. A ping you can see coming is a ping you can pose
      // for (docs/decisions/2026-08-22-the-moment.md).
      expect(find.textContaining(ping.localLabel), findsNothing);
      expect(find.byKey(const Key('capture-call-action')), findsNothing);
    });

    testWidgets('the whole moment: the call, the shutter, the pause, the word, '
        'and a photo in the store', (tester) async {
      final ping = pingOn(day(14));
      final shutter = ping.at.add(const Duration(minutes: 3));
      final camera = FakeCamera(frames, takenAtUtc: shutter);
      await launch(tester, today: day(14), now: shutter, camera: camera);
      await accept(tester, tripPaste);

      expect(textOf(const Key('capture-call')), 'Your minute. Look up.');
      await tester.tap(find.byKey(const Key('capture-call-action')));
      await tester.pumpAndSettle();

      // The thread has not run out, and the app is as precise as it ever gets.
      expect(textOf(const Key('capture-window')), 'a while yet');

      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();

      expect(camera.taken, hasLength(1));
      expect(
        textOf(const Key('capture-hour')),
        '${shutter.hour.toString().padLeft(2, '0')}:'
        '${shutter.minute.toString().padLeft(2, '0')}, yours.',
      );
      expect(textOf(const Key('capture-word-whisper')), 'blank is the usual');

      await tester.enterText(
        find.byKey(const Key('capture-word')),
        'we CAUGHT it',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      // The sheet closed itself and the day page is back, now answered.
      expect(find.byKey(const Key('capture-hour')), findsNothing);
      expect(
        textOf(const Key('capture-call')),
        'Yours landed at ${shutter.hour.toString().padLeft(2, '0')}:'
        '${shutter.minute.toString().padLeft(2, '0')}.',
      );
      expect(find.byKey(const Key('capture-call-action')), findsNothing);

      final kept = await db.readPhotos();
      expect(kept, hasLength(1));
      expect(kept.single.dayNumber, 1);
      expect(kept.single.contributorId, localMemberId);
      expect(kept.single.origin, 'pinged');
      expect(kept.single.word, 'we CAUGHT it');
      expect(kept.single.takenAtUtcIso, shutter.toIso8601String());
      expect(kept.single.filePath, camera.taken.single);
    });

    testWidgets('what you keep is what the Pool draws', (tester) async {
      // The join between the two features, and the only thing that proves
      // they share a store rather than a wire: capture writes through
      // `photoStoreProvider`, the Pool reads through `photoRepositoryProvider`,
      // and `bootstrapApp` binds both to one `PhotoStore`. Bind them to two
      // and every assertion above still passes while the Pool stays empty.
      final ping = pingOn(day(14));
      final shutter = ping.at.add(const Duration(minutes: 3));
      await launch(
        tester,
        today: day(14),
        now: shutter,
        camera: FakeCamera(frames, takenAtUtc: shutter),
      );
      await accept(tester, tripPaste);

      await tester.tap(find.byKey(const Key('capture-call-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('capture-word')),
        'we CAUGHT it',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      // The id is minted by the store, so ask the store what it minted.
      final id = (await db.readPhotos()).single.id;

      await tester.tap(find.byKey(const Key('tab-pool')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pool-empty')), findsNothing);
      expect(find.byKey(Key('pool-photo-$id')), findsOneWidget);
      // Day one of the plan, where the moment was answered.
      expect(find.byKey(const Key('pool-day-1')), findsOneWidget);
      // The bytes are on this phone — this one it took itself.
      expect(find.byKey(Key('pool-photo-$id-awaiting')), findsNothing);
    });

    testWidgets('the word is skippable, and blank is stored as no word', (
      tester,
    ) async {
      final ping = pingOn(day(14));
      await launch(tester, today: day(14), now: ping.at);
      await accept(tester, tripPaste);

      await tester.tap(find.byKey(const Key('capture-call-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      // The tap that skips writing is the same tap that was always there.
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      final kept = await db.readPhotos();
      expect(kept.single.word, isNull);
    });

    testWidgets('one retake, and after it the control is gone', (tester) async {
      final ping = pingOn(day(14));
      final camera = FakeCamera(frames, takenAtUtc: ping.at);
      await launch(tester, today: day(14), now: ping.at, camera: camera);
      await accept(tester, tripPaste);

      await tester.tap(find.byKey(const Key('capture-call-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('capture-once-more')), findsOneWidget);
      await tester.tap(find.byKey(const Key('capture-once-more')));
      await tester.pumpAndSettle();

      // Back at the framing, and the first frame was thrown away.
      expect(find.byKey(const Key('capture-shutter')), findsOneWidget);
      expect(camera.discarded, [camera.taken.first]);

      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();

      // Absent, not disabled.
      expect(find.byKey(const Key('capture-once-more')), findsNothing);
      expect(find.byKey(const Key('capture-keep')), findsOneWidget);
    });

    testWidgets('leaving without keeping throws the frame away', (
      tester,
    ) async {
      final ping = pingOn(day(14));
      final camera = FakeCamera(frames, takenAtUtc: ping.at);
      await launch(tester, today: day(14), now: ping.at, camera: camera);
      await accept(tester, tripPaste);

      await tester.tap(find.byKey(const Key('capture-call-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      expect(await db.readPhotos(), hasLength(1));
    });

    testWidgets('a missed slot is not a lockout: the door is open till '
        'midnight', (tester) async {
      final ping = pingOn(day(14));
      final late = ping.at.add(const Duration(hours: 6));
      await launch(tester, today: day(14), now: late);
      await accept(tester, tripPaste);

      expect(
        textOf(const Key('capture-call')),
        "Your minute came and went. The door's open till midnight.",
      );
      await tester.tap(find.byKey(const Key('capture-call-action')));
      await tester.pumpAndSettle();

      // Surface 10c: no thread at all, so there is nothing to have failed.
      expect(
        textOf(const Key('capture-window')),
        "Your slot was teatime. It's fine — whatever you take now lands at "
        "the hour it's taken.",
      );

      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      final kept = await db.readPhotos();
      // The late photo carries its real hour, and is visibly late.
      expect(kept.single.takenAtUtcIso, late.toIso8601String());
    });

    testWidgets('a camera that will not open says so, and keeps nothing', (
      tester,
    ) async {
      final ping = pingOn(day(14));
      await launch(
        tester,
        today: day(14),
        now: ping.at,
        camera: RefusingCamera(),
      );
      await accept(tester, tripPaste);

      await tester.tap(find.byKey(const Key('capture-call-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();

      expect(
        textOf(const Key('capture-refused')),
        'The camera would not open.',
      );
      expect(await db.readPhotos(), isEmpty);
    });

    testWidgets('a day whose date is still open asks nothing of anyone', (
      tester,
    ) async {
      final ping = pingOn(day(14));
      await launch(tester, today: day(14), now: ping.at);
      await accept(tester, halfDatedPaste);

      // Day 1 is dated and today, so it does have a moment.
      expect(find.byKey(const Key('capture-call')), findsOneWidget);

      // Day 2 has no date, so it can hold no instant and asks nothing. The
      // Trail is how a dateless day is reached at all.
      await tester.tap(find.byKey(const Key('tab-trail')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('trail-node-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('capture-call')), findsNothing);
    });

    testWidgets('a day that is not today asks nothing', (tester) async {
      final ping = pingOn(day(14));
      await launch(tester, today: day(14), now: ping.at);
      await accept(tester, tripPaste);

      await tester.tap(find.byKey(const Key('tab-trail')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('trail-node-3')));
      await tester.pumpAndSettle();

      // A day that is over belongs to the whole party; adding to it later is
      // the import sweep's job, not this flow's.
      expect(find.byKey(const Key('capture-call')), findsNothing);
    });
  });
}
