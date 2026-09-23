// The trip's own surface, its three words, and the party the pings are dealt
// across — tested through the real stack: a plan pasted and accepted into
// Drift, which is what starts a trip, and everything read back off the
// Trail's title.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is in
// paste_confirm_flow_test.dart; read that file's header before writing any
// test that pumps the app.
//
// Two things shape these tests, as they shape pool_test.dart. Every tab stays
// alive in the tree but the ones you are not looking at are *offstage*, and
// finders skip offstage widgets — so every test walks in through the tab bar.
// And a phone can only ever write one member row into its own roster, so the
// party of eight the product is actually for is seeded at the read seam
// (`bootstrapApp(membership:)`), exactly as the Pool seeds a pool.
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn_model/cairn_model.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import 'package:cairn/app_state/ping_schedule.dart';
import 'package:cairn/app_state/trip_providers.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/itinerary_sync.dart'
    show unnamedTripPlaceholder;
import 'package:cairn/repositories/membership_repository.dart';
import 'package:cairn/repositories/photo_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn/storage/remote/shared_facts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Three dated days: 14, 15 and 17 June 2027.
const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Thu 17 June 2027 - Osaka
- Dotonbori
''';

/// Two dated days and a third left open — a plan that has dates and still
/// has no ending, since a trip ends at the end of its *last* day.
const openTailPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Day 3 - Osaka
- Dotonbori
''';

/// A plan accepted with every date still open.
const dateOpenPaste = '''
Day 1 - Tokyo
- Senso-ji

Day 2 - Kyoto
- Fushimi Inari
''';

DateTime day(int dayOfJune) => DateTime.utc(2027, 6, dayOfJune);

/// A trip id of the shape the phone actually mints
/// (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md), stood up here by
/// hand because these tests seed the read side of the seam and never start a
/// trip through the store. The bytes are arbitrary; that it is a real uuid is
/// not — an id that would not survive a round trip through `trips.id` is not
/// the thing these tests are standing in for.
final aTrip = TripId.mint(List.filled(16, 0xa7));

/// One photo of [by]'s, on day 1.
PooledPhoto photoBy(String by) => PooledPhoto(
  ref: PhotoRef(
    id: PhotoId('p-$by'),
    dayNumber: 1,
    contributor: MemberId(by),
    takenAt: DateTime.utc(2027, 6, 14, 10),
    origin: PhotoOrigin.pinged,
  ),
  localPath: null,
);

/// A stand-in server for [MembershipStore.adoptTrip]: it answers exactly
/// what a test sets and hands back whatever was pushed to [syncItinerary]
/// (the same "echo the push" baseline [FakeServer] in
/// shared_facts_sync_test.dart uses), since the merge itself is not this
/// store's business to reimplement.
///
/// Every method [adoptTrip] never calls throws, so a test that reaches one
/// by accident fails loudly rather than reading a plausible stub answer.
class FakeAdoptFacts implements SharedFacts {
  FakeAdoptFacts({this.trip});

  /// The shared `trips` row, or null while this server has never heard of
  /// the trip.
  RemoteTrip? trip;

  /// What the next [syncItinerary] hands back instead of echoing the push.
  RemoteItinerary? holds;

  /// Set to make the next [syncItinerary] fail the way a mid-flight drop
  /// does, for the "no half-adopted trip" test.
  Object? failSyncItinerary;

  /// Runs while [readTrip] is in flight — the window in which something
  /// else on this phone can start a trip of its own.
  Future<void> Function()? duringReadTrip;

  var readTrips = 0;
  var syncs = 0;

  @override
  Future<SharedFactsSession?> session() async => null;

  @override
  Future<RemoteTrip?> readTrip(TripId tripId) async {
    readTrips++;
    await duringReadTrip?.call();
    return trip;
  }

  @override
  Future<RemoteItinerary> syncItinerary({
    required TripId tripId,
    required DateTime planRevisedAt,
    required List<RemoteDay> days,
    required DateTime pocketRevisedAt,
    required List<RemoteSetAside> setAside,
  }) async {
    syncs++;
    if (failSyncItinerary case final error?) throw error;
    return holds ??
        RemoteItinerary(
          planRevisedAt: planRevisedAt,
          pocketRevisedAt: pocketRevisedAt,
          days: days,
          setAside: setAside,
        );
  }

