import 'trip_close.dart';

/// Where a whole trip stands against an instant.
///
/// **This is the only place the ending is decided.** `DayStanding` answers it
/// for one day; this answers it for the trip, and every surface, every write
/// path and every seam that has to know whether a trip is over asks here
/// rather than comparing dates of its own. A copy per layer is the thing to
/// refuse in review, for the same reason a second copy of the gate is
/// (`docs/architecture.md`, invariant 2).
///
/// The shape is `docs/decisions/2026-08-26-the-ending.md`: a trip ends when
/// its last day seals, spends [graceAfterATrip] taking nothing but late
/// photographs, and then becomes the archive.
enum TripStanding {
  /// The last day has not sealed. The trip is ahead of us or being lived, and
  /// everything the app can do, it can do.
  underway,

  /// The trip is over and its grace window is still open.
  ///
  /// **Photographs, and nothing else.** This window exists for one thing —
  /// somebody who shot on a real camera, or who has not emptied their roll
  /// yet, can still put the day right. It is not an extension of the trip:
  /// every day has sealed, no ping is dealt, and every surface reads the trip
  /// as over. The one power it holds open is the pool's, and the people who
  /// bring photographs to it, which is why a code still admits somebody here.
  grace,

  /// The grace has run out. The trip takes nothing more.
  ///
  /// What it holds — the itinerary, the pool and the party — is the record
  /// the app presents from here on, and the book made from it never expires.
  /// A code minted before this instant opens nothing after it.
  archived;

  /// Whether the trip is behind us: true in [grace] as well as [archived].
  ///
  /// The distinction the two share is presentational — a trip in its grace
  /// reads exactly as over as an archived one, because it *is* over. What
  /// separates them is only what may still be written.
  bool get isOver => this != TripStanding.underway;

  /// Whether the pool still takes a photograph. The whole of what the grace
  /// window is for.
  bool get takesPhotos => this != TripStanding.archived;

  /// Whether a live code still admits somebody.
  ///
  /// True through the grace, deliberately: the photographs are still coming
  /// and the person holding them has to be able to get in to hand them over.
  /// It goes false at the same instant [takesPhotos] does, because a code
  /// that outlived its trip would open the whole archive to whoever still
  /// remembered three words (`trip_invite.dart`, and the same rule in SQL).
  bool get admitsJoiners => this != TripStanding.archived;

  /// Whether the trip is fixed: the record is what it is and nothing edits
  /// it any more.
  bool get isReadOnly => this == TripStanding.archived;
}

/// Where a trip whose last day seals at [endsAt] stands at [now].
///
/// A null [endsAt] is a trip whose end is not known yet — a plan accepted
/// with its dates still open. It is [TripStanding.underway], because nothing
/// has ended; it is deliberately not read as "never ends", and the trip takes
/// its standing the moment the plan has one. This is the same answer
/// `TripInvite.standingAt` gives a null close, for the same reason.
///
/// **Both boundaries are inclusive of the state they open**, which is the
/// convention every other clock question in this package already follows: a
/// day is `walked` at exactly the instant it seals, and a code is expired at
/// exactly [tripClosesAt]. So a trip is in its [TripStanding.grace] at
/// exactly [endsAt], and [TripStanding.archived] at exactly
/// `endsAt + graceAfterATrip` — never underway for one more microsecond, and
/// never taking one more photograph at the instant it closes.
///
/// [now] is required rather than read from a clock here, for the reason
/// `Trip.gateFor` requires it: this package has none, and a trip's clock
/// follows the itinerary's leg (`docs/decisions/2026-08-22-last-calls.md`
/// §4), so the instant is the caller's to supply. [endsAt] is likewise the
/// caller's, worked out on the trip's own clock and not on UTC midnight —
/// which is what keeps a trip that crossed a border from closing on the
/// wrong evening.
TripStanding tripStandingAt({
  required DateTime now,
  required DateTime? endsAt,
}) {
  if (endsAt == null) return TripStanding.underway;
  final instant = now.toUtc();
  if (instant.isBefore(endsAt.toUtc())) return TripStanding.underway;
  if (instant.isBefore(tripClosesAt(endsAt).toUtc())) {
    return TripStanding.grace;
  }
  return TripStanding.archived;
}
