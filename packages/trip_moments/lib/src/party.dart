import 'stable_hash.dart';

/// The people on a trip, in a canonical order.
///
/// The party is the input that makes a collision-free schedule possible.
/// Each device derives the whole day's assignment -- everyone's slot, not
/// just its own -- from the party plus the date, which is why no two people
/// can land on the same time and why nobody has to ask a server who got
/// what. A device that only knew its own id could only hash that id, and
/// independent hashes collide and cluster.
///
/// Every member of a trip can already read the full roster offline (the
/// backend's `trip_members_select_co_member` policy), so this is data the
/// app holds locally, not something new the schedule requires.
///
/// **Every device must hold the same party for the same day.** The
/// assignment is a pure function of the party it is given, so a device that
/// has not yet seen a new member computes a different permutation from one
/// that has. See the package README, "When devices disagree", for how the
/// app layer is expected to handle a mid-trip join.
class Party {
  /// The member ids, sorted and de-duplicated.
  ///
  /// Sorting is what makes the party canonical: two devices that fetched
  /// the roster in different orders, or received it from different
  /// queries, still produce the same [Party] and therefore the same
  /// schedule. Ordering is by UTF-16 code unit ([String.compareTo]), which
  /// is fully specified and identical on every Dart backend.
  final List<String> memberIds;

  /// A short, stable fingerprint of [memberIds], mixed into every seed.
  ///
  /// Computed once here rather than per day, because a fourteen-day trip
  /// otherwise re-hashes the same roster fourteen times.
  final String fingerprint;

  Party._(this.memberIds, this.fingerprint);

  /// Builds a party from any collection of member ids.
  ///
  /// Duplicates are collapsed and order is normalised, so the caller can
  /// pass the roster exactly as it came back from storage. Throws if the
  /// collection is empty or contains an empty id -- an empty id would make
  /// two different parties fingerprint alike.
  factory Party(Iterable<String> memberIds) {
    final unique = memberIds.toSet().toList()..sort();
    if (unique.isEmpty) {
      throw ArgumentError.value(
          memberIds, 'memberIds', 'party cannot be empty');
    }
    if (unique.any((id) => id.isEmpty)) {
      throw ArgumentError.value(
        memberIds,
        'memberIds',
        'member ids cannot be empty strings',
      );
    }
    return Party._(List.unmodifiable(unique), stableFingerprint(unique));
  }

  /// How many people are on the trip.
  int get size => memberIds.length;

  /// Whether [memberId] is on this trip.
  bool contains(String memberId) => memberIds.contains(memberId);

  @override
  String toString() => 'Party(${memberIds.length} members, $fingerprint)';
}
