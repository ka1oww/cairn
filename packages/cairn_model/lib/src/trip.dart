import 'calendar_date.dart';
import 'day_pool.dart';
import 'equality.dart';
import 'gate.dart';
import 'ids.dart';
import 'member.dart';
import 'trip_clock.dart';
import 'trip_close.dart';
import 'trip_day.dart';
import 'trip_invite.dart';
import 'trip_powers.dart' as powers;

/// The whole journey: who is on it, how long it runs, what the plan says, and
/// what time it is.
final class Trip {
  final TripId id;

  /// What the trip is called, as its members named it.
  final String name;

  /// The person who started the trip.
  ///
  /// The only asymmetry in the party. Whoever holds the removal power can
  /// remove someone ([canRemove]) and can delete the trip while it holds
  /// nobody else's photos ([canDelete]); nothing else distinguishes them
  /// from anyone else, and in particular the gate does not care who started
  /// the trip.
  ///
  /// **They may have left.** A starter who leaves is not on [members] any
  /// more, and the removal power passes to whoever has been here longest —
  /// see [removalPowerHolder]. So this is the name of the person who started
  /// the trip, for as long as the trip exists, and never a guarantee that
  /// they are still on it.
  final MemberId startedBy;

  /// The clock the trip's members share.
  ///
  /// This is the trip's own time, not any device's: the one `trip_moments`
  /// places pings in, and the one `photo_day_assignment` falls back to when a
  /// photo has no GPS. A day may be read on a different clock from this one —
  /// see [TripDay.clock] — but only ever a clock fixed where that day started.
  final TripClock clock;

  /// Everyone on the trip, [startedBy] included unless they have left.
  /// Unmodifiable.
  final List<Member> members;

  /// The trip's days, day 1 first. Unmodifiable.
  final List<TripDay> days;

