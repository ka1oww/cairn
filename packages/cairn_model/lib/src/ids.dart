/// Shared base for this package's identifier types.
///
/// Identifiers are distinct types rather than bare `String`s so that a photo
/// id can never be handed to something expecting a member id. Two identifiers
/// of different types are never equal even when they wrap the same characters
/// — [runtimeType] is part of both [==] and [hashCode].
///
/// The string itself is whatever the layer below produces: a Supabase
/// `uuid` rendered as text for [MemberId] (`profiles.id`, which is
/// `auth.users.id`), [TripId] (`trips.id`) and [PhotoId] (`photos.id`).
/// This package never generates one — it has no I/O and no randomness.
abstract base class _Identifier {
  /// The opaque identifier, exactly as the storage layer spells it.
  final String value;

  const _Identifier(this.value)
      : assert(value != '', 'an identifier must not be empty');

  @override
  bool operator ==(Object other) =>
      other is _Identifier &&
      other.runtimeType == runtimeType &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => '$runtimeType($value)';
}

/// Identifies one trip.
final class TripId extends _Identifier {
  const TripId(super.value);
}

/// Identifies one person, for the whole of their account — not per trip.
///
/// The same person on two trips is the same [MemberId]; what differs is the
/// [Member] row that places them on each one.
final class MemberId extends _Identifier {
  const MemberId(super.value);
}

/// Identifies one photo in the shared pool.
///
/// The bytes behind it live in object storage under a key derived from this
/// id (see `supabase/README.md`); resolving that key is not this package's
/// concern.
final class PhotoId extends _Identifier {
  const PhotoId(super.value);
}
