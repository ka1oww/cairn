# Grill round one — 22 August 2026

Six questions from the first interrogation of the plan, answered on the
round-one review board. The captain took the recommended answer on all six,
with three clarifications of his own recorded below — and the clarifications
govern where they go further than the questions did.

## 1. The gate — past days open

A day that is over belongs to the party. The gate applies to today only.
Captain: *"yes lets do that."*

Consequence: the phone model and the server now agree, and the deliberate
"shut forever" test that pinned the opposite must be removed rather than
worked around. Permanent lockout is rejected because it contradicts the
already-settled decision that a ping missed to Do Not Disturb is acceptable —
see [the alert level](2026-08-22-notification-alert-level.md).

## 2. The itinerary and the roster — synced through the server

The itinerary becomes a shared fact stored on the server, and membership
changes reach every phone so the ping schedule cannot be dealt from a stale
roster.

Captain's clarification: *"we need to make sure that one update on the
itinerary will be deployed to all."* So the itinerary is not distributed once
at join; it is editable and edits propagate to every phone. That is a
stronger requirement than the question asked, and it governs.

The backend charter still holds: the schedule, the Trail and the stars stay
computed on the phone. Storing a shared fact is not computing on the server.

## 3. Photographs — originals kept

The pool stores the original. Resizing happens for display only. The
"full-size set" handover promise from
[first calls](2026-08-21-first-calls.md) stands, and the storage plan must
change to match it, not the other way round.

The captain assumed this is free on Cloudflare. It is not free at the sizes
this implies; it is cheap. The free allowance is small relative to originals
from eight people, and the real measurement was never taken. Sizing the bill
is work, not a decision, and the decision stands regardless of the number.

## 4. The end of a trip — a real ending

A grace window for late photographs, then uploads close, invite codes die,
the book is made, and the archive becomes read-only.

Captain's question: *"and they can export the pool of photos?"* Yes, and that
was already decided — the handover puts the full set on each person's own
phone. Recorded here because nothing implements it yet; the download path is
the highest-severity blank in the backend.

The grace window's length was still unanswered here and belonged to round
two. It is now settled: see [the grace window](2026-08-22-grace-window.md).

## 5. Joining — three spoken words, expiring

Three words, forgiving of order and spelling, expiring at the end of the trip
plus a short grace. The eight-character generator is replaced.
Captain: *"okay suree."*

An invite code that outlives its trip is a privacy hole regardless of what it
is made of: after the end, every day is past, so a stale code opens the whole
archive.

## 6. Both cameras — spike it now

Prototype simultaneous back-and-front capture before any more surfaces are
drawn on top of it.
Captain: *"lets do it now, lets make sure it runs like bereal."*

Scope note: the API question can be answered in code, but proof requires a
physical iPhone. Simulators have no real cameras. The spike ran the same day
and its verdict is recorded in
[the camera stays BeReal-shaped](2026-08-22-camera-like-bereal.md).
