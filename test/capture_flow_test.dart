// The capture flow: the ping, the window, the pause, the word — and the
// walk through the whole stack, from a pasted plan to a row in Drift.
//
// Three layers of claim, in order of how much they cost to run:
//
//  1. The window, as a pure function. Its edges are the design's numbers
//     (two minutes, the last thirty seconds) and are the easiest thing in the
//     flow to get wrong by an off-by-one. The countdown the capture screen
//     shows is the same function read a third way, so it is pinned here too.
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
import 'package:flutter/services.dart' show StringCodec;
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
///
/// `bothLenses` makes it the two-lens source a phone is: one `takeOne()` is
/// one capture *event*, and it delivers a back frame and a front one.
class FakeCamera implements CameraSource {
  FakeCamera(
    this.directory, {
    required this.takenAtUtc,
    this.bothLenses = false,
  });

  final Directory directory;
  DateTime takenAtUtc;
  final bool bothLenses;

  final List<String> taken = [];
  final List<String> frontTaken = [];
  final List<String> discarded = [];

  @override
  Future<CapturedFrame> takeOne() async {
    // Written synchronously on purpose: a widget test's clock is faked, and
    // an awaited file write does not complete inside `pumpAndSettle`. The
    // real sources are async; this one only has to be a source.
    final path = '${directory.path}/frame-${taken.length + 1}.png';
    File(path).writeAsBytesSync(standInFrameBytes(taken.length + 1));
    taken.add(path);
    if (!bothLenses) {
      return CapturedFrame(path: path, takenAtUtc: takenAtUtc);
    }
    final frontPath = '${directory.path}/front-${taken.length}.png';
    File(frontPath).writeAsBytesSync(standInFrameBytes(taken.length));
    frontTaken.add(frontPath);
    return CapturedFrame(
      path: path,
      frontPath: frontPath,
      takenAtUtc: takenAtUtc,
    );
  }

  @override
  Future<void> discard(String path) async => discarded.add(path);
}

/// The recording edge, plus a tally of how often it was asked.
class CountingNotificationEdge extends RecordingNotificationEdge {
  int passes = 0;

  @override
  Future<void> replaceScheduledPings(List<ScheduledPing> pings) {
    passes++;
    return super.replaceScheduledPings(pings);
  }
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

    test('two minutes, to the second, and then the window is shut', () {
      // The window is two minutes, at both of its edges. The last second of
      // the window is still the window; the closing instant itself is not.
      expect(
        callAt(DateTime.utc(2027, 6, 14, 11, 41, 59)),
        isA<MomentOpen>(),
        reason: 'a second short of two minutes is still your minute',
      );
      expect(
        callAt(DateTime.utc(2027, 6, 14, 11, 42)),
        isA<MomentLate>(),
        reason: 'two minutes past the ping the window has shut',
      );
    });

    test('the last thirty seconds are the last stretch, and not before', () {
      // `lastStretch` was retuned with the window rather than left at the two
      // minutes it was: two minutes of a two-minute window is not a tail, and
      // would make `isLastStretch: false` a state nobody could be in.
      expect(
        (callAt(
          DateTime.utc(2027, 6, 14, 11, 41, 29),
        ) as MomentOpen).isLastStretch,
        isFalse,
      );
      expect(
        (callAt(
          DateTime.utc(2027, 6, 14, 11, 41, 30),
        ) as MomentOpen).isLastStretch,
        isTrue,
      );
    });

    test('a moment carries the instant it shuts, open or shut', () {
      // The deadline is a fact about the moment, and both doors into the
      // camera hand it over: it is what the countdown counts to and what a
      // retake returns to, and nothing downstream recomputes it.
      final closes = DateTime.utc(2027, 6, 14, 11, 42);
      expect(
        (callAt(DateTime.utc(2027, 6, 14, 11, 41)) as MomentOpen).closesAt,
        closes,
      );
      expect(
        (callAt(DateTime.utc(2027, 6, 14, 18)) as MomentLate).closesAt,
        closes,
      );
    });

