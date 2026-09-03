// The launch that outlives its stand-in.
//
// A trip accepted before the phone's account has resolved is started under
// `localMemberId` — the literal string `me` — and that is correct for the
// launch that did it: the whole launch calls itself `me`, so the roster, the
// gate and the ping deal all agree. The defect this file pins is what used to
// happen on the *next* launch: the vault answers with the real account id,
// `localMemberIdProvider` becomes a uuid, and the roster still holds only
// `me` — so `pingsForPlan` deals the day to a party the launch is no longer
// in, and the trip never asks for a photograph again. Nothing reported it.
//
// The fix has two halves, tested here in the order they run:
//
//  - `bootstrap.dart` heals the roster on launch, one-shot and non-blocking
//    (`MembershipStore.adoptAccountIdentity`), so a trip already stranded
//    under the stand-in gets its pings back the next time the app opens; and
//  - the accept path adopts the account at the last moment it is still free
//    to (`lateAccountResolverProvider`), so a configured build whose sign-in
//    has answered by accept time never writes the `me` roster at all — while
//    a build with no backend, or one that is genuinely offline, still starts
//    the trip under the stand-in exactly as before.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is
// in paste_confirm_flow_test.dart; read that file's header before writing
// any test that pumps the app.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn_model/cairn_model.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import 'package:cairn/app_state/paste_flow.dart';
import 'package:cairn/app_state/ping_schedule.dart';
import 'package:cairn/app_state/trip_providers.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/membership_repository.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';

/// The account id the vault answers with on the launch after the sign-in
/// landed. A real uuid shape, because that is what GoTrue mints and what the
/// roster the server hands back names people by.
const account = '5f067177-2435-47aa-af00-72ad9ea22569';

DateTime day(int dayOfJune) => DateTime.utc(2027, 6, dayOfJune);

/// Three dated days: 14, 15 and 17 June 2027 — the same plan the membership
/// tests paste, seeded here straight through the repository because these
/// tests are about the launch *after* the one that accepted it.
ConfirmedItinerary threeDatedDays() => ConfirmedItinerary(
  days: [
    for (final (number, date, place) in [
      (1, 14, 'Tokyo'),
      (2, 15, 'Kyoto'),
      (3, 17, 'Osaka'),
    ])
      ConfirmedDay(
        number: number,
        date: CalendarDate.fromDateTimeIgnoringZone(day(date)),
        place: place,
      ),
  ],
);

/// The same plan in the app-state vocabulary `pingsForPlan` takes.
TripPlan threeDatedDaysPlan() => TripPlan(
  days: [
    for (final (number, date, place) in [
      (1, 14, 'Tokyo'),
      (2, 15, 'Kyoto'),
      (3, 17, 'Osaka'),
    ])
      PlanDay(number: number, date: day(date), place: place, stops: const []),
  ],
);

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

  /// The launch that created the stranded state: a plan accepted and a trip
  /// started while the whole launch still called itself `me`.
  Future<void> tripStartedUnderStandIn() async {
    await MembershipStore(db).startTrip(
      starter: MemberId(localMemberId),
      starterDisplayName: localMemberName,
      now: day(1),
    );
    await TripRepository(db).saveItinerary(threeDatedDays());
  }

  Future<void> launch(
    WidgetTester tester, {
    String? memberId,
    Future<String?> Function()? lateAccountId,
  }) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: day(14),
        now: day(14),
        utcOffset: Duration.zero,
        memberId: memberId,
        lateAccountId: lateAccountId,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Paste the membership tests' three-day plan and accept it.
  Future<void> pasteAndAccept(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('paste-input')), '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Thu 17 June 2027 - Osaka
