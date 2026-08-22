# The cat is deferred, not cut — 22 August 2026

Decided by the captain, on the answer board:

> perhaps lets not worry about the cat first, it dosent add anything to the app
> to make it functional. perhaps ticket it for a future feature

## The decision

**The cat is parked as a future feature.** It is not cut, and nothing about
the feasibility finding is disputed — it simply does not earn a place in the
first release, which is defined as
[whatever makes one real trip work for eight people](2026-08-22-first-release.md).

The captain's reasoning is the same reasoning this project accepted earlier
the same day: anything that does not make one real trip work is explicitly
allowed to wait. The cat is the clearest possible instance of that rule, and
applying it to something he likes is the test of whether the rule means
anything.

## The second remark, and the caveat it deserves

> hm...this is not very cute.

That judgement was passed on a **reconstruction**, not on the real artwork.
The four poses shown on the board were hand-transcribed from the design file's
coordinates into a separate drawing for that page. The design's own rendering
may look materially better, and it was never put in front of him.

So: do not carry "not very cute" forward as a verdict on the design's cat. If
the cat is ever revisited, show him the real thing rendered from
`docs/design/2026-08-21-handoff.zip` first. The deferral above stands on its
own reasoning and does not depend on this point either way.

## What was established before deferring, and stays true

- It is a real ~1 second animation once per day, not a jump.
- The artwork already exists as vector primitives in the design file — no
  illustrator, no purchased sprites, no generated frames, no animation engine.
- It needs **no new dependency and no change to the dependency map**: a
  remembered field on a screen that already reads local storage, not a new
  arrow.
- Cost is roughly 1 to 1.5 focused days, on top of the trail screen, and it
  cannot be built before that screen exists.

None of that expires. When the cat is picked up, the investigation does not
need repeating: the full feasibility report lives in firstmate's records at
`data/cairn-cat-feasibility/report.md`.
