/// When a trip closes, which is one of the two rules the ending is made of.
///
/// **Two rules, never one timestamp.** The trip stops accepting new
/// contributions seventy-two hours after it ends; the book stays makeable
/// forever (`docs/decisions/2026-08-26-the-ending.md`, which carries the
/// number, and `docs/decisions/2026-08-22-grace-window.md`, which is why it
/// is split in two at all). They were deliberately unbundled so each could
/// have its right answer, and a single "trip expiry" field would silently
/// re-bundle them. So only the first rule is written here, and the book's is
/// deliberately absent rather than forgotten: there is nothing to compute for
/// something that never expires.
///
/// Where a trip *stands* against this instant — underway, in its grace, or
/// archived — is `trip_standing.dart`, and it is the only place that decides
/// it.
library;

/// How long after a trip ends it still takes photographs.
///
/// **Seventy-two hours**, confirmed by the captain on 26 August 2026. The
/// number the split originally landed on was fourteen days; the shape it was
/// protecting is unchanged and the reasoning that produced the split still
/// reads true — people empty their camera roll within days of getting home or
/// they never do, so the length of the window buys silence rather than
/// photographs. Three days is the same argument taken to its end: it is long
/// enough to cover the flight home and the first evening back, and short
/// enough that the trip actually becomes a keepsake instead of trailing off.
///
/// This is written twice and never three times: here, and as
/// `trip_grace_after_end()` in `supabase/migrations/0005_trip_invites.sql`.
/// `supabase/tests/rls_probe.py` reads this constant out of this file and
/// compares the two rather than trusting them to stay in step.
const graceAfterATrip = Duration(hours: 72);

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
