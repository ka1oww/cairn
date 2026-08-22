# The camera stays BeReal-shaped — 22 August 2026

Decided by the captain, in chat, after reading the dual-camera spike (PR #14).

## The decision, in his words

> yes, i believe we should keep the taking of the photo resembling of the
> bereal as it is something many people are used to already

## What it settles

The capture keeps the shape people already recognise: **the back camera takes
the photograph, and a small inset from the front camera catches your own
face.** Taken as a **back-then-front sequence**, not both at once.

Familiarity is the stated reason. Not novelty, not technical merit — the
gesture is one the party has already learned somewhere else, and that is worth
more than anything a different arrangement would buy.

## Why this is not a new decision so much as a confirmed one

The record already said this. [Design calls](2026-08-22-design-calls.md) §5
reads "Back camera, with a small front inset … in the manner people already
know from BeReal", and calls the inset "a nice-to-have, not the mechanic".

What changed is that it is now settled on **evidence rather than assumption**.
The spike established that BeReal itself does not capture simultaneously: its
published minimum device requirements are older than simultaneous-capture
hardware allows, so it cannot be doing it. "Like BeReal" therefore *means*
sequential. The two positions that looked like they might conflict turned out
to be the same position.

## What is explicitly not being built

**True simultaneous capture.** It is reachable on both platforms — iOS through
`AVCaptureMultiCamSession` on an A12 or newer, Android through Camera2's
concurrent camera ids on Android 11+ — but each route needs hand-written
native code, has no Flutter support worth the name, and excludes real phones
the party would plausibly carry. It buys nothing the familiar gesture does not
already deliver.

If it is ever revisited, the spike at `learning/dual-camera-spike/` holds the
evidence and the working sequencer.

The two-frame camera is also not part of the first release: back-only is the
accepted fallback from design calls §5, and
[what the first release is](2026-08-22-first-release.md) puts the inset after
the line.

## The stale inversion, confirmed dead

An earlier design note had the moment's camera **inverted to
front-full-bleed**. That note attached to the shared simultaneous moment,
which was cut by [the moment](2026-08-22-the-moment.md) — and front-full-bleed
is the *opposite* of the composition decided here, so the record could not be
allowed to hold both.

The repository was swept for it on 22 August: every decision file, the design
README and round reviews, both early handoff bundles (whose camera surface 5c
draws "Back camera full-bleed, the selfie's future home a dashed frame"), the
architecture map, the root README, and the spike's own code. The inversion
survives nowhere in the tree. The record holds exactly one composition:
back-full-bleed, front inset. Whoever builds the camera screen builds that.
