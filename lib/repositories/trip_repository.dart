// THE SEAM (docs/architecture.md): the only layer that knows storage
// backends exist. Above it, a provider asks a question and cannot tell where
// the answer came from; below it, the store never learns who asked. When the
// Supabase/R2 adapter is built, it is consumed here and nowhere else.
import '../storage/drift/app_database.dart';

class TripRepository {
  TripRepository(this._db);

  final AppDatabase _db;

  /// The draft trip's working title, or null while none has been saved.
  ///
  /// Deliberately not a `cairn_model.Trip`, and deliberately no `TripId`:
  /// `cairn_model` says an id is "whatever the layer below produces — a
  /// Supabase uuid rendered as text", and a trip drafted offline has no
  /// Supabase row yet. Who mints a TripId before first sync is an open
  /// question the scaffold refuses to answer silently; see the scaffold PR.
  Stream<String?> watchTripName() =>
      _db.watchTripDraft().map((row) => row?.name);

  Future<void> saveTripName(String name) => _db.saveTripDraft(name);
}
