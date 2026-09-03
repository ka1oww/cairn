# Two minutes, unlimited retakes, one deadline — 3 September 2026

Decided by the captain, narrowing the capture timing after living with the
built flow. It supersedes the number in
[design calls](2026-08-22-design-calls.md) §7 and nothing else in that call:
late contributions are still always allowed, still carry their real hour, and
are still visibly late until midnight.

## The decision

**The window is two minutes. Inside it you may retake as often as you like,
and every retake answers the same deadline. A capture taken after the window
shut is late, and stays late.**

Four calls, and they only work together.

## Two minutes, not thirty

Thirty minutes let a person wait for a good moment. That is precisely the thing
this app refuses to be: a half hour is long enough to finish the meal, find the
light, get somewhere photogenic and *then* answer, and what lands is a picture
you arranged rather than a record of what was actually happening. A window
short enough that you answer it where you are standing is the whole mechanic.

The narrowing is only affordable because the ping is *yours* and nobody else's
([the moment](2026-08-22-the-moment.md)): a personal minute is a much smaller
thing to miss than a party-wide one, and missing it costs nothing that matters
because the late path never closes.

The number is `captureWindow` in `lib/app_state/capture_flow.dart`, which is
the only place it is written. It is not restated here on purpose.

## Unlimited retakes

The old cap of one retake was the authenticity guard, and it policed the wrong
thing. It priced fumbling the camera exactly as dearly as curating: a thumb
over the lens and a third attempt at a better angle both spent the same single
allowance, and only one of those is the behaviour the cap existed to stop.

The honest constraint was always the deadline. So the cap comes off and the
deadline does the work — which it can, because two minutes is not enough time
to curate however many attempts you are given.

## A retake reuses the same deadline

This is what makes unlimited retakes safe, and it is not a detail.

If a retake restarted the window, retaking would become a way to buy time, and
"unlimited retakes" would silently mean "unlimited window" — the two-minute
call above, destroyed by the one under it. **The deadline belongs to the
moment, not to the attempt.**

It is held that way structurally rather than by a rule someone has to remember.
The framing and breath states carry the moment's own `closesAt` and *nothing
else* about the window; whether you are late, whether you are in the tail, and
how long is left are all derived from that one instant by `windowStandingAt`.
There is no second copy of the verdict for any code path to reset.

## Late stays late

The record has to be honest. A capture taken after the window shut is marked
late and is never relabelled punctual — not by a retake, not by a hundred of
them, not by anything. **The app must never say punctual when you are not.**

The structural change above is what guarantees it rather than merely intending
it. Deriving late from a fixed instant makes it monotonic: time runs forwards
and the deadline never moves, so a moment that has gone late cannot come back.
The bug this replaces did the opposite — the retake path handed back a state
built with `isLate: false`, and a late capture came back from a retake looking
punctual. The same derivation also fixes a case the old latched boolean got
wrong in the other direction: a window that shuts *during* the breath now reads
as honestly late instead of staying frozen punctual.

## The last stretch was retuned, not collapsed

`lastStretch` was two minutes because it was the *tail* of a thirty-minute
window. At a two-minute window that tail is the whole window, and leaving it
where it was would have left a second number contradicting the first.

The two ways out were to collapse the concept or to retune it. **It is
retuned, to thirty seconds** — deliberately, and this is the record of why.
Collapsing it would make "the last stretch" and "the window" the same interval,
which turns the not-in-the-tail state into one nobody could ever be in and the
day page's line for it into words nobody could ever read. A quarter of the
window keeps both readings reachable and keeps the tail long enough to be a
change of wording rather than an alarm. The constant carries the same reasoning
beside it in `capture_flow.dart`.

## What the person sees

At two minutes the countdown stops being decoration and becomes the main
feedback the screen gives, so it is built (the design's drawn treatment of it —
the dashed thread burning down the edge — is not, and is still owed). Three
properties of it are rules rather than looks:

- **One clock for the whole route**, hoisted above the state switch. A clock
  that restarted on the framing-to-breath hop would hand back seconds the
  window had already spent, which is the retake bug wearing a different hat.
- **It is seeded from the app's own clock**, so it cannot disagree with the
  state machine about the same window, and a test that pins the clock governs
  it too.
- **A late capture is shown no timer at all**, which is surface 10c's rule
  taken literally: there is no thread, so there is nothing to have failed.

And the posted photograph never says how many retakes it took. No count is
held anywhere — not in the state, not in the store — because there is nothing
for it to be used for that is not a way of ranking people on how readily they
answered.
