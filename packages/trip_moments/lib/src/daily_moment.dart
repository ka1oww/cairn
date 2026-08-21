import 'quiet_window.dart';
import 'stable_hash.dart';

/// The seed namespace/version for the daily-moment derivation.
///
/// Baked into every seed string so that if the derivation ever needs to
/// change incompatibly, it can be bumped to `v2` and old and new builds
/// will at least fail loudly (disagree deterministically) rather than
/// silently drift. See the README for why a silent change is the failure
/// mode to avoid.
const String _dailyMomentNamespace = 'trip_moments/v1/daily';
const String _scatteredPingNamespace = 'trip_moments/v1/scatter';

/// Formats a calendar date as `YYYY-MM-DD`.
///
/// Only [DateTime.year], [DateTime.month] and [DateTime.day] are read —
/// any time-of-day or timezone component on the [DateTime] passed in is
/// ignored. Callers should pass the trip's *calendar* date for the day in
/// question, not a specific instant.
String dateKey(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Maps a `[0, 1)` unit value onto an absolute instant within [window] on
/// the given calendar [date], in a location [tripUtcOffset] east of UTC.
DateTime _placeInWindow({
  required DateTime date,
  required Duration tripUtcOffset,
  required QuietWindow window,
  required double unit,
}) {
  assert(unit >= 0 && unit < 1);
  // The instant of local midnight for `date` in the trip's timezone,
  // expressed as a UTC DateTime. If the trip is UTC+8, local midnight is
  // 16:00 UTC the previous day, i.e. UTC = local - offset.
  final localMidnightUtc =
      DateTime.utc(date.year, date.month, date.day).subtract(tripUtcOffset);
  final offsetWithinWindow = window.start +
      Duration(
        microseconds: (window.span.inMicroseconds * unit).round(),
      );
  return localMidnightUtc.add(offsetWithinWindow);
}

/// Computes **the** daily moment: an instant that every device on [tripId]
/// derives identically for the same [date], with no coordination and no
/// server, because it's a pure function of `(tripId, date)`.
///
/// The returned [DateTime] is a UTC instant. It always falls inside
/// [window] measured in the trip's own local time ([tripUtcOffset] east of
/// UTC), not the caller's local timezone.
///
/// Only the calendar fields of [date] (year/month/day) are used — see
/// [dateKey].
DateTime dailyMoment({
  required String tripId,
  required DateTime date,
  required Duration tripUtcOffset,
  QuietWindow window = QuietWindow.standard,
}) {
  final seed = '$_dailyMomentNamespace/$tripId/${dateKey(date)}';
  final unit = stableUnitInterval(seed);
  return _placeInWindow(
    date: date,
    tripUtcOffset: tripUtcOffset,
    window: window,
    unit: unit,
  );
}

/// Computes a single device's scattered ping: an instant derived from
/// [tripId], [date] *and* [deviceId], so each phone gets its own time each
/// day (different from every other phone on the trip), while still being
/// reproducible by that same phone recomputing it later.
///
/// [deviceId] should be a stable per-installation identifier (for example
/// a UUID generated once and persisted locally) — it never needs to leave
/// the device or be shared with anyone else on the trip for this to work.
///
/// The returned [DateTime] is a UTC instant, always inside [window] in the
/// trip's own local time.
DateTime scatteredPing({
  required String tripId,
  required DateTime date,
  required String deviceId,
  required Duration tripUtcOffset,
  QuietWindow window = QuietWindow.standard,
}) {
  final seed = '$_scatteredPingNamespace/$tripId/${dateKey(date)}/$deviceId';
  final unit = stableUnitInterval(seed);
  return _placeInWindow(
    date: date,
    tripUtcOffset: tripUtcOffset,
    window: window,
    unit: unit,
  );
}
