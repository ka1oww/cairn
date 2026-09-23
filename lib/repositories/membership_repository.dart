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
import '../storage/remote/shared_facts.dart';
import 'itinerary_sync.dart';

/// The trip as the seam hands it up: who is on it, who started it, what it is
/// called, and the codes minted for it.
///
/// Deliberately not a `cairn_model.Trip`: a `Trip` requires resolved dates
/// and a trip clock for every day, and a plan may be accepted with its dates
/// still open. The vocabulary inside it *is* the model's — `Member`,
/// `MemberId`, `TripInvite` — so no band above has to translate one.
class TripMembership {
  /// The trip's id: what the ping derivation seeds itself from.
  ///
  /// Minted on this phone when the trip was started and durable from that
  /// instant (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md), so
  /// nothing above here has to hold a trip that has no name yet, and nothing
  /// re-deals the pings when the trip first syncs.
  final TripId tripId;

  /// What the trip is called, or null while nobody has named it. Naming is
  /// flat, so this is nobody's in particular.
  final String? name;

  /// The destination's IANA clock, or null when this phone cannot honestly
  /// schedule the trip yet.
  final String? timeZone;

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
    this.timeZone,
    required this.startedBy,
    required List<Member> members,
    List<TripInvite> invites = const [],
  }) : members = List.unmodifiable(members),
       invites = List.unmodifiable(invites);
}

/// The trip's roster and its codes, read-only, plus the one write every
/// implementation must answer: adopting a trip somebody else started.
abstract interface class MembershipRepository {
  /// The trip on this phone, or null while none has been started.
  /// Re-emits after every write.
  Stream<TripMembership?> watchMembership();

  /// Makes this phone genuinely part of [tripId] — a trip already admitted
  /// elsewhere, not one this phone is starting. See
  /// [MembershipStore.adoptTrip] for the contract.
  Future<void> adoptTrip(TripId tripId);
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

  @override
  Future<void> adoptTrip(TripId tripId) => throw UnsupportedError(
    'InMemoryMembership seeds a party for reading; it holds no store to '
    'adopt a trip into.',
  );
}

/// Refuses [MembershipStore.adoptTrip] when this phone already holds a trip
/// other than the one it was asked to adopt.
///
/// Cairn holds one trip at a time, and silently replacing a trip the person
/// is already on would destroy local state — their own edits, their photos'
/// index, their invite codes — that this phone cannot recover from a server
/// that only ever answers the trip it is asked about.
class DifferentTripHeldException implements Exception {
  final TripId held;
  final TripId requested;

  const DifferentTripHeldException({
    required this.held,
    required this.requested,
  });

  @override
  String toString() =>
      'cannot adopt trip $requested: this phone already holds trip $held';
}

/// Refuses [MembershipStore.adoptTrip] when the server has never heard of
/// the trip being adopted.
///
/// A null answer from [SharedFacts.readTrip] is an ordinary "not yet synced"
/// for a trip this phone started, but a trip nobody has ever created cannot
/// be adopted — there is nothing to become part of.
class UnknownTripException implements Exception {
  final TripId tripId;

  const UnknownTripException(this.tripId);

  @override
  String toString() => 'no such trip: $tripId';
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
  MembershipStore(
    this._db, {
    this.draw = _drawAtRandom,
    this.now = DateTime.now,
    SharedFacts? facts,
  }) : _facts = facts;

  // A named `facts:` parameter reads better at every call site than the
  // private field name an initializing formal would force
  // (`MembershipStore(db, facts: server)`), so this stays a plain assignment
  // rather than `this._facts`.

  final AppDatabase _db;

  /// The backend [adoptTrip] reads and pulls from. Optional, and null for
  /// every caller that only starts or manages a trip this phone already
  /// holds — the whole rest of this store is local-only and never needed it.
  /// A [StateError] refuses [adoptTrip] itself if it is called without one.
  final SharedFacts? _facts;

  /// Where a code's randomness comes from. `cairn_model` has none — it turns
  /// three numbers into a code and refuses to invent them — so the draw
  /// happens here, the way a photo id is minted here.
  final InviteDraw Function() draw;

  /// The authoring clock for a rename. Injected because the name is an
  /// offline last-write-wins fact and tests must be able to pin its revision.
  final DateTime Function() now;

