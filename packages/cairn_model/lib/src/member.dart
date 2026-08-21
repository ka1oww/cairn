import 'ids.dart';

/// A person on the trip.
///
/// Roles are flat. There is no role field here, and no permission set, because
/// the product has neither: everyone on a trip can do the same things. The one
/// asymmetry that exists — the person who started the trip can remove someone
/// — lives on the trip as `Trip.startedBy`, not on the member, because it is a
/// fact about who started *that trip* rather than a rank the person carries.
final class Member {
  final MemberId id;

  /// The name credited under this person's photos.
  ///
  /// There is no separate username system: this comes from the Google or Apple
  /// sign-in and is editable when someone joins a trip, because providers tend
  /// to supply full legal names. See
  /// `docs/decisions/2026-08-22-design-calls.md`, "Each photo is credited,
  /// small and quiet" — including the known backend defect it exposes, which
  /// this package cannot fix and does not model.
  final String displayName;

  /// The 1-based day of the trip this person joined on.
  ///
  /// 1 for everyone who was on the trip before it started. Someone who joins
  /// on day 3 gets days 1 and 2 freely — they could never have contributed to
  /// them, so the gate has nothing to ask of them. See `Trip.gateFor`.
  final int joinedOnDay;

  Member({
    required this.id,
    required this.displayName,
    this.joinedOnDay = 1,
  }) {
    if (displayName.trim().isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'a member must have a display name',
      );
    }
    if (joinedOnDay < 1) {
      throw ArgumentError.value(joinedOnDay, 'joinedOnDay', 'must be >= 1');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Member &&
      other.id == id &&
      other.displayName == displayName &&
      other.joinedOnDay == joinedOnDay;

  @override
  int get hashCode => Object.hash(id, displayName, joinedOnDay);

  @override
  String toString() =>
      'Member(${id.value}, $displayName, joined day $joinedOnDay)';
}
