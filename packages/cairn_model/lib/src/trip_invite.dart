import 'ids.dart';
import 'invite_code.dart';
import 'trip_close.dart';

/// Where an invite code stands right now.
enum InviteStanding {
  /// It admits people.
  live,

  /// Somebody who was allowed to shut it did.
  revoked,

  /// Its trip has closed, so it opens nothing. See [tripClosesAt].
  expired,
}

/// One invite code that was minted for a trip.
///
/// **It carries no expiry of its own.** A code dies when its trip closes and
/// at no other time, so [standingAt] is told the trip's close rather than
/// remembering a second copy of it — see `trip_close.dart` for why one rule
/// stays one value.
///
/// Minting is flat: any member may mint one
/// (`docs/decisions/2026-08-22-starter-and-container.md` §3), which is why
/// [mintedBy] is a fact worth keeping — revoking belongs to whoever minted
/// it, or to the starter.
final class TripInvite {
  final InviteCode code;

  /// Who minted it.
  final MemberId mintedBy;

  /// When it was minted, in UTC.
  final DateTime mintedAt;

  /// When it was shut, in UTC, or null while it is still open. Rotating a
  /// code is minting a new one and revoking the old, never repointing this
  /// one at another trip.
  final DateTime? revokedAt;

  TripInvite({
    required this.code,
    required this.mintedBy,
    required DateTime mintedAt,
    DateTime? revokedAt,
  })  : mintedAt = _utc(mintedAt, 'mintedAt'),
        revokedAt = revokedAt == null ? null : _utc(revokedAt, 'revokedAt');

  /// Where this code stands at [now], on a trip that closes at
  /// [tripClosesAt].
  ///
  /// A null [tripClosesAt] is a trip whose end is not known yet — a plan
  /// accepted with its dates still open. Nothing has expired, because
  /// nothing has ended; the code takes the close the moment the plan has
  /// one. It is deliberately not read as "never expires".
  InviteStanding standingAt(DateTime now, {required DateTime? tripClosesAt}) {
    if (revokedAt != null) return InviteStanding.revoked;
    if (tripClosesAt != null && !now.toUtc().isBefore(tripClosesAt)) {
      return InviteStanding.expired;
    }
    return InviteStanding.live;
  }

  /// This code with [at] as the moment it was shut.
  TripInvite revoked(DateTime at) => TripInvite(
        code: code,
        mintedBy: mintedBy,
        mintedAt: mintedAt,
        revokedAt: at,
      );

  @override
  bool operator ==(Object other) =>
      other is TripInvite &&
      other.code == code &&
      other.mintedBy == mintedBy &&
      other.mintedAt == mintedAt &&
      other.revokedAt == revokedAt;

  @override
  int get hashCode => Object.hash(code, mintedBy, mintedAt, revokedAt);

  @override
  String toString() => 'TripInvite(${code.spoken}, by ${mintedBy.value})';
}

DateTime _utc(DateTime value, String name) {
  if (!value.isUtc) {
    throw ArgumentError.value(value, name, 'must be UTC');
  }
  return value;
}
