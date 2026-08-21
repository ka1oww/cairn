import 'party.dart';
import 'ping_window.dart';
import 'slots.dart';
import 'trip_day.dart';

/// The seed namespace for the slot-dealing derivation.
///
/// Baked into every seed so that if the derivation ever has to change
/// incompatibly, it can be bumped and old and new builds will disagree
/// loudly and everywhere rather than silently agreeing on some trips and
/// splitting on others. `v2` because `v1` was the retired shared-moment
/// derivation; the two have nothing in common.
const String _slotNamespace = 'trip_moments/v2/slots';

/// Exactly one ping per person per day. Never two, never zero on a day
/// long enough to hold a slot for them.
///
/// The ceiling is structural rather than conventional: [DayAssignment]
/// answers [DayAssignment.pingFor] with a single nullable [Ping], not a
/// list, so there is nowhere to `.add()` a second one. Cairn interrupts
/// once a day and never otherwise, which is the cleanest permission ask in
/// the app; see `docs/decisions/2026-08-21-first-calls.md`, "The second
/// solo ping is cut".
const int pingsPerPersonPerDay = 1;

/// One person's single interruption on one day.
class Ping {
  /// Who is pinged.
  final String memberId;

  /// Which slot of the day this is, counting from 0 at the start of the
  /// waking day. Slot order is time order.
  final int slotIndex;

  /// The instant to fire at, in UTC.
  ///
  /// This is what goes to the local-notification scheduler. Convert with
  /// `.toLocal()` only for display; the instant itself is already correct
  /// whatever timezone the phone thinks it is in.
  final DateTime at;

  /// The same instant as a wall-clock offset from local midnight in the
  /// day's own clock -- 11:40 on the trip, not on the phone. For display
  /// and for reading a schedule at a glance.
  final Duration localTimeOfDay;

  const Ping({
    required this.memberId,
    required this.slotIndex,
    required this.at,
    required this.localTimeOfDay,
  });

  /// `HH:MM` in the trip's clock.
  String get localLabel {
    final h = localTimeOfDay.inHours.toString().padLeft(2, '0');
    final m = (localTimeOfDay.inMinutes % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  String toString() => 'Ping($memberId, slot $slotIndex, $localLabel local, '
      '${at.toIso8601String()})';
}

/// Every ping for one day of a trip: the whole party's schedule, which
/// every device derives identically.
///
/// A device computes the entire day, not just its own line, because that
/// is what makes the assignment collision-free without a server. Reading
/// only your own ping is [pingFor].
class DayAssignment {
  /// The calendar date, in the trip's clock.
  final DateTime date;

  /// The clock this day was read in -- the offset in force where the day
  /// started, held for the whole day. See [TripDay].
  final Duration utcOffset;

  /// The day's effective bounds, as offsets from local midnight: the
  /// waking day narrowed by any arrival or departure time.
  final Duration opensAt;

  /// See [opensAt].
  final Duration closesAt;

  /// Every ping this day, in time order. At most one per member.
  final List<Ping> pings;

  /// Members with no ping today, sorted.
  ///
  /// Non-empty only on a day too short to hold a slot for everyone -- the
  /// arrival and departure days. Fewer slots on a short day is the correct
  /// answer, not a shortfall to pad; who sits out rotates with the daily
  /// reshuffle.
  final List<String> unpingedMemberIds;

  final Map<String, Ping> _byMember;

  DayAssignment._({
    required this.date,
    required this.utcOffset,
    required this.opensAt,
    required this.closesAt,
    required this.pings,
    required this.unpingedMemberIds,
  }) : _byMember = {for (final p in pings) p.memberId: p} {
    assert(
      _byMember.length == pings.length,
      'a member cannot hold two slots on the same day',
    );
  }

  /// How many slots this day actually holds.
  int get slotCount => pings.length;

  /// This member's ping today, or null if they have none.
  ///
  /// Returns a single [Ping], not a list: the one-a-day ceiling has no
  /// collection to overflow. See [pingsPerPersonPerDay].
  Ping? pingFor(String memberId) => _byMember[memberId];

  @override
  String toString() => 'DayAssignment(${dateKey(date)}: '
      '${pings.map((p) => '${p.localLabel} ${p.memberId}').join(', ')}'
      '${unpingedMemberIds.isEmpty ? '' : ' | no slot: '
          '${unpingedMemberIds.join(', ')}'})';
}

/// Rounds a duration up to a whole minute.
int _openMinuteOf(Duration d) {
  final whole = d.inMinutes;
  final isExact = whole * Duration.microsecondsPerMinute == d.inMicroseconds;
  return isExact ? whole : whole + 1;
}

/// Deals one day of a trip: every member's ping, or the reasons they have
/// none.
///
/// A pure function of `(tripId, party, day, window)`. Two phones that hold
/// the same trip, the same roster and the same date compute bit-for-bit
/// identical answers with no coordination, no server and no network --
/// which is the property this whole package exists for.
///
/// The day is divided into as many equal slots as there are people, one
/// person per slot, dealt by a permutation reshuffled every day so nobody
/// owns the breakfast slot for a whole trip. See
/// `docs/decisions/2026-08-22-the-moment.md`.
DayAssignment dayAssignment({
  required String tripId,
  required Party party,
  required TripDay day,
  PingWindow window = PingWindow.standard,
}) {
  final (open, close) = day.resolveBounds(window);
  final openMinute = _openMinuteOf(open);
  final closeMinute = close.inMinutes;
  assert(openMinute >= 0, 'a day cannot open before local midnight');

  final seedBase =
      '$_slotNamespace/$tripId/${party.fingerprint}/${dateKey(day.date)}';

  // The permutation covers the whole party even when only part of it is
  // dealt in, so that who sits out a short day rotates with everyone else
  // rather than being decided separately.
  final order = dealOrder(seedBase: seedBase, partySize: party.size);
  final slots = slotCountFor(
    partySize: party.size,
    availableMinutes: closeMinute - openMinute,
  );

  final midnightUtc = day.localMidnightUtc;
  final pings = <Ping>[];
  for (var slot = 0; slot < slots; slot++) {
    final minute = pingMinuteForSlot(
      seedBase: seedBase,
      openMinute: openMinute,
      closeMinute: closeMinute,
      slotCount: slots,
      slotIndex: slot,
    );
    pings.add(Ping(
      memberId: party.memberIds[order[slot]],
      slotIndex: slot,
      at: midnightUtc.add(Duration(minutes: minute)),
      localTimeOfDay: Duration(minutes: minute),
    ));
  }

  final unpinged = order.skip(slots).map((i) => party.memberIds[i]).toList()
    ..sort();

  return DayAssignment._(
    date: DateTime(day.date.year, day.date.month, day.date.day),
    utcOffset: day.utcOffset,
    opensAt: open,
    closesAt: close,
    pings: List.unmodifiable(pings),
    unpingedMemberIds: List.unmodifiable(unpinged),
  );
}
