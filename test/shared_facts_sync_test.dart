// The trip's shared facts, kept in step across phones: the itinerary and the
// roster, and nothing else (the trail, the stars, the gate and the ping
// schedule stay computed on each phone).
//
// **The server's half of the merge is not tested here.** Last-write-wins per
// day is decided inside `sync_trip_itinerary`, and its authority is
// `supabase/tests/rls_probe.py`, which applies the real migrations to a real
// Postgres and drives them exactly as PostgREST does — a stale push losing, a
// fresh one winning, a day nobody pushed left alone, a phone unable to delete
// a day it has never seen. Re-implementing that rule in a Dart fake would put
// a third copy of it in the repository, and a third copy is the thing to
// refuse in review.
//
// So [FakeServer] is deliberately dumb: it records what the phone pushed and
// hands back whatever the test says the trip holds. What is asserted here is
// the phone's half — *what* it pushes, *when* it pushes, and what it does
// with what comes back — plus the two things only the phone can get wrong:
// stamping a merge clock it had no right to stamp, and losing local work
// because the train went into a tunnel.
//
// Plain `test`s rather than `testWidgets`: the sync is a fact about the seam,
// not about any screen, and nothing above the seam knows it exists.
import 'dart:async';
import 'dart:io';

import 'package:cairn_model/cairn_model.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/repositories/itinerary_sync.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn/storage/remote/shared_facts.dart';

AppDatabase inMemory() => AppDatabase(
  DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
);

const anna = 'a0000000-0000-4000-8000-000000000001';
const bo = 'a0000000-0000-4000-8000-000000000002';
const cass = 'a0000000-0000-4000-8000-000000000003';

/// One push, as the phone made it.
typedef Push = ({
  DateTime planRevisedAt,
  List<RemoteDay> days,
  DateTime pocketRevisedAt,
  List<RemoteSetAside> setAside,
});

/// A stand-in for Supabase that keeps a plan in a field.
///
/// **It never merges.** With [holds] set it returns exactly that, whatever
/// was pushed — which is how a test says "somebody else changed the trip".
/// With [holds] null it echoes the push straight back, which is what a real
/// server does when one phone is the only one editing and is the honest
/// baseline for every test about what the *phone* does. Neither is a merge;
/// see the header for why there is no third copy of that rule here.
class FakeServer implements SharedFacts {
  FakeServer({this.trip, this.holds});

  /// Who this phone is signed in as. Set to null for the app's actual state
  /// today: Sign in with Apple is not built, so nothing has a session.
  SharedFactsSession? auth = SharedFactsSession(
    accessToken: 'token',
    userId: MemberId(anna),
  );

  /// The shared `trips` row, or null while the server has never heard of it.
  RemoteTrip? trip;

  /// What the next [syncItinerary] hands back, or null to echo the push.
  RemoteItinerary? holds;

  /// Set to make every call fail the way a tunnel does.
  String? unreachable;

  /// Set to make every call fail the way a refusal does.
  String? refuses;

  final pushes = <Push>[];
  final created = <RemoteTripDraft>[];
  var readTrips = 0;

  /// Completes the first time the phone pushes, so a test can wait for a
  /// sync nobody asked for by hand.
  final firstPush = Completer<void>();

  void _gate() {
    if (unreachable != null) throw SharedFactsUnavailable(unreachable!);
    if (refuses != null) throw SharedFactsRefused(refuses!);
  }

  @override
  Future<SharedFactsSession?> session() async => auth;

  @override
  Future<RemoteTrip?> readTrip(TripId tripId) async {
    _gate();
    readTrips++;
    return trip;
  }

  @override
  Future<void> createTrip(RemoteTripDraft draft) async {
    _gate();
    created.add(draft);
    trip = RemoteTrip(
      id: draft.id,
      name: draft.name,
      startedBy: draft.createdBy,
      members: [
        RemoteMember(
          id: draft.createdBy,
          displayName: 'Anna',
          joinedAt: DateTime.utc(2027, 6, 1),
        ),
      ],
    );
  }

