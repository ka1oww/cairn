# Traveling App

A shared trip companion for a group of friends — eight of them, on one trip —
travelling together.

> Today's plan on the way out, today's memories on the way back.

One person pastes a rough itinerary before the trip. The trip renders as a winding
path with one node per day and a flag on today; days advance by the clock, never by
completing anything. Everyone opens it in the morning to see what the day holds.
During the day, photos are taken — including BeReal-style dual shots — and photos
from the camera roll are swept in when the app is opened (iOS offers no background
import, and the app promises nothing more than that). Everything lands in a shared
pool sorted by day, and the pool becomes a book when the trip ends.

This is a passion project, not a business. There is no monetisation goal.

## Status

Pre-implementation. The decision and design records live in `docs/` (see below);
nothing here is the real app yet.

## Planned stack

- **Flutter**, iOS first. Web and PWA were ruled out because iOS evicts PWA storage.
- **Sign in with Apple** as the first auth route.
- A **minimal backend** that does exactly two things: hold the shared photo pool and
  hold trip membership. The itinerary, the trail, the stars and the daily ping are
  computed on the phone, so the app works fully offline.
- State management and the local database are still being chosen — see
  `learning/riverpod-drift-demo/` once it exists.

## Layout

| Path | What it is |
| --- | --- |
| `learning/` | Throwaway demos built to make a technical decision. Not the app. |

## Where the thinking lives

The full design record — what was decided, what was rejected, and why — is kept
in `docs/decisions/` and `docs/design/`. See those directories for the reasoning
behind the architecture, the design system, and the key decisions. This README is
deliberately thin; it is not the design document.

For what is actually built, what is not, and the order the rest arrives in, see
`docs/roadmap.md`.
