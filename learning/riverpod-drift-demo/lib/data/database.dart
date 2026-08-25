// This file is the whole "Drift problem" demo: real tables, a real SQLite
// file (or its web equivalent), and queries written in actual SQL-flavoured
// Dart rather than key/value blobs. Compare this to how you'd model the same
// three tables in Hive or Isar — there, "find photo counts per day" would
// mean loading every photo into memory and counting in Dart. Here it's one
// query, and the database engine does the counting.
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

// --- Tables -----------------------------------------------------------
//
// Drift tables are plain Dart classes. `build_runner` reads this file and
// generates `database.g.dart`, which contains the boring, error-prone code
// you'd otherwise hand-write for sqflite: CREATE TABLE strings, row-mapping
// functions, and typed column getters. That generated file is why this repo
// needs a codegen step (`dart run build_runner build`) before it will build —
// see the README's "what this demo does NOT show" section for the cost of
// that.

/// One row per (fake) trip. The real app only ever has one trip "current" at
/// a time, but modelling it as a table instead of a single global object
/// costs nothing and makes multi-trip support a future feature rather than a
/// rewrite.
class Trips extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
}

/// A stop on the itinerary, tagged with which day of the trip it belongs to.
/// `dayNumber` is deliberately a plain integer (1, 2, 3) rather than a real
/// calendar date — for this throwaway demo we only care about "day 1 of the
/// trip", not which calendar date that maps to.
class Stops extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get tripId => integer().references(Trips, #id)();
  IntColumn get dayNumber => integer()();
  TextColumn get name => text()();
}

/// A photo attached to a stop. This is the row the "add photo" button
/// inserts. Nothing in this table's definition, or anywhere else in this
/// file, knows that a UI badge exists — the UI finds out about new rows by
/// *watching a query*, not by being told directly. That's the link between
/// the Drift half of this demo and the Riverpod half: see
/// `lib/providers/trip_providers.dart`.
class Photos extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get stopId => integer().references(Stops, #id)();
  DateTimeColumn get takenAt => dateTime()();
}

/// One row per day, holding the count of photos taken that day. This is the
/// return type of the aggregate query below — a plain Dart class Drift can
/// map query results into, since "day + count" isn't one of the three
/// tables above.
class DayPhotoCount {
  final int dayNumber;
  final int photoCount;
  DayPhotoCount({required this.dayNumber, required this.photoCount});
}

