/// When a trip closes, which is one of the two rules the ending is made of.
///
/// **Two rules, never one timestamp.** The trip stops accepting new
/// contributions fourteen days after it ends; the book stays makeable
/// forever (`docs/decisions/2026-08-22-grace-window.md`). They were
/// deliberately unbundled so each could have its right answer, and a single
/// "trip expiry" field would silently re-bundle them. So only the first rule
/// is written here, and the book's is deliberately absent rather than
/// forgotten: there is nothing to compute for something that never expires.
library;

/// How long after a trip ends it still takes photographs.
///
/// Fourteen rather than thirty because people empty their camera roll within
/// days of getting home or they never do — the extra fortnight buys silence,
/// not photos.
const graceAfterATrip = Duration(days: 14);

/// The instant [tripEndsAt] closes to new contributions.
///
/// This is also when the trip's invite codes die
/// (`docs/decisions/2026-08-22-grill-round-one.md` §5): after the end every
/// day is past, so a code that outlived its trip would open the whole
/// archive to whoever still remembered three words. The codes take this
/// instant rather than carrying an expiry of their own, because two
/// timestamps for one rule are two chances to disagree about when a trip is
/// over.
DateTime tripClosesAt(DateTime tripEndsAt) => tripEndsAt.add(graceAfterATrip);
