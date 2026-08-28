// THE SEAM (docs/architecture.md): the only layer that knows storage
// backends exist. Above it, a provider asks "the trip's photos" or "keep this
// frame on day 4" and cannot tell — by construction — whether the answer is a
// SQLite row on this phone or a round trip to a shared pool. Below it, the
// store never learns who asked.
//
// This file has two halves that arrived from opposite directions and are
// deliberately still distinguishable:
//
// - **The read side is an interface.** The Pool was built against the *shape*
//   of the seam before anything wrote a photo, which is why [PhotoRepository]
//   is abstract and why [InMemoryPhotoPool] exists. Nothing above this layer
//   may name a concrete implementation.
// - **The write side is one concrete store.** [PhotoStore] is the Drift-backed
//   implementation: it answers the read interface *and* owns keeping a frame
//   and writing a word. When the Supabase/R2 adapter is built it is consumed
//   here — the outbox ordering the map names (bytes to R2 first, row second)
//   belongs in this class and nowhere else.
//
// Dialect translation happens here as it does for the itinerary: rows go up
// as `cairn_model` vocabulary (`PhotoRef`) and come down as plain records, so
// neither the band above nor the band below has to know the other's spelling.
import 'dart:math';

import 'package:cairn_model/cairn_model.dart';

import '../storage/drift/app_database.dart';

/// One photo in the trip's shared pool, as the seam hands it up.
///
/// The [ref] is the domain's own word for a photo — which day it belongs to,
/// who contributed it, when it was taken. The other two fields are the facts
/// `PhotoRef` deliberately refuses to carry: where the bytes sit is a property
/// of *this device*, and the word is authored text that rides the photo rather
/// than identifying it. Keeping both outside `PhotoRef` is what lets the same
/// reference survive the move to a shared pool unchanged.
class PooledPhoto {
  final PhotoRef ref;

  /// An absolute path to the image file on this device, or null when the
  /// bytes are not here.
  ///
  /// Null is not a defect and not a loading state. The pool is shared by eight
  /// people and stores originals
  /// (`docs/decisions/2026-08-22-grill-round-one.md` §3); a photo somebody
  /// else took is a real row in the index long before its bytes have been
  /// fetched here. Today it is non-null for exactly the photos this phone took
  /// itself, because nothing fetches anyone else's yet.
  final String? localPath;

  /// The line written at the capture breath, or null. Null is the usual.
  final String? word;

  const PooledPhoto({required this.ref, this.localPath, this.word});
}

/// The trip's shared photo pool, read-only.
///
/// One question, because the Pool asks one: every photo of the trip, in one
/// pool everyone can see. Grouping them by day is the app-state layer's job
/// (`lib/app_state/pool_view.dart`) and needs no second query — `PhotoRef`
/// already carries the day it was assigned to.
abstract interface class PhotoRepository {
  /// Every photo in the trip's pool, re-emitting when the pool changes.
  ///
  /// Unordered as far as this interface is concerned: what order a day's
  /// photos are shown in is `cairn_model.DayPool`'s rule, applied above this
  /// layer, so a store is never asked to remember it too.
  Stream<List<PooledPhoto>> watchTripPhotos();
}

/// The pool held in memory: no store, no writes, seeded once at construction.
///
/// It was what the app bound before anything could take a photo. It stays for
/// the tests that want a pool of a known shape without a database behind it —
/// the Pool's own tests read through it, and reading a fixture is not the same
/// exercise as reading what capture actually wrote.
///
/// It emits once and completes, because nothing can change it.
class InMemoryPhotoPool implements PhotoRepository {
  InMemoryPhotoPool([Iterable<PooledPhoto> photos = const []])
    : _photos = List.unmodifiable(photos);

  final List<PooledPhoto> _photos;

  @override
  Stream<List<PooledPhoto>> watchTripPhotos() => Stream.value(_photos);
}

/// Mints a local photo id.
///
/// `cairn_model` will not draw the randomness — it has no I/O and no entropy —
/// and the bands above the seam should not be inventing storage identity, so
/// the draw happens here and `PhotoId.mint` does the formatting, exactly the
/// split `mintTripId` and `TripId.mint` already use.
typedef PhotoIdMinter = String Function();

