// The end of a trip: the last day seals, seventy-two hours of grace, then the
// archive.
//
// The shape is `docs/decisions/2026-08-26-the-ending.md`, and the rule itself
// is `cairn_model`'s `tripStandingAt` — one function, asked by every surface
// and every write path. So this file tests three different things and is
// careful about which is which:
//
//  1. **Where a trip stands**, as arithmetic over a saved plan
//     (`trip_lifecycle.dart`). This is the half that knows about dates, and
//     the half a timezone can move.
//  2. **What each standing permits**, at the write paths that must obey it —
//     the pool's, the plan's and the trip's own. Driven through the real
//     notifiers and the real store rather than asserted about a boolean,
//     because the claim is that the *write* does not happen.
//  3. **What the screens say**, once through the whole stack per standing.
//
// The clock a widget test reads is pinned twice on purpose: `today` is the
// date the day page is standing on and `now` is the instant everything else
// reads, and the interesting cases here are precisely the ones where the
// second has run past the first.
//
// closeStreamsSynchronously is load-bearing in every test that pumps the app;
// read `paste_confirm_flow_test.dart`'s header before writing another.
import 'dart:io';

import 'package:cairn_model/cairn_model.dart' as model;
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import 'package:cairn/app_state/camera_source.dart';
import 'package:cairn/app_state/capture_flow.dart';
import 'package:cairn/app_state/day_view.dart';
import 'package:cairn/app_state/ping_schedule.dart';
import 'package:cairn/app_state/stand_in_frame.dart';
import 'package:cairn/app_state/trip_lifecycle.dart';
import 'package:cairn/app_state/trip_providers.dart';
import 'package:cairn/app_state/trip_settings.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/membership_repository.dart';
import 'package:cairn/repositories/photo_repository.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';

