/// Where a day stands against an instant, on that day's own clock.
///
/// This is the only question the gate asks about time, and it is asked in one
/// place so that "which day is the one you are living" cannot be answered two
/// slightly different ways in two layers
/// (`docs/architecture.md`, invariant 2).
enum DayStanding {
  /// The day has not begun yet on its own clock.
  notYet,

  /// The day being lived: the instant falls inside `[startsAt, endsAt)`.
  inProgress,

  /// The day is behind us. It sealed at its own midnight and nothing moves it
  /// afterwards — which is what makes it the party's rather than anyone's
  /// (`docs/decisions/2026-08-22-grill-round-one.md` §1).
  walked;

  /// Whether the day is over.
  bool get isWalked => this == DayStanding.walked;
}
