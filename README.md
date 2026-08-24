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
screen, which is also the screen the trail will open for any other day. Four
pure-Dart domain packages sit under it. The trail, the pool, capture, the daily
ping and every server call are not built yet.

`docs/roadmap.md` is the authority on what is built, what is not, and the order
the rest arrives in; `docs/architecture.md` maps every node and is honest about
the gaps.

## Stack

- **Flutter**, iOS only for now — there is no `android/` directory. Web and PWA
  were ruled out because iOS evicts PWA storage.
- **Riverpod** for app state and **Drift** (SQLite) for the local database.
  Chosen, and built on: the argument is made in `learning/riverpod-drift-demo/`
  and the app commits code to both. Writing that choice down as a decision
  record is queued work — see the honesty section of `docs/architecture.md`.
- **Supabase** (Postgres) and **Cloudflare R2** for the minimal backend, which
  holds only the shared facts: the photo pool, trip membership and the shared
  trip clock. The trail, the stars and the daily ping are computed on the
  phone, so the app works fully offline. The schema is written and exercised against a local
  Postgres; no hosted project exists yet.
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