  @override
  Future<RemoteItinerary> syncItinerary({
    required TripId tripId,
    required DateTime planRevisedAt,
    required List<RemoteDay> days,
    required DateTime pocketRevisedAt,
    required List<RemoteSetAside> setAside,
  }) async {
    _gate();
    pushes.add((
      planRevisedAt: planRevisedAt,
      days: days,
      pocketRevisedAt: pocketRevisedAt,
      setAside: setAside,
    ));
    if (!firstPush.isCompleted) firstPush.complete();
    return holds ??
        RemoteItinerary(
          planRevisedAt: planRevisedAt,
          pocketRevisedAt: pocketRevisedAt,
          days: days,
          setAside: setAside,
        );
  }
}

/// The plan as it arrives back from the server, spelled the way the RPC
/// spells it.
RemoteItinerary serverHolds(
  List<RemoteDay> days, {
  DateTime? planAt,
  DateTime? pocketAt,
  List<RemoteSetAside> pocket = const [],
}) => RemoteItinerary(
  planRevisedAt: planAt ?? days.map((d) => d.revisedAt).reduce(_later),
  pocketRevisedAt: pocketAt ?? DateTime.utc(1970),
  days: days,
  setAside: pocket,
);

DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

RemoteDay serverDay(
  int number,
  String place,
  DateTime revisedAt, {
  String? dateIso,
  List<String> stops = const [],
}) => RemoteDay(
  number: number,
  dateIso: dateIso,
  place: place,
  revisedAt: revisedAt,
  stops: [
    for (final (position, text) in stops.indexed)
      RemoteStop(position: position, text: text),
  ],
);

ConfirmedItinerary plan(
  List<ConfirmedDay> days, {
  List<KeptLine> aside = const [],
}) => ConfirmedItinerary(days: days, keptAside: aside);

ConfirmedDay confirmed(
  int number,
  String place, {
  CalendarDate? date,
  List<String> stops = const [],
}) => ConfirmedDay(
  number: number,
  date: date,
  place: place,
  stops: [for (final text in stops) Stop(text: text)],
);

/// The trip this phone has already started, the way accepting a paste starts
/// one. Every test needs one: a phone with no trip has nothing shared to be.
Future<TripId> startTrip(AppDatabase db) =>
    db.startTripIfAbsent(starterId: anna, starterDisplayName: 'Anna');

RemoteTrip sharedTrip(TripId id, List<RemoteMember> members, {String? name}) =>
    RemoteTrip(id: id, name: name, startedBy: MemberId(anna), members: members);

