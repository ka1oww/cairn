import 'ids.dart';

/// Where a photo came from.
///
/// This changes how much its timestamp is worth, which matters because the
/// hour is part of the day page's composition rather than metadata in small
/// grey text (`docs/decisions/2026-08-22-design-calls.md`, "Times show,
/// prominently").
enum PhotoOrigin {
  /// The app took it, when it pinged this person. Its instant is known
  /// exactly.
  pinged,

  /// It came off the camera roll. Its instant was derived from EXIF, via the
  /// degradation ladder in `packages/photo_day_assignment` — which reports how
  /// it decided and how much to trust it. That evidence stays in that package;
  /// what reaches the domain is the answer.
  imported,
}

/// A reference to one photo in the shared pool: which day it belongs to, who
/// contributed it, and when it was taken.
///
/// The bytes are not here. They live in object storage under a key derived
/// from [id] (see `supabase/README.md` — Postgres is the index, R2 is blob
/// storage), and nothing in this package reads, writes, or names them.
final class PhotoRef {
  final PhotoId id;

  /// The 1-based day of the trip this photo belongs to.
  ///
  /// Deciding this is `packages/photo_day_assignment`'s job, and a person can
  /// always override it by hand (`photos.trip_day_is_manual`). By the time a
  /// photo is a [PhotoRef] the question is settled.
  final int dayNumber;

  /// Who contributed it. The backend enforces that this is the person doing
  /// the inserting and nobody else.
  final MemberId contributor;

  /// When the photo was taken, as a UTC instant.
  ///
  /// Always UTC — the constructor refuses anything else. What hour it *reads*
  /// as depends on whose clock you hold it up to, and on the day page that is
  /// always the day's own clock: `TripDay.clockTimeOf`.
  final DateTime takenAt;

  final PhotoOrigin origin;

  PhotoRef({
    required this.id,
    required this.dayNumber,
    required this.contributor,
    required this.takenAt,
    required this.origin,
  }) {
    if (dayNumber < 1) {
      throw ArgumentError.value(dayNumber, 'dayNumber', 'must be >= 1');
    }
    if (!takenAt.isUtc) {
      throw ArgumentError.value(
        takenAt,
        'takenAt',
        'must be a UTC instant — a local DateTime carries the device\'s '
            'timezone into the trip, which is exactly the bug this refuses',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PhotoRef &&
      other.id == id &&
      other.dayNumber == dayNumber &&
      other.contributor == contributor &&
      other.takenAt == takenAt &&
      other.origin == origin;

  @override
  int get hashCode => Object.hash(id, dayNumber, contributor, takenAt, origin);

  @override
  String toString() =>
      'PhotoRef(${id.value}, day $dayNumber, by ${contributor.value}, '
      '${takenAt.toIso8601String()}, ${origin.name})';
}