/// Three dated days: 14, 15 and 16 June 2027.
///
/// Read on a clock at UTC the trip ends at midnight ending the 16th — 17
/// June, 00:00Z — and closes seventy-two hours later, at 20 June, 00:00Z.
/// Every instant below is written against those two.
const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- 09:30 Skytree

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Wed 16 June 2027 - Osaka
- Dotonbori
''';

final theTripEnds = DateTime.utc(2027, 6, 17);
final theTripCloses = DateTime.utc(2027, 6, 20);

DateTime june(int day, [int hour = 0]) => DateTime.utc(2027, 6, day, hour);

/// The plan those three days become, as the app state band speaks it.
TripPlan datedPlan([List<int> days = const [14, 15, 16]]) => TripPlan(
  days: [
    for (final (i, d) in days.indexed)
      PlanDay(number: i + 1, date: june(d), stops: const []),
  ],
);

/// A ping at a fixed minute of the last day, for the window's own tests.
final aPing = tm.Ping(
  memberId: localMemberId,
  slotIndex: 0,
  at: june(16, 11),
  localTimeOfDay: const Duration(hours: 11),
);

/// A camera that hands back a real frame without a device.
class FakeCamera implements CameraSource {
  FakeCamera(this.directory, {required this.takenAtUtc});

  final Directory directory;
  final DateTime takenAtUtc;

  final List<String> taken = [];
  final List<String> discarded = [];

  @override
  Future<CapturedFrame> takeOne() async {
    final path = '${directory.path}/frame-${taken.length + 1}.png';
    File(path).writeAsBytesSync(standInFrameBytes(taken.length + 1));
    taken.add(path);
    return CapturedFrame(path: path, takenAtUtc: takenAtUtc);
  }

  @override
  Future<void> discard(String path) async => discarded.add(path);
}

void main() {
  // -------------------------------------------------------------------------
  group('where a trip stands', () {
    test('the trip ends at midnight ending its last dated day', () {
      expect(tripEndsAtFor(datedPlan(), Duration.zero), theTripEnds);
      expect(tripCloseFor(datedPlan(), Duration.zero), theTripCloses);
      expect(
        theTripCloses.difference(theTripEnds),
        model.graceAfterATrip,
        reason: 'seventy-two hours, and the domain owns the number',
      );
    });

    test('underway, then the grace, then the archive', () {
      model.TripStanding at(DateTime now) =>
          tripStandingFor(datedPlan(), Duration.zero, now);

      expect(at(june(15, 12)), model.TripStanding.underway);
      expect(at(june(18, 12)), model.TripStanding.grace);
      expect(at(june(21, 12)), model.TripStanding.archived);
    });

    test('both boundaries are exact, to the microsecond', () {
      model.TripStanding at(DateTime now) =>
          tripStandingFor(datedPlan(), Duration.zero, now);
      const aMoment = Duration(microseconds: 1);

      // The last day is still being lived right up to its own midnight.
      expect(at(theTripEnds.subtract(aMoment)), model.TripStanding.underway);
      expect(at(theTripEnds), model.TripStanding.grace);

      // And the seventy-second hour is inside the grace, not outside it.
      expect(at(theTripCloses.subtract(aMoment)), model.TripStanding.grace);
      expect(at(theTripCloses), model.TripStanding.archived);
    });

    test('the end is midnight on the trip\'s clock, not on UTC\'s', () {
      // The same three days, lived in Tokyo. The trip's last midnight comes
      // nine hours earlier in UTC, and so does everything downstream of it.
      const tokyo = Duration(hours: 9);
      expect(tripEndsAtFor(datedPlan(), tokyo), june(16, 15));
      expect(tripCloseFor(datedPlan(), tokyo), june(19, 15));

      // An instant inside the grace at UTC is already the archive in Tokyo:
      // the sixteen hours between two travellers' clocks are the whole of
      // this test.
      final instant = june(19, 20);
      expect(
        tripStandingFor(datedPlan(), Duration.zero, instant),
        model.TripStanding.grace,
      );
      expect(
        tripStandingFor(datedPlan(), tokyo, instant),
        model.TripStanding.archived,
      );
      expect(
        tripStandingFor(datedPlan(), const Duration(hours: -7), instant),
        model.TripStanding.grace,
        reason: 'and further west it is barely over at all',
      );
    });

    test('a plan with no dates has not ended, and never times out', () {
      final undated = TripPlan(
        days: [
          for (var n = 1; n <= 3; n++)
            PlanDay(number: n, date: null, stops: const []),
        ],
      );
      expect(tripEndsAtFor(undated, Duration.zero), isNull);
      expect(tripCloseFor(undated, Duration.zero), isNull);
      expect(
        tripStandingFor(undated, Duration.zero, DateTime.utc(2040)),
        model.TripStanding.underway,
        reason: 'nothing here guesses a date, so nothing here expires on one',
      );
      expect(
        tripStandingFor(null, Duration.zero, DateTime.utc(2040)),
        model.TripStanding.underway,
      );
    });

    test('an undated tail means the trip has not ended', () {
      // Day 3 was accepted with its date still open. A trip ends at the end
      // of its *last* day, so this trip's ending is not known yet -- reading
      // it as the last dated day would archive it while its travellers were
      // still on it, three days after day 2.
      final plan = TripPlan(
        days: [
          PlanDay(number: 1, date: june(14), stops: const []),
          PlanDay(number: 2, date: june(16), stops: const []),
          PlanDay(number: 3, date: null, stops: const []),
        ],
      );
      expect(tripEndsAtFor(plan, Duration.zero), isNull);
      expect(tripCloseFor(plan, Duration.zero), isNull);
      expect(
        tripStandingFor(plan, Duration.zero, DateTime.utc(2040)),
        model.TripStanding.underway,
        reason: 'however late it is asked',
      );
    });

    test('a gap in the middle of a dated plan still ends it', () {
      final plan = TripPlan(
        days: [
          PlanDay(number: 1, date: june(14), stops: const []),
          PlanDay(number: 2, date: null, stops: const []),
          PlanDay(number: 3, date: june(16), stops: const []),
        ],
      );
      expect(tripEndsAtFor(plan, Duration.zero), theTripEnds);
    });

    test('the plan is read in day order, not in the order it arrives', () {
      final plan = TripPlan(
        days: [
          PlanDay(number: 3, date: june(16), stops: const []),
          PlanDay(number: 1, date: june(14), stops: const []),
          PlanDay(number: 2, date: june(15), stops: const []),
        ],
      );
      expect(tripEndsAtFor(plan, Duration.zero), theTripEnds);
    });
  });

  // -------------------------------------------------------------------------
  group('the grace admits photographs and nothing else', () {
    test('the moment is still answerable once the trip is over', () {
      final ping = aPing;
      expect(
        captureCallFor(
          ping: ping,
          now: ping.at,
          answeredAt: null,
          utcOffset: Duration.zero,
          standing: model.TripStanding.grace,
        ),
        isA<MomentOpen>(),
      );
      expect(
        captureCallFor(
          ping: ping,
          now: ping.at.add(const Duration(hours: 2)),
          answeredAt: null,
          utcOffset: Duration.zero,
          standing: model.TripStanding.grace,
        ),
        isA<MomentLate>(),
      );
    });

    test('and nothing is asked of anybody once it has closed', () {
      final ping = aPing;
      expect(
        captureCallFor(
          ping: ping,
          now: ping.at,
          answeredAt: null,
          utcOffset: Duration.zero,
          standing: model.TripStanding.archived,
        ),
        isA<NoMomentHere>(),
        reason: 'no moment here — not a refusal drawn on the page',
      );
    });

    test('the code lives through the grace and dies at the close', () {
      final invite = model.TripInvite(
        code: model.InviteCode.draw(firstDraw: 1, secondDraw: 2, numberDraw: 3),
        mintedBy: model.MemberId('a0000000-0000-4000-8000-000000000001'),
        mintedAt: june(14),
      );
      model.InviteStanding at(DateTime now) =>
          invite.standingAt(now, tripClosesAt: theTripCloses);

      expect(at(june(18, 12)), model.InviteStanding.live);
      expect(
        at(theTripCloses.subtract(const Duration(microseconds: 1))),
        model.InviteStanding.live,
      );
      expect(at(theTripCloses), model.InviteStanding.expired);
    });
  });

  // -------------------------------------------------------------------------
  group('the trip\'s sheet, per standing', () {
    TripSettingsView sheetAt(model.TripStanding standing) {
      final you = model.MemberId('a0000000-0000-4000-8000-000000000001');
      return tripSettingsFor(
        trip: TripMembership(
          tripId: model.TripId.mint(List.filled(16, 0xa7)),
          startedBy: you,
          members: [model.Member(id: you, displayName: 'You', joinedOnDay: 1)],
          invites: [
            model.TripInvite(
              code: model.InviteCode.draw(
                firstDraw: 1,
                secondDraw: 2,
                numberDraw: 3,
              ),
              mintedBy: you,
              mintedAt: june(14),
            ),
          ],
        ),
        plan: datedPlan(),
        photos: const [],
        you: you,
        now: switch (standing) {
          model.TripStanding.underway => june(15, 12),
          model.TripStanding.grace => june(18, 12),
          model.TripStanding.archived => june(21, 12),
        },
        utcOffset: Duration.zero,
        standing: standing,
      )!;
    }

    test('the grace still names the trip and still makes words', () {
      final sheet = sheetAt(model.TripStanding.grace);
      expect(sheet.canRename, isTrue);
      expect(sheet.canMintCode, isTrue);
      expect(sheet.code, isNotNull, reason: 'the words still open the trip');
      expect(
        sheet.ending,
        'Still open for anything you are holding, until the end of 19 June.',
      );
    });

    test('the archive does neither, and says why', () {
      final sheet = sheetAt(model.TripStanding.archived);
      expect(sheet.canRename, isFalse);
      expect(sheet.canMintCode, isFalse);
      expect(sheet.code, isNull, reason: 'every code of a closed trip is dead');
      expect(sheet.codeNote, startsWith('The words are done.'));
      expect(sheet.ending, 'Closed. What is in it is what it is.');
    });

    test('a trip still underway has no ending to report', () {
      expect(sheetAt(model.TripStanding.underway).ending, isNull);
    });

    test('deleting is the one thing an archive still allows', () {
      // Not an oversight: deleting is discarding the record rather than
      // editing it, and the guard that matters — somebody else's photographs
      // — is the one already on it. See `canDeleteTrip`.
      expect(sheetAt(model.TripStanding.archived).deletion.allowed, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // The write path, driven through the real notifier and the real store. The
  // claim is not that a boolean is false; it is that no row is written.
  group('what may be kept, once the day is over', () {
    late AppDatabase db;
    late Directory frames;

    setUp(() {
      db = AppDatabase(
        DatabaseConnection(
          NativeDatabase.memory(),
          closeStreamsSynchronously: true,
        ),
      );
      frames = Directory.systemTemp.createTempSync('cairn-ending');
    });
    tearDown(() async {
      await db.close();
      if (frames.existsSync()) frames.deleteSync(recursive: true);
    });

    /// A container standing on the trip's last day, whose `now` can be moved
    /// afterwards — which is the whole point: a frame taken while the trip
    /// was open, kept after it closed.
    Future<
      ({
        ProviderContainer container,
        FakeCamera camera,
        void Function(DateTime) travelTo,
      })
    >
    lastDayOfTheTrip() async {
      var clock = june(16, 9);
      final camera = FakeCamera(frames, takenAtUtc: june(16, 9));
      final store = PhotoStore(db);
      final container = ProviderContainer(
        overrides: [
          tripRepositoryProvider.overrideWithValue(TripRepository(db)),
          photoRepositoryProvider.overrideWithValue(store),
          photoStoreProvider.overrideWithValue(store),
          membershipRepositoryProvider.overrideWithValue(MembershipStore(db)),
          membershipStoreProvider.overrideWithValue(MembershipStore(db)),
          todayProvider.overrideWithValue(june(16)),
          nowProvider.overrideWith((ref) => clock),
          tripUtcOffsetProvider.overrideWithValue(Duration.zero),
          cameraSourceProvider.overrideWithValue(camera),
        ],
      );
      addTearDown(container.dispose);

      await db.startTripIfAbsent(
        starterId: localMemberId,
        starterDisplayName: 'You',
      );
      await TripRepository(db).saveItinerary(
        ConfirmedItinerary(
          days: [
            for (final d in [14, 15, 16])
              ConfirmedDay(
                number: d - 13,
                date: model.CalendarDate(2027, 6, d),
                place: 'Somewhere',
                stops: const [],
              ),
          ],
        ),
        at: june(1),
      );
      // **Every provider is auto-dispose under Riverpod 3**, so a container
      // test has to hold what it reads: an unlistened `StreamProvider` is
      // disposed the instant `read` returns and its future never completes,
      // and an unlistened notifier loses the frame it is holding between two
      // awaits. Listening is what a widget does for free.
      container.listen(savedItineraryProvider, (_, _) {});
      container.listen(tripMembershipProvider, (_, _) {});
      container.listen(tripPhotosProvider, (_, _) {});
      container.listen(captureFlowProvider, (_, _) {});

      await container.read(savedItineraryProvider.future);
      await container.read(tripMembershipProvider.future);
      await container.read(tripPhotosProvider.future);

      return (
        container: container,
        camera: camera,
        travelTo: (DateTime to) {
          clock = to;
          container.invalidate(nowProvider);
        },
      );
    }

    /// Answers the day's moment, and hands back the flow mid-breath — the
    /// frame taken, the word written, nothing kept yet.
    Future<CaptureFlow> upToTheBreath(
      ProviderContainer container,
      void Function(DateTime) travelTo,
    ) async {
      final ping = container.read(todaysPingProvider);
      expect(ping, isNotNull, reason: 'the last day is dated, so it is dealt');
      travelTo(ping!.at);

      final flow = container.read(captureFlowProvider.notifier);
      flow.open();
      expect(container.read(captureFlowProvider), isA<Framing>());
      await flow.shoot();
      expect(container.read(captureFlowProvider), isA<TheBreath>());
      flow.write('the last evening');
      return flow;
    }

    test('a frame kept inside the grace lands in the pool', () async {
      final (:container, :camera, :travelTo) = await lastDayOfTheTrip();
      final flow = await upToTheBreath(container, travelTo);

      // The trip ended while the word was being written. It is over, and it
      // is still taking photographs — that is what the grace is for.
      travelTo(june(18, 12));
      expect(container.read(tripStandingProvider), model.TripStanding.grace);
      await flow.turnTheDayOver();

      final kept = await db.readPhotos();
      expect(kept, hasLength(1));
      expect(kept.single.dayNumber, 3);
      expect(kept.single.word, 'the last evening');
      expect(camera.discarded, isEmpty);
    });

    test('a frame kept after the close lands nowhere at all', () async {
      final (:container, :camera, :travelTo) = await lastDayOfTheTrip();
      final flow = await upToTheBreath(container, travelTo);

      travelTo(june(21, 12));
      expect(container.read(tripStandingProvider), model.TripStanding.archived);
      await flow.turnTheDayOver();

      expect(
        await db.readPhotos(),
        isEmpty,
        reason:
            'the archive is fixed; a photograph landing in it afterwards '
            'would change the record the book was made from',
      );
      // And the frame is not left on disk pretending to be a photograph.
      expect(camera.discarded, camera.taken);
      expect(container.read(captureFlowProvider), isA<CaptureClosed>());
    });

    test('the camera will not open on a closed trip', () async {
      final (:container, camera: _, :travelTo) = await lastDayOfTheTrip();
      travelTo(june(21, 12));

      container.read(captureFlowProvider.notifier).open();
      expect(container.read(captureFlowProvider), isA<CaptureClosed>());
    });
  });

  // -------------------------------------------------------------------------
  // Once through the whole stack per standing.
  group('what the screens say', () {
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

    /// Launches, pastes the trip and accepts it, standing at [now].
    ///
    /// The accept itself is always allowed: at that instant no plan is saved,
    /// so the trip has no ending yet and the standing is `underway`. That is
    /// what makes it possible to stand a *closed* trip up at all on a phone
    /// that can only start one by pasting into it.
    Future<void> launchInto(WidgetTester tester, DateTime now) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        bootstrapApp(
          database: db,
          today: DateTime.utc(now.year, now.month, now.day),
          now: now,
          utcOffset: Duration.zero,
        ),
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

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('tab-trail')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('trip-sheet-open')));
      await tester.pumpAndSettle();
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

    testWidgets('in the grace, today says the trip is walked and still open', (
      tester,
    ) async {
      await launchInto(tester, june(18, 12));

      expect(find.byKey(const Key('post-trip')), findsOneWidget);
      expect(
        textOf(const Key('post-trip-closing')),
        'Still open for anything you are holding, until the end of 19 June.',
      );

      await openSheet(tester);
      expect(find.byKey(const Key('trip-rename')), findsOneWidget);
      expect(find.byKey(const Key('trip-code-new')), findsOneWidget);
      expect(find.byKey(const Key('trip-code')), findsOneWidget);
    });

    testWidgets('past the close, the sheet is a record and offers nothing', (
      tester,
    ) async {
      await launchInto(tester, june(21, 12));

      expect(
        textOf(const Key('post-trip-closing')),
        'Closed. What is in it is what it is.',
      );

      await openSheet(tester);
      expect(
        textOf(const Key('trip-ending')),
        'Closed. What is in it is what it is.',
      );
      // Absent, not disabled — this project's treatment for anything that
      // cannot fire.
      expect(find.byKey(const Key('trip-rename')), findsNothing);
      expect(find.byKey(const Key('trip-code-new')), findsNothing);
      expect(find.byKey(const Key('trip-code-none')), findsNothing);
      expect(find.byKey(const Key('trip-code')), findsNothing);
      expect(
        textOf(const Key('trip-code-note')),
        startsWith('The words are done.'),
      );
    });

    testWidgets('the plan of a closed trip cannot be replaced', (tester) async {
      await launchInto(tester, june(21, 12));
      await openSheet(tester);

      // The route to the plan is still there, and deliberately so: the paste
      // box behind it is also the door somebody joins another trip through.
      await tester.tap(find.byKey(const Key('trip-repaste')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('paste-input')),
        'Mon 5 July 2027 - Lisbon\n- Alfama\n',
      );
      await tester.tap(find.byKey(const Key('read-button')));
      await tester.pumpAndSettle();

      // The read is shown in full — there is nothing wrong with it — and
      // what is missing is the accept.
      expect(find.byKey(const Key('accept-button')), findsNothing);
      expect(
        textOf(const Key('accept-refused')),
        startsWith('This trip has closed, so its plan cannot be replaced'),
      );

      // And nothing was written: the archive still holds the trip it closed
      // with.
      final saved = await db.readItineraryDays();
      expect(saved.map((d) => d.place), ['Tokyo', 'Kyoto', 'Osaka']);
    });
  });
}
