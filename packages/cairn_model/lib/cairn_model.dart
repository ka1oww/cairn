/// The Cairn trip domain, defined once so the database, the app's state layer
/// and the interface speak the same vocabulary.
///
/// Pure Dart: no Flutter, no network, no database, no I/O. See the package
/// README for what each word means and which decision record settled it.
library;

export 'src/calendar_date.dart' show CalendarDate;
export 'src/clock_time.dart' show ClockTime;
export 'src/day_pool.dart' show DayPool;
export 'src/day_standing.dart' show DayStanding;
export 'src/gate.dart' show GateState;
export 'src/ids.dart' show MemberId, PhotoId, TripId;
export 'src/invite_code.dart' show InviteCode;
export 'src/member.dart' show Member;
export 'src/photo_ref.dart' show PhotoOrigin, PhotoRef;
export 'src/stop.dart' show Stop;
export 'src/trip.dart' show Trip;
export 'src/trip_clock.dart' show TripClock;
export 'src/trip_close.dart' show graceAfterATrip, tripClosesAt;
export 'src/trip_day.dart' show TripDay;
export 'src/trip_invite.dart' show InviteStanding, TripInvite;
export 'src/trip_powers.dart'
    show
        canDeleteTrip,
        canMintInvite,
        canRemoveMember,
        canRenameTrip,
        canRevokeInvite,
        removalPowerHolder;
