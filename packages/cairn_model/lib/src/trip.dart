import 'calendar_date.dart';
import 'day_pool.dart';
import 'equality.dart';
import 'gate.dart';
import 'ids.dart';
import 'member.dart';
import 'trip_clock.dart';
import 'trip_day.dart';

/// The whole journey: who is on it, how long it runs, what the plan says, and
/// what time it is.
final class Trip {
  final TripId id;

  /// What the trip is called, as its members named it.
  final String name;

  /// The person who started the trip.
  ///
  /// The only asymmetry in the party. They can remove someone
  /// ([canRemove]); nothing else distinguishes them from anyone else, and in
  /// particular the gate does not care who started the trip.
  final MemberId startedBy;

  /// The clock the trip's members share.
  ///
  /// This is the trip's own time, not any device's: the one `trip_moments`
  /// places pings in, and the one `photo_day_assignment` falls back to when a
  /// photo has no GPS. A day may be read on a different clock from this one —
  /// see [TripDay.clock] — but only ever a clock fixed where that day started.
  final TripClock clock;

  /// Everyone on the trip, including [startedBy]. Unmodifiable.
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
    if (!seen.contains(startedBy)) {
      throw ArgumentError.value(
        startedBy,
        'startedBy',
        'the person who started the trip is on it',
      );
    }
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

  /// Whether [remover] may remove [target] from the trip.
  ///
  /// True only for the person who started the trip, removing somebody else.
  /// This is the whole of the trip's permission model — there is no role to
  /// grant, nothing else is asymmetric, and every other action is available to
  /// every member equally.
  ///
  /// Removing yourself is not this: leaving a trip is something anyone can do
  /// and is not modelled here, and what happens to a trip whose starter leaves
  /// has not been decided (`supabase/README.md`, "No handling for a trip's
  /// last owner leaving"). So this stays false for `remover == target` rather
  /// than answering a question the record has not.
  bool canRemove({required MemberId remover, required MemberId target}) =>
      remover == startedBy &&
      remover != target &&
      isMember(remover) &&
      isMember(target);

  /// Whether the day [pool] holds is open to [viewer], and why.
  ///
  /// A member sees a day when they have contributed to it, or when the day
  /// ended before they joined. Nothing else opens it: not being the person who
  /// started the trip, not how long ago the day was, not how many other people
  /// answered.
  ///
  /// Throws [ArgumentError] if [viewer] is not on this trip. A non-member has
  /// no gate state because they have no access to reach a gate with — the
  /// photo rows are not even visible to them (`supabase/README.md`, the
  /// `photos_select_trip_member` policy). Answering "shut" for them would
  /// quietly suggest there is a way in.
  GateState gateFor({required MemberId viewer, required DayPool pool}) {
    final member = memberOrNull(viewer);
    if (member == null) {
      throw ArgumentError.value(
        viewer,
        'viewer',
        'is not on this trip, so has no view of it at all',
      );
    }
    final day = this.day(pool.dayNumber);
    if (pool.hasContributed(viewer)) {
      return GateState.openedByContribution;
    }
    if (day.number < member.joinedOnDay) {
      return GateState.openBecauseJoinedLater;
    }
    return GateState.shutAwaitingContribution;
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
