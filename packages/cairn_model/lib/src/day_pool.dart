import 'equality.dart';
import 'ids.dart';
import 'photo_ref.dart';

/// One day's slice of the shared photo pool: the photos still in it, and
/// everyone who has ever put one there.
///
/// The two are tracked separately on purpose, and it is the only reason this
/// type exists rather than a bare `List<PhotoRef>`.
///
/// A person can delete their own photo, and **the day stays open when they
/// do**. Contributing is something a person did; a photo is a thing that
/// exists. Deleting the thing does not undo the act, and access already earned
/// must not be quietly revoked — someone tidying up a bad shot should not find
/// themselves locked out of a day they answered. So [deletePhoto] removes from
/// [photos] and never touches [contributors], and there is no operation on
/// this class that removes a contributor at all.
///
/// The one way to lose that: rebuilding a pool with [DayPool.of] from the
/// photos that survived, which seeds [contributors] from those photos alone.
/// When you reload a day from storage, use [DayPool.restore] and pass the
/// contributor set you persisted.
final class DayPool {
  /// The 1-based trip day this pool holds.
  final int dayNumber;

  /// The photos still in the pool, oldest first.
  ///
  /// Ordering is the constructor's job, not the caller's: the day page is a
  /// vertical timeline in the order things happened
  /// (`docs/decisions/2026-08-22-design-calls.md`), so a pool that could hand
  /// back an arbitrary order would be one more thing every layer had to
  /// remember to sort. Ties break on photo id so the order is total and
  /// stable.
  final List<PhotoRef> photos;

  /// Everyone who has contributed a photo to this day, including anyone whose
  /// photo has since been deleted.
  final Set<MemberId> contributors;

  DayPool._(this.dayNumber, List<PhotoRef> photos, Set<MemberId> contributors)
      : photos = List.unmodifiable(photos),
        contributors = Set.unmodifiable(contributors);

  /// A day nobody has contributed to yet.
  factory DayPool.empty(int dayNumber) {
    _validateDayNumber(dayNumber);
    return DayPool._(dayNumber, const [], const {});
  }

  /// A pool of exactly these photos, with [contributors] seeded from them.
  ///
  /// Right for a pool being built up from what is in front of you. Wrong for
  /// reloading a day whose contributors may have deleted their photos — see
  /// [DayPool.restore].
  factory DayPool.of(int dayNumber, Iterable<PhotoRef> photos) =>
      DayPool.restore(
        dayNumber: dayNumber,
        photos: photos,
        contributors: photos.map((photo) => photo.contributor),
      );

  /// A pool rebuilt from storage: these photos, and this contributor set,
  /// which may name people whose photos are gone.
  factory DayPool.restore({
    required int dayNumber,
    required Iterable<PhotoRef> photos,
    required Iterable<MemberId> contributors,
  }) {
    _validateDayNumber(dayNumber);
    final ordered = photos.toList();
    final seen = <PhotoId>{};
    for (final photo in ordered) {
      if (photo.dayNumber != dayNumber) {
        throw ArgumentError.value(
          photo,
          'photos',
          'belongs to day ${photo.dayNumber}, not day $dayNumber',
        );
      }
      if (!seen.add(photo.id)) {
        throw ArgumentError.value(
          photo.id,
          'photos',
          'the same photo appears twice in this day',
        );
      }
    }
    ordered.sort(_byTimeThenId);
    return DayPool._(dayNumber, ordered, contributors.toSet());
  }

  /// This pool with [photo] added, and its contributor recorded.
  DayPool add(PhotoRef photo) => DayPool.restore(
        dayNumber: dayNumber,
        photos: [...photos, photo],
        contributors: [...contributors, photo.contributor],
      );

  /// This pool with [photoId] gone, deleted by [by].
  ///
  /// Only the photo's own contributor may delete it; anyone else is an
  /// [ArgumentError], not a silent no-op. The contributor set is untouched,
  /// which is what keeps the day open afterwards.
  DayPool deletePhoto(PhotoId photoId, {required MemberId by}) {
    final matches = photos.where((candidate) => candidate.id == photoId);
    if (matches.isEmpty) {
      throw ArgumentError.value(
        photoId,
        'photoId',
        'no such photo on day $dayNumber',
      );
    }
    if (matches.first.contributor != by) {
      throw ArgumentError.value(
        by,
        'by',
        'only the person who contributed a photo can delete it',
      );
    }
    return DayPool.restore(
      dayNumber: dayNumber,
      photos: photos.where((candidate) => candidate.id != photoId),
      contributors: contributors,
    );
  }

  /// Whether [member] has ever contributed to this day. This is what the gate
  /// asks.
  bool hasContributed(MemberId member) => contributors.contains(member);

  /// True when no photo is in the pool. Not the same as "nobody contributed":
  /// a day whose only photo was deleted is empty but has a contributor.
  bool get isEmpty => photos.isEmpty;

  static void _validateDayNumber(int dayNumber) {
    if (dayNumber < 1) {
      throw ArgumentError.value(
          dayNumber, 'dayNumber', 'day numbers start at 1');
    }
  }

  static int _byTimeThenId(PhotoRef a, PhotoRef b) {
    final byTime = a.takenAt.compareTo(b.takenAt);
    return byTime != 0 ? byTime : a.id.value.compareTo(b.id.value);
  }

  @override
  bool operator ==(Object other) =>
      other is DayPool &&
      other.dayNumber == dayNumber &&
      listEquals(other.photos, photos) &&
      setEquals(other.contributors, contributors);

  @override
  int get hashCode => Object.hash(
        dayNumber,
        Object.hashAll(photos),
        Object.hashAllUnordered(contributors),
      );

  @override
  String toString() => 'DayPool(day $dayNumber, ${photos.length} photos, '
      '${contributors.length} contributors)';
}
