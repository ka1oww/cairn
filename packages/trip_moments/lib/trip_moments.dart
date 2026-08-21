/// Pure-Dart, offline, deterministic derivation of trip notification
/// timing. No Flutter, no network, no server — see the package README.
library trip_moments;

export 'src/daily_moment.dart' show dailyMoment, scatteredPing, dateKey;
export 'src/day_pings.dart' show DayPings, maxPingsPerDay;
export 'src/quiet_window.dart' show QuietWindow;
export 'src/stable_hash.dart' show stableUnitInterval;
export 'src/trip_schedule.dart' show tripSchedule;
