// THE SEAM (docs/architecture.md): the only layer that knows storage
// backends exist. Above it, a provider asks "who is on this trip" and cannot
// tell whether the answer is a SQLite row or a round trip to Postgres; below
// it, the store never learns who asked.
//
// This file has the same two halves the photo seam has, for the same reason:
//
// - **The read side is an interface.** [MembershipRepository] is what the
//   trip's surfaces and the ping's derivation are written against, and
//   [InMemoryMembership] is how a test hands them a party of eight without a
//   phone that could ever have met eight people. Nothing above this layer may
//   name a concrete implementation.
// - **The write side is one concrete store.** [MembershipStore] is the
//   Drift-backed implementation: it answers the read interface *and* owns
//   starting the trip, renaming it, minting and revoking codes, and deleting
//   the whole thing. When the Supabase adapter is built it is consumed here.
//
// **What is local-only, and what waits for Phase 2.** Everything here is one
// phone's record. A code minted here is real, canonical and revocable, and
// redeeming one is answered honestly (`lib/app_state/join_flow.dart`) — but
// nothing carries a membership between phones, so the roster this store can
// write has exactly one person in it. The interface is the shape the
// propagated roster lands in; the derivation above it already deals eight.
import 'dart:math';

import 'package:cairn_model/cairn_model.dart';

import '../storage/drift/app_database.dart';

/// The trip as the seam hands it up: who is on it, who started it, what it is
/// called, and the codes minted for it.
///
/// Deliberately not a `cairn_model.Trip`: a `Trip` requires resolved dates
/// and a trip clock for every day, and a plan may be accepted with its dates
/// still open. The vocabulary inside it *is* the model's — `Member`,
/// `MemberId`, `TripInvite` — so no band above has to translate one.
class TripMembership {
  /// The trip's id: what the ping derivation seeds itself from.
  final String tripId;

  /// What the trip is called, or null while nobody has named it. Naming is
  /// flat, so this is nobody's in particular.
  final String? name;

  /// Who started the trip. They may have left; see
  /// `cairn_model`'s `removalPowerHolder`, which is the only thing that
  /// answers "who holds the removal power".
  final MemberId startedBy;

  /// Everyone on the trip, longest-standing first and then by id — one
  /// stable order, the same on every phone. Unmodifiable.
  final List<Member> members;

  /// Every code ever minted for this trip, oldest first, revoked ones
  /// included: a revoked code is a fact about the trip, and dropping it here
  /// would make a redemption of it indistinguishable from a code nobody ever
  /// minted. Unmodifiable.
  final List<TripInvite> invites;

  TripMembership({
    required this.tripId,
    this.name,
    required this.startedBy,
    required List<Member> members,
    List<TripInvite> invites = const [],
  })  : members = List.unmodifiable(members),
        invites = List.unmodifiable(invites);
}

/// The trip's roster and its codes, read-only.
abstract interface class MembershipRepository {
  /// The trip on this phone, or null while none has been started.
  /// Re-emits after every write.
  Stream<TripMembership?> watchMembership();
}

/// A trip held in memory: no store, no writes, seeded once at construction.
///
/// It is how a test stands the party up at the size the product is actually
/// for. A phone cannot reach eight people yet, and the schedule's whole
/// promise — that no two of eight collide — is only worth anything when it is
/// asserted against eight.
class InMemoryMembership implements MembershipRepository {
  InMemoryMembership(this._membership);

  final TripMembership? _membership;

  @override
  Stream<TripMembership?> watchMembership() => Stream.value(_membership);
}

/// Mints the code's three numbers. A test pins them so an assertion can name
/// a code; every other caller takes [_drawAtRandom].
typedef InviteDraw = ({int firstWord, int secondWord, int number});

InviteDraw _drawAtRandom() {
  final random = Random.secure();
  return (
    firstWord: random.nextInt(1 << 32),
    secondWord: random.nextInt(1 << 32),
    number: random.nextInt(1 << 32),
  );
}

/// The trip with a store behind it: the read interface above, plus every
/// write the trip's own surfaces make.
class MembershipStore implements MembershipRepository {
  MembershipStore(this._db, {this.draw = _drawAtRandom});

  final AppDatabase _db;

  /// Where a code's randomness comes from. `cairn_model` has none — it turns
  /// three numbers into a code and refuses to invent them — so the draw
  /// happens here, the way a photo id is minted here.
  final InviteDraw Function() draw;