  @override
  Future<void> createTrip(RemoteTripDraft draft) =>
      throw UnimplementedError('adoptTrip never creates a shared trip');

  @override
  Future<RemoteTripName> syncTripName({
    required TripId tripId,
    required String name,
    required DateTime revisedAt,
  }) => throw UnimplementedError('adoptTrip never renames a trip');

  @override
  Future<RemoteUploadTicket> photoUploadTicket({
    required TripId tripId,
    required String photoId,
    required String contentType,
    required int byteSize,
  }) => throw UnimplementedError('adoptTrip never mints an upload ticket');

  @override
  Future<void> putPhotoBytes(RemoteUploadTicket ticket, Uint8List bytes) =>
      throw UnimplementedError('adoptTrip never uploads bytes');

  @override
  Future<void> recordPhoto(RemotePhoto photo) =>
      throw UnimplementedError('adoptTrip never records a photo');

  @override
  Future<void> writePhotoCaption({
    required TripId tripId,
    required String photoId,
    required String? caption,
  }) => throw UnimplementedError('adoptTrip never writes a caption');
}

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

  Future<void> launch(
    WidgetTester tester, {
    required DateTime today,
    List<PooledPhoto> pool = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: today,
        now: today,
        utcOffset: Duration.zero,
        tripTimeZone: 'Etc/UTC',
        photos: InMemoryPhotoPool(pool),
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

  /// Paste, accept, and open the trip's sheet off the Trail's title.
  Future<void> openSheet(
    WidgetTester tester, {
    required DateTime today,
    String paste = tripPaste,
    List<PooledPhoto> pool = const [],
  }) async {
    await launch(tester, today: today, pool: pool);
    await accept(tester, paste);
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

  /// The three words as they are said, off the sheet's stacked card.
  String spokenCode() => textOf(const Key('trip-code')).replaceAll('\n', ' ');

  // ------------------------------------------------------------- the roster

  testWidgets('accepting a plan starts the trip, with you on it and words to '
      'say', (tester) async {
    await openSheet(tester, today: day(15));

    // One person, and the app says who they are rather than inventing a name.
    expect(textOf(const Key('trip-person-0-name')), 'You');
    // A fact beside a name, never a rank — there is no other role anywhere.
    expect(textOf(const Key('trip-person-0-note')), 'started it');
    expect(find.byKey(const Key('trip-person-1')), findsNothing);

    // The honest state of a roster on a phone that cannot be told about
    // anybody else: written, not an empty list and not a spinner.
    expect(
      textOf(const Key('trip-alone')),
      'Just you so far. Nobody else\'s phone can reach this trip yet.',
    );

    // The code exists from the moment the trip does — a code you have to
    // summon first is no use while somebody is holding your phone.
    expect(InviteCode.tryParse(spokenCode()), isNotNull);
  });

  testWidgets('the trip is unnamed until somebody names it', (tester) async {
    await openSheet(tester, today: day(15));

    // Nothing guesses a name out of the plan.
    expect(textOf(const Key('trip-name')), 'This trip');

    await tester.tap(find.byKey(const Key('trip-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('trip-name-input')),
      'Japan, June',
    );
    await tester.tap(find.byKey(const Key('trip-name-save')));
    await tester.pumpAndSettle();

    expect(textOf(const Key('trip-name')), 'Japan, June');

    // And the Trail grows the eyebrow the design draws above its headline,
    // now that there is a trip name to put there.
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(textOf(const Key('trail-trip-name')), 'JAPAN, JUNE');
  });

  testWidgets('the span is the plan\'s own, not a guess', (tester) async {
    await openSheet(tester, today: day(15));
    expect(textOf(const Key('trip-span')), '14–17 June · 3 days');
  });

  // --------------------------------------------------------------- the code

  testWidgets('the code dies with the trip, grace and all', (tester) async {
    await openSheet(tester, today: day(15));

    // 17 June is the last day; it seals at midnight, and the seventy-two
    // hour grace runs from there (cairn_model's tripClosesAt). So the code
    // works through the 20th and is dead when the 21st begins.
    expect(
      textOf(const Key('trip-code-expiry')),
      'Dies with the trip, after the end of 20 June.',
    );
  });

  testWidgets('a plan with no dates cannot say when its code dies, and does '
      'not pretend to', (tester) async {
    await openSheet(tester, today: day(15), paste: dateOpenPaste);

    expect(
      textOf(const Key('trip-code-expiry')),
      'Dies when the trip closes. This plan has no dates yet.',
    );
  });

  testWidgets('nor can a plan whose last day alone is open, and it says which '
      'of the two it is', (tester) async {
    // Days 1 and 2 are dated, day 3 is not. A trip ends at the end of its
    // last day, so this one has no known ending -- but the span above this
    // line is showing 14-15 June, so "no dates yet" would be a plain
    // contradiction of what is on the same sheet.
    await openSheet(tester, today: day(15), paste: openTailPaste);

    expect(textOf(const Key('trip-span')), '14–15 June · 3 days');
    expect(
      textOf(const Key('trip-code-expiry')),
      'Dies when the trip closes. This plan\'s last day has no date yet.',
    );
  });

  testWidgets('what the words can and cannot do is written on the sheet', (
    tester,
  ) async {
    await openSheet(tester, today: day(15));

    // The Phase 2 gap, stated plainly rather than implied by a button that
    // quietly does nothing.
    expect(
      textOf(const Key('trip-code-note')),
      'Say it out loud — that is the whole trick. Cairn cannot carry anyone '
      'here from their phone yet, so for now the words are the invitation '
      'and nothing arrives.',
    );
  });

  testWidgets('new words keep the old ones when the guard is cancelled', (
    tester,
  ) async {
    await openSheet(tester, today: day(15));
    final first = spokenCode();

    await tester.tap(find.byKey(const Key('trip-code-new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('trip-code-new-ask')), findsOneWidget);
    await tester.tap(find.byKey(const Key('trip-code-new-keep')));
    await tester.pumpAndSettle();

    expect(spokenCode(), first);
  });

  testWidgets('new words retire the old ones after the guard is confirmed', (
    tester,
  ) async {
    await openSheet(tester, today: day(15));
    final first = spokenCode();

    await tester.tap(find.byKey(const Key('trip-code-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-code-new-confirm')));
    await tester.pumpAndSettle();

    final second = spokenCode();
    expect(second, isNot(first));
    expect(InviteCode.tryParse(second), isNotNull);
  });

  // ------------------------------------------------------------- deleting it

  testWidgets('a trip holding only your own photos is yours to delete', (
    tester,
  ) async {
    await openSheet(tester, today: day(15), pool: [photoBy(localMemberId)]);

    expect(
      textOf(const Key('trip-delete-line')),
      'Takes the plan and every photo row with it. It cannot be undone.',
    );

    await tester.tap(find.byKey(const Key('trip-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-delete-confirm')));
    await tester.pumpAndSettle();

    // The trip is gone, so the app is back where a phone with no trip starts.
    expect(find.byKey(const Key('paste-input')), findsOneWidget);
  });

  testWidgets('once it holds somebody else\'s photos nobody can delete it', (
    tester,
  ) async {
    await openSheet(tester, today: day(15), pool: [photoBy('jonas')]);

    // Refused in writing, and the control is absent rather than greyed out.
    expect(
      textOf(const Key('trip-delete-line')),
      'It holds somebody else\'s photos now, so nobody can — whoever started '
      'it included.',
    );
    expect(find.byKey(const Key('trip-delete')), findsNothing);
  });

  // ------------------------------------------------- the party, and the deal

  group('the party the day is dealt across', () {
    /// Eight people, which is the size the product is for.
    List<Member> eight() => [
      for (final (i, name) in [
        'You',
        'Jonas',
        'Tomas',
        'Ava',
        'Mira',
        'Sam',
        'Ines',
        'Bo',
      ].indexed)
        Member(
          id: MemberId(i == 0 ? localMemberId : name.toLowerCase()),
          displayName: name,
          joinedOnDay: 1,
        ),
    ];

    ProviderContainer containerWith(TripMembership? trip) {
      final container = ProviderContainer(
        overrides: [
          membershipRepositoryProvider.overrideWithValue(
            InMemoryMembership(trip),
          ),
          savedItineraryProvider.overrideWith(
            (ref) => Stream.value(
              TripPlan(
                days: [
                  for (final n in [1, 2, 3])
                    PlanDay(number: n, date: day(13 + n), stops: const []),
                ],
              ),
            ),
          ),
          tripUtcOffsetProvider.overrideWithValue(Duration.zero),
          tripTimeZoneProvider.overrideWithValue('Etc/UTC'),
          nowProvider.overrideWithValue(pinnedClock(from: day(14))),
        ],
      );
      addTearDown(container.dispose);
      // Riverpod disposes a provider nobody is listening to, and a stream
      // provider disposed while still loading never completes its future.
      // The app always has a widget listening; a container test has to say
      // so itself.
      container.listen(tripMembershipProvider, (_, _) {});
      container.listen(savedItineraryProvider, (_, _) {});
      return container;
    }

    test('the roster is the party, and eight people get eight different '
        'minutes', () async {
      final container = containerWith(
        TripMembership(
          tripId: aTrip,
          startedBy: MemberId(localMemberId),
          members: eight(),
        ),
      );
      await container.read(tripMembershipProvider.future);
      await container.read(savedItineraryProvider.future);

      final party = container.read(tripPartyProvider);
      expect(party, isNotNull);
      expect(party!.memberIds, hasLength(8));

      // The whole promise of the offline deal: every phone derives the same
      // assignment for everyone, so no two people are called at once. It is
      // only worth asserting against a real party, which is why the roster
      // had to become real before this test could exist.
      for (final date in [day(14), day(15), day(16)]) {
        final minutes = <DateTime>{};
        for (final member in eight()) {
          final pings = pingsForPlan(
            plan: container.read(savedItineraryProvider).value,
            party: party,
            utcOffset: Duration.zero,
            memberId: member.id.value,
            tripId: aTrip,
          );
          for (final ping in pings) {
            if (ping.at.difference(date).inDays.abs() <= 1 &&
                ping.at.day == date.day) {
              minutes.add(ping.at);
            }
          }
        }
        expect(
          minutes,
          hasLength(8),
          reason: 'eight slots on ${date.day} June',
        );
      }
    });

    test('no trip is no party, and no party is no pings', () async {
      final container = containerWith(null);
      await container.read(tripMembershipProvider.future);
      await container.read(savedItineraryProvider.future);

      // Not a party of one standing in: an app with no trip has no pings,
      // and scheduling for an invented member would call a person who is
      // not there.
      expect(container.read(tripPartyProvider), isNull);
      expect(container.read(pingScheduleProvider), isEmpty);
    });

    test('a party of one is still a party', () async {
      final container = containerWith(
        TripMembership(
          tripId: aTrip,
          startedBy: MemberId(localMemberId),
          members: [
            Member(
              id: MemberId(localMemberId),
              displayName: 'You',
              joinedOnDay: 1,
            ),
          ],
        ),
      );
      await container.read(tripMembershipProvider.future);
      await container.read(savedItineraryProvider.future);

      expect(container.read(tripPartyProvider), isA<tm.Party>());
      expect(container.read(pingScheduleProvider), hasLength(3));
    });
  });

  // ------------------------------------------------------- adopting a trip

  group('adopting a trip', () {
    final jonas = MemberId('jonas');
    final ada = MemberId('ada');

    RemoteTrip aSharedTrip() => RemoteTrip(
      id: aTrip,
      name: 'Japan, June',
      nameRevisedAt: DateTime.utc(2027, 5, 1),
      startedBy: jonas,
      timeZone: 'Asia/Tokyo',
      members: [
        RemoteMember(
          id: jonas,
          displayName: 'Jonas',
          joinedAt: DateTime.utc(2027, 5, 1),
        ),
        RemoteMember(
          id: ada,
          displayName: 'Ada',
          joinedAt: DateTime.utc(2027, 6, 1),
        ),
      ],
    );

    RemoteItinerary aSharedPlan() => RemoteItinerary(
      planRevisedAt: DateTime.utc(2027, 6, 1),
      pocketRevisedAt: DateTime.utc(2027, 6, 1),
      days: [
        RemoteDay(
          number: 1,
          dateIso: '2027-06-14',
          place: 'Tokyo',
          revisedAt: DateTime.utc(2027, 6, 1),
          stops: const [RemoteStop(position: 0, text: 'Senso-ji')],
        ),
        RemoteDay(
          number: 2,
          dateIso: '2027-06-15',
          place: 'Kyoto',
          revisedAt: DateTime.utc(2027, 6, 1),
          stops: const [RemoteStop(position: 0, text: 'Fushimi Inari')],
        ),
      ],
    );

    test('adopts cleanly: facts, roster and plan all land locally', () async {
      final facts = FakeAdoptFacts(trip: aSharedTrip())..holds = aSharedPlan();
      final store = MembershipStore(db, facts: facts);

      await store.adoptTrip(aTrip);

      final trip = await db.readTripFacts();
      expect(trip, isNotNull);
      expect(trip!.tripId, aTrip.value);
      expect(trip.name, 'Japan, June');
      expect(
        trip.nameRevisedAtUtcIso,
        DateTime.utc(2027, 5, 1).toIso8601String(),
      );
      expect(trip.timeZone, 'Asia/Tokyo');
      expect(trip.startedByMemberId, jonas.value);

      final members = await db.readTripMembers();
      expect(members.map((m) => m.id), containsAll([jonas.value, ada.value]));

      final days = await db.readItineraryDays();
      expect(days, hasLength(2));
      expect(days.first.place, 'Tokyo');

      final stops = await db.readItineraryStops();
      expect(stops, hasLength(2));
      expect(stops.first.stopText, 'Senso-ji');
      expect(stops.first.kind, isNotNull);
    });

    test('each member joins on the day the plan says, not day 1', () async {
      final trip = aSharedTrip();
      final late = RemoteTrip(
        id: trip.id,
        name: trip.name,
        nameRevisedAt: trip.nameRevisedAt,
        startedBy: trip.startedBy,
        timeZone: trip.timeZone,
        members: [
          trip.members.first,
          RemoteMember(
            id: ada,
            displayName: 'Ada',
            joinedAt: DateTime.utc(2027, 6, 15, 9),
          ),
        ],
      );
      final facts = FakeAdoptFacts(trip: late)..holds = aSharedPlan();
      final store = MembershipStore(db, facts: facts);

      await store.adoptTrip(aTrip);

      final byId = {for (final m in await db.readTripMembers()) m.id: m};
      expect(byId[jonas.value]!.joinedOnDay, 1);
      expect(byId[ada.value]!.joinedOnDay, 2);
    });

    test('the wire placeholder is not adopted as a name', () async {
      final trip = aSharedTrip();
      final unnamed = RemoteTrip(
        id: trip.id,
        name: unnamedTripPlaceholder,
        nameRevisedAt: DateTime.utc(1970),
        startedBy: trip.startedBy,
        timeZone: trip.timeZone,
        members: trip.members,
      );
      final facts = FakeAdoptFacts(trip: unnamed)..holds = aSharedPlan();
      final store = MembershipStore(db, facts: facts);

      await store.adoptTrip(aTrip);

      expect((await db.readTripFacts())!.name, isNull);
    });

    test('adopting the trip this phone already holds is a no-op', () async {
      final facts = FakeAdoptFacts(trip: aSharedTrip())..holds = aSharedPlan();
      final store = MembershipStore(db, facts: facts);
      await store.adoptTrip(aTrip);
      expect(facts.readTrips, 1);
      expect(facts.syncs, 1);

      // Asking again for the very same trip must not re-deal anything: no
      // second read, no second pull.
      await store.adoptTrip(aTrip);
      expect(facts.readTrips, 1);
      expect(facts.syncs, 1);
    });

    test('refuses a different trip while one is already held', () async {
      final facts = FakeAdoptFacts(trip: aSharedTrip())..holds = aSharedPlan();
      final store = MembershipStore(db, facts: facts);
      await store.adoptTrip(aTrip);

      final anotherTrip = TripId.mint(List.filled(16, 0x5c));
      await expectLater(
        () => store.adoptTrip(anotherTrip),
        throwsA(isA<DifferentTripHeldException>()),
      );
      // The refusal is decided before any network call, since a trip is
      // already known to be held.
      expect(facts.readTrips, 1);

      // And the held trip is untouched.
      final trip = await db.readTripFacts();
      expect(trip!.tripId, aTrip.value);
    });

    test('refuses a trip the server has never heard of', () async {
      final facts = FakeAdoptFacts(trip: null);
      final store = MembershipStore(db, facts: facts);

      await expectLater(
        () => store.adoptTrip(aTrip),
        throwsA(isA<UnknownTripException>()),
      );
      expect(await db.readTripFacts(), isNull);
    });

    test(
      'a mid-way failure pulling the plan leaves no half-adopted trip',
      () async {
        await db.writePlanDraft('Day 1 - somewhere');
        final facts = FakeAdoptFacts(trip: aSharedTrip())
          ..failSyncItinerary = Exception('the train went into a tunnel');
        final store = MembershipStore(db, facts: facts);

        await expectLater(() => store.adoptTrip(aTrip), throwsException);

        // Nothing survives the failed adoption: no trip row, no roster —
        // a clean state the person can retry from, not a trip they cannot
        // read today on.
        expect(await db.readTripFacts(), isNull);
        expect(await db.readTripMembers(), isEmpty);
        // And nothing that was there before is gone: the import sitting in
        // the paste box is not the adoption's to discard.
        expect(await db.readPlanDraft(), 'Day 1 - somewhere');
      },
    );

    test('a failed local write rolls the whole adoption back', () async {
      final trip = aSharedTrip();
      final twice = RemoteTrip(
        id: trip.id,
        name: trip.name,
        nameRevisedAt: trip.nameRevisedAt,
        startedBy: trip.startedBy,
        timeZone: trip.timeZone,
        members: [trip.members.first, trip.members.first],
      );
      await db.writePlanDraft('Day 1 - somewhere');
      final facts = FakeAdoptFacts(trip: twice)..holds = aSharedPlan();
      final store = MembershipStore(db, facts: facts);

      // The roster is the last write and the duplicate row refuses it; the
      // trip row and the plan written before it must not outlive that.
      await expectLater(() => store.adoptTrip(aTrip), throwsA(anything));

      expect(await db.readTripFacts(), isNull);
      expect(await db.readTripMembers(), isEmpty);
      expect(await db.readItineraryDays(), isEmpty);
      expect(await db.readPlanDraft(), 'Day 1 - somewhere');
    });

    test('a trip started mid-call is the one that survives', () async {
      final facts = FakeAdoptFacts(trip: aSharedTrip())..holds = aSharedPlan();
      final store = MembershipStore(db, facts: facts);
      late final TripId started;
      facts.duringReadTrip = () async {
        started = await db.startTripIfAbsent(
          starterId: 'me',
          starterDisplayName: 'Me',
        );
        await db.replaceItinerary(
          days: const [(number: 1, dateIso: '2027-07-01', place: 'Lisbon')],
          stops: const [],
          setAsides: const [],
          nowUtcIso: '2027-06-01T00:00:00.000Z',
        );
      };

      await expectLater(() => store.adoptTrip(aTrip), throwsA(anything));

      final trip = await db.readTripFacts();
      expect(trip!.tripId, started.value);
      expect(trip.tripId, isNot(aTrip.value));
      final days = await db.readItineraryDays();
      expect(days.single.place, 'Lisbon');
      expect((await db.readTripMembers()).map((m) => m.id), ['me']);
    });

    test(
      'calling adoptTrip with no backend configured refuses loudly',
      () async {
        final store = MembershipStore(db);
        await expectLater(
          () => store.adoptTrip(aTrip),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}