- Dotonbori
''');
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  /// Reads the schedule off the live providers, pumping until the roster
  /// stream has emitted. Bounded: a schedule that stays empty comes back
  /// empty rather than hanging the test.
  Future<List<tm.Ping>> pingsOf(WidgetTester tester) async {
    final container = containerOf(tester);
    for (var i = 0; i < 20; i++) {
      final pings = container.read(pingScheduleProvider);
      if (pings.isNotEmpty) return pings;
      await tester.pump();
    }
    return container.read(pingScheduleProvider);
  }

  // ------------------------------------------------------- the defect itself

  test('a roster still holding the stand-in deals no pings to the account — '
      'the mechanism, run against the real derivation', () async {
    await tripStartedUnderStandIn();

    // The next launch resolves the account id from the vault, but the roster
    // was never repaired: the party is still ['me'].
    final members = await db.readTripMembers();
    final party = tm.Party([for (final m in members) m.id]);
    final tripId = TripId((await db.readTripFacts())!.tripId);

    // The deal exists — it is just dealt entirely to a member this launch no
    // longer is. That is the whole defect: zero pings for the rest of the
    // trip, and nothing says so.
    expect(
      pingsForPlan(
        plan: threeDatedDaysPlan(),
        party: party,
        utcOffset: Duration.zero,
        memberId: localMemberId,
        tripId: tripId,
      ),
      hasLength(3),
      reason: 'the schedule itself is fine — for the stand-in',
    );
    expect(
      pingsForPlan(
        plan: threeDatedDaysPlan(),
        party: party,
        utcOffset: Duration.zero,
        memberId: account,
        tripId: tripId,
      ),
      isEmpty,
      reason: 'the signed-in launch gets nothing: it is not in the party',
    );
  });

  // --------------------------------------------------- the heal, at the root

  testWidgets('a trip stranded under the stand-in is healed on the next '
      'launch, and the pings come back', (tester) async {
    await tripStartedUnderStandIn();

    // The next launch: the vault answered, so the whole launch is the
    // account — and the composition root repairs the roster it left behind.
    await launch(tester, memberId: account);

    expect(await pingsOf(tester), hasLength(3));
    final trip = (await db.readTripFacts())!;
    expect(trip.startedByMemberId, account);
    expect((await db.readTripMembers()).single.id, account);
  });

  testWidgets('the heal runs on every launch and changes nothing the second '
      'time', (tester) async {
    await tripStartedUnderStandIn();
    await MembershipStore(db)
        .adoptAccountIdentity(standInId: localMemberId, accountId: account);

    final rosterAfterFirst = await db.readTripMembers();
    final factsAfterFirst = (await db.readTripFacts())!;

    // A reconcile that changed nothing must write nothing: the roster's
    // stream asks for work when it emits, so a heal that always wrote would
    // be a heal that never stops. Watch for the write directly.
    final emissions = <Object?>[];
    final watching = db.watchTripFacts().listen(emissions.add);
    addTearDown(watching.cancel);
    await tester.pump();
    final emissionsBefore = emissions.length;

    await MembershipStore(db)
        .adoptAccountIdentity(standInId: localMemberId, accountId: account);
    await tester.pump();
    await tester.pump();

    expect(emissions.length, emissionsBefore, reason: 'no second write');
    expect(await db.readTripMembers(), rosterAfterFirst);
    expect(
      (await db.readTripFacts())!.startedByMemberId,
      factsAfterFirst.startedByMemberId,
    );
  });

  testWidgets('healing a roster the account already sits in drops the '
      'stand-in instead of duplicating the account', (tester) async {
    await tripStartedUnderStandIn();
    // A second row for the account itself, as if a healed write had landed
    // beside the stand-in's. Two rows must become one, not a refused insert.
    await db.replaceRoster(
      members: [
        (id: localMemberId, displayName: localMemberName, joinedOnDay: 1),
        (id: account, displayName: localMemberName, joinedOnDay: 1),
      ],
    );

    await MembershipStore(db)
        .adoptAccountIdentity(standInId: localMemberId, accountId: account);

    expect((await db.readTripMembers()).single.id, account);
  });

  // ------------------------------------------- the accept path, both flavours

  testWidgets('an accept after the sign-in has answered starts the trip '
      'under the account, not the stand-in', (tester) async {
    // A configured build whose boot budget expired but whose sign-in landed
    // behind the first frame — the ordinary online first launch.
    await launch(tester, lateAccountId: () async => account);
    await pasteAndAccept(tester);

    final trip = (await db.readTripFacts())!;
    expect(trip.startedByMemberId, account);
    expect((await db.readTripMembers()).single.id, account);
    // The launch adopted the id it started the trip under, so this launch's
    // own deal is already the account's.
    expect(await pingsOf(tester), hasLength(3));
  });

  testWidgets('an accept on a configured build that still cannot reach the '
      'backend starts the trip under the stand-in, exactly as offline does', (
    tester,
  ) async {
    await launch(tester, lateAccountId: () async => null);
    await pasteAndAccept(tester);

    expect((await db.readTripFacts())!.startedByMemberId, localMemberId);
    expect((await db.readTripMembers()).single.id, localMemberId);
    expect(await pingsOf(tester), hasLength(3));
  });

  testWidgets('a trip created fully offline, with no backend configured, '
      'still works end to end', (tester) async {
    // No memberId and no resolver: the whole launch is the stand-in, which
    // is the offline-first story unchanged.
    await launch(tester);
    await pasteAndAccept(tester);

    expect((await db.readTripFacts())!.startedByMemberId, localMemberId);
    expect((await db.readTripMembers()).single.id, localMemberId);
    expect(await pingsOf(tester), hasLength(3));
  });

  testWidgets('a sign-in that lands after the trip has started does not '
      'change who this launch is', (tester) async {
    // The trip already exists under the stand-in — started on an earlier,
    // offline launch. The account answering mid-launch must not flip the
    // identity out from under a roster that still says `me`: the launch
    // stays coherent, and the *next* launch heals.
    await tripStartedUnderStandIn();
    await launch(tester, lateAccountId: () async => account);
    await tester.pumpAndSettle();

    // Saving an edit of the live plan runs the same accept path, driven
    // through the flow itself — the sheet's entry calls exactly this pair
    // (`trip_sheet.dart`), and the navigation is not what this test is about.
    final flow = containerOf(tester).read(pasteFlowProvider.notifier);
    flow.editLivePlan();
    await tester.pump();
    await flow.accept();
    await tester.pump();
    await tester.pump();

    expect((await db.readTripFacts())!.startedByMemberId, localMemberId);
    expect((await db.readTripMembers()).single.id, localMemberId);
    expect(
      containerOf(tester).read(localMemberIdProvider),
      localMemberId,
      reason: 'identity is fixed for the launch once a trip holds it',
    );
  });
}
