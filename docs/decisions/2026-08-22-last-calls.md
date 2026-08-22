# Last planning calls — 22 August 2026

The remaining questions that had to be settled before any code could be written,
because each one decides something the database or the gate already half-assumed.

## 1. Roles are flat, except that the person who started the trip can remove someone

No other asymmetry. Nobody edits anyone else's photos or where they landed.

Among eight friends there is no moderation problem to solve, and hierarchy is
social poison in a group that does not have one. But the join code is three
spoken words, so a wrong join is genuinely possible and somebody has to be able
to undo it. One power, narrowly, and nothing else.

This is also what gives the backend's member-self-promotion defect its meaning:
being able to promote yourself only matters once you have said that the starter
can do something a member cannot.

## 2. You can delete your own photo, and the day stays open

It simply goes. No marker, no gap, no note that something was there.

Re-locking the day would be punitive and slightly absurd — you did contribute,
and you are not undoing that by disliking the picture. And a person should be
able to remove a photograph of themselves they hate; refusing that is the app
being precious about its own artefact at the expense of someone's comfort. A
visible "deleted" gap is a scold with a paper texture.

## 3. Joining mid-trip: past days open freely, today is gated normally

Already drawn in the design — *"two days already walked, their photos are yours
to scroll"*. The gate exists to make you contribute to the day you are living,
not to punish you for having arrived late.

## 4. The trip has one clock, and it follows the itinerary's leg

Every ping slot uses that one clock, so a day stays a single shared day for
everyone on the trip. A photo's day still comes from where it was taken when
location is available; the two packages that disagree about a trip's timezone
reconcile to this rule.

The ping window is waking hours rather than the whole 24, for the obvious
reason: the point is to catch people while they are out and about, and never to
buzz at three in the morning.

## 5. The book never needs the server

A keepsake that phones home is not a keepsake. Once the trip is over, the book
is yours and works with the network off, forever.

A cheap keepalive still runs, protecting the membership data and the free tier's
one-year restore cliff — but that protects the *account*, not the artefact.

## 6. The ping does not break through Do Not Disturb

See [the alert level](2026-08-22-notification-alert-level.md).

## 7. The import promise is worded truthfully

See [the import promise](2026-08-22-auto-import-honesty.md).

## 8. The ping schedule

**The waking window is 08:00 to 22:30.** Eight people across fourteen and a half
hours is one slot roughly every 110 minutes. Deliberately 22:30 rather than
22:00 so the last slot can still catch dinner; anything later is the late-photo
path.

A cleverer itinerary-driven window was argued for and deferred: it makes the
ping schedule depend on the itinerary being complete, so a missing stop becomes
a missing photo. Worth revisiting once a real trip has tested the itinerary.

**The first and last days follow the itinerary's real arrival and departure.**
Land at 16:00 on day one and that day's slots run 16:00–22:30, for however many
people fit. These are the only two days where the fixed window is reliably
wrong, and fewer slots on a short day is correct rather than a shortfall to pad.

**On a day that changes country, the clock is fixed where the day starts** and
only moves at the next day boundary. A day is an artefact, not a measurement:
one clock from start to finish keeps the time thread honest and the slots stable.
