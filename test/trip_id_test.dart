// The trip's id, minted on the phone before the trip has ever synced
// (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md).
//
// Three claims, and they are the whole of the acceptance:
//
//  1. **Starting a trip offline yields a real, durable id.** Nothing is asked
//     of a server — there is no server to ask — and the id survives a
//     relaunch, because the transaction that decided there was no trip is the
//     transaction that wrote the id.
//  2. **An id is never reissued.** Accepting a second plan, minting more
//     codes, renaming, relaunching: the trip keeps the id it was born with.
//     This is the property the reconcile path rests on, and it is also what
//     keeps the ping schedule from re-dealing itself.
//  3. **A trip written before the mint existed is healed once**, on the way
//     to schema v5, because 'local-trip' is not something `trips.id` would
//     ever accept.
//
// These are plain `test`s over the store rather than widget tests: the mint
// is a fact about the trip, not about any screen, and the flow that reaches
// it through the real screens is walked in capture_flow_test.dart — whose
// pinned mint is itself an assertion that the id reaches the derivation.
import 'dart:io';

import 'package:cairn_model/cairn_model.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/repositories/membership_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';

AppDatabase inMemory({TripId Function()? mint}) => AppDatabase(
  DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
  mint: mint ?? mintTripId,
);

/// A store over a database that lives in a real file, so it can be closed and
/// opened again — which is the only honest way to ask whether an id is
/// durable.
Directory tempDirectory() {
  final dir = Directory.systemTemp.createTempSync('cairn-trip-id');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

const you = 'me';

/// Winds a freshly built database back to schema v4, the shape a phone had
/// before the trip minted its own id.
///
/// Everything a later version *added* has to go, not only the version number:
/// an upgrade that finds its own column already there fails outright. v5
/// changed no table at all, so v4 and v5 differ only in the number; v6 added
/// the itinerary's merge clock and the sync cursors
/// (`supabase/migrations/0010_trip_itinerary.sql` is its other half).
Future<void> windBackToV4(AppDatabase db) async {
  await db.customStatement('DROP TABLE sync_states');
  await db.customStatement(
    'ALTER TABLE itinerary_days DROP COLUMN revised_at_utc_iso',
  );
  await db.customStatement('PRAGMA user_version = 4');
}

void main() {
  group('starting a trip with nothing to ask', () {
    test('mints an id there and then, and keeps it', () async {
      final db = inMemory();
      addTearDown(db.close);

      final minted = await db.startTripIfAbsent(
        starterId: you,
        starterDisplayName: 'You',
      );

      expect(
        minted.isCanonical,
        isTrue,
        reason: 'a uuid is what `trips.id` will accept unchanged',
      );
      expect(
        (await db.readTripFacts())!.tripId,
        minted.value,
        reason: 'the id the caller was handed is the id that was written',
      );
    });

    test('the whole store starts a trip without being told an id', () async {
      // Nothing above the store may name a trip's id: there is one mint, and
      // it is where the row is written.
      final db = inMemory();
      addTearDown(db.close);
      final store = MembershipStore(db);

      final minted = await store.startTrip(
        starter: MemberId(you),
        starterDisplayName: 'You',
        now: DateTime.utc(2027, 6, 14, 9),
      );

      expect(minted.isCanonical, isTrue);
      final trip = await store.watchMembership().first;
      expect(trip!.tripId, minted);
    });

    test('two phones starting two trips do not start the same trip', () async {
      // The draw is `Random.secure`, and a trip id that two phones could
      // both mint is a trip two parties would sync into one.
      final ids = <String>{};
      for (var i = 0; i < 32; i++) {
        final db = inMemory();
        final id = await db.startTripIfAbsent(
          starterId: you,
          starterDisplayName: 'You',
        );
        expect(id.isCanonical, isTrue);
        ids.add(id.value);
        await db.close();
      }
      expect(ids, hasLength(32));
    });
  });

  group('an id is the trip\'s for good', () {
    test('starting again returns the id the trip already has', () async {
      // Accepting a second plan replaces the itinerary; it does not start a
      // second trip, and it must not renumber the first one.
      final db = inMemory();
      addTearDown(db.close);
      final store = MembershipStore(db);

      final first = await store.startTrip(
        starter: MemberId(you),
        starterDisplayName: 'You',
        now: DateTime.utc(2027, 6, 14, 9),
      );
      final again = await store.startTrip(
        starter: MemberId(you),
        starterDisplayName: 'You',
        now: DateTime.utc(2027, 6, 15, 9),
      );

      expect(again, first);
      expect((await db.readTripFacts())!.tripId, first.value);
    });

    test('it survives a relaunch', () async {
      final path = '${tempDirectory().path}/cairn.sqlite';

      var db = AppDatabase(NativeDatabase(File(path)));
      final minted = await db.startTripIfAbsent(
        starterId: you,
        starterDisplayName: 'You',
      );
      await db.close();

      // A second phone-full of randomness is available to this database and
      // it must not use any of it.
      db = AppDatabase(NativeDatabase(File(path)));
      addTearDown(db.close);
      expect((await db.readTripFacts())!.tripId, minted.value);
      expect(
        await db.startTripIfAbsent(starterId: you, starterDisplayName: 'You'),
        minted,
      );
    });

    test('renaming the trip does not renumber it', () async {
      final db = inMemory();
      addTearDown(db.close);
      final store = MembershipStore(db);

      final minted = await store.startTrip(
        starter: MemberId(you),
        starterDisplayName: 'You',
        now: DateTime.utc(2027, 6, 14, 9),
      );
      await store.rename('Japan');

      final trip = await store.watchMembership().first;
      expect(trip!.name, 'Japan');
      expect(trip.tripId, minted);
    });

    test('deleting the trip and starting another mints a new id', () async {
      // The one place a phone legitimately ends up on a different trip id.
      // The old one is gone rather than reused: a deleted trip is not a trip
      // that can be synced into afterwards.
      final db = inMemory();
      addTearDown(db.close);
      final store = MembershipStore(db);

      final first = await store.startTrip(
        starter: MemberId(you),
        starterDisplayName: 'You',
        now: DateTime.utc(2027, 6, 14, 9),
      );
      await store.deleteTrip();
      final second = await store.startTrip(
        starter: MemberId(you),
        starterDisplayName: 'You',
        now: DateTime.utc(2027, 6, 20, 9),
      );

      expect(second, isNot(first));
      expect(second.isCanonical, isTrue);
    });
  });

  group('a trip from before the mint existed', () {
    /// The pinned id v5 is told to mint, so the assertion can name it.
    final healed = TripId.mint(List.filled(16, 0x3c));

    test('is given a real id on the way to v5', () async {
      final path = '${tempDirectory().path}/cairn.sqlite';

      // Stand up exactly what a phone on the old build had: the trip's
      // tables, and the constant every trip on this phone used to carry.
      var db = AppDatabase(NativeDatabase(File(path)));
      await db.startTripIfAbsent(starterId: you, starterDisplayName: 'You');
      await db.customStatement("update trip_facts set trip_id = 'local-trip'");
      await windBackToV4(db);
      await db.close();

      db = AppDatabase(NativeDatabase(File(path)), mint: () => healed);
      addTearDown(db.close);

      final trip = await db.readTripFacts();
      expect(trip!.tripId, healed.value);
      expect(TripId(trip.tripId).isCanonical, isTrue);
    });

    test('and a trip that already has one is left alone', () async {
      final path = '${tempDirectory().path}/cairn.sqlite';

      var db = AppDatabase(NativeDatabase(File(path)));
      final minted = await db.startTripIfAbsent(
        starterId: you,
        starterDisplayName: 'You',
      );
      await windBackToV4(db);
      await db.close();

      db = AppDatabase(NativeDatabase(File(path)), mint: () => healed);
      addTearDown(db.close);

      expect(
        (await db.readTripFacts())!.tripId,
        minted.value,
        reason: 'the repair is for pre-mint ids, and only for those',
      );
    });

    test('a phone with no trip at all is not given one', () async {
      final path = '${tempDirectory().path}/cairn.sqlite';

      var db = AppDatabase(NativeDatabase(File(path)));
      await windBackToV4(db);
      await db.close();

      db = AppDatabase(NativeDatabase(File(path)), mint: () => healed);
      addTearDown(db.close);

      expect(await db.readTripFacts(), isNull);
    });
  });
}
