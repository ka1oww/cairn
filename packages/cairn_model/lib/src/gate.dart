import 'day_standing.dart';

/// Whether a day's page is held shut or open to one member, and why.
///
/// Contribution gates access: that is one of the five load-bearing properties
/// of the app and the one thing scattering the daily ping did not touch
/// (`docs/decisions/2026-08-22-the-moment.md`). A shut gate is not an empty
/// screen — it shows the shape of the day, obscured: the times and the names
/// are visible, the images are not
/// (`docs/decisions/2026-08-22-design-calls.md`, "The shut gate shows the
/// shape of the day, obscured"). What it withholds is the photographs, and
/// what this type answers is whether it is withholding them.
///
/// **The gate applies to the day you are living, and to no other day**
/// (`docs/decisions/2026-08-22-grill-round-one.md` §1: *"A day that is over
/// belongs to the party. The gate applies to today only."*). A day that has
/// sealed is open to everyone who was on the trip for it, whether or not they
/// answered it, and whether or not they had even joined yet
/// (`docs/decisions/2026-08-22-last-calls.md` §3). The gate exists to make you
/// contribute to the day you are living, never to punish you afterwards for a
/// day you did not.
///
/// The reason is the value, not a second field beside a boolean: an open gate
/// with a "still waiting for you" reason is not a state the app has, and this
/// way it is not a state that can be built either.
enum GateState {
  /// Open. This person has contributed a photo to this day, so the day is
  /// theirs to see. Deleting that photo afterwards does not close it again —
  /// see `DayPool`.
  ///
  /// Outranks every other reason, and deliberately: it is a fact about the
  /// person rather than about the clock, so a day you answered reads the same
  /// way at three in the afternoon and at three the next morning.
  openedByContribution,

  /// Open. The day is over. A day that has sealed belongs to the whole party —
  /// the people who answered it, the people who did not, and the person who
  /// joined the trip the following morning. There is nothing left to withhold
  /// from any of them.
  openBecauseTheDayIsOver,

  /// Shut. This is the day in progress and this person has not contributed to
  /// it. The way in is to contribute; there is no other key, and no role that
  /// comes with one. It opens by itself at midnight if they never do.
  shutAwaitingContribution,

  /// Shut. The day has not begun. Nothing has happened in it to be shown and
  /// nothing can be put into it yet, so "contribute and it opens" would be a
  /// promise about a day nobody has reached — which is why this is its own
  /// reason rather than [shutAwaitingContribution].
  shutUntilTheDayArrives;

  /// Whether the images on this day's page are visible to the member this
  /// state was computed for.
  bool get isOpen =>
      this == GateState.openedByContribution ||
      this == GateState.openBecauseTheDayIsOver;

  /// The whole rule, in one place.
  ///
  /// Every surface that shows a photograph answers the gate through this —
  /// `Trip.gateFor` for a whole trip, and the app's own state layer for the
  /// one-phone slice that has no roster yet. A second copy of these four lines
  /// is the thing to refuse in review: the phone already keeps one deliberate
  /// duplicate of this rule, in SQL, and that one is documented
  /// (`docs/architecture.md`, invariant 2).
  static GateState decide({
    required DayStanding standing,
    required bool hasContributed,
  }) {
    if (hasContributed) return GateState.openedByContribution;
    return switch (standing) {
      DayStanding.walked => GateState.openBecauseTheDayIsOver,
      DayStanding.inProgress => GateState.shutAwaitingContribution,
      DayStanding.notYet => GateState.shutUntilTheDayArrives,
    };
  }
}