/// Sixteen bytes of the platform's secure randomness, spelled as one uuid.
///
/// **The spelling is the whole point, and it used to be wrong**: this drew the
/// same sixteen bytes but wrote them as thirty-two undashed hex characters,
/// which no `uuid` column accepts and which `r2-upload-url` refuses outright
/// before it will sign anything. The two halves of that seam had never been
/// run against each other, so the first real upload would have been the first
/// thing to notice. `test/photo_id_format_test.dart` compares them now.
String mintPhotoId() {
  final random = Random.secure();
  return PhotoId.mint([for (var i = 0; i < 16; i++) random.nextInt(256)]).value;
}

/// The photo pool with a store behind it: the read interface above, plus the
/// write path capture answers the ping through.
///
/// This is the implementation the app binds. It satisfies [PhotoRepository]
/// and re-emits after every write, which is the contract the Pool's screen was
/// written against — so the photo you take appears in the pool with no wiring
/// between the two features at all.
class PhotoStore implements PhotoRepository {
  /// [mintId] exists for tests, which pin the ids so an assertion can name
  /// one; every other caller takes the random minter.
  PhotoStore(this._db, {this.mintId = mintPhotoId});

  final AppDatabase _db;
  final PhotoIdMinter mintId;

  /// Every photo on this phone, oldest first.
  ///
  /// One stream serves every photo surface — the Pool's grid, the day page's
  /// timeline, the Trail's filled node — for the same reason one stream serves
  /// every itinerary question: two subscriptions are two chances to disagree
  /// about what the trip holds.
  @override
  Stream<List<PooledPhoto>> watchTripPhotos() =>
      _db.watchPhotos().map((rows) => [for (final row in rows) _toPhoto(row)]);

  /// The photos on one day of the plan, oldest first.
  Stream<List<PooledPhoto>> watchPhotosForDay(int dayNumber) =>
      watchTripPhotos().map(
        (photos) => [
          for (final p in photos)
            if (p.ref.dayNumber == dayNumber) p,
        ],
      );

  /// Keeps one photo, and hands back the reference to it.
  ///
  /// [takenAt] must be UTC — `PhotoRef` refuses anything else, and this is
  /// the boundary where that refusal is worth having: a local `DateTime`
  /// here would carry the device's timezone into the trip's record.
  ///
  /// [word] is stored exactly as it was typed. A blank or whitespace-only
  /// line is stored as no word at all, because silence is the default the
  /// capture sheet is shaped around and an empty string is not a shorter
  /// sentence — it is the absence of one.
  Future<PooledPhoto> keep({
    required int dayNumber,
    required MemberId contributor,
    required DateTime takenAt,
    required PhotoOrigin origin,
    required String filePath,
    String? word,
  }) async {
    final ref = PhotoRef(
      id: PhotoId(mintId()),
      dayNumber: dayNumber,
      contributor: contributor,
      takenAt: takenAt,
      origin: origin,
    );
    final kept = word == null || word.trim().isEmpty ? null : word;
    await _db.insertPhoto((
      id: ref.id.value,
      dayNumber: ref.dayNumber,
      contributorId: ref.contributor.value,
      takenAtUtcIso: ref.takenAt.toIso8601String(),
      origin: ref.origin.name,
      word: kept,
      filePath: filePath,
    ));
    return PooledPhoto(ref: ref, localPath: filePath, word: kept);
  }

  /// Rewrites one photo's word, or clears it with a blank line.
  ///
  /// The line stays writable on your own print until the trip closes
  /// (design round 10, `18c`); *whose* print may be written on is a rule
  /// for the band above, not for the store.
  Future<void> writeWord(PhotoId id, String? word) => _db.updatePhotoWord(
    id: id.value,
    word: word == null || word.trim().isEmpty ? null : word,
  );

  static PooledPhoto _toPhoto(Photo row) => PooledPhoto(
    ref: PhotoRef(
      id: PhotoId(row.id),
      dayNumber: row.dayNumber,
      contributor: MemberId(row.contributorId),
      takenAt: DateTime.parse(row.takenAtUtcIso).toUtc(),
      origin: PhotoOrigin.values.firstWhere(
        (o) => o.name == row.origin,
        // A row whose origin we cannot read is still a real photograph;
        // losing it would be worse than reading its instant as merely
        // derived, which is what `imported` already means.
        orElse: () => PhotoOrigin.imported,
      ),
    ),
    localPath: row.filePath,
    word: row.word,
  );
}