@DriftDatabase(tables: [Trips, Stops, Photos])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  // Bump this and add a MigrationStrategy step whenever a table shape
  // changes. A fixed schema with no migrations is one of the things this
  // demo intentionally skips — see the README.
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    // Seeding lives in `beforeOpen`, guarded by an emptiness check,
    // rather than in `onCreate` alone. `onCreate` is *supposed* to fire
    // only the first time a database is created, but the web backend's
    // sharedIndexedDb storage (used here because this browser lacks
    // SharedArrayBuffer/nested-worker support — see the console log
    // when the app starts) does not reliably persist the schema-version
    // marker `onCreate` relies on, so it can fire again on a later
    // load even though the previous data is still there. Checking
    // "is the trips table actually empty?" is the only signal that
    // can't lie, so that's what guards the insert here. Native SQLite
    // on iOS does not have this quirk, but this guard is harmless there
    // too — it is a no-op on rows 2..n of the app's history regardless
    // of platform.
    beforeOpen: (details) async {
      final alreadySeeded = await select(trips).get();
      if (alreadySeeded.isNotEmpty) return;

      final tripId = await into(trips)
          .insert(const TripsCompanion(name: Value('Ember Team Coastal Loop')));
      final stopNames = <int, List<String>>{
        1: ['Ferry terminal', 'Old town market', 'Cliffside trail'],
        2: ['Harbour breakfast', 'Lighthouse museum', 'Sunset point'],
        3: ['Farmers market', 'Botanical garden', 'Airport'],
      };
      for (final entry in stopNames.entries) {
        for (final name in entry.value) {
          await into(stops).insert(
            StopsCompanion.insert(
              tripId: tripId,
              dayNumber: entry.key,
              name: name,
            ),
          );
        }
      }
    },
  );

  /// All stops for the trip, oldest day first. This is the "plain select"
  /// query the task asked us to also include, as a baseline to contrast
  /// against the aggregate query below.
  Future<List<Stop>> allStopsOrderedByDay() {
    return (select(
      stops,
    )..orderBy([(s) => OrderingTerm.asc(s.dayNumber)])).get();
  }

  /// Live count of photos taken on one specific day, as a Stream.
  ///
  /// `.watchSingle()` (via `.map((row) => row.read(...))`) is Drift's way of
  /// saying "re-run this query and push a new value every time a table it
  /// depends on changes" — Drift tracks table dependencies automatically, so
  /// inserting into `photos` is enough to wake this up. That stream is what
  /// a Riverpod StreamProvider watches in trip_providers.dart; nothing here
  /// needs to know that Riverpod exists.
  Stream<int> watchPhotoCountForDay(int dayNumber) {
    final countExp = photos.id.count();
    final query =
        selectOnly(photos)
            .join([innerJoin(stops, stops.id.equalsExp(photos.stopId))])
          ..addColumns([countExp])
          ..where(stops.dayNumber.equals(dayNumber));
    return query.watchSingle().map((row) => row.read(countExp) ?? 0);
  }

  /// Live count of every photo in the trip, regardless of day. Backs the
  /// Pool tab badge.
  Stream<int> watchTotalPhotoCount() {
    final countExp = photos.id.count();
    final query = selectOnly(photos)..addColumns([countExp]);
    return query.watchSingle().map((row) => row.read(countExp) ?? 0);
  }

  /// The aggregate query the task specifically asked for: photo counts
  /// grouped by day, computed by joining Stops to Photos and letting SQLite
  /// do the GROUP BY/COUNT. This is the line in the sand between "a real
  /// database" and a key-value store — Hive/Isar can store the same rows,
  /// but this exact query would have to be hand-rolled in Dart by loading
  /// every photo and tallying it yourself.
  Stream<List<DayPhotoCount>> watchPhotoCountsPerDay() {
    final countExp = photos.id.count();
    final query =
        selectOnly(stops)
            .join([innerJoin(photos, photos.stopId.equalsExp(stops.id))])
          ..addColumns([stops.dayNumber, countExp])
          ..groupBy([stops.dayNumber])
          ..orderBy([OrderingTerm.asc(stops.dayNumber)]);
    return query.watch().map(
      (rows) => rows
          .map(
            (row) => DayPhotoCount(
              dayNumber: row.read(stops.dayNumber)!,
              photoCount: row.read(countExp) ?? 0,
            ),
          )
          .toList(),
    );
  }

  /// Attaches a new photo to the first stop of the given day. Stands in for
  /// "a photo finished uploading" in the real app. Note there is nothing
  /// Riverpod- or widget-shaped anywhere in this function: it just writes a
  /// row. Every screen watching a query above finds out on its own.
  Future<void> addPhotoToDay(int dayNumber) async {
    final dayStops =
        await (select(stops)
              ..where((s) => s.dayNumber.equals(dayNumber))
              ..limit(1))
            .get();
    if (dayStops.isEmpty) return;
    await into(photos).insert(
      PhotosCompanion.insert(
        stopId: dayStops.first.id,
        takenAt: DateTime.now(),
      ),
    );
  }
}

/// Opens the platform-appropriate backend for this database.
///
/// `driftDatabase()` (from `package:drift_flutter`) picks native SQLite via
/// FFI on macOS/iOS/Android/desktop, and a WebAssembly build of SQLite
/// (compiled to `web/sqlite3.wasm`, driven from a worker at
/// `web/drift_worker.js`) when compiled to the web. That's the one piece of
/// platform-specific plumbing Drift needs — everything above this line is
/// the same Dart on every platform. The real app will run this exact same
/// query/table code on iOS using the native branch; only this connection
/// function differs, and only because we're demoing on web instead of iOS.
QueryExecutor _openConnection() {
  return driftDatabase(
    name: 'riverpod_drift_demo',
    web: DriftWebOptions(
      sqlite3Wasm: Uri.parse('sqlite3.wasm'),
      driftWorker: Uri.parse('drift_worker.js'),
    ),
  );
}
