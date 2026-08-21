/// Pure-Dart, offline, deterministic derivation of trip notification
/// timing: one ping per person per day, dealt across the party so that no
/// two people are interrupted at the same time. No Flutter, no network, no
/// server -- see the package README.
library trip_moments;

export 'src/assignment.dart'
    show DayAssignment, Ping, dayAssignment, pingsPerPersonPerDay;
export 'src/party.dart' show Party;
export 'src/ping_window.dart' show PingWindow;
export 'src/slots.dart'
    show dealOrder, minimumSlotMinutes, pingMinuteForSlot, slotCountFor, slotStartMinute;
export 'src/stable_hash.dart'
    show stableDigestMax, stableDigestValue, stableFingerprint, stableIndex;
export 'src/trip_day.dart' show TripDay, dateKey;
export 'src/trip_schedule.dart' show pingsForMember, tripDays, tripSchedule;
