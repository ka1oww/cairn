// STORAGE band (docs/architecture.md): the Drift store. Knows Drift and the
// device disk; knows nothing of who asks. Queried only by repositories/.
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// One day of the confirmed itinerary, as accepted on the paste-and-confirm
/// screen. The date is nullable on purpose: the parser never guesses a date
/// it cannot resolve, and a person is allowed to accept the plan with a date
/// still open (docs/decisions/2026-08-22-paste-confirmation.md).
class ItineraryDays extends Table {
  /// 1-based position in the trip; the itinerary's one ordering.
  IntColumn get number => integer()();

  /// `YYYY-MM-DD` (`cairn_model.CalendarDate.iso`), or null while unresolved.
  TextColumn get dateIso => text().nullable()();

  TextColumn get place => text().nullable()();

  @override
  Set<Column> get primaryKey => {number};
}

/// A stop under a day, in itinerary order. The star is not a column: a stop
/// is starred exactly when [timeIso] is present — the star rule lives in
/// `cairn_model.Stop.isStarred` and storing it separately would let the two
/// drift apart.
class ItineraryStops extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get dayNumber => integer().references(ItineraryDays, #number)();

  /// Order within the day, 0-based.
  IntColumn get position => integer()();

  TextColumn get stopText => text()();

  /// `HH:MM` (`cairn_model.ClockTime.iso`), or null for an untimed stop.
  TextColumn get timeIso => text().nullable()();
}

/// A pasted line the parser set aside instead of placing — kept with its
/// person-showable reason, never silently dropped ("the trip's pocket" in
/// design round 8). Stored so the kept lines survive the confirmation screen
/// and can be placed by hand in a later slice.
class ItinerarySetAsides extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Order the lines are shown in, 0-based.
  IntColumn get position => integer()();

  /// 1-based line number in the original paste.
  IntColumn get sourceLineNumber => integer()();

  TextColumn get lineText => text()();

  /// The parser's person-showable sentence for why the line was set aside.
  TextColumn get explanation => text()();
}

@DriftDatabase(tables: [ItineraryDays, ItineraryStops, ItinerarySetAsides])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // v1 was the scaffold's single disposable trip_drafts row,
            // documented as demo data from the day it landed; the itinerary
            // tables replace it and nothing carries over.
            await m.deleteTable('trip_drafts');
            await m.createAll();
          }
        },
      );

  /// The saved itinerary's days, in trip order. This is the stream the
  /// repository hangs its itinerary watch on: every write path here replaces
  /// all three tables in one transaction, so a change to stops or set-aside
  /// lines always arrives with a change to this table.
  Stream<List<ItineraryDay>> watchItineraryDays() =>
      (select(itineraryDays)..orderBy([(t) => OrderingTerm.asc(t.number)]))
          .watch();

  Future<List<ItineraryStop>> readItineraryStops() => (select(itineraryStops)
        ..orderBy([
          (t) => OrderingTerm.asc(t.dayNumber),
          (t) => OrderingTerm.asc(t.position),
        ]))
      .get();

  Future<List<ItinerarySetAside>> readItinerarySetAsides() =>
      (select(itinerarySetAsides)
            ..orderBy([(t) => OrderingTerm.asc(t.position)]))
          .get();

  /// Replaces the stored itinerary wholesale, atomically. There is one
  /// itinerary per phone in this slice (the trip is local-only until
  /// cairn-shared-state-sync), so "save" means "replace".
  ///
  /// Takes plain records rather than Drift companions so the repository
  /// above needs no Drift import — the seam may only know this band's
  /// surface, not its library (`lib/README.md`).
  Future<void> replaceItinerary({
    required List<ItineraryDayRecord> days,
    required List<ItineraryStopRecord> stops,
    required List<ItinerarySetAsideRecord> setAsides,
  }) {
    return transaction(() async {
      await delete(itineraryStops).go();
      await delete(itinerarySetAsides).go();
      await delete(itineraryDays).go();
      await batch((b) {
        b.insertAll(itineraryDays, [
          for (final day in days)
            ItineraryDaysCompanion.insert(
              number: Value(day.number),
              dateIso: Value(day.dateIso),
              place: Value(day.place),
            ),
        ]);
        b.insertAll(itineraryStops, [
          for (final stop in stops)
            ItineraryStopsCompanion.insert(
              dayNumber: stop.dayNumber,
              position: stop.position,
              stopText: stop.text,
              timeIso: Value(stop.timeIso),
            ),
        ]);
        b.insertAll(itinerarySetAsides, [
          for (final line in setAsides)
            ItinerarySetAsidesCompanion.insert(
              position: line.position,
              sourceLineNumber: line.sourceLineNumber,
              lineText: line.text,
              explanation: line.explanation,
            ),
        ]);
      });
    });
  }
}

/// The write-side shapes [AppDatabase.replaceItinerary] accepts.
typedef ItineraryDayRecord = ({int number, String? dateIso, String? place});
typedef ItineraryStopRecord = ({
  int dayNumber,
  int position,
  String text,
  String? timeIso,
});
typedef ItinerarySetAsideRecord = ({
  int position,
  int sourceLineNumber,
  String text,
  String explanation,
});

/// Opens the on-device database. Native SQLite arrives through
/// `package:sqlite3` 3.x's build hooks (the successor to the end-of-life
/// `sqlite3_flutter_libs`); there is no web target and no wasm detour here —
/// that was the learning demo's compromise, not the app's.
AppDatabase openAppDatabase() => AppDatabase(driftDatabase(name: 'cairn'));