    test('past the window the door is open and stays open till midnight', () {
      expect(callAt(DateTime.utc(2027, 6, 14, 12, 10)), isA<MomentLate>());
      // No lockout, ever: hours later is still the open door
      // (docs/decisions/2026-08-22-design-calls.md §7). The narrowing took
      // the window down to two minutes and left this alone.
      expect(callAt(DateTime.utc(2027, 6, 14, 23, 40)), isA<MomentLate>());
      expect(callAt(DateTime.utc(2027, 6, 14, 23, 59, 59)), isA<MomentLate>());
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
  group('the countdown', () {
    // One derivation behind three things that have to agree — what is left,
    // whether this is the tail, and whether the window has shut — because a
    // surface that worked any of them out itself could contradict the other
    // two mid-second.
    final closes = DateTime.utc(2027, 6, 14, 11, 42);
    WindowStanding at(DateTime now) =>
        windowStandingAt(closesAt: closes, now: now);

    test('a whole window reads as the whole window', () {
      final window = at(DateTime.utc(2027, 6, 14, 11, 40));
      expect(window.remaining, const Duration(minutes: 2));
      expect(window.countdownLabel, '2:00 left');
      expect(window.isLastStretch, isFalse);
      expect(window.isLate, isFalse);
    });

    test('the tail is thirty seconds, and the label says so', () {
      expect(
        at(DateTime.utc(2027, 6, 14, 11, 41, 29)).countdownLabel,
        '0:31 left',
      );
      expect(at(DateTime.utc(2027, 6, 14, 11, 41, 29)).isLastStretch, isFalse);
      expect(
        at(DateTime.utc(2027, 6, 14, 11, 41, 30)).countdownLabel,
        '0:30 left',
      );
      expect(at(DateTime.utc(2027, 6, 14, 11, 41, 30)).isLastStretch, isTrue);
    });

    test('the last reading is 0:01 and never a lingering 0:00', () {
      // Rounded up: half a second left is still a second on screen, and the
      // countdown is gone entirely by the time it would have said zero.
      expect(
        at(DateTime.utc(2027, 6, 14, 11, 41, 59, 500)).countdownLabel,
        '0:01 left',
      );
      expect(
        at(DateTime.utc(2027, 6, 14, 11, 41, 59)).countdownLabel,
        '0:01 left',
      );
    });

    test('a shut window is handed no countdown at all', () {
      // Surface 10c in the type: a late capture is not given a timer to hide,
      // it is given nothing to show, so there is nothing to have failed.
      final window = at(closes);
      expect(window.isLate, isTrue);
      expect(window.remaining, Duration.zero);
      expect(window.countdownLabel, isNull);
      expect(at(DateTime.utc(2027, 6, 14, 18)).countdownLabel, isNull);
    });

    test('the deadline is an input, so late is a one-way door', () {
      // Nothing here derives `closesAt`, which is what lets a retake hand
      // back the very instant it was given. Time runs one way over a fixed
      // instant, so a moment that has gone late cannot come back.
      for (final now in [
        DateTime.utc(2027, 6, 14, 11, 42),
        DateTime.utc(2027, 6, 14, 11, 45),
        DateTime.utc(2027, 6, 14, 23, 59),
      ]) {
        expect(at(now).isLate, isTrue, reason: '$now');
      }
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
          nowProvider.overrideWithValue(pinnedClock(from: day(15))),
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

    test('the clock moving is not a reason to register anything again', () {
      // The registration follows the *deal*, and the clock only says which
      // of it is behind us. Watching the clock instead made this a pass on
      // the app root's cadence: the trip's whole notification set torn down
      // and re-registered every ten seconds, for as long as a trip surface
      // was on screen.
      final schedule = pingsForPlan(
        plan: plan([day(14), day(15), day(16)]),
        party: party,
        utcOffset: Duration.zero,
        memberId: localMemberId,
        tripId: testTripId,
      );
      final edge = CountingNotificationEdge();
      // A clock that really reads differently on every ask, so that a
      // registration watching it would rebuild and this test would fail.
      var instant = day(15);
      final container = ProviderContainer(
        overrides: [
          pingScheduleProvider.overrideWithValue(schedule),
          nowProvider.overrideWith((ref) => pinnedClock(from: instant)),
          notificationEdgeProvider.overrideWithValue(edge),
        ],
      );
      addTearDown(container.dispose);
      container.listen(pingRegistrationProvider, (_, _) {});

      expect(container.read(pingRegistrationProvider), hasLength(2));
      expect(edge.passes, 1);

      for (var tick = 1; tick <= 5; tick++) {
        instant = instant.add(const Duration(seconds: 10));
        container.invalidate(nowProvider);
        container.read(pingRegistrationProvider);
      }

      expect(
        edge.passes,
        1,
        reason: 'the schedule was re-registered on a bare clock tick',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('the flow', () {
    late AppDatabase db;
    late Directory frames;

    /// Wall time that passed while none of the app's timers ran.
    ///
    /// The countdown measures elapsed time rather than counting its own ticks
    /// (`ping_schedule.dart`'s clock says why), and this is the only way to
    /// say so in a test: `tester.pump(d)` fires every tick it skips over, so
    /// a phone suspended for ninety seconds cannot be written as a pump — a
    /// countdown that merely added a second per tick would come back looking
    /// right. Set this instead and nothing of the app's runs at all.
    late Duration suspended;

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
      suspended = Duration.zero;
    });
    tearDown(() async {
      await db.close();
      if (frames.existsSync()) frames.deleteSync(recursive: true);
    });

    Future<void> launch(
      WidgetTester tester, {
      DateTime? today,
      required DateTime now,
      Duration utcOffset = Duration.zero,
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
          utcOffset: utcOffset,
          camera: camera ?? FakeCamera(frames, takenAtUtc: now),
          // The countdown's elapsed-time source, pinned exactly as `now:`
          // pins the instant it counts from — the real one is the wall clock,
          // and a countdown reading that here would pass or fail by how long
          // the suite took to run. This one follows the widget test's own
          // faked clock, so `pump(d)` moves it exactly as it moves everything
          // else, and carries [suspended] on top: wall time the app slept
          // through.
          elapsed: () {
            final from = tester.binding.clock.now();
            return () =>
                tester.binding.clock.now().difference(from) + suspended;
          },
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

    /// What the capture screen's countdown says, or null when there is no
    /// countdown on screen at all — which is the whole of surface 10c's rule
    /// and so is asserted as often as the label itself.
    String? countdown() =>
        find.byKey(const Key('capture-countdown')).evaluate().isEmpty
        ? null
        : textOf(const Key('capture-countdown'));

    /// The same reading as a duration, for the tests that care that it *moved*
    /// rather than what it says.
    Duration leftOnScreen() {
      final clock = countdown()!.split(' ').first.split(':');
      return Duration(
        minutes: int.parse(clock.first),
        seconds: int.parse(clock.last),
      );
    }

    /// Opens the camera from the day page's one call to action.
    Future<void> openTheCamera(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('capture-call-action')));
      await tester.pumpAndSettle();
    }

    /// The app going away and coming back — the one moment no tick of the
    /// app's own announces.
    Future<void> awayAndBack(WidgetTester tester) async {
      for (final state in [
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
      ]) {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/lifecycle',
          const StringCodec().encodeMessage(state.toString()),
          (_) {},
        );
      }
      await tester.pump();
    }

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
      // Half a minute in: the window is two minutes wide now, so a shutter
      // three minutes past the ping would be a late capture, not this one.
      final shutter = ping.at.add(const Duration(seconds: 30));
      final camera = FakeCamera(frames, takenAtUtc: shutter);
      await launch(tester, today: day(14), now: shutter, camera: camera);
      await accept(tester, tripPaste);

      expect(textOf(const Key('capture-call')), 'Your minute. Look up.');
      await openTheCamera(tester);

      // The thread has not run out, and the app is as deadpan as it ever gets
      // — with the countdown beside it, which is the only precise thing on
      // the screen and the main feedback a two-minute window gives.
      expect(textOf(const Key('capture-window')), 'a while yet');
      expect(countdown(), '1:30 left');

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

      await openTheCamera(tester);
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

    testWidgets('turning the day over keeps the back frame and lets the '
        'front one go', (tester) async {
      // A capture event is two files and the day keeps one of them. The row
      // points at the back frame where it lies, and nothing reads the front
      // one past the review — so the exit that keeps must let it go, exactly
      // as `once more` and leaving do. It used to keep neither and delete
      // neither, orphaning a full-resolution frame per photograph.
      final ping = pingOn(day(14));
      final camera = FakeCamera(frames, takenAtUtc: ping.at, bothLenses: true);
      await launch(tester, today: day(14), now: ping.at, camera: camera);
      await accept(tester, tripPaste);

      await openTheCamera(tester);
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      // Both halves are on the review before anything is decided.
      expect(find.byKey(const Key('capture-back-frame')), findsOneWidget);
      expect(find.byKey(const Key('capture-front-frame')), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      final kept = await db.readPhotos();
      expect(kept.single.filePath, camera.taken.single);
      expect(
        camera.discarded,
        camera.frontTaken,
        reason: 'the front frame is nobody\'s once the day has turned over',
      );
      expect(
        camera.discarded,
        isNot(contains(camera.taken.single)),
        reason: 'the kept row points at the back frame where it lies',
      );
    });

    testWidgets('a retake throws away both halves of the event', (
      tester,
    ) async {
      final ping = pingOn(day(14));
      final camera = FakeCamera(frames, takenAtUtc: ping.at, bothLenses: true);
      await launch(tester, today: day(14), now: ping.at, camera: camera);
      await accept(tester, tripPaste);

      await openTheCamera(tester);
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-once-more')));
      await tester.pumpAndSettle();

      expect(camera.discarded, [...camera.taken, ...camera.frontTaken]);
    });

    testWidgets('the word is skippable, and blank is stored as no word', (
      tester,
    ) async {
      final ping = pingOn(day(14));
      await launch(tester, today: day(14), now: ping.at);
      await accept(tester, tripPaste);

      await openTheCamera(tester);
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      // The tap that skips writing is the same tap that was always there.
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      final kept = await db.readPhotos();
      expect(kept.single.word, isNull);
    });

    testWidgets('a retake before the deadline, and the control stays', (
      tester,
    ) async {
      final ping = pingOn(day(14));
      final camera = FakeCamera(frames, takenAtUtc: ping.at);
      await launch(tester, today: day(14), now: ping.at, camera: camera);
      await accept(tester, tripPaste);

      await openTheCamera(tester);
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

      // And the control is still there. There is no cap on retakes; what
      // bounds one now is the window, which is why the countdown sits beside
      // the control.
      expect(find.byKey(const Key('capture-once-more')), findsOneWidget);
      expect(find.byKey(const Key('capture-keep')), findsOneWidget);
      expect(countdown(), isNotNull);
    });

    testWidgets('several retakes in a row, and the window pays for none '
        'of them', (tester) async {
      final ping = pingOn(day(14));
      // Answered a minute in, so the clock the app was given and the deadline
      // it is counting to are *different* instants. A retake that recomputed
      // the deadline from "now" would be invisible if they were the same.
      final arrived = ping.at.add(const Duration(seconds: 60));
      final camera = FakeCamera(frames, takenAtUtc: arrived);
      await launch(tester, today: day(14), now: arrived, camera: camera);
      await accept(tester, tripPaste);

      await openTheCamera(tester);
      expect(countdown(), '1:00 left', reason: 'a minute of it already gone');

      // Thirty more seconds spent standing at the framing screen.
      await tester.pump(const Duration(seconds: 30));
      expect(countdown(), '0:30 left');
      expect(textOf(const Key('capture-window')), 'last stretch');

      for (var attempt = 1; attempt <= 4; attempt++) {
        await tester.tap(find.byKey(const Key('capture-shutter')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('capture-once-more')),
          findsOneWidget,
          reason: 'retake $attempt was refused a control',
        );
        await tester.tap(find.byKey(const Key('capture-once-more')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('capture-shutter')), findsOneWidget);
      }

      // Four frames taken and all four thrown away — nothing is kept until
      // the day is turned over.
      expect(camera.taken, hasLength(4));
      expect(camera.discarded, camera.taken);

      // And the deadline never moved. A retake that recomputed it from now
      // would be reading about a minute and a half here, on its way to never
      // closing at all; a countdown the retakes had restarted would be
      // reading the whole two minutes. Both are the bug.
      expect(countdown(), isNotNull, reason: 'the window shut mid-test');
      expect(
        leftOnScreen(),
        lessThanOrEqualTo(const Duration(seconds: 30)),
        reason: 'four retakes handed back time the window had already spent',
      );
      expect(textOf(const Key('capture-window')), 'last stretch');

      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      final kept = await db.readPhotos();
      expect(kept, hasLength(1), reason: 'one moment is one photograph');
      expect(kept.single.filePath, camera.taken.last);
      // The count of retakes is nobody's business but the person's: the
      // posted photograph never shows how many retakes it took, so it is not
      // stored and the pool has no column that could show it.
      expect(kept.single.word, isNull);
    });

    testWidgets('the countdown runs the window down, and the surface goes '
        'with it', (tester) async {
      final ping = pingOn(day(14));
      await launch(tester, today: day(14), now: ping.at);
      await accept(tester, tripPaste);

      await openTheCamera(tester);
      expect(countdown(), '2:00 left');
      expect(textOf(const Key('capture-window')), 'a while yet');

      // Ninety seconds in, the tail. `lastStretch` is thirty seconds now,
      // retuned with the window rather than left at the two minutes it was.
      await tester.pump(const Duration(seconds: 90));
      expect(countdown(), '0:30 left');
      expect(textOf(const Key('capture-window')), 'last stretch');

      await tester.pump(const Duration(seconds: 29));
      expect(countdown(), '0:01 left');

      // Two minutes exactly, and the window is shut — with the camera still
      // open, because there is no lockout. What goes away is the timer, not
      // the door (surface 10c).
      await tester.pump(const Duration(seconds: 1));
      expect(countdown(), isNull);
      expect(
        textOf(const Key('capture-window')),
        "Your slot was teatime. It's fine — whatever you take now lands at "
        "the hour it's taken.",
      );
      expect(find.byKey(const Key('capture-shutter')), findsOneWidget);
    });

    testWidgets('three minutes inside the app is three minutes off the '
        'window', (tester) async {
      // The app's clock is asked, never remembered. It used to be a cached
      // `Provider<DateTime>` read once at launch and held for the life of the
      // session, so a launch from the ping notification pinned "now" at the
      // moment the app started and every verdict afterwards was measured
      // against a clock that had stopped. Cold-launch five seconds after the
      // ping, spend three minutes in the app, and the capture surface used to
      // open on `1:55 left / a while yet` a minute after the window shut.
      final ping = pingOn(day(14));
      final arrived = ping.at.add(const Duration(seconds: 5));
      final camera = FakeCamera(frames, takenAtUtc: arrived);
      await launch(tester, today: day(14), now: arrived, camera: camera);
      await accept(tester, tripPaste);

      // Launched inside the window, so the day page rightly asks for the
      // photograph. That call is what the person taps three minutes later.
      expect(textOf(const Key('capture-call')), 'Your minute. Look up.');

      await tester.pump(const Duration(minutes: 3));

      // The day page has to let go of it too, and by itself: the whole app's
      // time-derived verdicts are asked again on the root's cadence, so a
      // call to action nobody touched stops being an invitation to be
      // punctual once the window has shut.
      expect(
        textOf(const Key('capture-call')),
        "Your minute came and went. The door's open till midnight.",
        reason: 'the day page was still offering a window that had shut',
      );

      await openTheCamera(tester);

      expect(
        textOf(const Key('capture-window')),
        "Your slot was teatime. It's fine — whatever you take now lands at "
        "the hour it's taken.",
        reason: 'the camera opened on a clock that stopped at launch',
      );
      expect(countdown(), isNull, reason: 'a shut window still had a thread');

      // And it stays right through the retakes, because the deadline it is
      // measured against never moved either.
      for (var attempt = 1; attempt <= 2; attempt++) {
        await tester.tap(find.byKey(const Key('capture-shutter')));
        await tester.pumpAndSettle();
        expect(countdown(), isNull, reason: 'a countdown on retake $attempt');
        await tester.tap(find.byKey(const Key('capture-once-more')));
        await tester.pumpAndSettle();
        expect(
          textOf(const Key('capture-window')),
          "Your slot was teatime. It's fine — whatever you take now lands at "
          "the hour it's taken.",
          reason: 'retake $attempt came back punctual',
        );
      }
    });

    testWidgets('an app still running past midnight lets go of yesterday', (
      tester,
    ) async {
      // The late door runs to midnight and nothing but the date shuts it —
      // `captureCallFor` never compares against one. So the date has to move
      // while the app runs, and it does because it is the same clock read
      // another way. This is the only test here that does not pin `today:`,
      // for exactly that reason: pinning it would answer the question the
      // test is asking.
      //
      // Written in the device's own zone on both sides, because the date is
      // the device's: the trip's offset is the one in force that evening, so
      // the ping lands in that evening's waking hours whatever zone the
      // suite runs in.
      final evening = DateTime(2027, 6, 14, 23, 50);
      final zone = evening.timeZoneOffset;
      final camera = FakeCamera(frames, takenAtUtc: evening.toUtc());
      await launch(
        tester,
        now: evening.toUtc(),
        utcOffset: zone,
        camera: camera,
      );
      await accept(tester, tripPaste);

      expect(
        textOf(const Key('capture-call')),
        "Your minute came and went. The door's open till midnight.",
        reason: 'ten past eleven at night is still the fourteenth',
      );

      await tester.pump(const Duration(minutes: 20));

      expect(
        textOf(const Key('capture-call')),
        'Your minute is somewhere in today.',
        reason: "midnight passed and yesterday's door was still open",
      );
    });

    testWidgets('a window that shut in a pocket is shut on the day page when '
        'the phone comes back', (tester) async {
      // The resume half of the same asking. Nothing of the app's runs while a
      // backgrounded phone is suspended, so the cadence covers none of this
      // interval — the whole flip has to come from the lifecycle event, which
      // is why nothing below pumps any time at all.
      final ping = pingOn(day(14));
      final camera = FakeCamera(frames, takenAtUtc: ping.at);
      await launch(tester, today: day(14), now: ping.at, camera: camera);
      await accept(tester, tripPaste);

      expect(textOf(const Key('capture-call')), 'Your minute. Look up.');

      suspended = const Duration(minutes: 3);
      await awayAndBack(tester);

      expect(
        textOf(const Key('capture-call')),
        "Your minute came and went. The door's open till midnight.",
        reason: 'the phone came back to a window it thought was still open',
      );
    });

    testWidgets('a minute that arrives while you are looking at the trip is '
        'offered without a relaunch', (tester) async {
      // The other direction of the same defect, and the one no lifecycle
      // event covers: the app that was already open, in front of you, when
      // your minute came. A clock asked once at launch left the day page on
      // 'somewhere in today' for the whole two minutes, so the moment could
      // be reached only by a cold launch from the notification.
      final ping = pingOn(day(14));
      final beforehand = ping.at.subtract(const Duration(minutes: 3));
      final camera = FakeCamera(frames, takenAtUtc: ping.at);
      await launch(tester, today: day(14), now: beforehand, camera: camera);
      await accept(tester, tripPaste);

      expect(
        textOf(const Key('capture-call')),
        'Your minute is somewhere in today.',
      );
      expect(find.byKey(const Key('capture-call-action')), findsNothing);

      // Four minutes of sitting on the trip. No relaunch, no resume, and
      // nothing tapped — only the root's own asking.
      await tester.pump(const Duration(minutes: 4));

      expect(
        textOf(const Key('capture-call')),
        'Your minute. Look up.',
        reason: 'the minute arrived and the day page never heard about it',
      );
      expect(find.byKey(const Key('capture-call-action')), findsOneWidget);

      // And it is a door rather than a changed sentence: what it opens on is
      // the window as it really stands, a minute of it already spent.
      await openTheCamera(tester);
      expect(countdown(), '1:00 left');
      expect(textOf(const Key('capture-window')), 'a while yet');
    });

    testWidgets('a window that ran down in somebody else\'s app is run down '
        'when the phone comes back', (tester) async {
      // The countdown measures elapsed time; it does not count its own ticks.
      // iOS suspends a backgrounded app's timers wholesale and
      // `Timer.periodic` fires no catch-up ticks for the interval it slept
      // through, so a clock that added a second per tick came back from
      // ninety seconds in a pocket still reading `2:00 left / a while yet` —
      // half a minute after the window had shut. On a two-minute window the
      // one screen that exists to say whether you are late must never say
      // punctual when you are not.
      final ping = pingOn(day(14));
      final camera = FakeCamera(frames, takenAtUtc: ping.at);
      await launch(tester, today: day(14), now: ping.at, camera: camera);
      await accept(tester, tripPaste);

      await openTheCamera(tester);
      expect(countdown(), '2:00 left');
      expect(textOf(const Key('capture-window')), 'a while yet');

      // Ninety seconds of the window spent somewhere else. Deliberately not
      // `pump(90s)`: that fires all ninety of the ticks the real suspension
      // eats, and a tick-counting countdown would pass it.
      suspended = const Duration(seconds: 90);
      await awayAndBack(tester);

      expect(
        countdown(),
        '0:30 left',
        reason: 'the countdown counted its ticks instead of the clock',
      );
      expect(textOf(const Key('capture-window')), 'last stretch');

      // And the resume is only a prompt to look again, never the source of
      // the answer: thirty-five more seconds pass with no lifecycle event at
      // all, and the first ordinary rebuild — the shutter — finds the window
      // shut rather than finding where the ticks left off.
      suspended = const Duration(seconds: 125);
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('capture-hour')), findsOneWidget);
      expect(countdown(), isNull, reason: 'a shut window still had a thread');

      // Late is late however it was arrived at, and the frame still lands at
      // the hour it was really taken.
      await tester.tap(find.byKey(const Key('capture-once-more')));
      await tester.pumpAndSettle();
      expect(
        textOf(const Key('capture-window')),
        "Your slot was teatime. It's fine — whatever you take now lands at "
        "the hour it's taken.",
      );
    });

    testWidgets('a retake after the window shut is still late, and stays '
        'marked late', (tester) async {
      // The bug this replaces: `onceMore` used to hand back a fresh
      // `isLate: false`, so a late capture came back from a retake looking
      // punctual — the mark the whole late path exists to carry, wiped by the
      // one control that is always on screen.
      const lateSentence =
          "Your slot was teatime. It's fine — whatever you take now lands at "
          "the hour it's taken.";
      final ping = pingOn(day(14));
      final late = ping.at.add(const Duration(hours: 6));
      final camera = FakeCamera(frames, takenAtUtc: late);
      await launch(tester, today: day(14), now: late, camera: camera);
      await accept(tester, tripPaste);

      await openTheCamera(tester);
      expect(textOf(const Key('capture-window')), lateSentence);
      expect(countdown(), isNull);

      for (var attempt = 1; attempt <= 3; attempt++) {
        await tester.tap(find.byKey(const Key('capture-shutter')));
        await tester.pumpAndSettle();
        // No timer on the breath either: a late capture is not handed one to
        // hide, it is handed nothing to show.
        expect(countdown(), isNull, reason: 'a countdown on retake $attempt');
        await tester.tap(find.byKey(const Key('capture-once-more')));
        await tester.pumpAndSettle();
        expect(
          textOf(const Key('capture-window')),
          lateSentence,
          reason: 'retake $attempt came back punctual',
        );
        expect(
          countdown(),
          isNull,
          reason:
              'retake $attempt re-opened the '
              'window',
        );
      }

      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      // And it lands at the hour it was really taken, which is the only
      // pressure the system applies.
      expect(
        (await db.readPhotos()).single.takenAtUtcIso,
        late.toIso8601String(),
      );
    });

    testWidgets('a window that shuts during the breath is honestly late', (
      tester,
    ) async {
      // The other direction of the same rule. The deadline is frozen and time
      // is not, so lateness is derived rather than latched: a moment answered
      // punctually but dithered over past the deadline goes late, and the
      // retake that follows finds it late rather than finding the window it
      // opened with.
      final ping = pingOn(day(14));
      await launch(tester, today: day(14), now: ping.at);
      await accept(tester, tripPaste);

      await openTheCamera(tester);
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      expect(countdown(), isNotNull, reason: 'the breath opened in time');

      await tester.pump(const Duration(minutes: 3));
      expect(countdown(), isNull);

      await tester.tap(find.byKey(const Key('capture-once-more')));
      await tester.pumpAndSettle();
      expect(
        textOf(const Key('capture-window')),
        "Your slot was teatime. It's fine — whatever you take now lands at "
        "the hour it's taken.",
      );
    });

    testWidgets('leaving without keeping throws the frame away', (
      tester,
    ) async {
      final ping = pingOn(day(14));
      final camera = FakeCamera(frames, takenAtUtc: ping.at);
      await launch(tester, today: day(14), now: ping.at, camera: camera);
      await accept(tester, tripPaste);

      await openTheCamera(tester);
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
      await openTheCamera(tester);

      // Surface 10c: no thread at all, so there is nothing to have failed.
      expect(
        textOf(const Key('capture-window')),
        "Your slot was teatime. It's fine — whatever you take now lands at "
        "the hour it's taken.",
      );
      expect(countdown(), isNull);

      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      final kept = await db.readPhotos();
      // The late photo carries its real hour, and is visibly late.
      expect(kept.single.takenAtUtcIso, late.toIso8601String());
    });

    testWidgets('the last minute before midnight is still yours', (
      tester,
    ) async {
      // The window narrowed to two minutes and the late path did not move an
      // inch: it runs to midnight, and the minute before midnight is inside
      // it.
      final ping = pingOn(day(14));
      await launch(
        tester,
        today: day(14),
        now: day(14).add(const Duration(hours: 23, minutes: 59)),
        camera: FakeCamera(frames, takenAtUtc: ping.at),
      );
      await accept(tester, tripPaste);

      expect(
        textOf(const Key('capture-call')),
        "Your minute came and went. The door's open till midnight.",
      );
      await openTheCamera(tester);
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      expect(await db.readPhotos(), hasLength(1));
    });

    testWidgets('midnight is where the late path stops, and the day belongs '
        'to the party after it', (tester) async {
      // A minute later and yesterday asks nothing of anybody. This is the
      // cutoff itself: the moment is a fact about *today*, and adding to a
      // day that is over is the import sweep's job, not this flow's.
      await launch(
        tester,
        today: day(15),
        now: day(15).add(const Duration(minutes: 1)),
      );
      await accept(tester, tripPaste);

      // Today is day two, and its own minute is still somewhere ahead — the
      // waking day starts at 08:00.
      expect(
        textOf(const Key('capture-call')),
        'Your minute is somewhere in today.',
      );

      await tester.tap(find.byKey(const Key('tab-trail')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('trail-node-1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('capture-call')),
        findsNothing,
        reason: 'yesterday was still offering a moment after midnight',
      );
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

      await openTheCamera(tester);
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