  @override
  Stream<TripMembership?> watchMembership() =>
      _db.watchTripFacts().asyncMap((trip) async {
        if (trip == null) return null;
        final members = await _db.readTripMembers();
        final codes = await _db.readTripInviteCodes();
        return TripMembership(
          tripId: TripId(trip.tripId),
          name: trip.name,
          timeZone: trip.timeZone,
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

  /// Starts the trip, if this phone has not started one, gives it its first
  /// code, and hands back the trip's id.
  ///
  /// Accepting a pasted plan is what starts a trip — there is no other door,
  /// and the person who accepted it is the starter. Idempotent, because
  /// pasting a different plan replaces the itinerary and replacing your own
  /// itinerary is not starting a second trip.
  ///
  /// **Nobody tells it what the trip is called.** The id is minted where the
  /// row is written ([AppDatabase.startTripIfAbsent]), so there is no window
  /// in which a caller holds an id the store has not kept, and no caller can
  /// hand in an id of its own invention
  /// (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md).
  ///
  /// The code is minted here rather than waiting to be asked for, because
  /// "eight people can join with three spoken words" is the first release's
  /// own line (docs/decisions/2026-08-22-first-release.md) and a trip whose
  /// code has to be summoned first is a trip nobody can be let into while
  /// the phone is in somebody else's hand.
  Future<TripId> startTrip({
    required MemberId starter,
    required String starterDisplayName,
    required DateTime now,
  }) async {
    final tripId = await _db.startTripIfAbsent(
      starterId: starter.value,
      starterDisplayName: starterDisplayName,
    );
    if ((await _db.readTripInviteCodes()).isEmpty) {
      await mintInvite(by: starter, now: now);
    }
    return tripId;
  }

  /// Makes this phone genuinely part of [tripId] — a trip this phone was
  /// just admitted to elsewhere, not one it is starting.
  ///
  /// This is the local half of joining only: redeeming an invite code and
  /// getting [tripId] back is a network call owned above this layer. Given
  /// that id, this is everything it takes for the trip to actually be this
  /// phone's — its facts, its roster and its plan — so that the day after
  /// admission this phone can see the trip, read today, and be on the same
  /// plan as everyone else.
  ///
  /// **Every round trip happens before the first local write, and the local
  /// writes are one transaction.** That ordering is the whole of the
  /// "no half-adopted trip" promise, and it is structural rather than
  /// repaired afterwards: nothing is written until everything the write
  /// needs is in hand, and a write that fails part-way rolls back to exactly
  /// what this phone held before the call — an import still sitting in the
  /// paste box included, which is why no wholesale delete is involved.
  ///
  /// 1. A different trip already held refuses loudly
  /// ([DifferentTripHeldException]) rather than replacing it — Cairn holds
  /// one trip at a time, and a silent swap would destroy local state (edits,
  /// a photo index, invite codes) with no way back. Adopting the trip this
  /// phone already holds is a no-op: the join succeeded once and asking
  /// again must not re-deal the ping schedule or re-fetch a plan this phone
  /// already has.
  /// 2. [SharedFacts.readTrip] is asked. A null answer means this server has
  /// never heard of the trip — a refusal ([UnknownTripException]), not an
  /// empty trip to adopt anyway.
  /// 3. The plan is pulled: [SharedFacts.syncItinerary] is one round trip
  /// both ways, and a phone with no plan of its own pulls by pushing
  /// nothing — an empty day list and [beforeAnySync], which the interface's
  /// own contract says wins nothing and deletes nothing.
  /// 4. In one transaction: the trip's row through
  /// [AppDatabase.adoptTripFacts] (the one write [startTrip] cannot make: it
  /// always mints its own id, and this id is the admitted trip's own), the
  /// plan through [AppDatabase.applyRemoteItinerary], then the roster
  /// through [AppDatabase.replaceRoster] — last, because which day each
  /// member joined on is read off the plan just written, by the same
  /// [TripSync.joinedOnDay] every reconcile uses. The trip's row insert is
  /// deliberately not idempotent, so a trip started on this phone between
  /// step 1 and here raises, the transaction rolls back, and the trip that
  /// won the race keeps its plan. The wire name is mapped through
  /// [localTripName] on the way in, so a trip nobody has named is not
  /// adopted *named*.
  /// 5. Nothing else to do: the ping schedule is derived from
  /// [TripMembership.tripId] on every read (`ping_schedule.dart`'s
  /// `pingScheduleProvider`), so once step 4 has written this trip's id as
  /// this phone's, the joiner's daily minute is already dealt like
  /// everyone else's — exactly as it is the moment [startTrip] writes an
  /// id, with nothing further to seed.
  @override
  Future<void> adoptTrip(TripId tripId) async {
    final facts = _facts;
    if (facts == null) {
      throw StateError(
        'MembershipStore.adoptTrip needs a SharedFacts backend; construct '
        'with facts:',
      );
    }

    final existing = await _db.readTripFacts();
    if (existing != null) {
      if (existing.tripId == tripId.value) return;
      throw DifferentTripHeldException(
        held: TripId(existing.tripId),
        requested: tripId,
      );
    }

    final shared = await facts.readTrip(tripId);
    if (shared == null) {
      throw UnknownTripException(tripId);
    }

    final merged = await facts.syncItinerary(
      tripId: tripId,
      planRevisedAt: DateTime.parse(beforeAnySync),
      days: const [],
      pocketRevisedAt: DateTime.parse(beforeAnySync),
      setAside: const [],
    );

    final dayDates = [
      for (final day in merged.days) (day.number, day.dateIso),
    ];

    await _db.transaction(() async {
      await _db.adoptTripFacts(
        tripId: tripId,
        startedByMemberId: shared.startedBy.value,
        name: localTripName(shared.name),
        nameRevisedAt: shared.nameRevisedAt,
        timeZone: shared.timeZone,
      );
      await _db.applyRemoteItinerary(
        days: [
          for (final day in merged.days)
            (
              number: day.number,
              dateIso: day.dateIso,
              place: day.place,
              revisedAtUtcIso: day.revisedAt.toUtc().toIso8601String(),
            ),
        ],
        stops: [
          for (final day in merged.days)
            for (final stop in day.stops) _adoptedStop(day.number, stop),
        ],
        setAsides: [
          for (final line in merged.setAside)
            (
              position: line.position,
              sourceLineNumber: line.sourceLineNumber,
              text: line.text,
              explanation: line.explanation,
            ),
        ],
        planRevisedAtUtcIso: merged.planRevisedAt.toUtc().toIso8601String(),
        pocketRevisedAtUtcIso: merged.pocketRevisedAt.toUtc().toIso8601String(),
        syncedAtUtcIso: now().toUtc().toIso8601String(),
        pushedDayNumbers: const {},
      );
      await _db.replaceRoster(
        members: [
          for (final member in shared.members)
            (
              id: member.id.value,
              displayName: member.displayName,
              joinedOnDay: TripSync.joinedOnDay(
                joinedAt: member.joinedAt,
                days: dayDates,
              ),
            ),
        ],
      );
    });
  }

  /// One incoming stop as the store writes it, classified the way every
  /// incoming stop is ([rehydrateLineMetadata]) — with no "what did this
  /// phone already hold" fallback, because a trip being adopted for the
  /// first time is held nowhere yet.
  static ItineraryStopRecord _adoptedStop(int dayNumber, RemoteStop stop) {
    final line = rehydrateLineMetadata(stop, retainedAreaHeading: false);
    return (
      dayNumber: dayNumber,
      position: stop.position,
      text: stop.text,
      timeIso: stop.timeIso,
      kind: line.kind,
      placeText: line.placeText,
      placeCandidatesJson: line.placeCandidatesJson,
      chosenPlace: stop.chosenPlace,
      areaText: stop.areaText,
      areaSource: stop.areaSource,
    );
  }

  /// Whether a trip has been started on this phone. One read, no stream —
  /// what the accept path asks before it may adopt a late-arriving account
  /// id (`paste_flow.dart`): once a trip holds an identity, the launch that
  /// wrote it keeps it, and only the next launch's heal may change it.
  Future<bool> hasTrip() async => await _db.readTripFacts() != null;

  /// Rewrites a roster still holding [standInId] to name [accountId] instead.
  ///
  /// The repair for a trip started before the phone's account had resolved:
  /// such a trip is started under the offline stand-in (`localMemberId` in
  /// `ping_schedule.dart`), and on every later launch the signed-in id is not
  /// a member of its own trip — so the ping deal (`pingsForPlan`) hands this
  /// phone nothing for the rest of the trip, the day page never offers a
  /// capture, and the sync can never create the shared `trips` row (a
  /// `created_by` of `me` is not a uuid). The composition root runs this once
  /// per launch, non-blocking, as soon as it knows who the launch is.
  ///
  /// Idempotent, and **a heal that changes nothing writes nothing**: the
  /// roster's stream is what asks the sync for work, so an unconditional
  /// rewrite here would be a write asking for a sync on every launch. If the
  /// roster somehow already names [accountId] beside the stand-in, the
  /// stand-in row is dropped rather than renamed into a duplicate.
  ///
  /// What it deliberately does not touch: an invite code's `mintedBy` (the
  /// starter may revoke any code regardless — `canRevokeInvite` — so a code
  /// minted by the stand-in is still revocable after the heal) and a photo's
  /// contributor (every sealed day is open to everyone, so a stand-in credit
  /// changes no gate answer that matters by the next launch; rewriting the
  /// pool is the photo store's business, not the roster's).
  Future<void> adoptAccountIdentity({
    required String standInId,
    required String accountId,
  }) async {
    if (accountId.isEmpty || accountId == standInId) return;
    final facts = await _db.readTripFacts();
    if (facts == null) return;
    final members = await _db.readTripMembers();
    final starterIsStandIn = facts.startedByMemberId == standInId;
    final rosterHoldsStandIn = members.any((row) => row.id == standInId);
    if (!starterIsStandIn && !rosterHoldsStandIn) return;
    final healed = <String, TripMemberRecord>{};
    for (final row in members) {
      final id = row.id == standInId ? accountId : row.id;
      healed.putIfAbsent(
        id,
        () => (
          id: id,
          displayName: row.displayName,
          joinedOnDay: row.joinedOnDay,
        ),
      );
    }
    await _db.replaceRoster(
      members: [...healed.values],
      startedByMemberId: starterIsStandIn ? accountId : null,
    );
  }

  /// Renames the trip, or clears the name with a blank. Any member may
  /// (docs/decisions/2026-08-22-starter-and-container.md §2); *who* is asking
  /// is checked above this layer, where the roster is known.
  Future<void> rename(String? name) {
    final trimmed = name?.trim();
    return _db.renameTrip(
      trimmed == null || trimmed.isEmpty ? null : trimmed,
      at: now(),
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
    final taken = {for (final row in await _db.readTripInviteCodes()) row.code};
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
  Future<void> revokeInvite(InviteCode code, DateTime at) =>
      _db.revokeInviteCode(
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
