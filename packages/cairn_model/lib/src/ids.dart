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
///
/// **This package still has no randomness**, so it invents no identifier of
/// its own. [TripId.mint] is the one place that builds an identifier rather
/// than accepting one, and it is a *formatter*: the caller brings sixteen
/// random bytes, exactly as `InviteCode.draw` takes three numbers a caller
/// already has.
abstract base class _Identifier {
  /// The opaque identifier, exactly as the storage layer spells it.
  final String value;

  _Identifier(this.value) {
    if (value == '') {
      throw ArgumentError.value(
          value, 'value', 'an identifier must not be empty');
    }
  }

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
///
/// **The phone mints it, before the trip has ever been near a server**
/// (`docs/decisions/2026-08-25-the-trip-mints-its-own-id.md`). A trip can be
/// started with no connection, so nothing may wait on a round trip to learn
/// what the trip is called in the one place every layer names it — and the
/// ping schedule seeds itself from this string, so an id that changed at
/// first sync would silently re-deal every remaining day of the trip.
///
/// The canonical spelling is one RFC 4122 version-4 uuid in the lower-case
/// hyphenated form Postgres reads back, because `trips.id` is a `uuid`
/// column: an id the phone minted is the id the server keeps, and that only
/// works if the phone mints something the column will accept.
final class TripId extends _Identifier {
  TripId(super.value);

  /// Formats sixteen random bytes as one version-4 uuid.
  ///
  /// It takes the randomness rather than drawing it, the way
  /// `InviteCode.draw` takes three numbers: this package has no source of
  /// entropy and is not about to grow one. Where the bytes come from is the
  /// app's store's business (`lib/storage/drift/app_database.dart`).
  ///
  /// [bytes] must be exactly sixteen values in 0..255. The version and
  /// variant nibbles are overwritten here, so a caller that hands over
  /// sixteen bytes of a weaker source gets a well-formed uuid over weak
  /// entropy — the shape is this function's promise, the randomness is the
  /// caller's.
  factory TripId.mint(List<int> bytes) => TripId(_uuidFrom(bytes));

  /// Whether this id is spelled the way [TripId.mint] spells one, and so the
  /// way `trips.id` will accept it when the trip first syncs.
  ///
  /// It is a question about the *spelling*, not about provenance: it cannot
  /// tell a phone-minted id from a server-minted one, and is not meant to —
  /// the whole point of the decision is that those are the same thing. What
  /// it does catch is an id from before the mint existed, which is what the
  /// store's migration uses it for.
  bool get isCanonical => _canonicalUuid.hasMatch(value);
}

final RegExp _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Sixteen bytes as one lower-case hyphenated version-4 uuid.
///
/// Written once because two identifiers now mint one — a trip's and a
/// photo's — and both have to be spelled the way a Postgres `uuid` column
/// reads back. Two copies of this would be two chances to disagree about a
/// nibble, and the disagreement would only surface on the first real round
/// trip.
String _uuidFrom(List<int> bytes) {
  if (bytes.length != 16) {
    throw ArgumentError.value(
        bytes.length, 'bytes', 'a uuid is made of exactly sixteen bytes');
  }
  final octets = List<int>.generate(16, (i) {
    final byte = bytes[i];
    if (byte < 0 || byte > 255) {
      throw ArgumentError.value(byte, 'bytes', 'every byte must be 0..255');
    }
    return byte;
  }, growable: false);
  octets[6] = (octets[6] & 0x0f) | 0x40; // version 4
  octets[8] = (octets[8] & 0x3f) | 0x80; // variant 10xx (RFC 4122)
  final hex = [
    for (final byte in octets) byte.toRadixString(16).padLeft(2, '0'),
  ];
  return '${hex.sublist(0, 4).join()}-'
      '${hex.sublist(4, 6).join()}-'
      '${hex.sublist(6, 8).join()}-'
      '${hex.sublist(8, 10).join()}-'
      '${hex.sublist(10, 16).join()}';
}

/// Identifies one person, for the whole of their account — not per trip.
///
/// The same person on two trips is the same [MemberId]; what differs is the
/// [Member] row that places them on each one.
final class MemberId extends _Identifier {
  MemberId(super.value);
}

/// Identifies one photo in the shared pool.
///
/// The bytes behind it live in object storage under a key derived from this
/// id (see `supabase/README.md`); resolving that key is not this package's
/// concern.
///
/// **The phone mints it**, exactly as it mints a [TripId] and for a related
/// reason: a photograph is taken and kept before anything asks the network,
/// and the id it is kept under is the id the server has to accept. So the
/// canonical spelling is one RFC 4122 version-4 uuid, lower-case and
/// hyphenated, because `photos.id` is a `uuid` column
/// (`supabase/migrations/0006_photos.sql`) and the upload function refuses
/// any other spelling before it will sign anything
/// (`supabase/functions/r2-upload-url/handler.ts`).
final class PhotoId extends _Identifier {
  PhotoId(super.value);

  /// Formats sixteen random bytes as one version-4 uuid.
  ///
  /// It takes the randomness rather than drawing it, exactly as
  /// [TripId.mint] does: this package has no source of entropy. Where the
  /// bytes come from is the seam's business
  /// (`lib/repositories/photo_repository.dart`).
  factory PhotoId.mint(List<int> bytes) => PhotoId(_uuidFrom(bytes));

  /// Whether this id is spelled the way `photos.id` will accept it.
  bool get isCanonical => _canonicalUuid.hasMatch(value);
}