  Trip({
    required this.id,
    required this.name,
    required this.startedBy,
    required this.clock,
    required List<Member> members,
    required List<TripDay> days,
  })  : members = List.unmodifiable(members),
        days = List.unmodifiable(days) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'a trip must have a name');
    }
    if (this.days.isEmpty) {
      throw ArgumentError.value(days, 'days', 'a trip runs at least one day');
    }
    for (var i = 0; i < this.days.length; i++) {
      final day = this.days[i];
      if (day.number != i + 1) {
        throw ArgumentError.value(
          days,
          'days',
          'day numbers must run 1..${this.days.length} in order; '
              'found ${day.number} at position ${i + 1}',
        );
      }
      if (i > 0 && !day.startsAt.isAfter(this.days[i - 1].startsAt)) {
        // Dates can repeat or skip when a trip crosses the date line, so the
        // days are checked on the one thing that must still hold: each day
        // begins after the one before it.
        throw ArgumentError.value(
          days,
          'days',
          'day ${day.number} starts at ${day.startsAt}, which is not after '
              'day ${day.number - 1} at ${this.days[i - 1].startsAt}',
        );
      }
    }
    if (this.members.isEmpty) {
      throw ArgumentError.value(members, 'members', 'a trip has members');
    }
    final seen = <MemberId>{};
    for (final member in this.members) {
      if (!seen.add(member.id)) {
        throw ArgumentError.value(
          member.id,
          'members',
          'the same person appears twice on this trip',
        );
      }
      if (member.joinedOnDay > this.days.length) {
        throw ArgumentError.value(
          member.joinedOnDay,
          'members',
          '${member.displayName} joined on day ${member.joinedOnDay} of a '
              '${this.days.length}-day trip',
        );
      }
    }
    // The starter is deliberately not required to be on the trip. Refusing
    // to let them leave traps someone who has fallen out with the group, so
    // the record lets them go and passes the removal power on instead
    // (docs/decisions/2026-08-22-starter-and-container.md §1).
  }

  /// How many days the trip runs.
  int get length => days.length;

  /// The date of day 1, on day 1's clock.
  CalendarDate get startDate => days.first.date;

  /// The date of the last day, on that day's clock.
  CalendarDate get endDate => days.last.date;

  /// The instant the trip begins.
  DateTime get startsAt => days.first.startsAt;

  /// The instant the trip ends, exclusive: when the last day seals.
  DateTime get endsAt => days.last.endsAt;

  /// Day [number], 1-based. Throws [RangeError] if the trip has no such day.
  TripDay day(int number) {
    if (number < 1 || number > days.length) {
      throw RangeError.range(number, 1, days.length, 'number', 'no such day');
    }
    return days[number - 1];
  }

  /// [member]'s place on this trip, or null if they are not on it.
  Member? memberOrNull(MemberId member) {
    for (final candidate in members) {
      if (candidate.id == member) return candidate;
    }
    return null;
  }

  /// Whether [member] is on this trip.
  bool isMember(MemberId member) => memberOrNull(member) != null;

  /// Who holds the removal power: [startedBy] while they are here, and
  /// otherwise whoever has been on the trip longest. Never nobody.
  ///
  /// It is not a title and must never be drawn as one — see
  /// `trip_powers.dart`, which is where this rule and the rest of the trip's
  /// permission model are written.
  MemberId get removalPowerHolder =>
      powers.removalPowerHolder(startedBy: startedBy, members: members);

  /// Whether [remover] may remove [target] from the trip.
  ///
  /// The whole of the trip's permission asymmetry — there is no role to
  /// grant, nothing else about a member is asymmetric, and every other
  /// action is available to every member equally.
  ///
  /// Removing yourself is not this: leaving a trip is something anyone can
  /// do and is not a power, so this stays false for `remover == target`.
  bool canRemove({required MemberId remover, required MemberId target}) =>
      powers.canRemoveMember(
        remover: remover,
        target: target,
        startedBy: startedBy,
        members: members,
      );

  /// Whether [member] may rename this trip. Any member may.
  bool canRename(MemberId member) =>
      powers.canRenameTrip(member: member, members: members);

  /// Whether [member] may delete this trip.
  ///
  /// The starter's alone, and only while nobody else's photos are in it.
  /// [holdsOtherMembersPhotos] is a fact about the pool, which this type
  /// does not hold — the caller who can see the pool answers it.
  bool canDelete(
    MemberId member, {
    required bool holdsOtherMembersPhotos,
  }) =>
      powers.canDeleteTrip(
        member: member,
        startedBy: startedBy,
        members: members,
        holdsOtherMembersPhotos: holdsOtherMembersPhotos,
      );

  /// Whether [member] may mint an invite code for this trip. Any member may.
  bool canMintInvite(MemberId member) =>
      powers.canMintInvite(member: member, members: members);

  /// Whether [member] may revoke [invite]: whoever minted it, or the
  /// starter.
  bool canRevoke(MemberId member, TripInvite invite) => powers.canRevokeInvite(
        member: member,
        startedBy: startedBy,
        mintedBy: invite.mintedBy,
      );

  /// The instant this trip closes to new photos, and with it the instant its
  /// invite codes die: fourteen days after the last day seals
  /// (`trip_close.dart`). The book is not this and never expires.
  DateTime get closesAt => tripClosesAt(endsAt);

  /// Whether the day [pool] holds is open to [viewer] at [now], and why.
  ///
  /// **The gate applies to the day being lived, and to no other day**
  /// (`docs/decisions/2026-08-22-grill-round-one.md` §1). A member sees a day
  /// when they have contributed to it, and sees every day that is already over
  /// whether they contributed or not — a day that has sealed belongs to the
  /// party. Nothing else opens it: not being the person who started the trip,
  /// not how many other people answered, and not how long ago it was, because
  /// "over" is the whole of that question.
  ///
  /// [now] is required rather than read from a clock here, because this
  /// package has none: a trip has one clock and it follows the itinerary's leg
  /// (`docs/decisions/2026-08-22-last-calls.md` §4), so the instant is the
  /// caller's to supply and each day is then read on its own clock.
  ///
  /// [Member.joinedOnDay] deliberately plays no part. It used to open the days
  /// before someone arrived, back when every other past day stayed shut; now
  /// that every past day is open the late joiner's case is the ordinary one,
  /// and their arrival is a thing the interface marks once
  /// (`docs/design/`, 15d) rather than a reason a gate reports.
  ///
  /// Throws [ArgumentError] if [viewer] is not on this trip. A non-member has
  /// no gate state because they have no access to reach a gate with — the
  /// photo rows are not even visible to them (`supabase/README.md`, the
  /// `photos_select_trip_member` policy). Answering "shut" for them would
  /// quietly suggest there is a way in.
  GateState gateFor({
    required MemberId viewer,
    required DayPool pool,
    required DateTime now,
  }) {
    if (!isMember(viewer)) {
      throw ArgumentError.value(
        viewer,
        'viewer',
        'is not on this trip, so has no view of it at all',
      );
    }
    return GateState.decide(
      standing: day(pool.dayNumber).standingAt(now),
      hasContributed: pool.hasContributed(viewer),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Trip &&
      other.id == id &&
      other.name == name &&
      other.startedBy == startedBy &&
      other.clock == clock &&
      listEquals(other.members, members) &&
      listEquals(other.days, days);

  @override
  int get hashCode => Object.hash(
        id,
        name,
        startedBy,
        clock,
        Object.hashAll(members),
        Object.hashAll(days),
      );

  @override
  String toString() =>
      'Trip(${id.value}, $name, ${members.length} members, $length days)';
}
