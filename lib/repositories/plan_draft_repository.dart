// THE SEAM (docs/architecture.md): the only layer that knows storage
// backends exist. This one is deliberately the smallest seam in the app —
// the paste box's pending import is a single string on a single phone.
//
// It is local and stays local. The pending import is pre-accept text: it has
// no trip, no day numbers and no clock, so there is nothing about it eight
// phones could agree on. `itinerary_sync.dart` is where a shared fact goes;
// this is not one, and adding it there would push a half-read scan at
// everybody on the trip.
import '../storage/drift/app_database.dart';

class PlanDraftRepository {
  PlanDraftRepository(this._db);

  final AppDatabase _db;

  /// The pending import, or null when there is none.
  Future<String?> read() => _db.readPlanDraft();

  /// Starts (or replaces) the draft. Only an import that landed calls this.
  Future<void> write(String text) => _db.writePlanDraft(text);

  /// Updates a draft that already exists, and creates nothing.
  Future<void> overwriteIfPresent(String text) =>
      _db.updatePlanDraftIfPresent(text);

  Future<void> clear() => _db.clearPlanDraft();
}
