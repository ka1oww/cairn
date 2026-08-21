import 'assignment.dart';
import 'party.dart';
import 'ping_window.dart';
import 'trip_day.dart';

/// Deals every day of a trip in one offline pass, so the app can hand the
/// whole run to the OS notification scheduler and then not touch the
/// network again for the rest of the trip.
///
/// [days] is the itinerary: one [TripDay] per calendar day, each carrying
/// the clock it starts in and any arrival or departure time that shortens
/// it. Build an ordinary single-country trip's list with [tripDays]; build
/// it by hand when the party changes country mid-trip, so each day can
/// carry the offset in force where that day begins.
///
/// Returns one [DayAssignment] per day, in the order given.
List<DayAssignment> tripSchedule({
  required String tripId,
  required Party party,
  required List<TripDay> days,
  PingWindow window = PingWindow.standard,
}) {
  return List.unmodifiable([
    for (final day in days)
      dayAssignment(
        tripId: tripId,
        party: party,
        day: day,
        window: window,
      ),
  ]);
}

/// Builds the [TripDay] list for a trip that stays in one clock.
///
/// [fromDate] and [toDate] are calendar dates, inclusive; only their
/// year/month/day fields are read. [arrival] and [departure] are offsets
/// from local midnight -- the time you actually land on the first day and
/// actually leave on the last -- and are applied only to those two days,
/// which are the only two where the fixed waking day is reliably wrong.
///
/// On a single-day trip both bounds apply to that one day.
///
/// For a trip that crosses a border, construct [TripDay]s directly so each
/// day can carry its own [TripDay.utcOffset].
List<TripDay> tripDays({
  required DateTime fromDate,
  required DateTime toDate,
  required Duration utcOffset,
  Duration? arrival,
  Duration? departure,
}) {
  final from = DateTime(fromDate.year, fromDate.month, fromDate.day);
  final to = DateTime(toDate.year, toDate.month, toDate.day);
  if (to.isBefore(from)) return const [];

  final days = <TripDay>[];
  var current = from;
  while (!current.isAfter(to)) {
    days.add(TripDay(
      date: current,
      utcOffset: utcOffset,
      opensAt: current == from ? arrival : null,
      closesAt: current == to ? departure : null,
    ));
    current = DateTime(current.year, current.month, current.day + 1);
  }
  return List.unmodifiable(days);
}

/// Every ping belonging to one person across a whole schedule, in order.
///
/// This is what a device actually registers with the OS: its own line
/// through a schedule it computed for the entire party. At most one entry
/// per day, and fewer entries than days if a short arrival or departure
/// day had no slot for them.
List<Ping> pingsForMember(List<DayAssignment> schedule, String memberId) {
  return List.unmodifiable([
    for (final day in schedule)
      if (day.pingFor(memberId) case final ping?) ping,
  ]);
}
