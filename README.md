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

Under construction, and running. The app builds and opens on a phone: paste a
rough itinerary, confirm what the parser read, and land on **Today** — the day
screen the Trail opens for every other day too. The Trail, the Pool and the
capture that fills it are built, and four pure-Dart domain packages sit under
them. Nothing buzzes yet: the daily ping's schedule is real but nothing is
registered with iOS. The one server path that exists — the itinerary and the
roster syncing to every phone — is built and tested but dormant: it waits on a
hosted project to point at and a session to speak as. A trip now *ends* as
well as starting: when its last day passes it spends seventy-two hours taking
late photographs and nothing else, and after that it is a read-only record —
uploads shut, invite codes die, and the plan cannot be replaced. The book made
from that record is still ahead.

`docs/roadmap.md` is the authority on what is built, what is not, and the order
the rest arrives in; `docs/architecture.md` maps every node and is honest about
the gaps. `docs/storage-and-cost.md` is what the shared photo pool costs to
keep, measured against a real camera roll rather than estimated.

## Stack

- **Flutter**, iOS only for now — there is no `android/` directory. Web and PWA
  were ruled out because iOS evicts PWA storage.
- **Riverpod** for app state and **Drift** (SQLite) for the local database,
  on Drift's native backend. Chosen, built on, and recorded in
  `docs/decisions/2026-08-25-riverpod-and-drift.md`, which says what they were
  weighed against; the argument was first made in working code in
  `learning/riverpod-drift-demo/`.
- **Supabase** (Postgres) and **Cloudflare R2** for the minimal backend, which
  holds only the shared facts: the photo pool, trip membership, the itinerary
  and the shared trip clock. The trail, the stars and the daily ping are
  computed on the phone, so the app works fully offline. The schema is written
  and exercised against a local Postgres; no hosted project exists yet.
- **Sign in with Apple** as the first auth route. Not built.

## Layout

| Path | What it is |
| --- | --- |
| `lib/`, `ios/` | The Flutter app. `lib/README.md` is the authority on its layout. |
| `packages/` | Pure-Dart packages the app is written against, kept Flutter-free. |
| `supabase/` | The backend schema and its local tests. Nothing is hosted yet. |
| `learning/` | Throwaway demos built to make a technical decision. Not the app. |

## Where the thinking lives

The full design record — what was decided, what was rejected, and why — is kept
in `docs/decisions/` and `docs/design/`. See those directories for the reasoning
behind the architecture, the design system, and the key decisions. This README is
deliberately thin; it is not the design document.

For what is actually built, what is not, and the order the rest arrives in, see
`docs/roadmap.md`.
