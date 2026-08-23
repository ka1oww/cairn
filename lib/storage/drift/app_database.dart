// STORAGE band (docs/architecture.md): the Drift store. Knows Drift and the
// device disk; knows nothing of who asks. Queried only by repositories/.
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// The one row the scaffold persists: a working title for the trip this
/// phone is drafting. The real `trips` shape (clock, days, members — see
/// `packages/cairn_model` and `supabase/`) arrives with the first real
/// slice; this table exists to prove the stack end to end, and its data is
/// disposable until then.
class TripDrafts extends Table {
  /// Single-row table: the one draft is always row 0.
  IntColumn get id => integer()();
  TextColumn get name => text()();

  @override
  Set<Column> get primaryKey => {id};
}

const _draftRowId = 0;

@DriftDatabase(tables: [TripDrafts])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  Stream<TripDraft?> watchTripDraft() {
    final query = select(tripDrafts)..where((t) => t.id.equals(_draftRowId));
    return query.watchSingleOrNull();
  }

  Future<void> saveTripDraft(String name) {
    return into(tripDrafts).insertOnConflictUpdate(
      // The integer primary key aliases SQLite's rowid, so the generated
      // companion treats it as defaultable — hence Value(), not a bare int.
      TripDraftsCompanion.insert(id: const Value(_draftRowId), name: name),
    );
  }
}

/// Opens the on-device database. Native SQLite arrives through
/// `package:sqlite3` 3.x's build hooks (the successor to the end-of-life
/// `sqlite3_flutter_libs`); there is no web target and no wasm detour here —
/// that was the learning demo's compromise, not the app's.
AppDatabase openAppDatabase() => AppDatabase(driftDatabase(name: 'cairn'));
