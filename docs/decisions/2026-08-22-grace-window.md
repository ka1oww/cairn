# The grace window is fourteen days, and the book never expires — 22 August 2026

Decided by the captain, on the answer board, agreeing to the recommendation:
*"Sure. That's a good idea actually."* This answers the question
[grill round one](2026-08-22-grill-round-one.md) §4 left open.

## The decision

**Fourteen days of grace after a trip ends. Then the trip closes to new
photos. The book stays makeable forever.**

## Why the number stopped being hard once it was split

He first said "a month? not sure — would like to discuss". The uncertainty was
real, and it came from one number being asked to do two different jobs:

| The job | What it protects | Cost of getting it wrong |
|---|---|---|
| When the trip stops accepting new photos | Someone who shot on a real camera, or forgot to import | Too short: a photo lost permanently |
| When the book can still be made | The payoff | Too short: the ending becomes a deadline nobody met |

Forced to share one number, those two trade a lost photo against a lost book.
They do not have to share one. Split them and each gets the answer it wants.

Fourteen rather than thirty because people empty their camera roll within days
of getting home or they never do; the extra fortnight buys silence, not
photos. And the trip has to actually close, or the real ending decided in
[grill round one](2026-08-22-grill-round-one.md) §4 never happens and the trip
stays a document instead of becoming a keepsake.

The book stays open indefinitely at no cost, because by the time it closes the
photos are already in. This is also the only answer consistent with
[last calls](2026-08-22-last-calls.md) §5: a keepsake that phones home — or
expires — is not a keepsake.

## What this settles for the build

Two separate rules, not one:

- **Trip closes to new contributions:** trip end + 14 days.
- **Book generation:** available forever, from photos already in the pool.

**Do not implement these as one timestamp.** They protect different things,
they were deliberately unbundled to get each its right answer, and a single
"trip expiry" field would silently re-bundle them — the exact mistake the
split exists to prevent.
