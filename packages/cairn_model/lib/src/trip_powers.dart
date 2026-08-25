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
/// The rules live here as functions over the few facts each one needs,
/// rather than only as methods on [Trip], because the app holds a roster
/// long before it can build a whole [Trip] — and one rule written twice is
/// one rule that will eventually be two.
library;

import 'ids.dart';
import 'member.dart';
import 'trip.dart';

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
bool canRemoveMember({
  required MemberId remover,
  required MemberId target,
  required MemberId startedBy,
  required List<Member> members,
}) {
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
bool canRenameTrip({
  required MemberId member,
  required List<Member> members,
}) =>
    _isMember(member, members);

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
bool canRevokeInvite({
  required MemberId member,
  required MemberId startedBy,
  required MemberId mintedBy,
}) =>
    member == mintedBy || member == startedBy;

/// Whether [member] may mint an invite code. Any member may.
///
/// Restricting it buys almost nothing: the code is three spoken words, so
/// anybody already on the trip knows a working one and can repeat it across
/// a table. Starter-only minting would only make the starter a bottleneck
/// when somebody's flatmate joins late.
bool canMintInvite({
  required MemberId member,
  required List<Member> members,
}) =>
    _isMember(member, members);

bool _isMember(MemberId id, List<Member> members) {
  for (final member in members) {
    if (member.id == id) return true;
  }
  return false;
}
