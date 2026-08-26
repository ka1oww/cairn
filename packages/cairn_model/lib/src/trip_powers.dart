/// Who on a trip may do what.
///
/// **Roles are flat.** There is no role field anywhere in this package and
/// no permission set, because the product has neither: everyone on a trip
/// can do the same things, with the single exception below
/// (`docs/decisions/2026-08-22-last-calls.md` §1). The exception exists for
/// one narrow reason — the join code is three spoken words, so a wrong join
/// is genuinely possible and somebody has to be able to undo it.
///
/// **It is narrower than a group admin, and that distinction is
/// load-bearing** (`docs/decisions/2026-08-22-starter-and-container.md` §1).
/// The power removes a member and does nothing else: it cannot promote
/// anyone, cannot moderate a photo, cannot touch anyone else's contribution
/// and cannot make another person into a starter. An interface that calls
/// its holder an "admin" — or shows the role as a title at all — is
/// over-promising it.
///
/// **An archived trip is read-only, and that is a permission, not a
/// presentation.** Once a trip has closed its record is fixed — the
/// itinerary, the pool and the party are what the app presents from then on
/// (`docs/decisions/2026-08-26-the-ending.md`) — so every power that would
/// *change* the trip takes a [TripStanding] and answers false for
/// [TripStanding.archived]. It is written here rather than as a check in
/// front of each caller, because a rule enforced by whoever remembers it is
/// a rule one new caller loses. The one deliberate exception is
/// [canDeleteTrip]; its own doc says why.
///
/// The rules live here as functions over the few facts each one needs,
/// rather than only as methods on [Trip], because the app holds a roster
/// long before it can build a whole [Trip] — and one rule written twice is
/// one rule that will eventually be two.
library;

import 'ids.dart';
import 'member.dart';
import 'trip.dart';
import 'trip_standing.dart';

/// Who currently holds the removal power: the starter, or — once the starter
/// has left — whoever has been on the trip longest.
///
/// There is always exactly one holder and it is never nobody
/// (`docs/decisions/2026-08-22-starter-and-container.md` §1). No handover
/// dialog names a successor: naming one is a modal at the worst possible
/// moment and it can be dismissed, and letting the power vanish leaves the
/// wrong-join case with no undo.
///
/// "Longest" is [Member.joinedOnDay], which is the only grain this model
/// keeps. Two people who joined on the same day are separated by their
/// member id — arbitrary, but *the same* arbitrary answer on every phone,
/// which is what "exactly one holder" needs from a party that agrees
/// offline.
MemberId removalPowerHolder({
  required MemberId startedBy,
  required List<Member> members,
}) {
  if (members.isEmpty) {
    throw ArgumentError.value(members, 'members', 'a trip has members');
  }
  for (final member in members) {
    if (member.id == startedBy) return startedBy;
  }
  var longest = members.first;
  for (final member in members.skip(1)) {
    if (member.joinedOnDay < longest.joinedOnDay ||
        (member.joinedOnDay == longest.joinedOnDay &&
            member.id.value.compareTo(longest.id.value) < 0)) {
      longest = member;
    }
  }
  return longest.id;
}

/// Whether [remover] may remove [target].
///
/// The whole of the trip's permission asymmetry. Removing yourself is not
/// this: leaving is something anyone may do and is not a power.
///
/// Refused on an archived trip: the party is part of the record the trip
/// closed with, and a name taken off it afterwards would take that person's
/// photographs' author with it.
bool canRemoveMember({
  required MemberId remover,
  required MemberId target,
  required MemberId startedBy,
  required List<Member> members,
  required TripStanding standing,
}) {
  if (standing.isReadOnly) return false;
  if (remover == target) return false;
  if (!_isMember(target, members)) return false;
  if (!_isMember(remover, members)) return false;
  return remover == removalPowerHolder(startedBy: startedBy, members: members);
}

/// Whether [member] may rename the trip. Any member may
/// (`docs/decisions/2026-08-22-starter-and-container.md` §2).
///
/// Written down as a rule rather than left implicit because the flatness is
/// the decision: renaming is reversible, visible to everyone and harmless,
/// and making somebody wait for the starter to fix a typo is precisely the
/// hierarchy the flat-roles decision exists to avoid.
///
/// Flat, and still refused on an archived trip: what a trip was called is
/// part of what it closed as.
bool canRenameTrip({
  required MemberId member,
  required List<Member> members,
  required TripStanding standing,
}) =>
    !standing.isReadOnly && _isMember(member, members);

/// Whether [member] may delete the trip.
///
/// The starter's, **and only while the trip holds nobody else's photos**.
/// Once other people have contributed nobody can delete it, the starter
/// included: deleting cascades every photo on the trip, which is the
/// irreversible destruction of eight people's memories by one tap. Leaving
/// is the action a person actually needs.
///
/// This does not pass to the longest-standing member when the starter
/// leaves. The power that passes is removal and only removal — a trip whose
/// starter has gone is a trip nobody can delete, which is the safe direction
/// for the one irreversible act in the product.
///
/// **It takes no [TripStanding], deliberately.** Every other power here is
/// refused once the trip is archived, and this one is not: deleting is not
/// an edit to the record, it is discarding the whole of it, and a trip
/// nobody could ever be rid of is a worse answer than one its own starter
/// can throw away. The thing an archive has to protect is other people's
/// memories, and the condition above already does exactly that — the moment
/// anybody else's photograph is in the trip, nobody can delete it, archived
/// or not.
bool canDeleteTrip({
  required MemberId member,
  required MemberId startedBy,
  required List<Member> members,
  required bool holdsOtherMembersPhotos,
}) =>
    !holdsOtherMembersPhotos &&
    member == startedBy &&
    _isMember(member, members);

/// Whether [member] may revoke an invite code that [mintedBy] minted.
///
/// Whoever created it, or the starter, who has to be able to shut a leaked
/// code they did not create
/// (`docs/decisions/2026-08-22-starter-and-container.md` §3).
///
/// Refused on an archived trip because there is nothing left to shut: every
/// code of a closed trip is already dead ([TripStanding.admitsJoiners]), and
/// stamping one as revoked afterwards would rewrite a fact about the trip to
/// no effect.
bool canRevokeInvite({
  required MemberId member,
  required MemberId startedBy,
  required MemberId mintedBy,
  required TripStanding standing,
}) =>
    !standing.isReadOnly && (member == mintedBy || member == startedBy);

/// Whether [member] may mint an invite code. Any member may.
///
/// Restricting it buys almost nothing: the code is three spoken words, so
/// anybody already on the trip knows a working one and can repeat it across
/// a table. Starter-only minting would only make the starter a bottleneck
/// when somebody's flatmate joins late.
///
/// Refused on an archived trip, where a freshly minted code would be born
/// dead: it takes its close from the trip and the trip has already closed,
/// so minting one would be handing somebody three words that open nothing.
bool canMintInvite({
  required MemberId member,
  required List<Member> members,
  required TripStanding standing,
}) =>
    !standing.isReadOnly && _isMember(member, members);

bool _isMember(MemberId id, List<Member> members) {
  for (final member in members) {
    if (member.id == id) return true;
  }
  return false;
}
