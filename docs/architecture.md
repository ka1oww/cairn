# Cairn — the dependency map

Every piece of the app as a node, arrows for what-knows-what, so that pointing
at any node answers "what breaks if this changes." The visual twin of this
file is [`architecture.html`](architecture.html) — same nodes, same arrows,
drawn. This file is the durable, diff-able, greppable version.

Drawn 22 August 2026 from `main` (after PRs #7–#10 merged) and PR #11
(design round 7). Updated the same day for the app scaffold
(`fm/cairn-app-scaffold`), which turned the app bands from intention into
first code. Updated 24 August 2026 for the paste-and-confirm flow
(`fm/cairn-screen-paste-confirm`), the app's first real screens, again
the same day for Today (`fm/cairn-screen-today`), the day page that replaced
that slice's placeholder as the launch surface, and again for the Trail
(`fm/cairn-screen-trail`), the trip's front door and the real tab container
the destinations now live in. Updated 25 August 2026 twice, for two slices
that landed together and met in the middle: the Pool
(`fm/cairn-screen-pool`), the container's third tab and the read seam under
it, and capture (`fm/cairn-screen-capture`) — the ping, the camera, the pause
and the word — which drew the app's first photo write path all the way down
the bands, lit up two platform edges that had been drawn as intentions, and
put the store behind the Pool's seam. Updated again for the read-back editor
(`fm/cairn-paste-editor`), which turned the confirmation screen from a read
and an accept into design round 8's by-hand corrections in full. Updated 26
August 2026 for the re-paste merge (`fm/cairn-repaste-merge`), which opened a
band the map had not needed before: `lib/logic/`, pure decision cores the
providers call.
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

**The app has a way in, and a trip with all three of its destinations in
it.** The
paste-and-confirm slice replaced the scaffold's proving screen and its
disposable `trip_drafts` table — the sidestep that let a drafted trip carry no
id at all, now closed at both ends
(`docs/decisions/2026-08-25-the-trip-mints-its-own-id.md`): a person can paste
a plan, see what the
parser understood day by day with its doubt surfaced per cause, flip
ambiguous dates month-first in one tap, and accept — which persists the
itinerary through the seam into Drift. Today (`fm/cairn-screen-today`) then
replaced that slice's placeholder: the app opens on the day page for today's
date, showing the day's identity and its stops in pasted order, with a time
shown only where the plan starred one. The Trail (`fm/cairn-screen-trail`)
added the trip-level view — one node per day on the winding path, a flag on
today, every node opening the same day page — and with it the **real
container**: a tab bar holding Today and the Trail, built so the Pool becomes
a third entry and shown without one until it existed. The Pool
(`fm/cairn-screen-pool`) is that third entry: the trip's photos in one shared
place, grouped by day and read newest first, over a **read-only seam** —
`PhotoRepository`. Capture (`fm/cairn-screen-capture`) put a store behind that
seam and gave it something to read: the ping's schedule, the camera behind
`CameraSource`, the pause, the word, and a row in Drift's `photos` with the
frame beside it on disk. The trip itself
(`fm/cairn-roles-and-container`) is now a stored thing rather than an implied
one: a roster, the fact of who started it, and three-word invite codes that
die when the trip closes — with the whole permission model in `cairn_model`
and a sheet off the Trail's title over it. It also has a **real id from the
instant it is started** (`fm/cairn-tripid-before-sync`): the phone mints the
uuid rather than waiting for Postgres to, so a trip can be created in flight
mode and the id it is born with is the id it keeps after it first syncs. The party the pings are dealt
across is that roster, so the stub member is gone; it holds one person on a
phone nobody has signed into. The **itinerary and the roster are now shared
facts** (grill round one §2): the schema holds them, and `TripSync`
(`lib/repositories/itinerary_sync.dart`) reconciles them last-write-wins per
day, over a first slice of the Supabase adapter that speaks PostgREST. That
whole path is **dormant, not absent** — it needs a project URL, a publishable
key and a session, and there is no hosted project and no sign-in, so every
build so far reports itself dormant and touches nothing. The pool is still
local: nobody else's bytes arrive until Phase 2. Everything else between the
screens and the packages — photos on the day page and the Trail, the import
sweep, the rest of the platform glue, the R2 half of the adapter — is still
**not built**, and the right edge is unchanged: the backend schema is verified
only against a local Postgres, no hosted Supabase project exists, no R2 bucket
has been created, nothing is deployed.
`lib/README.md` spells this map's bands as directories — read it alongside
this file.

The map therefore still draws the *intended* architecture in full, with state
marked per node. A map of only what exists would omit most of the product.

```
     Trail · Day page & gate · Capture · Pool · Book · Join & confirm · Settings   SCREENS        partial
        │                          (know app state, and nothing below it)
        ▼
     Riverpod providers · ping scheduler · import sweep · platform glue · logic    APP STATE      partial
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
- **The shared facts' reconcile.** `itinerary_sync.dart` is the first of the
  above to be built. It is the one file that holds both backends at once: it
  reads the plan and the roster out of Drift, pushes them through the adapter,
  applies what comes back, and reports a standing rather than an error —
  dormant, no trip, awaiting the trip row, offline, refused, synced. **Offline
  means the local copy is untouched and authoritative**, which is the whole
  reason this lives here and not in a provider.

  Two rules it exists to keep. *Last write wins, per day*, and the day is the
  atom — the same rule `sync_trip_itinerary` applies server-side, written
  twice on purpose and never three times. And *a reconcile that changed
  nothing writes nothing*: the plan's own Drift stream is what asks for a
  sync, so an unconditional write would ask for the next one, forever.

The rest is not built, and the conflict policy beyond the itinerary's is
**undecided** — drawn on the map as open, not settled.

---

## The nodes

For each: what it knows (its outward arrows), what breaks if it changes (its
inward arrows), and why it exists.

### Screens — the way in, the day page, the Trail, the Pool and capture built; the rest not built, drawn in `docs/design/`

The scaffold's proving screen is gone, replaced (not extended) by the first
real screens: the paste box, the confirmation screen (design round 8's four
surfaces — the confident read, the doubt surfaced with cause-specific asks,
the one-tap month-first re-read, the paste that wouldn't parse), and the day
page (`lib/screens/`). The confirmation screen is now the editor round 8
called for: a chip's menu edits its text or time, moves it to another day, or
removes it to the set-aside (never deleting it); a long press drags the chip
itself between days and back out of the set-aside; and a day's own header can
be renamed or dated. All of it edits a draft in `paste_flow.dart` before
`accept()` ever runs (`AGENTS.md`'s "the read-back is an editor" entry).

**There is one day screen and no separate day detail.** `DayPage` is the
whole of it: Today is `DayPage(date: today)`, and the Trail opens the same
widget for every node it draws. That is a structural claim, not a
convenience, and it is what a second "day detail" surface would break. The
Trail opens it through `DayPage.planDay(n)` — by the plan's own day number
rather than by date — because a day accepted with its date still open is
reachable by no date at all; that is a second way *in*, not a second screen,
and both end in the same `DayView`.

**The container is the tab bar** (`lib/screens/trip_shell.dart`), and it now
holds all three of the design's destinations — Today, the Trail, the Pool
(surface 2e). The Pool was absent rather than greyed out until it existed,
because a disabled tab is chrome for a thing that does not exist; that rule
governs whatever is drawn next, not the Pool. Each tab owns a `Navigator`, so a day
page opened from the Trail is still open when you come back from Today.
Trip-level actions hang off the Trail's title and never off a tab (surface 6e);
the temporary route back to the paste box (`repasteRequestedProvider`) lives
there now, and goes when the real trip-settings sheet lands.

**Capture is a route, not a destination** (`lib/screens/capture_screen.dart`).
It is reached from the day's one call to action and nothing else: the day page
carries a single line saying where the moment stands, and only an open or a
late window offers a way in. That is the same principle as the absent Pool tab
— the flow is not a place you can wander into, it is the answer to a ping.

Every screen knows **app state and nothing else** — no repository, no store,
no network, no SQL. What breaks if a screen changes: nothing below it, ever.
That is the layering rule paying rent.

| Node | State | Knows about | Why it exists |
| --- | --- | --- | --- |
| **Trail** | partial — the path built (`lib/screens/trail_screen.dart`): one node per day of the plan in itinerary order, past/today/ahead drawn apart, the flag on today, every node opening `DayPage.planDay(n)`; the photo-filled node, the long-trip chapters and edge scrubber, and the cat not started | app state | The trip-level front door. The cairn is the trip's portrait, not its front door (design-calls §6). It opens `DayPage` for each day rather than owning a day surface of its own. The winding is the screen's identity, not decoration; a list of days would be a different screen wearing this one's name. |
| **The container** | built — `TripShell`: a tab per destination, one `Navigator` each | app state | Today, the Trail and the Pool are tabs — surface 2e's structure entire. Trip-level actions hang off the Trail's title, never a fourth tab (6e), and a test pins the destination count at three. |
| **Day page & shut gate** | partial — the plan half built (`DayPage`, `lib/screens/day_page.dart`), reachable by date and, since the Trail, by plan-day number; the photo timeline and the seal not started, and with them this page's half of the gate — the rule is built and answered in one place (`day_gate.dart`), but a page with no photographs on it has nothing to withhold, so nothing is drawn here rather than a gate being stubbed over an empty day; since capture it also carries the day's one call to action, which is the only photo-shaped thing on it | app state | One screen for every day, Today included. Built: the day's identity (day n of m, date, place), the flat ordered stop list, the star and its time — the only time in the app — and the drawn edges (nothing planned, a date the plan skips, before the trip, after it, a plan with no dates). Not built: the day is also the artefact, a vertical timeline of photos with hours prominent and credit small; shut, it shows times and names with images withheld and seals silently at midnight. |
| **Capture** | built, back-only — `CaptureScreen` over `capture_flow.dart`: the call on the day page, the framing screen with the window's own words, the shutter, the breath with exactly one retake, the word, and the keep that writes a row; the front inset and a live viewfinder not built | app state | Answers the ping. Back camera primary, small front inset; thirty-minute window; the late path is always open and visibly late. The inset is explicitly after the line (camera-like-bereal decision), so back-only is not a shortcut here — it is the settled first-release scope. It is a **route, not a destination**: the day page's one call is the only way in, which is the same reasoning that kept the Pool off the tab bar until it existed. |
| **Pool** | partial — the screen built (`lib/screens/pool_screen.dart`): the trip's photos grouped by day, newest day first, oldest photo first within a day, over the read seam — which capture's store now sits behind, so a photo taken on this phone appears here. It is also the gate's one live consumer: the day being lived keeps its heading, its date and its count and withholds its pictures until you add yours, because the gate is about photographs wherever they are drawn. The taker's initial chip, the dashed "+" tile, opening a photo full-screen and the house treatment not built; nobody else's bytes can arrive until Phase 2 | app state | Plumbing: the whole trip's photos in a plain, fast grid by day (first-calls, "The Pool is plumbing"). Deliberately not a destination and deliberately not a place to spend design effort. It is also what the book is later made from, which is why it holds the whole trip rather than today. |
| **Book** | not built | app state | What the trip turns into: one spread per day, the photograph as the cover's face with the cairn signing the foot (book-round-nine decision), digital only, works with the network off forever. Automatic — it generates itself and there is no editor (book-no-editor decision). Interior designed in round 9; the printed page is not. Deliberately after the first release. |
| **Join & confirm** | partial — paste-the-plan and the confirmation screen built (local-only) as a full editor over a draft (edit, time, move, remove and drag a chip; rename or date a day; a date candidate inside a day's own title is asked about rather than bound), and beside them the second door: `JoinScreen` over `join_flow.dart` reads three words back in any order and any spelling within one edit, and answers every case it can see (not a code, this trip's own, retired, the trip has closed) plus the honest one it cannot — a well-formed code for a trip on another phone, which nothing here can reach. Deep link and display-name edit not started | app state | The way in: invite code (or deep link), display-name edit, paste-the-plan, and the confirmation screen where the parser's confidence, unplaced lines and date candidates are put in front of the person to correct before accepting, instead of trusting them. |
| **Settings & members** | partial — built as `TripSheet` (`lib/screens/trip_sheet.dart`) over `trip_settings.dart`, off the Trail's title and never a fourth tab (6e): the roster with its one quiet note per row, the live code with what it can and cannot do, rename, new words, and the gated delete with its refusal in writing. Leave and remove are absent rather than disabled — there is nobody else on this phone's roster to remove, and a party of one leaving would leave the trip with nobody | app state | Rename, invites, member list, leave, remove. Its affordances follow the starter-and-container decision (rename flat, delete gated, one narrow removal power, never titled "admin"). |

### App state

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **Riverpod providers** | partial — the paste-and-confirm flow's state (`paste_flow.dart`), the saved-plan stream and the photo seam's providers (`trip_providers.dart`), the day view (`day_view.dart`: which day a date *or* a plan-day number is, and whether it is behind us), the trail view (`trail_view.dart`: the whole trip as nodes, and where the flag goes), the pool view (`pool_view.dart`: the trip's photos grouped by the day already on them), the gate (`day_gate.dart`: one answer to "is this day mine to see", for every surface that draws a photograph), the capture flow (`capture_flow.dart`: where the moment stands, and the whole of the shutter-pause-word walk), the trip's own sheet (`trip_settings.dart`: the roster, the live code and when it dies, and what each of the trip's own acts is allowed to do) and the second door (`join_flow.dart`: what saying three words back can answer) | repositories, `cairn_model`, `itinerary_parser` (the parse use case), `trip_moments` (the schedule) | Every screen | One source of truth per question. A Drift stream flows through a provider; writing a row updates every watching screen with no manual wiring — which is exactly how a kept photo reaches the Pool with no wire between the two features. The parser's dialect is translated to screen-facing view models here — screens never import it, and no `cairn_model` type reaches one either. |
| **Ping scheduler** | built over the real roster (`ping_schedule.dart`) — the derivation, the day's ping and the register-the-remaining-days pass are real, and the party is now the trip's stored members rather than a stub: `tripPartyProvider` reads the roster, and no trip means no pings rather than an invented member. It still holds one person, because nothing propagates membership between phones; the trip clock is still the device's offset | repositories (roster, trip clock, itinerary arrival/departure), `trip_moments`, local-notifications edge | The one interruption per person per day | Feeds `trip_moments` its inputs and registers every remaining day's local notifications in one offline pass. Registration replaces the whole future deal rather than appending to it, because the deal is re-derived whenever the plan or the clock moves and a stale ping firing alongside a fresh one is indistinguishable from two pings a day. |
| **Pure decision cores** (`lib/logic/`) | partial — one resident: the re-paste merge (`repaste_merge.dart`), the decision core of editing a plan after it was accepted; the slice that calls it is not built | `repositories/` value types, `cairn_model`, `itinerary_parser` — no Flutter, no Riverpod, no IO | The providers that call it | A decision worth unit-testing on its own belongs below the providers, not inside one: the merge is a pure function of (saved plan, repasted plan), so it is testable without a database, a widget or a clock. Its rules are written once, in the file and in `AGENTS.md`; screens never reach it. |
| **Import sweep** | not built | camera-roll edge, `photo_day_assignment`, repositories | The completeness of the record | Runs when the app opens — the import promise commits to exactly that and no more (iOS offers no background trigger). Extracts metadata, asks the ladder, queues uploads. |
| **Platform glue** | partial — the camera is behind `CameraSource` (`camera_source.dart`), with the real back camera on a device and a generated stand-in where there is none; location and Sign in with Apple not started | camera, location, Sign in with Apple edges | Capture and Join | The thin controllers that drive dual capture, tag a pinged photo with GPS so it rides rung 1, and run the sign-in flow. Kept out of widgets so screens stay platform-blind. |

### The seam

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **Repositories** | partial — one repository over the itinerary tables (`ConfirmedItinerary` in and out, spoken in `cairn_model` vocabulary), unchanged by the Today and Trail slices, both of which derive from the one saved-itinerary stream rather than adding a read; plus the photo seam, which is deliberately two halves — `PhotoRepository`, the read-only interface the Pool was built against before a photo could exist, and `PhotoStore`, the Drift implementation that answers it *and* owns the write path (keep a frame, write a word, watch the pool whole or by day). The composition root binds both providers to the one store. The membership seam (`membership_repository.dart`) has the same two halves for the same reason — `MembershipRepository`, the read interface the trip's surfaces and the ping's party are written against and the only way a test can stand a party of eight up, and `MembershipStore`, the Drift implementation that also owns starting the trip, renaming it, minting and revoking codes and deleting it. The remote side has begun: `TripSync` (`itinerary_sync.dart`) reconciles the two shared facts — the itinerary and the roster — against Supabase, and nothing above it knows it exists, because it makes the store every screen already reads agree with the other phones. The rest of what is listed under [The repositories seam](#the-repositories-seam), not started | Drift, Supabase/R2 client adapter, `cairn_model` | Everything above it — every provider, every service, every screen | See [The repositories seam](#the-repositories-seam). The only node that knows both storage backends exist. |

### Storage

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **Drift store** | partial — the itinerary tables (`itinerary_days`, `itinerary_stops`, `itinerary_set_asides`), `photos`, and the trip itself: `trip_facts` (one row: which trip, what it is called, who started it), `trip_members` (the roster, with no role column and never one) and `trip_invite_codes` (minted and revoked, with no expiry column — a code dies with its trip and that rule is not stored twice). Schema v6: v2 dropped the scaffold's disposable `trip_drafts` demo, v3 added photos, v4 added the trip's three, v5 gave a pre-mint trip a real uuid, v6 gave every day the merge clock the shared copy is reconciled on and added `sync_states` — the cursor, not the cargo, and the one table here holding no shared fact at all | `cairn_model` (rows typed against the vocabulary), device disk | Repositories; transitively every reactive read in the app | Typed SQLite with real joins and watchable queries — "photos per day" is one query, and its stream is what makes the UI reactive. Choice validated in `learning/riverpod-drift-demo/` (native backend on iOS, not the demo's wasm detour) and recorded in [`docs/decisions/2026-08-25-riverpod-and-drift.md`](decisions/2026-08-25-riverpod-and-drift.md). |
| **Supabase/R2 client adapter** | partial — the shared facts' half is built (`lib/storage/remote/`): `SharedFacts` is the interface, `PostgrestSharedFacts` speaks it over plain HTTP (no `supabase_flutter`; PostgREST is an ordinary REST API and the package would bring GoTrue, Realtime, Storage and a Podfile's worth of native dependencies). Auth, the edge functions and R2 not built | Supabase Auth, Postgres (PostgREST under RLS), both edge functions, R2 (presigned PUT/GET) | Repositories — nothing else in the app may import a Supabase or HTTP symbol | Wraps the session JWT, the RLS-filtered queries, the edge-function calls, and the direct-to-R2 byte transfers behind one interface the repositories consume. Where the project lives is a `--dart-define` and never a checked-in file; unset, the adapter refuses before it sends anything. |

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
| **Postgres schema + RLS** | partial — built and verified on a throwaway local Postgres 17 (96-probe RLS suite); **no hosted project exists**; starter-and-container decisions not yet implemented | Supabase Auth (`auth.uid()`); written against the model vocabulary | Client adapter, both edge functions, and cross-device agreement on the trip clock | `profiles`, `trips` (+ timezone/window columns — the one shared clock), `trip_members`, `trip_invites`, `photos`, `day_unlocks`, `day_pages`, `day_page_photos`, and the itinerary's four (`trip_itineraries`, `trip_itinerary_days`, `trip_itinerary_stops`, `trip_itinerary_set_asides`); `is_trip_member`/`is_trip_starter`, `day_page_is_open`, `redeem_trip_invite`, `sync_trip_itinerary`, and the `trip_roster` view. Membership is the root of every access check. |
| **Supabase Auth (GoTrue)** | not built — no project; Apple provider is a dashboard step; Google queued | (platform service) | Postgres (`auth.uid()` in every policy), client adapter, edge functions | Accounts. Sign in with Apple first; display name editable at join because providers supply legal names. |
| **`r2-upload-url` edge fn** | partial — code exists (membership check fixed in #9), never deployed | Postgres (re-checks membership as the caller), R2 (mints a 5-minute presigned PUT) | The only write path for photo bytes | Exists solely because the R2 secret cannot live in the app binary. |
| **`r2-download-url` edge fn** | **not built** — requirements settled in `supabase/README.md` | Postgres (**must call `day_page_is_open` before signing**), R2 (presigned GET) | The gate itself: a version that skips the check is the single worst potential leak in the app | The bucket is private; every read needs a signature; gating the signature is what makes the shut gate real rather than a curtain. |
| **Cloudflare R2** | not built — bucket not created; plan settled | nothing | Both edge functions; the app's byte transfers; the 10 GB free tier is a real ceiling, and the only line in the backend that ever bills — measured in [docs/storage-and-cost.md](storage-and-cost.md) | Photo bytes and day-page composites at zero egress. Holds **originals**, untouched; a derived variant may sit beside one but never replaces it. Postgres is the index; R2 is never listed — the `photos` row *is* the pointer. |

### Platform edges — wiring not built; the platform provides them

Services know the edges; the edges know nothing of Cairn.

| Node | State | What breaks if it changes | Why it is on the map |
| --- | --- | --- | --- |
| **Camera roll (PhotoKit)** | not built | The import sweep, and the honesty of the import promise | iOS never wakes a third-party app for a new photo — no background trigger, no entitlement. The sweep runs on open; the interface says exactly that. |
| **Camera (dual capture)** | partial — the back camera is driven for real behind `CameraSource`; the front inset is not built, and deliberately so | Capture | Back primary + front inset, taken as a back-then-front sequence — the spike (`learning/dual-camera-spike/`) established that is what "like BeReal" actually means, and true simultaneous capture is explicitly not being built. Back-only ships first; the inset lands after the first release. |
| **Local notifications** | not built — the schedule is derived and handed to a `NotificationEdge`, but the only implementation records what it was given rather than registering it with iOS; this is the one genuinely unbuilt piece of the ping | The ping reaching anyone | Registered in one offline pass from the schedule. Ordinary alert level — **never** time-sensitive, never pierces Do Not Disturb (notification-alert-level decision). Delivery is the OS's to refuse. |
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
| **`itinerary_parser`** | built | nothing | The confirmation screen's inputs; day/stop structure; the star rule (a stop is starred exactly when it carries a time) | Deterministic, offline parse of a pasted plan into days and stops. Built to ask, not guess: confidence, unplaced lines and a date candidate lifted out of a day's own title (never bound) exist so the confirm screen can put uncertainty in front of the user. |
| **`trip_moments` v2** | built — v2 merged in #8, v1 retired | `crypto` (SHA-256) | Cross-device agreement on ping times. The derivation is a compatibility contract: change the hash, seed format, window maths or arithmetic and two app versions on one trip silently disagree. Any such change must bump the `trip_moments/v2` namespace. | One ping per person per day, dealt as a collision-free permutation over the party, reshuffled daily, in the trip's clock, window 08:00–22:30, offline and serverless. Takes the roster, clock and first/last-day windows as caller-supplied inputs — and offers **no fallback when devices hold different rosters**; keeping rosters agreed is the app layer's job. |
| **`photo_day_assignment`** | built | `timezone_finder`, `timezone` (embedded IANA data) | Which day every imported photo lands on — silently wrong here means the Trail, Pool and Book are wrong and nobody notices | GPS-derived timezone over bare EXIF, with a documented degradation ladder and a confidence on every answer. The authority for "which day is this instant"; `cairn_model` deliberately offers no rival answer. Read surfaces group on the day number already on a photo and never re-run the ladder — the answer was settled when the photo entered the pool, and a person may have overridden it by hand since. Standing trap: `findLocation(longitude, latitude)` — longitude first. |

---

## Invariants that cross the map

Couplings that behave like dependencies but appear in no import graph. Each is
a "change one, change all" edge:

1. **The day's clock is fixed where the day starts** — encoded three times, by
   design, in three sibling packages that cannot see each other:
   `cairn_model.TripDay` (immutable clock, no `copyWith`),
   `trip_moments`' day handling (#8), and `photo_day_assignment`'s
   `timeZoneOverridesByDay`. Nothing but tests and this map keeps them agreeing.
2. **The gate rule exists twice on purpose, and only twice.** On the phone the
   rule is `cairn_model.GateState.decide` — `Trip.gateFor` answers with it for
   a whole trip, and the app's `lib/app_state/day_gate.dart` answers with it
   for the one-phone slice that has no roster to build a `Trip` from. On the
   server: `day_page_is_open` in SQL, which the download function must call
   before signing a GET. Change what opens a day and both must move together,
   or the phone will show what the server refuses (or worse, the reverse). A
   *third* copy — one in the Pool, one on the day page, one on the Trail — is
   the thing to refuse in review. The rule, since round one: the gate applies
   to the day being lived; every day that has sealed is open to the whole
   party.
3. **The trip clock has exactly one source**: the `trips` row. Both packages
   take the zone as a parameter precisely so no phone ever infers it
   independently — two phones inferring different zones is silent schedule
   drift with no error anywhere.
4. **The `trip_moments` derivation is frozen.** Hash, seed namespace, window,
   inset, arithmetic. Changing any of it mid-trip splits the schedule between
   app versions; the only safe change is a loud one (`v2` → `v3`).
   **The trip id is one of its inputs, so the id is frozen too**: it is minted
   on the phone when the trip is started and the server keeps it rather than
   reissuing (`docs/decisions/2026-08-25-the-trip-mints-its-own-id.md`).
   Renumbering a trip re-deals every remaining day of it, silently, with
   nothing raising anywhere.
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
8. **A photo row is an index, never the photograph.** On the server, Postgres
   holds the row and R2 holds the bytes; on the phone, Drift's `photos` holds
   the row and the file sits beside it on disk. The local shape mirrors the
   remote one on purpose, so the sync path is a copy rather than a
   translation — and it means deleting a row is never deleting a photograph.
9. **The itinerary merge rule exists twice on purpose, and only twice.** Last
   write wins, per day; the day is the atom. On the server it is
   `sync_trip_itinerary` (`0010_trip_itinerary.sql`), which must refuse a
   stale push it is told about; on the phone it is
   `lib/repositories/itinerary_sync.dart`, which must know which of its own
   days survived the push it just made. Both are needed and a third is the
   thing to refuse in review — the same bar the gate and the invite grammar
   are held to. Two consequences that look like details and are not: a stop
   carries no clock of its own (it cannot win or lose apart from its day), and
   the *plan* carries a shape revision separate from every day's, because a
   deleted day leaves no row to carry an instant.

---

## Honesty about the gaps

Drawn as open on the map, not as settled. None of these is a contradiction —
in every case the decision record is clear and the code is behind it,
acknowledged and queued (`docs/roadmap.md`, "Work already queued").

- **The starter-and-container decisions are implemented on the phone and not
  on the server.** `cairn_model`'s `trip_powers.dart` is the whole permission
  model — rename and mint flat, delete the starter's only while the trip holds
  nobody else's photos, revoke by the minter or the starter, and the removal
  power passing silently to the longest-standing member when the starter
  leaves — and the trip's own surface asks it before every act. The migrations
  in `supabase/` still have starter-only rename/delete with no photo condition
  and no succession, and a `max_uses` the phone has no notion of. The
  three-word grammar and the trip-close expiry are reconciled: the migration
  mints two words and a number, forgives order and spelling by the same rule,
  and refuses a code whose trip has closed. The timezone power has nowhere to
  live yet: no trip clock is stored, so there is nothing to change.
- **An invite code is real, canonical and revocable — and cannot let anybody
  in.** Minting, rotating and revoking are implemented, expiry is derived from
  the trip's close (never stored as a second timestamp), and saying a code
  back is answered honestly for every case this phone can see. What is missing
  is the only thing that would make joining work: a membership that reaches
  another phone. Until Phase 2 lands that, a well-formed code for somebody
  else's trip gets a written "Cairn cannot reach it yet", and the roster on
  this phone holds exactly one person.
- **The download path does not exist.** Only uploads are built. The
  requirements (sign nothing without `day_page_is_open`) are written down,
  which is exactly why the blank is the map's most dangerous one.
- **Sync and conflict policy is settled for the itinerary and the roster, and
  undecided for everything else.** The two shared facts reconcile
  last-write-wins per day with no conflict UI and no CRDT — a deliberate
  choice, and it costs what last-write-wins always costs: a phone with a fast
  clock wins edits it should lose. Photos still have only three written notes
  (outbox ordering, `day_pages` insert→update fallback, deletion refetch), and
  no reconciliation of rows against R2 objects exists in any direction.
- **The shared facts' sync is built and dormant.** It needs a project URL, a
  publishable key and a session; there is no hosted project and no sign-in, so
  it reports itself dormant and touches nothing. That is not a stub — the
  whole path is exercised by tests through a fake backend and a mocked HTTP
  client — but a green test suite is *not* evidence that a hosted project
  answers the way the local Postgres does. The gate before anything real is
  still `supabase db push` against a throwaway project.
- **The shared roster replaces this phone's, and `localMemberId` is still the
  string `'me'`.** Once a session exists, `TripSync` writes the account ids the
  server named over the local roster — which is right, and which means
  `lib/app_state/ping_schedule.dart`'s `localMemberId` must become the signed-in
  user's id in the same change that lands sign-in, or this phone's own person
  vanishes from a party it is standing in. Nothing can hit this today (no
  session, so no roster ever lands), and it is written here because the next
  person to build auth is the one who will.
- **The ping is dealt over a real roster that holds one person.** The
  derivation and the schedule were always real; the party is now read from the
  trip's own members rather than stubbed, and the collision-free promise is
  exercised against eight people through a seeded roster in
  `test/membership_test.dart`. What is still a stand-in is the *contents*: a
  phone can only write its own row, so the roster holds one member until
  membership propagates (Phase 2), and the trip's UTC offset still comes from
  the device because no trip clock is stored. Only the inputs change when
  Phase 2 lands.
- **Nothing has been registered with iOS.** The schedule reaches a
  `NotificationEdge` and stops there. Until an implementation calls into the
  OS, nobody's pocket buzzes: the whole ping path is real except its last
  inch, which is the inch the user would notice.
- **The camera opens, but there is no viewfinder.** Capture drives the camera
  through a controller and takes one frame; it never shows the live preview
  behind the shutter. That is a visual-treatment question the design round
  answers, and this slice is deliberately bare.
- **Where there is no camera, the app draws its own frame.** The iOS
  Simulator has no camera and never will, so `DeviceCameraSource` falls back
  to a generated image whenever no back camera answers. That makes the flow
  walkable on the simulator — and it means a green run there is not evidence
  the real capture path works. Only a device is.
- **The pool holds one phone's photos.** Capture writes into it and the Pool
  draws it, which is the whole loop on one device — but nothing fetches
  anybody else's bytes, so `PooledPhoto.localPath` is non-null for exactly the
  photos this phone took. A pool eight people share is Phase 2, and the tile
  that says it is waiting for bytes is already drawn for it.
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
- **Derived variants and keepalive.** No server-side variant pipeline exists
  (phone-side work), and none is needed to show a photo small: the pool keeps
  the original and `lib/screens/photo_frame.dart` decodes it down to whatever
  box it is drawn in, so a stored variant would only ever save bandwidth
  fetching somebody else's photo. When one is built it is written *beside* the
  original and never over it. The dormancy keepalive that protects the free
  tier between trips is planned, not built. (CI exists since #13 and covers the
  packages, the JS-safety golden, the RLS probe, the learning demo and the app.)
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
