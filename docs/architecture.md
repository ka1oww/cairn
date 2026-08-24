# Cairn — the dependency map

Every piece of the app as a node, arrows for what-knows-what, so that pointing
at any node answers "what breaks if this changes." The visual twin of this
file is [`architecture.html`](architecture.html) — same nodes, same arrows,
drawn. This file is the durable, diff-able, greppable version.

Drawn 22 August 2026 from `main` (after PRs #7–#10 merged) and PR #11
(design round 7). Updated the same day for the app scaffold
(`fm/cairn-app-scaffold`), which turned the app bands from intention into
first code. Updated 24 August 2026 for the paste-and-confirm flow
(`fm/cairn-screen-paste-confirm`), the app's first real screens, and again
the same day for Today (`fm/cairn-screen-today`), the day page that replaced
that slice's placeholder as the launch surface.
Sources: `docs/roadmap.md`, all seven files in `docs/decisions/`,
`supabase/README.md`, `AGENTS.md`, and each package's `README.md`.

---

## How to read it

**An arrow means "knows about"** — imports, calls, queries, or is written
against. Every arrow points downward:

> Screens know app state. App state knows repositories. Repositories know
> storage. Storage knows the model. **Nothing ever points upward.**

An upward arrow — a package that imports a screen, a storage class that
reaches into a provider, SQL that assumes a widget — is a layering violation,
and making one visible is this map's whole job.

Two things that are *not* arrows:

- **Data flowing upward is fine.** A repository returns rows; a package
  returns a schedule. Return values and parameters move data up and in without
  the lower layer knowing who asked. Knowledge points down; data flows any
  direction.
- **A shared rule is not an import.** Three packages encode "a day's clock is
  fixed where the day starts" without referencing each other. Those couplings
  are listed under [Invariants that cross the map](#invariants-that-cross-the-map),
  because they break exactly like dependencies do — just without a compiler
  noticing.

**Node states:**

| State | Meaning |
| --- | --- |
| **built** | Exists and is tested today, on `main` or an open PR branch. |
| **partial** | Exists but is known incomplete. |
| **not built** | Planned. Nothing there yet. |

---

## The most important fact on the map

**The app has a way in and a front door, and only those.** The
paste-and-confirm slice replaced the scaffold's proving screen and its
disposable `trip_drafts` table: a person can paste a plan, see what the
parser understood day by day with its doubt surfaced per cause, flip
ambiguous dates month-first in one tap, and accept — which persists the
itinerary through the seam into Drift. Today (`fm/cairn-screen-today`) then
replaced that slice's placeholder: the app opens on the day page for today's
date, showing the day's identity and its stops in pasted order, with a time
shown only where the plan starred one. The itinerary is **local-only**;
syncing it as a shared fact (grill round one §2) is still not built.
Everything else between the screens and the packages — the Trail, the Pool,
capture, photos on the day page, the ping scheduler, the import sweep, the
platform glue, the Supabase/R2 client adapter — is still **not built**, and
the right edge is unchanged: the backend schema is verified only against a
local Postgres, no hosted Supabase project exists, no R2 bucket has been
created, nothing is deployed.
`lib/README.md` spells this map's bands as directories — read it alongside
this file.

The map therefore still draws the *intended* architecture in full, with state
marked per node. A map of only what exists would omit most of the product.

```
     Trail · Day page & gate · Capture · Pool · Book · Join & confirm · Settings   SCREENS        partial
        │                          (know app state, and nothing below it)
        ▼
     Riverpod providers · ping scheduler · import sweep · platform glue            APP STATE      partial
        │                                     │ (services also know platform
        ▼                                     ▼  edges and domain packages)
     ╔══════════════════ REPOSITORIES — the seam ══════════════════╗               SEAM           partial
     ║  the only layer that knows both storage backends exist      ║
     ╚═══════╤══════════════════════════════════════════╤═════════╝
             ▼                                          ▼
     Drift (local SQLite)                    Supabase/R2 client adapter            STORAGE        partial
                                              │        │         │
                                              ▼        ▼         ▼
                                            Auth   Postgres+RLS  edge fns → R2    BACKEND        partial
        ▼ (storage rows and app types are written against the vocabulary)
     cairn_model  ·  itinerary_parser  ·  trip_moments  ·  photo_day_assignment    DOMAIN         built
```

Platform edges (camera roll, camera, notifications, location, Sign in with
Apple) sit beside the app-state band: services know them; they know nothing.

---

## The repositories seam

The waist of the hourglass. Every question a screen asks funnels down through
app state into this one layer, and this is the **only** layer that knows the
phone has a local database *and* that a network exists. Above it, a provider
asks "photos for day 4" and cannot tell — by construction — whether the answer
came off disk or over the wire. Below it, Drift and the Supabase client never
learn who asked or why.

That opacity is the point, and it is why the seam is the most expensive layer
to skip. Skip it and every screen grows its own opinion about caching,
retries, and which copy of a photo is the real one — eight opinions, all
subtly different, none testable in isolation.

Everything awkward about being offline-first lives here, deliberately, so it
lives nowhere else:

- **The outbox.** Upload bytes to R2 first, insert the `photos` row second, so
  a crash between the two leaves an orphan object (invisible, reconcilable)
  rather than a broken tile (visible to everyone). `supabase/README.md` names
  this ordering; nothing implements it yet.
- **Conflict fallbacks.** Two phones composing the same `day_pages` row: the
  second insert violates `unique (trip_id, page_date)` and must fall back to
  an update. The schema refuses to pick a winner; the repository must.
- **Deletion refetch.** `updated_at` cursors see edits, not deletions; a row
  deleted on another phone is only noticed by refetching.
- **Translation.** The three computation packages deliberately do not import
  `cairn_model` (see below). Their dialects (`ParsedDay`, `PhotoDayAssignmentResult`,
  `trip_moments`' assignments) are converted into the vocabulary here — at one seam,
  not scattered through widgets.

None of this is built, and the conflict/sync policy beyond the notes above is
**undecided** — drawn on the map as open, not settled.

---

## The nodes

For each: what it knows (its outward arrows), what breaks if it changes (its
inward arrows), and why it exists.

### Screens — the way in and the day page built; the rest not built, drawn in `docs/design/`

The scaffold's proving screen is gone, replaced (not extended) by the first
real screens: the paste box, the confirmation screen (design round 8's four
surfaces — the confident read, the doubt surfaced with cause-specific asks,
the one-tap month-first re-read, the paste that wouldn't parse), and the day
page (`lib/screens/`). Round 8's by-hand corrections beyond the asks —
holding a chip to move it between days, renaming in place, laying days out
by hand — are still not built.

**There is one day screen and no separate day detail.** `DayPage(date)` is
the whole of it: Today is `DayPage(today)`, and the Trail will open the same
widget on any other date. That is a structural claim, not a convenience, and
it is what a second "day detail" surface would break. The route back to the
paste box (`repasteRequestedProvider`) is marked temporary in code and is
replaced by the real container when the Trail and the Pool land.

Every screen knows **app state and nothing else** — no repository, no store,
no network, no SQL. What breaks if a screen changes: nothing below it, ever.
That is the layering rule paying rent.

| Node | State | Knows about | Why it exists |
| --- | --- | --- | --- |
| **Trail** | not built | app state | The trip-level front door. The cairn is the trip's portrait, not its front door (design-calls §6). It opens `DayPage` for each day rather than owning a day surface of its own. |
| **Day page & shut gate** | partial — the plan half built (`DayPage`, `lib/screens/day_page.dart`); the photo timeline, the gate and the seal not started | app state | One screen for every day, Today included. Built: the day's identity (day n of m, date, place), the flat ordered stop list, the star and its time — the only time in the app — and the drawn edges (nothing planned, a date the plan skips, before the trip, after it, a plan with no dates). Not built: the day is also the artefact, a vertical timeline of photos with hours prominent and credit small; shut, it shows times and names with images withheld and seals silently at midnight. |
| **Capture** | not built | app state (platform glue drives the camera) | Answers the ping. Back camera primary, small front inset; thirty-minute window; the late path is always open and visibly late. |
| **Pool** | not built | app state | Plumbing: the whole trip's photos in a plain, fast grid by day. Deliberately not a destination. |
| **Book** | not built | app state | What the trip turns into: one spread per day, the photograph as the cover's face with the cairn signing the foot (book-round-nine decision), digital only, works with the network off forever. Automatic — it generates itself and there is no editor (book-no-editor decision). Interior designed in round 9; the printed page is not. Deliberately after the first release. |
| **Join & confirm** | partial — paste-the-plan and the confirmation screen built (local-only); invite code, deep link and display-name edit not started | app state | The way in: invite code (or deep link), display-name edit, paste-the-plan, and the confirmation screen that surfaces the parser's confidence and unplaced lines instead of trusting them. |
| **Settings & members** | not built | app state | Rename, invites, member list, leave, remove. Its affordances follow the starter-and-container decision (rename flat, delete gated, one narrow removal power, never titled "admin"). |

### App state

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **Riverpod providers** | partial — the paste-and-confirm flow's state (`paste_flow.dart`), the saved-plan stream (`trip_providers.dart`), and the day view (`day_view.dart`: which day a date is, and whether it is behind us); nothing of the Trail, the Pool or capture yet | repositories, `cairn_model`, `itinerary_parser` (the parse use case) | Every screen | One source of truth per question. A Drift stream flows through a provider; writing a row updates every watching screen with no manual wiring. The parser's dialect is translated to screen-facing view models here — screens never import it, and no `cairn_model` type reaches one either. |
| **Ping scheduler** | not built | repositories (roster, trip clock, itinerary arrival/departure), `trip_moments`, local-notifications edge | The one interruption per person per day | Feeds `trip_moments` its inputs and registers every remaining day's local notifications in one offline pass. |
| **Import sweep** | not built | camera-roll edge, `photo_day_assignment`, repositories | The completeness of the record | Runs when the app opens — the import promise commits to exactly that and no more (iOS offers no background trigger). Extracts metadata, asks the ladder, queues uploads. |
| **Platform glue** | not built | camera, location, Sign in with Apple edges | Capture and Join | The thin controllers that drive dual capture, tag a pinged photo with GPS so it rides rung 1, and run the sign-in flow. Kept out of widgets so screens stay platform-blind. |

### The seam

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **Repositories** | partial — one repository over the local itinerary tables (`ConfirmedItinerary` in and out, spoken in `cairn_model` vocabulary), unchanged by the Today slice, which needed no new read; the remote side, and everything listed under [The repositories seam](#the-repositories-seam), not started | Drift, Supabase/R2 client adapter, `cairn_model` | Everything above it — every provider, every service, every screen | See [The repositories seam](#the-repositories-seam). The only node that knows both storage backends exist. |

### Storage

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **Drift store** | partial — the itinerary tables (`itinerary_days`, `itinerary_stops`, `itinerary_set_asides`; schema v2, which drops the scaffold's disposable `trip_drafts` demo); no photo or trip table yet | `cairn_model` (rows typed against the vocabulary), device disk | Repositories; transitively every reactive read in the app | Typed SQLite with real joins and watchable queries — "photos per day" is one query, and its stream is what makes the UI reactive. Choice validated in `learning/riverpod-drift-demo/` (native backend on iOS, not the demo's wasm detour) but **not yet recorded in a decision file**. |
| **Supabase/R2 client adapter** | not built | Supabase Auth, Postgres (PostgREST under RLS), both edge functions, R2 (presigned PUT/GET) | Repositories — nothing else in the app may import a Supabase or HTTP symbol | Wraps the session JWT, the RLS-filtered queries, the edge-function calls, and the direct-to-R2 byte transfers behind one interface the repositories consume. |

### Backend (`supabase/` + Cloudflare)

The backend is deliberately minimal: the shared photo pool, trip membership,
the shared trip clock — and, since grill round one §2, the itinerary as a
shared *stored* fact, edited once and propagated to every phone. The trail,
stars, gate evaluation and ping schedule are still computed on the phone and
**must never move server-side without a deliberate decision** (`AGENTS.md`);
storing a shared fact is not computing on the server. The server records
nothing about pings fired or who has answered today.

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **Postgres schema + RLS** | partial — built and verified on a throwaway local Postgres 17 (55-probe RLS suite); **no hosted project exists**; starter-and-container decisions not yet implemented | Supabase Auth (`auth.uid()`); written against the model vocabulary | Client adapter, both edge functions, and cross-device agreement on the trip clock | `profiles`, `trips` (+ timezone/window columns — the one shared clock), `trip_members`, `trip_invites`, `photos`, `day_unlocks`, `day_pages`, `day_page_photos`; `is_trip_member`/`is_trip_starter`, `day_page_is_open`, `redeem_trip_invite`. Membership is the root of every access check. |
| **Supabase Auth (GoTrue)** | not built — no project; Apple provider is a dashboard step; Google queued | (platform service) | Postgres (`auth.uid()` in every policy), client adapter, edge functions | Accounts. Sign in with Apple first; display name editable at join because providers supply legal names. |
| **`r2-upload-url` edge fn** | partial — code exists (membership check fixed in #9), never deployed | Postgres (re-checks membership as the caller), R2 (mints a 5-minute presigned PUT) | The only write path for photo bytes | Exists solely because the R2 secret cannot live in the app binary. |
| **`r2-download-url` edge fn** | **not built** — requirements settled in `supabase/README.md` | Postgres (**must call `day_page_is_open` before signing**), R2 (presigned GET) | The gate itself: a version that skips the check is the single worst potential leak in the app | The bucket is private; every read needs a signature; gating the signature is what makes the shut gate real rather than a curtain. |
| **Cloudflare R2** | not built — bucket not created; plan settled | nothing | Both edge functions; the app's byte transfers; the 10 GB free tier is a real ceiling | Photo bytes and day-page composites at zero egress. Postgres is the index; R2 is never listed — the `photos` row *is* the pointer. |

### Platform edges — wiring not built; the platform provides them

Services know the edges; the edges know nothing of Cairn.

| Node | State | What breaks if it changes | Why it is on the map |
| --- | --- | --- | --- |
| **Camera roll (PhotoKit)** | not built | The import sweep, and the honesty of the import promise | iOS never wakes a third-party app for a new photo — no background trigger, no entitlement. The sweep runs on open; the interface says exactly that. |
| **Camera (dual capture)** | not built | Capture | Back primary + front inset, taken as a back-then-front sequence — the spike (`learning/dual-camera-spike/`) established that is what "like BeReal" actually means, and true simultaneous capture is explicitly not being built. Back-only ships first; the inset lands after the first release. |
| **Local notifications** | not built | The ping reaching anyone | Registered in one offline pass from the schedule. Ordinary alert level — **never** time-sensitive, never pierces Do Not Disturb (notification-alert-level decision). Delivery is the OS's to refuse. |
| **Location** | not built | Rung-1 day assignment for pinged photos | A GPS tag at capture time is what lets the app's own photos take the best rung of the ladder. |
| **Sign in with Apple** | not built | The whole account path | First auth route. Web/PWA were ruled out (iOS evicts PWA storage); native + Apple sign-in is the way in. |

### Domain — the bottom of the map

Four **sibling** packages. None imports another; none imports anything above
itself; all are pure Dart, tested with `dart test` from their own directories.
The three computation packages deliberately do **not** import `cairn_model` —
each speaks its own dialect, and the repositories translate. The model is the
vocabulary for the layers *above* the packages, not a dependency of its peers.

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **`cairn_model`** | built (merged, #7) | nothing — zero dependencies | Everything planned above it is written against this vocabulary: Drift rows, repository interfaces, providers, screen types. Renaming a concept here ripples through every unbuilt layer — which is exactly why it was built first. | One definition of Trip, TripClock, TripDay, Stop, Member, PhotoRef, DayPool, GateState, CalendarDate, ClockTime and the typed ids, so the database, state layer and interface stop inventing three private ones. Encodes: clock fixed at day start, gate as one enum, contributors survive photo deletion, no roles. |
| **`itinerary_parser`** | built | nothing | The confirmation screen's inputs; day/stop structure; the star rule (a stop is starred exactly when it carries a time) | Deterministic, offline parse of a pasted plan into days and stops. Built to ask, not guess: confidence and unplaced lines exist so the confirm screen can put uncertainty in front of the user. |
| **`trip_moments` v2** | built — v2 merged in #8, v1 retired | `crypto` (SHA-256) | Cross-device agreement on ping times. The derivation is a compatibility contract: change the hash, seed format, window maths or arithmetic and two app versions on one trip silently disagree. Any such change must bump the `trip_moments/v2` namespace. | One ping per person per day, dealt as a collision-free permutation over the party, reshuffled daily, in the trip's clock, window 08:00–22:30, offline and serverless. Takes the roster, clock and first/last-day windows as caller-supplied inputs — and offers **no fallback when devices hold different rosters**; keeping rosters agreed is the app layer's job. |
| **`photo_day_assignment`** | built | `timezone_finder`, `timezone` (embedded IANA data) | Which day every imported photo lands on — silently wrong here means the Trail, Pool and Book are wrong and nobody notices | GPS-derived timezone over bare EXIF, with a documented degradation ladder and a confidence on every answer. The authority for "which day is this instant"; `cairn_model` deliberately offers no rival answer. Standing trap: `findLocation(longitude, latitude)` — longitude first. |

---

## Invariants that cross the map

Couplings that behave like dependencies but appear in no import graph. Each is
a "change one, change all" edge:

1. **The day's clock is fixed where the day starts** — encoded three times, by
   design, in three sibling packages that cannot see each other:
   `cairn_model.TripDay` (immutable clock, no `copyWith`),
   `trip_moments`' day handling (#8), and `photo_day_assignment`'s
   `timeZoneOverridesByDay`. Nothing but tests and this map keeps them agreeing.
2. **The gate rule exists twice on purpose.** On the phone:
   `cairn_model.GateState` / `Trip.gateFor`. On the server:
   `day_page_is_open` in SQL, which the download function must call before
   signing a GET. Change what opens a day and both must move together, or the
   phone will show what the server refuses (or worse, the reverse).
3. **The trip clock has exactly one source**: the `trips` row. Both packages
   take the zone as a parameter precisely so no phone ever infers it
   independently — two phones inferring different zones is silent schedule
   drift with no error anywhere.
4. **The `trip_moments` derivation is frozen.** Hash, seed namespace, window,
   inset, arithmetic. Changing any of it mid-trip splits the schedule between
   app versions; the only safe change is a loud one (`v2` → `v3`).
5. **JavaScript-safe arithmetic.** Dart `int` bitwise operators are 32-bit
   under dart2js, so the derivation uses multiplication and addition, never
   shifts. Golden tests pin it. Do not "simplify" it back.
6. **RLS refuses by filtering to zero rows, not by raising.** A test asserting
   "this threw" can pass while testing nothing. Assert on the state of the
   table afterwards. This already burned one analysis.
7. **Membership checks go only through `is_trip_member` / `is_trip_starter`**
   (`SECURITY DEFINER`). An inlined membership subquery in an RLS policy
   recurses infinitely; `force row level security` on any table re-enables the
   recursion. Both directions are demonstrated in `supabase/tests/`.

---

## Honesty about the gaps

Drawn as open on the map, not as settled. None of these is a contradiction —
in every case the decision record is clear and the code is behind it,
acknowledged and queued (`docs/roadmap.md`, "Work already queued").

- **The starter-and-container decisions are settled but not implemented.**
  The record says: rename and invite are flat; delete is the starter's only
  while the trip holds nobody else's photos; timezone changes belong with
  delete; the removal power passes silently to the longest-standing member
  when the starter leaves. Today's schema still has starter-only
  rename/delete with no photo condition and no succession, and
  `cairn_model.Trip.canRemove` knows nothing of succession. Queued near-term.
- **The download path does not exist.** Only uploads are built. The
  requirements (sign nothing without `day_page_is_open`) are written down,
  which is exactly why the blank is the map's most dangerous one.
- **Sync and conflict policy is undecided** beyond three written notes
  (outbox ordering, `day_pages` insert→update fallback, deletion refetch).
  No reconciliation of rows against R2 objects exists in any direction.
- **Riverpod and Drift are validated and now built on, not decided.** The
  learning demo makes the argument and the app scaffold commits code to both;
  no decision file records the choice; the root `README.md` still says
  "being chosen." The map draws them as the plan, flagged.
- **The day page derives today from the device date.** A trip has one clock
  and it follows the itinerary's leg (last-calls §4), but nothing creates a
  trip row yet, so `todayProvider` (`lib/app_state/day_view.dart`) reads the
  device's calendar date. Right for anyone standing in the trip's own
  timezone, a day out for a phone set elsewhere, and the one place that
  changes when the trip clock lands. It is also read once per launch rather
  than ticking at midnight.
- **A day accepted with its date still open is not reachable by date.** The
  day page matches dates to days and never infers one from position, because
  the parser does not guess dates and neither does the layer above it. The
  consequence: in a plan where some days are dated and some are not, a date
  no day claims reads as a gap. A plan with *no* dates at all is handled
  separately — day one, its date shown open.
- **No day-page state was ever drawn for after the trip.** The design's
  post-trip surface is the shelf and the book (7b), both after the first
  release, so the day page uses the plainest honest treatment: the trip is
  walked, and the last day is still here.
- **One fixed clock per trip on the server, in v1.** The first/last-day
  arrival-departure windows and the country-change rule live only on the
  phone (`trip_moments` computes them from the itinerary). Grill round one §2
  has since decided the itinerary becomes a shared stored fact that syncs to
  every phone — nothing implements that yet, and until it lands the server
  still cannot express these windows.
- **The book's interior is designed; the printed page is not.** Round 9 drew
  the interior against the captain's printed reference. The cover's face is
  the photograph, with the cairn signing the foot (book-round-nine decision,
  superseding the cairn-fronted cover); old handoffs still showing the
  retired four-up are superseded by that round.
- **In-transit photos on a multi-timezone day are parked.** A photo taken
  between two days' zones can be `outsideTrip` by refusal; manual placement
  is the current answer.
- **Thumbnails and keepalive.** No thumbnail pipeline exists (phone-side
  work). The dormancy keepalive that protects the free tier between trips is
  planned, not built. (CI exists since #13 and covers the packages, the
  JS-safety golden, the RLS probe, the learning demo and the app.)
- **Nothing has ever touched a hosted Supabase project or a real R2 bucket.**
  The schema's verification is real but local; `supabase db push` against a
  throwaway project is still the gate before anything real.

---

## What to do with this map

Before changing a node, read its row: the "what breaks" column is the blast
radius, and the invariants list is the couplings the import graph won't show
you. Before *adding* an arrow, check its direction — if it points upward,
the design is wrong, not the rule. And when a gap above closes, update this
file and `architecture.html` in the same change; a map that looks more
finished than the project is worse than no map.