  @override
  Stream<TripMembership?> watchMembership() =>
      _db.watchTripFacts().asyncMap((trip) async {
        if (trip == null) return null;
        final members = await _db.readTripMembers();
        final codes = await _db.readTripInviteCodes();
        return TripMembership(
          tripId: trip.tripId,
          name: trip.name,
          startedBy: MemberId(trip.startedByMemberId),
          members: [
            for (final row in members)
              Member(
                id: MemberId(row.id),
                displayName: row.displayName,
                joinedOnDay: row.joinedOnDay,
              ),
          ],
          invites: [
            for (final row in codes)
              if (InviteCode.tryParse(row.code) case final code?)
                TripInvite(
                  code: code,
                  mintedBy: MemberId(row.mintedByMemberId),
                  mintedAt: DateTime.parse(row.mintedAtUtcIso).toUtc(),
                  revokedAt: row.revokedAtUtcIso == null
                      ? null
                      : DateTime.parse(row.revokedAtUtcIso!).toUtc(),
                ),
          ],
        );
      });

  /// Starts the trip, if this phone has not started one, and gives it its
  /// first code.
  ///
  /// Accepting a pasted plan is what starts a trip — there is no other door,
  /// and the person who accepted it is the starter. Idempotent, because
  /// pasting a different plan replaces the itinerary and replacing your own
  /// itinerary is not starting a second trip.
  ///
  /// The code is minted here rather than waiting to be asked for, because
  /// "eight people can join with three spoken words" is the first release's
  /// own line (docs/decisions/2026-08-22-first-release.md) and a trip whose
  /// code has to be summoned first is a trip nobody can be let into while
  /// the phone is in somebody else's hand.
  Future<void> startTrip({
    required String tripId,
    required MemberId starter,
    required String starterDisplayName,
    required DateTime now,
  }) async {
    await _db.startTripIfAbsent(
      tripId: tripId,
      starterId: starter.value,
      starterDisplayName: starterDisplayName,
    );
    if ((await _db.readTripInviteCodes()).isEmpty) {
      await mintInvite(by: starter, now: now);
    }
  }

  /// Renames the trip, or clears the name with a blank. Any member may
  /// (docs/decisions/2026-08-22-starter-and-container.md §2); *who* is asking
  /// is checked above this layer, where the roster is known.
  Future<void> rename(String? name) {
    final trimmed = name?.trim();
    return _db.renameTrip(
      trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
  }

  /// Mints one code for this trip and hands it back.
  ///
  /// It draws again if the code it drew is already a row: two identical codes
  /// on one trip would be one code with two histories, and the space is large
  /// enough that this loop is a formality rather than a strategy.
  Future<TripInvite> mintInvite({
    required MemberId by,
    required DateTime now,
  }) async {
    final taken = {
      for (final row in await _db.readTripInviteCodes()) row.code,
    };
    InviteCode code;
    var attempts = 0;
    do {
      final drawn = draw();
      code = InviteCode.draw(
        firstDraw: drawn.firstWord,
        secondDraw: drawn.secondWord,
        numberDraw: drawn.number,
      );
      attempts++;
    } while (taken.contains(code.spoken) && attempts < 64);
    final invite = TripInvite(code: code, mintedBy: by, mintedAt: now.toUtc());
    await _db.insertInviteCode((
      code: code.spoken,
      mintedByMemberId: by.value,
      mintedAtUtcIso: invite.mintedAt.toIso8601String(),
    ));
    return invite;
  }

  /// Shuts one code. Whether the person asking may is checked above this
  /// layer, against `cairn_model`'s `canRevokeInvite`.
  Future<void> revokeInvite(InviteCode code, DateTime at) => _db.revokeInviteCode(
        code: code.spoken,
        atUtcIso: at.toUtc().toIso8601String(),
      );

  /// Deletes the trip from this phone: the plan, the pool's rows, the roster
  /// and the codes.
  ///
  /// Whether the person asking may — the starter, and only while the trip
  /// holds nobody else's photos — is `cairn_model`'s `canDeleteTrip`, checked
  /// above this layer where both the roster and the pool are known. The
  /// frames on disk are deliberately left; see [AppDatabase.deleteTripWholesale].
  Future<void> deleteTrip() => _db.deleteTripWholesale();
}
