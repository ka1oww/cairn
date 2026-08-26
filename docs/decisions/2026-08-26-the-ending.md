# The grace is seventy-two hours, and a closed trip is a record — 26 August 2026

Decided by the captain, confirming the window's length while the ending was
being built: **trip end + 72 hours**. It shortens the number set by
[the grace window](2026-08-22-grace-window.md); everything else that decision
settled stands, including the half that mattered most — the split.

## The decision

**A trip ends when its last day seals. For seventy-two hours after that it
still takes photographs and nothing else. Then it closes: uploads shut, invite
codes die, and what it holds becomes the record it closed with.**

Three standings, and the app never has a fourth:

| Standing | Takes photographs | Admits joiners | Editable |
|---|---|---|---|
| `underway` | yes | yes | yes |
| `grace` | yes | yes | yes |
| `archived` | no | no | no |

## Why seventy-two hours and not a fortnight

The argument that made fourteen right has not changed, and it is the argument
that makes seventy-two hours better. People empty their camera roll within days
of getting home or they never do, so the length of the window buys silence
rather than photographs. Fourteen days was that reasoning stopped halfway;
three days is it taken to its end. It covers the flight home and the first
evening back, which is when a real-camera shooter actually imports, and then
the trip becomes a keepsake instead of trailing off for a fortnight.

What has *not* changed is the split. The trip's close and the book's
availability are still two rules and must never become one timestamp: the book
never expires, and a single "trip expiry" field would silently re-bundle them.
That is why `trip_close.dart` holds one constant and deliberately says nothing
about the book.

## Where the rule lives

**One function.** `tripStandingAt` in `cairn_model`'s `trip_standing.dart`
decides the standing from `(now, endsAt)`, and every surface and every write
path asks it — through `tripStandingProvider` on the phone. A second comparison
of dates above that provider is the thing to refuse in review, for the same
reason a second copy of `GateState.decide` is.

The read-only half of it is a *permission*, not a presentation: `trip_powers.dart`
refuses renaming, minting and revoking on an archived trip, so a new caller
inherits the rule instead of having to remember it. The one exception is
`canDeleteTrip`, which takes no standing at all — deleting is discarding the
whole record rather than editing it, and the guard that actually protects
people (nobody may delete a trip holding somebody else's photographs) is
already on it.

## What "the book is made" means here, and what it does not

At the close the trip's final state — the itinerary, the pool, the party — is
fixed. That is the whole of what this decision implements. **No archive
presentation was designed or built**: the post-trip day page says the trip is
walked and adds one sentence for where the ending stands, the trip's sheet says
the same sentence and stops offering what it cannot do, and that is all. The
book and the handover are a separate later piece of work and are deliberately
not promised anywhere in this one.

## Written twice, never three times

The number is in two places and the probe compares them:

- `graceAfterATrip` in `packages/cairn_model/lib/src/trip_close.dart`
- `trip_grace_after_end()` in `supabase/migrations/0005_trip_invites.sql`

`supabase/tests/rls_probe.py` reads the Dart constant out of the source and
checks the SQL against it, the same way it does for the invite vocabulary.

Both halves of the close are enforced on both sides, because there are eight
phones and one of them has a wrong clock:

| The rule | Phone | Server |
|---|---|---|
| No new photographs | `CaptureFlow.turnTheDayOver` / `open` | `photos_insert_trip_member` |
| Codes die | `TripInvite.standingAt` | `redeem_trip_invite` via `trip_closes_at` |
| The plan cannot be replaced | `PasteFlow.accept` | — (the phone owns the plan's shape) |
| No sync at all | `TripSync._reconcile` → `SyncStanding.archived` | `sync_trip_itinerary` via `trip_closes_at` |

What the close does **not** take is a person's hold on their own photograph:
correcting which day it landed on, or removing it, stays theirs afterwards, on
both sides. Shutting that too would be curation, and nobody on a Cairn trip
curates anybody — not even themselves out of the record's shape.

## The clock

The end is midnight on the trip's own clock, not UTC's: the phone works it out
as the last dated day plus a day minus the trip's offset, and the server reads
`(end_date + 1) at time zone t.timezone`. This slice has one offset for the
whole trip, read off the device — the same acknowledged approximation as
`todayProvider`, and the same one place that changes when a stored trip clock
lands. Two travellers sixteen hours apart therefore see the archive shut
sixteen hours apart, which is correct: it shuts at the end of *the trip's*
third day home, and the trip has one clock.

A trip ends at the end of its **last** day, and a plan whose last day carries
no date has not ended: it is `underway`, deliberately, and never "closed" or
"unknown" — nothing in this app guesses a date, so nothing in it expires on
one. That covers a plan with no dates at all and equally a plan dated only as
far as day 3 of 8, which ending on the last *dated* day would archive while
its travellers were still on it. The arithmetic is `cairn_model`'s
`tripEndsAtFrom`, over the plan's day dates in plan order, and both sides of
the sync seam call it rather than restating it.