void main() {
  group('nothing is configured, so nothing happens', () {
    test(
      'with nobody signed in the sync is dormant and writes nothing',
      () async {
        final db = inMemory();
        addTearDown(db.close);
        await startTrip(db);
        await TripRepository(db).saveItinerary(
          plan([
            confirmed(1, 'Oslo', stops: ['Vigeland']),
          ]),
          at: DateTime.utc(2027, 6, 1),
        );
        final server = FakeServer()..auth = null;

        final outcome = await TripSync(database: db, facts: server).syncNow();

        expect(outcome.standing, SyncStanding.dormant);
        expect(server.pushes, isEmpty);
        expect(
          await db.readItineraryDays(),
          hasLength(1),
          reason: 'a dormant sync leaves the phone exactly as it found it',
        );
      },
    );

    test(
      'a phone that has not started a trip has nothing to reconcile',
      () async {
        final db = inMemory();
        addTearDown(db.close);
        final server = FakeServer();

        final outcome = await TripSync(database: db, facts: server).syncNow();

        expect(outcome.standing, SyncStanding.noTrip);
        expect(server.readTrips, 0);
      },
    );
  });

  group('a trip that has never been shared', () {
    test('says so rather than inventing the clock it does not know', () async {
      // `trips` needs an IANA zone and two dates; this slice of the app holds
      // a device UTC offset and a plan whose dates may all be open. Deriving
      // `Etc/GMT-8` from an offset would be a lie at the first border.
      final db = inMemory();
      addTearDown(db.close);
      await startTrip(db);
      final server = FakeServer(trip: null);

      final outcome = await TripSync(database: db, facts: server).syncNow();

      expect(outcome.standing, SyncStanding.awaitingTripRow);
      expect(server.created, isEmpty);
      expect(server.pushes, isEmpty);
    });

    test('is created once something can say what its clock is', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      await TripRepository(db).saveItinerary(
        plan([
          confirmed(1, 'Oslo', date: CalendarDate(2027, 6, 14)),
          confirmed(2, 'Bergen', date: CalendarDate(2027, 6, 16)),
        ]),
        at: DateTime.utc(2027, 6, 1),
      );
      final server = FakeServer(trip: null);

      final outcome = await TripSync(
        database: db,
        facts: server,
        tripRow: (pending) async => RemoteTripDraft(
          id: pending.tripId,
          name: pending.name ?? 'Norway',
          createdBy: pending.startedBy,
          timeZone: 'Europe/Oslo',
          startDateIso: pending.firstDateIso!,
          endDateIso: pending.lastDateIso!,
        ),
      ).syncNow();

      expect(outcome.standing, SyncStanding.synced);
      expect(server.created.single.id, id);
      expect(
        (server.created.single.startDateIso, server.created.single.endDateIso),
        ('2027-06-14', '2027-06-16'),
        reason: 'the plan\'s own resolved dates, not a guess',
      );
    });
  });

  group('a local change is pushed', () {
    test('the whole plan goes up, days in order with their stops', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      final server = FakeServer(trip: sharedTrip(id, const []));
      await TripRepository(db).saveItinerary(
        plan([
          confirmed(
            1,
            'Oslo',
            date: CalendarDate(2027, 6, 14),
            stops: ['Vigeland', 'Opera'],
          ),
          confirmed(2, 'Bergen', stops: ['Bryggen']),
        ]),
        at: DateTime.utc(2027, 6, 1, 9),
      );

      await TripSync(database: db, facts: server).syncNow();

      final push = server.pushes.single;
      expect(push.days.map((d) => d.number), [1, 2]);
      expect(push.days.first.stops.map((s) => s.text), ['Vigeland', 'Opera']);
      expect(push.days.first.dateIso, '2027-06-14');
      expect(
        push.days.every((d) => d.revisedAt == DateTime.utc(2027, 6, 1, 9)),
        isTrue,
        reason: 'a first save is a change to every day in it',
      );
      expect(
        push.planRevisedAt,
        DateTime.utc(2027, 6, 1, 9),
        reason: 'the shape moved: the plan went from no days to two',
      );
    });

    test('a second save stamps only the day that actually changed', () async {
      // The day is the merge atom, so a save that re-wrote every day's clock
      // would have this phone claim authorship of days it merely still held
      // — and clobber everyone else's edits on the next push.
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      final server = FakeServer(trip: sharedTrip(id, const []));
      final repository = TripRepository(db);

      await repository.saveItinerary(
        plan([
          confirmed(1, 'Oslo', stops: ['Vigeland']),
          confirmed(2, 'Bergen', stops: ['Bryggen']),
        ]),
        at: DateTime.utc(2027, 6, 1, 9),
      );
      await repository.saveItinerary(
        plan([
          confirmed(1, 'Oslo', stops: ['Vigeland']),
          confirmed(2, 'Bergen', stops: ['Bryggen', 'Fløyen']),
        ]),
        at: DateTime.utc(2027, 6, 2, 9),
      );

      await TripSync(database: db, facts: server).syncNow();

      final days = {for (final d in server.pushes.single.days) d.number: d};
      expect(days[1]!.revisedAt, DateTime.utc(2027, 6, 1, 9));
      expect(days[2]!.revisedAt, DateTime.utc(2027, 6, 2, 9));
      expect(
        server.pushes.single.planRevisedAt,
        DateTime.utc(2027, 6, 1, 9),
        reason: 'editing a day is not a change to the plan\'s shape',
      );
    });

    test(
      'removing a day moves the shape revision, so the server may drop it',
      () async {
        final db = inMemory();
        addTearDown(db.close);
        final id = await startTrip(db);
        final server = FakeServer(trip: sharedTrip(id, const []));
        final repository = TripRepository(db);

        await repository.saveItinerary(
          plan([confirmed(1, 'Oslo'), confirmed(2, 'Bergen')]),
          at: DateTime.utc(2027, 6, 1, 9),
        );
        await repository.saveItinerary(
          plan([confirmed(1, 'Oslo')]),
          at: DateTime.utc(2027, 6, 3, 9),
        );

        await TripSync(database: db, facts: server).syncNow();

        expect(server.pushes.single.planRevisedAt, DateTime.utc(2027, 6, 3, 9));
        expect(server.pushes.single.days.map((d) => d.number), [1]);
      },
    );

    test(
      'the set-aside pocket travels, and emptying it still counts',
      () async {
        final db = inMemory();
        addTearDown(db.close);
        final id = await startTrip(db);
        final server = FakeServer(trip: sharedTrip(id, const []));
        final repository = TripRepository(db);

        await repository.saveItinerary(
          plan(
            [confirmed(1, 'Oslo')],
            aside: [
              KeptLine(
                sourceLineNumber: 9,
                text: 'book the cabin',
                explanation: 'no day named',
              ),
            ],
          ),
          at: DateTime.utc(2027, 6, 1, 9),
        );
        await TripSync(database: db, facts: server).syncNow();
        expect(server.pushes.last.setAside.single.text, 'book the cabin');
        expect(server.pushes.last.pocketRevisedAt, DateTime.utc(2027, 6, 1, 9));

        await repository.saveItinerary(
          plan([confirmed(1, 'Oslo')]),
          at: DateTime.utc(2027, 6, 4, 9),
        );
        await TripSync(database: db, facts: server).syncNow();
        expect(server.pushes.last.setAside, isEmpty);
        expect(
          server.pushes.last.pocketRevisedAt,
          DateTime.utc(2027, 6, 4, 9),
          reason:
              'an emptied pocket must still carry a revision, or a stale '
              'phone refills it forever',
        );
      },
    );

    test('a save reaches the server without anyone asking it to', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      final server = FakeServer(trip: sharedTrip(id, const []));
      final sync = TripSync(database: db, facts: server);
      addTearDown(sync.stop);
      sync.start();

      await TripRepository(db).saveItinerary(
        plan([
          confirmed(1, 'Oslo', stops: ['Vigeland']),
        ]),
        at: DateTime.utc(2027, 6, 1, 9),
      );

      await server.firstPush.future.timeout(const Duration(seconds: 5));
      expect(server.pushes, isNotEmpty);
    });

    test('and having agreed with the server, it stops', () async {
      // The loop this guards against is easy to build by accident: the plan's
      // own stream is what asks for a sync, so a reconcile that wrote the
      // answer back unconditionally would ask for the next one, forever, on
      // a phone in somebody's pocket.
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      final server = FakeServer(trip: sharedTrip(id, const []));
      final sync = TripSync(database: db, facts: server);
      addTearDown(sync.stop);
      sync.start();

      await TripRepository(db).saveItinerary(
        plan([
          confirmed(1, 'Oslo', stops: ['Vigeland']),
        ]),
        at: DateTime.utc(2027, 6, 1, 9),
      );
      await server.firstPush.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        server.pushes.length,
        lessThan(4),
        reason: 'a settled reconcile writes nothing, so nothing re-triggers it',
      );
    });
  });

  group('a remote change is applied', () {
    test('a day somebody else added arrives, with their clock on it', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      await TripRepository(db).saveItinerary(
        plan([
          confirmed(1, 'Oslo', stops: ['Vigeland']),
        ]),
        at: DateTime.utc(2027, 6, 1, 9),
      );
      final server = FakeServer(trip: sharedTrip(id, const []))
        ..holds = serverHolds([
          serverDay(
            1,
            'Oslo',
            DateTime.utc(2027, 6, 1, 9),
            stops: ['Vigeland'],
          ),
          serverDay(
            2,
            'Tromsø',
            DateTime.utc(2027, 6, 5, 12),
            stops: ['Fjellheisen'],
          ),
        ]);

      final outcome = await TripSync(database: db, facts: server).syncNow();

      expect(outcome.standing, SyncStanding.synced);
      expect(outcome.days, 2);
      final saved = await TripRepository(db).watchItinerary().first;
      expect(saved!.days.map((d) => d.place), ['Oslo', 'Tromsø']);
      expect(saved.days.last.stops.single.text, 'Fjellheisen');
      final rows = {for (final d in await db.readItineraryDays()) d.number: d};
      expect(
        rows[2]!.revisedAtUtcIso,
        DateTime.utc(2027, 6, 5, 12).toIso8601String(),
        reason: 'the clock that came down is the clock that is kept',
      );
    });

    test(
      'applying a merge is not a local edit, so it does not push back',
      () async {
        // Two phones that re-stamped everything they pulled would push each
        // other's plans back and forth for as long as they both had signal.
        final db = inMemory();
        addTearDown(db.close);
        final id = await startTrip(db);
        await TripRepository(db).saveItinerary(
          plan([confirmed(1, 'Oslo')]),
          at: DateTime.utc(2027, 6, 1, 9),
        );
        final server = FakeServer(trip: sharedTrip(id, const []))
          ..holds = serverHolds([
            serverDay(1, 'Oslo', DateTime.utc(2027, 6, 1, 9)),
            serverDay(2, 'Tromsø', DateTime.utc(2027, 6, 5, 12)),
          ], planAt: DateTime.utc(2027, 6, 5, 12));

        final sync = TripSync(database: db, facts: server);
        await sync.syncNow();
        await sync.syncNow();

        final second = server.pushes.last;
        expect(second.days.map((d) => d.number), [1, 2]);
        expect(second.days.last.revisedAt, DateTime.utc(2027, 6, 5, 12));
        expect(
          second.planRevisedAt,
          DateTime.utc(2027, 6, 5, 12),
          reason: 'the phone now speaks the shape the server told it about',
        );
      },
    );

    test('a day the server dropped is gone from this phone too', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      await TripRepository(db).saveItinerary(
        plan([confirmed(1, 'Oslo'), confirmed(2, 'Bergen')]),
        at: DateTime.utc(2027, 6, 1, 9),
      );
      final server = FakeServer(trip: sharedTrip(id, const []))
        ..holds = serverHolds([
          serverDay(1, 'Oslo', DateTime.utc(2027, 6, 1, 9)),
        ], planAt: DateTime.utc(2027, 6, 7));

      await TripSync(database: db, facts: server).syncNow();

      expect(await db.readItineraryDays(), hasLength(1));
      expect(
        await db.readItineraryStops(),
        isEmpty,
        reason: 'a dropped day takes its stops with it',
      );
    });

    test('a phone with no plan of its own pulls the whole trip', () async {
      // The joiner's case: pushing nothing wins nothing and deletes nothing.
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      final server = FakeServer(trip: sharedTrip(id, const []))
        ..holds = serverHolds([
          serverDay(
            1,
            'Oslo',
            DateTime.utc(2027, 6, 1, 9),
            stops: ['Vigeland'],
          ),
          serverDay(2, 'Bergen', DateTime.utc(2027, 6, 2, 9)),
        ]);

      await TripSync(database: db, facts: server).syncNow();

      expect(server.pushes.single.days, isEmpty);
      expect(
        server.pushes.single.planRevisedAt,
        DateTime.parse(beforeAnySync),
        reason: 'a phone that has never had a plan claims no shape at all',
      );
      expect(await db.readItineraryDays(), hasLength(2));
    });
  });

  group('the roster propagates, and not only at join', () {
    test('everyone the server names lands on this phone', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      await TripRepository(db).saveItinerary(
        plan([
          confirmed(1, 'Oslo', date: CalendarDate(2027, 6, 14)),
          confirmed(2, 'Bergen', date: CalendarDate(2027, 6, 15)),
        ]),
        at: DateTime.utc(2027, 6, 1),
      );
      final server = FakeServer(
        trip: sharedTrip(id, [
          RemoteMember(
            id: MemberId(anna),
            displayName: 'Anna',
            joinedAt: DateTime.utc(2027, 6, 14, 8),
          ),
          RemoteMember(
            id: MemberId(bo),
            displayName: 'Bo',
            joinedAt: DateTime.utc(2027, 6, 15, 11),
          ),
        ], name: 'Norway'),
      );

      final outcome = await TripSync(database: db, facts: server).syncNow();

      expect(outcome.members, 2);
      final members = await db.readTripMembers();
      expect(members.map((m) => m.displayName), ['Anna', 'Bo']);
      expect(
        members.map((m) => m.joinedOnDay),
        [1, 2],
        reason: 'the server hands over the instant; the phone counts the days',
      );
      expect((await db.readTripFacts())!.name, 'Norway');
    });

    test('a later join reaches a phone that was handed nothing', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      final one = RemoteMember(
        id: MemberId(anna),
        displayName: 'Anna',
        joinedAt: DateTime.utc(2027, 6, 14),
      );
      final server = FakeServer(trip: sharedTrip(id, [one]));
      final sync = TripSync(database: db, facts: server);

      await sync.syncNow();
      expect(await db.readTripMembers(), hasLength(1));

      server.trip = sharedTrip(id, [
        one,
        RemoteMember(
          id: MemberId(bo),
          displayName: 'Bo',
          joinedAt: DateTime.utc(2027, 6, 15),
        ),
      ]);
      await sync.syncNow();

      expect((await db.readTripMembers()).map((m) => m.displayName), [
        'Anna',
        'Bo',
      ]);
    });

    test('somebody who left stops being on the trip here', () async {
      // Wholesale, and safely so: RLS means the server only answers a member,
      // so a roster that preserved a local row the server did not name would
      // resurrect a ghost — and `trip_moments` deals that ghost a ping.
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      final anne = RemoteMember(
        id: MemberId(anna),
        displayName: 'Anna',
        joinedAt: DateTime.utc(2027, 6, 14),
      );
      final server = FakeServer(
        trip: sharedTrip(id, [
          anne,
          RemoteMember(
            id: MemberId(bo),
            displayName: 'Bo',
            joinedAt: DateTime.utc(2027, 6, 14),
          ),
          RemoteMember(
            id: MemberId(cass),
            displayName: 'Cass',
            joinedAt: DateTime.utc(2027, 6, 14),
          ),
        ]),
      );
      final sync = TripSync(database: db, facts: server);
      await sync.syncNow();
      expect(await db.readTripMembers(), hasLength(3));

      server.trip = sharedTrip(id, [anne]);
      await sync.syncNow();

      expect((await db.readTripMembers()).map((m) => m.id), [anna]);
    });

    test('a join before the plan has any dates lands on day one', () async {
      expect(
        TripSync.joinedOnDay(
          joinedAt: DateTime.utc(2027, 6, 20),
          days: const [(1, null), (2, null)],
        ),
        1,
      );
    });

    test('a join before the trip starts is still day one', () async {
      expect(
        TripSync.joinedOnDay(
          joinedAt: DateTime.utc(2027, 6, 1),
          days: const [(1, '2027-06-14'), (2, '2027-06-15')],
        ),
        1,
      );
    });

    test('a join after the last dated day is that day', () async {
      expect(
        TripSync.joinedOnDay(
          joinedAt: DateTime.utc(2027, 7, 1),
          days: const [(1, '2027-06-14'), (2, '2027-06-15')],
        ),
        2,
      );
    });
  });

  group('a phone upgraded from before the sync existed', () {
    /// Winds a freshly built database back to schema v5 — the shape a phone
    /// had when the itinerary was still one phone's private business.
    Future<void> windBackToV5(AppDatabase db) async {
      await db.customStatement('DROP TABLE sync_states');
      await db.customStatement(
        'ALTER TABLE itinerary_days DROP COLUMN revised_at_utc_iso',
      );
      await db.customStatement('PRAGMA user_version = 5');
    }

    test('keeps the plan it already had, and can still say so', () async {
      // The trap the migration exists to avoid: a plan whose days all carry
      // the epoch says "I have nothing to tell you" to an empty server, and
      // the first sync after an upgrade would delete the whole trip. No
      // Supabase project has ever been applied, so a plan already on a phone
      // is provably the newest plan in existence.
      final dir = Directory.systemTemp.createTempSync('cairn-sync-upgrade');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/cairn.sqlite');

      var db = AppDatabase(
        DatabaseConnection(
          NativeDatabase(file),
          closeStreamsSynchronously: true,
        ),
      );
      await startTrip(db);
      await TripRepository(db).saveItinerary(
        plan([
          confirmed(1, 'Oslo', stops: ['Vigeland']),
        ]),
        at: DateTime.utc(2027, 6, 1),
      );
      await windBackToV5(db);
      await db.close();

      db = AppDatabase(
        DatabaseConnection(
          NativeDatabase(file),
          closeStreamsSynchronously: true,
        ),
      );
      addTearDown(db.close);

      final epoch = DateTime.parse(beforeAnySync);
      expect(await db.readItineraryDays(), hasLength(1));
      expect(
        DateTime.parse((await db.readItineraryDays()).single.revisedAtUtcIso)
            .isAfter(epoch),
        isTrue,
      );
      expect(
        DateTime.parse((await db.readSyncState()).planRevisedAtUtcIso)
            .isAfter(epoch),
        isTrue,
        reason: 'the plan can claim its own shape, so no server deletes it',
      );
    });

    test('a phone with no plan claims nothing at all', () async {
      final dir = Directory.systemTemp.createTempSync('cairn-sync-empty');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/cairn.sqlite');

      var db = AppDatabase(
        DatabaseConnection(
          NativeDatabase(file),
          closeStreamsSynchronously: true,
        ),
      );
      await windBackToV5(db);
      await db.close();

      db = AppDatabase(
        DatabaseConnection(
          NativeDatabase(file),
          closeStreamsSynchronously: true,
        ),
      );
      addTearDown(db.close);

      expect(
        (await db.readSyncState()).planRevisedAtUtcIso,
        beforeAnySync,
        reason: 'claiming a shape it never had would delete somebody else\'s',
      );
    });
  });

  group('offline, the local copy is the trip', () {
    test('a tunnel changes nothing and is not an error', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      await TripRepository(db).saveItinerary(
        plan([
          confirmed(1, 'Oslo', stops: ['Vigeland']),
        ]),
        at: DateTime.utc(2027, 6, 1, 9),
      );
      final server = FakeServer(trip: sharedTrip(id, const []))
        ..unreachable = 'no route to the server';

      final outcome = await TripSync(database: db, facts: server).syncNow();

      expect(outcome.standing, SyncStanding.offline);
      final saved = await TripRepository(db).watchItinerary().first;
      expect(saved!.days.single.stops.single.text, 'Vigeland');
    });

    test('an edit made offline is pushed when the phone surfaces', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      final repository = TripRepository(db);
      await repository.saveItinerary(
        plan([
          confirmed(1, 'Oslo', stops: ['Vigeland']),
        ]),
        at: DateTime.utc(2027, 6, 1, 9),
      );
      final server = FakeServer(trip: sharedTrip(id, const []));
      final sync = TripSync(database: db, facts: server);
      await sync.syncNow();

      server.unreachable = 'no route to the server';
      await repository.saveItinerary(
        plan([
          confirmed(1, 'Oslo', stops: ['Vigeland', 'Munchmuseet']),
        ]),
        at: DateTime.utc(2027, 6, 2, 9),
      );
      expect((await sync.syncNow()).standing, SyncStanding.offline);
      expect(server.pushes, hasLength(1));

      server.unreachable = null;
      final outcome = await sync.syncNow();

      expect(outcome.standing, SyncStanding.synced);
      expect(server.pushes.last.days.single.stops.map((s) => s.text), [
        'Vigeland',
        'Munchmuseet',
      ]);
      expect(
        server.pushes.last.days.single.revisedAt,
        DateTime.utc(2027, 6, 2, 9),
        reason:
            'the edit kept the instant it was made at, not the instant '
            'the signal came back',
      );
    });

    test('a refusal is not retried and does not touch the plan', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      await TripRepository(db).saveItinerary(
        plan([confirmed(1, 'Oslo')]),
        at: DateTime.utc(2027, 6, 1, 9),
      );
      final server = FakeServer(trip: sharedTrip(id, const []))
        ..refuses = '403: not a member of this trip';

      final outcome = await TripSync(database: db, facts: server).syncNow();

      expect(outcome.standing, SyncStanding.refused);
      expect(await db.readItineraryDays(), hasLength(1));
    });

    test('two reconciles at once are one reconcile', () async {
      final db = inMemory();
      addTearDown(db.close);
      final id = await startTrip(db);
      final server = FakeServer(trip: sharedTrip(id, const []));
      final sync = TripSync(database: db, facts: server);

      await Future.wait([sync.syncNow(), sync.syncNow(), sync.syncNow()]);

      expect(
        server.pushes,
        hasLength(lessThanOrEqualTo(2)),
        reason: 'a burst collapses; it does not race itself',
      );
    });
  });
}
