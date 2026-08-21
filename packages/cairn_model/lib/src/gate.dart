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
/// The reason is the value, not a second field beside a boolean: an open gate
/// with a "still waiting for you" reason is not a state the app has, and this
/// way it is not a state that can be built either.
enum GateState {
  /// Open. This person has contributed a photo to this day, so the day is
  /// theirs to see. Deleting that photo afterwards does not close it again —
  /// see `DayPool`.
  openedByContribution,

  /// Open. The day ended before this person joined the trip. They could never
  /// have answered it, so there is nothing to withhold: joining hands someone
  /// the shared past rather than showing them hollow days they can never fix
  /// (`docs/design/`, 3d "Joined on day 3").
  openBecauseJoinedLater,

  /// Shut. This person was on the trip for this day and has not contributed to
  /// it. The way in is to contribute; there is no other key, and no role that
  /// comes with one.
  shutAwaitingContribution;

  /// Whether the images on this day's page are visible to the member this
  /// state was computed for.
  bool get isOpen => this != GateState.shutAwaitingContribution;
}
