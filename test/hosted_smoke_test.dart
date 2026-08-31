// The real thing: this phone's own stack, against the hosted project.
//
// Skipped unless asked for, because it talks to a live server and CI must not:
//
// ```sh
// flutter test test/hosted_smoke_test.dart --dart-define=CAIRN_HOSTED_SMOKE=true
// ```
//
// **Nothing here is a double.** The session comes from `GotrueSessions` over
// real GoTrue, the wire from `PostgrestSharedFacts` over real PostgREST, the
// merge from `sync_trip_itinerary` running in real Postgres, and the local
// copy from a real Drift database (in memory, so the test leaves no file). It
// is the one check in the repository that a green suite cannot fake, and it
// exists because everything else about the backend is verified against a
// throwaway Postgres (`supabase/tests/`) which has no PostgREST, no GoTrue and
// no row-level security engine wired to a real `auth.uid()`.
//
// The two phones are two `AppDatabase`s under one account. That is exactly the
// shape the merge is for: one pushes a plan, the other has never heard of the
// trip and pulls it by pushing nothing (`SharedFacts.syncItinerary`).
//
// It cleans up after itself: the trip it creates is deleted at the end, and
// `on delete cascade` takes the itinerary with it. The anonymous account it
// signs in as is left behind, which is the honest cost of an account nobody
// can delete without the service-role key.
import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:cairn/app_state/device_time_zone.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/itinerary_sync.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn/storage/remote/gotrue_sessions.dart';
import 'package:cairn/storage/remote/postgrest_shared_facts.dart';
import 'package:cairn/storage/remote/shared_facts.dart';

/// Whether to actually reach out. Off by default; see the header.
const askedFor = bool.fromEnvironment('CAIRN_HOSTED_SMOKE');

const config = SharedFactsConfig.fromEnvironment;

AppDatabase phone() => AppDatabase(
  DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
);

void main() {
  group(
    'the hosted project',
    () {
      late GotrueSessions sessions;
      late SharedFactsSession auth;
      late AppDatabase first;
      AppDatabase? second;
      String? tripId;

      setUpAll(() async {
        // Two phones is the whole point of this test, and drift's warning
        // about a second AppDatabase is about two of them sharing one
        // executor. These do not: each opens its own in-memory SQLite.
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        sessions = GotrueSessions(config: config);
        final signedIn = await sessions.current();
        expect(
          signedIn,
          isNotNull,
          reason:
              'anonymous sign-in must be enabled on ${config.url} — see '
              'supabase/README.md',
        );
        auth = signedIn!;
      });

      setUp(() => first = phone());

      tearDown(() async {
        await first.close();
        await second?.close();
      });

      tearDownAll(() async {
        // The trip's starter may delete it (`trips_delete_starter`), and the
        // itinerary hangs off it with `on delete cascade`. Nothing to clean up
        // if the test failed before it ever created one, and asking anyway
        // would bury the real failure under a LateInitializationError.
        final created = tripId;
        if (created == null) return;
        await http.delete(
          Uri.parse('${config.url}/rest/v1/trips?id=eq.$created'),
          headers: {
            'apikey': config.anonKey,
            'Authorization': 'Bearer ${auth.accessToken}',
          },
        );
      });

      test('a plan pushed from one phone arrives at another', () async {
        // ---- the first phone starts a trip and pastes a plan -------------
        final startedTrip = await first.startTripIfAbsent(
          starterId: auth.userId.value,
          starterDisplayName: 'Smoke',
        );
        tripId = startedTrip.value;
        await first.renameTrip('Hosted smoke');
        await first.replaceItinerary(
          nowUtcIso: DateTime.now().toUtc().toIso8601String(),
          days: const [
            (number: 1, dateIso: '2027-06-14', place: 'Oslo'),
            (number: 2, dateIso: '2027-06-15', place: 'Bergen'),
          ],
          stops: const [
            (dayNumber: 1, position: 0, text: 'Vigeland', timeIso: null, kind: null, areaText: null, areaSource: null),
            (dayNumber: 1, position: 1, text: 'Opera', timeIso: '10:12', kind: null, areaText: null, areaSource: null),
            (dayNumber: 2, position: 0, text: 'Fløibanen', timeIso: '09:00', kind: null, areaText: null, areaSource: null),
          ],
          setAsides: const [
            (
              position: 0,
              sourceLineNumber: 9,
              text: 'book the sleeper',
              explanation: "couldn't place",
            ),
          ],
        );

        final pushing = TripSync(
          database: first,
          facts: PostgrestSharedFacts(config: config, sessions: sessions),
          // The app's own assembly, not a hand-written stand-in: this is the
          // one test that reaches the real project, so what it proves should
          // be the code an ordinary build runs. Only the clock is pinned,
          // because the real edge is a method channel and `flutter test` has
          // no channel host to answer it.
          tripRow: tripRowFor(const FixedTimeZone('Europe/Oslo')),
        );

        final pushed = await pushing.syncNow();
        expect(
          pushed.standing,
          SyncStanding.synced,
          reason: pushed.detail ?? 'no detail',
        );
        expect(pushed.days, 2);

        // The roster arrives on the *next* reconcile, not this one: the pass
        // that creates the `trips` row has nothing to read a roster off yet,
        // because the row did not exist when it looked.
        expect(pushed.members, 0);
        final settled = await pushing.syncNow();
        expect(settled.standing, SyncStanding.synced);
        expect(settled.members, 1);

        // ---- a second phone, same account, has never heard of the trip ---
        //
        // Handed the trip's id the way an invite hands it over: the store is
        // the only thing allowed to mint one, so the second phone is given a
        // mint that draws the id the first phone already has. It then pulls
        // the whole plan by pushing nothing of its own.
        final joined = AppDatabase(
          DatabaseConnection(
            NativeDatabase.memory(),
            closeStreamsSynchronously: true,
          ),
          mint: () => startedTrip,
        );
        second = joined;
        await joined.startTripIfAbsent(
          starterId: auth.userId.value,
          starterDisplayName: 'Smoke',
        );
        final pulled = await TripSync(
          database: joined,
          facts: PostgrestSharedFacts(config: config, sessions: sessions),
        ).syncNow();

        expect(
          pulled.standing,
          SyncStanding.synced,
          reason: pulled.detail ?? 'no detail',
        );

        final days = await joined.readItineraryDays();
        final stops = await joined.readItineraryStops();
        final pocket = await joined.readItinerarySetAsides();
        expect(days.map((d) => (d.number, d.dateIso, d.place)), [
          (1, '2027-06-14', 'Oslo'),
          (2, '2027-06-15', 'Bergen'),
        ]);
        expect(
          stops.map((s) => (s.dayNumber, s.position, s.stopText, s.timeIso)),
          [
            (1, 0, 'Vigeland', null),
            (1, 1, 'Opera', '10:12'),
            (2, 0, 'Fløibanen', '09:00'),
          ],
        );
        expect(pocket.single.lineText, 'book the sleeper');

        // The roster the server named, which is what a real join propagates.
        final members = await joined.readTripMembers();
        expect(members.single.id, auth.userId.value);
      });
    },
    skip: askedFor
        ? false
        : 'live: pass --dart-define=CAIRN_HOSTED_SMOKE=true to run it',
  );
}
