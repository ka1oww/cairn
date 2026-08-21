import 'day_pings.dart';
import 'daily_moment.dart' as core;
import 'quiet_window.dart';

/// Builds the full ping schedule for a trip (or the remaining part of one)
/// in a single offline pass, so the app can register local notifications
/// for every day and then not touch the network again for the rest of the
/// trip.
///
/// [fromDate] and [toDate] are calendar dates (inclusive); only their
/// year/month/day fields are read. A typical call passes `fromDate: today`
/// (or the trip start date, whichever is later) and `toDate: tripEndDate`.
///
/// Returns one [DayPings] per calendar day in range, oldest first. Every
/// entry has exactly [maxPingsPerDay] instants by construction.
List<DayPings> tripSchedule({
  required String tripId,
  required String deviceId,
  required DateTime fromDate,
  required DateTime toDate,
  required Duration tripUtcOffset,
  QuietWindow window = QuietWindow.standard,
}) {
  final from = DateTime(fromDate.year, fromDate.month, fromDate.day);
  final to = DateTime(toDate.year, toDate.month, toDate.day);
  if (to.isBefore(from)) return const [];

  final schedule = <DayPings>[];
  var current = from;
  while (!current.isAfter(to)) {
    final moment = core.dailyMoment(
      tripId: tripId,
      date: current,
      tripUtcOffset: tripUtcOffset,
      window: window,
    );
    final scatter = core.scatteredPing(
      tripId: tripId,
      date: current,
      deviceId: deviceId,
      tripUtcOffset: tripUtcOffset,
      window: window,
    );
    final day = DayPings(
      date: current,
      dailyMoment: moment,
      scatteredPing: scatter,
    );
    assert(day.instants.length <= maxPingsPerDay);
    schedule.add(day);
    current = current.add(const Duration(days: 1));
  }
  return schedule;
}
