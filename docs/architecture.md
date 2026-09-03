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
providers call. Updated again the same day for file import
(`fm/cairn-import-*`), which added a fifth pure-Dart package
(`plan_extraction`) — rounded out with a PDF extractor (Wanderlog prints
included), with xlsx and csv extractors sharing one row model, and with
docx saying a table one line per row —
`import_flow.dart` over it, two more platform edges beside the app-state
band (the file picker, and Apple Vision's text recognition),
and a second door into the paste box. Updated 31 August 2026 for the C10
area gazetteer (`fm/cairn-gazetteer-p2`), tap-to-Maps phase 2: a validator
that `itinerary_parser` accepts as an optional `gazetteer` and that
`lib/app_state/area_gazetteer_loader.dart` loads once per launch, on import
only, off the UI thread — the app's first new asset bundle and its first
licence attribution surface (`lib/acknowledgements.dart`, drawn at the foot
of the trip sheet).
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
day, over a first slice of the Supabase adapter that speaks PostgREST. The
trip's **name** rides the same seam since the captain's rename ruling, on a
clock of its own (`name_revised_at` through `sync_trip_name`, migration
`0014`) rather than on any day's. That whole path is now **live**: a hosted
project exists with the schema applied to it (`supabase/README.md` is the
authority on exactly which migrations have run), an ordinary build points at
it by default, and the phone signs in as a
GoTrue anonymous account — the stand-in until Sign in with Apple lands
(`supabase/README.md`). The pool is still
local: nobody else's bytes arrive until Phase 2. **A trip now ends** as well as
starting (`fm/cairn-trip-end`): seventy-two hours of grace for late
photographs, then it is a record — uploads shut on both sides of the seam,
codes die, the sheet stops offering what it cannot do, the plan cannot be
replaced and the sync goes quiet. No archive *presentation* was built; the
book and the handover are still after the line. **The photographs have begun
to leave the phone** (`fm/cairn-photo-s1-outbox`): capture now enqueues every
kept frame in a durable outbox (schema v8) and `PhotoSync`
(`lib/repositories/photo_sync.dart`) pushes it — bytes to R2 through a
`r2-upload-url` ticket first, the `photos` row second — surviving a kill and a
dead network. Push half only: nothing pulls, so nobody else's bytes arrive
until the pull lands, and the whole path is proven against a fake server
(nothing has exercised it against a live bucket). Everything else between the
screens and the packages — photos on the day page and the Trail, the import
sweep, the rest of the platform glue, the download half of the adapter — is
still **not built**, and the right edge has moved where the Supabase half is
concerned: a hosted Supabase project exists with all eleven migrations applied
(`0011`, the photo transport delta, included; the adversarial RLS suite still
runs only against a local Postgres), but no R2 bucket has been created and no
photo byte yet arrives on another phone.
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
  cairn_model · itinerary_parser · trip_moments · photo_day_assignment · plan_extraction   DOMAIN         partial
```

Platform edges (camera roll, camera, notifications, location, Sign in with
Apple, the file picker, text recognition) sit beside the app-state band: services know
them; they know nothing.

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
  this ordering, and `lib/repositories/photo_sync.dart` now implements it:
  `PhotoStore.keep` writes the photo row and its `photo_outbox` row in one
  transaction, and the driver walks `queued → uploaded → gone`, one item at a
  time, oldest first, with every durable state a place a kill can leave you.
  The ordering is load-bearing in a second way: `r2-upload-url` refuses to
  sign a photo id a `photos` row already holds, so the row is what closes an
  original to further writes. A retry of an upload that never landed happens
  while no row exists and is still signed — but an outbox that inserted the
  row first would refuse its own retry.
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
  above to be built — and `photo_sync.dart`, the outbox's driver, is now its
  deliberate sibling rather than a lodger inside it: those two files are the
  only ones that hold both backends at once. `itinerary_sync.dart`
  reads the plan, the roster and the trip's name out of Drift, pushes them
  through the adapter,
  applies what comes back, and reports a standing rather than an error —
  dormant, no trip, awaiting the trip row, offline, refused, archived,
  synced. **Offline means the local copy is untouched and authoritative**, which is the whole
  reason this lives here and not in a provider.

  Two rules it exists to keep. *Last write wins, per day*, and the day is the
  atom — the same rule `sync_trip_itinerary` applies server-side, written
  twice on purpose and never three times. And *a reconcile that changed
  nothing writes nothing*: the plan's own Drift stream is what asks for a
  sync, so an unconditional write would ask for the next one, forever. And a
  third since the ending: *an archived trip is not reconciled at all*, reported
  before the first round trip so a pull cannot lay somebody's plan over a
  closed record (invariant 10).

  **One thing now crosses this seam upward, and it is deliberately the only
  one.** `TripSync.standings` is a read-only stream of where each reconcile
  got to, bound by the composition root and turned into a sentence once
  (`planSharingFor` in `trip_settings.dart`). It exists because the opacity
  above had a cost nobody had priced: a plan that had never left the phone
  looked identical, on every screen, to one that had, and that silence was
  defect D3's second half
  (`docs/decisions/2026-08-27-the-trip-clock-is-the-phones.md`). The seam's
  rule is unchanged in the direction that matters — **nothing above may ask
  the sync to do anything**, and nothing does; the plan's own Drift stream
  still drives every reconcile. A standing read *upward* is not the same
  arrow as a command sent *downward*, and growing the second one is the
  thing to refuse in review.

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
Trip-level actions hang off the Trail's title and never off a tab (surface 6e),
in the trip sheet.

**Editing never requires deleting the trip.** The read-back editor is the same
screen over a plan on its way in and over a plan already running — the trip
sheet's "Edit the whole plan" opens it, `planEditorProvider` is what the root
screen watches to draw it, and nothing is written until the save. Its second
door, "Re-paste the plan text", hands the paste box the plan said back as text
(`lib/logic/plan_text.dart`); reading it merges rather than replaces
(`lib/logic/repaste_merge.dart`), and what the new text no longer carries is
displaced into the set-aside, never deleted. The destructive hatch that used to
sit here — "Paste a different plan", which changed a plan by throwing the trip
away — is gone, and a second copy of it is the thing to refuse in review.
A day the merge leaves in place keeps its **number**, which is what keeps its
photographs: `photos.dayNumber` is the only link between a photo and a day, and
nothing re-files photos when a plan is saved. Keeping them is not the same as
keeping them with the right day, though: the merge's position pass can pair a
repasted day with a different current day, so a day can keep its photographs
while its content changes underneath them — drop the first of three undated
days from the re-paste text and day 1 keeps its number and its photographs but
takes what was day 2's content. That gap is known and deferred; `AGENTS.md`
lists it beside the other two. What a day the re-paste *adds* keeps is settled
the other way: an appended day is an unconfirmed read, so it carries the
parser's confidence, uncertainty and named weekday across the merge and the
screen asks about it exactly as it would on a first paste — `Sat - Nara` is a
question, not a clean day saved with its date silently open. A day the plan
already held carries none of that, because the person answered for it before
it was accepted. That is keyed on where a day came from and not on whether its
content is new, so the position-pairing gap above is also the path where a
genuinely new undated day still rides in clean: inserted above an existing
undated day it pairs by position, and the screen asks nothing.

**The paste box has a second door.** A plan can also arrive as a file:
`paste_screen.dart` offers two — a document, or a photo or screenshot — and
what comes back is *put in the box* rather than parsed. Every format reduces
to lines the parser already reads, so the file door adds no state to the parse
path and none to the re-paste merge; a picture takes the recognition edge
instead of an extractor, and a document whose pages turn out to be pictures is
offered one tap to read it that way. The person always sees the text before
the parser does, which is what makes recognition junk editable rather than a
silent bad parse.

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
| **Day page & shut gate** | partial — the plan half built (`DayPage`, `lib/screens/day_page.dart`), reachable by date and, since the Trail, by plan-day number; the photo timeline and the seal not started, and with them this page's half of the gate — the rule is built and answered in one place (`day_gate.dart`), but a page with no photographs on it has nothing to withhold, so nothing is drawn here rather than a gate being stubbed over an empty day; since capture it also carries the day's one call to action, which is the only photo-shaped thing on it; after the trip it adds one sentence for where the ending stands, and nothing more — no archive surface was built | app state | One screen for every day, Today included. Built: the day's identity (day n of m, date, place), the flat ordered stop list, the star and its time — the only time in the app — and the drawn edges (nothing planned, a date the plan skips, before the trip, after it, a plan with no dates). Not built: the day is also the artefact, a vertical timeline of photos with hours prominent and credit small; shut, it shows times and names with images withheld and seals silently at midnight. |
| **Capture** | built, back-only — `CaptureScreen` over `capture_flow.dart`: the call on the day page, the framing screen with the window's own words, the shutter, the breath with as many retakes as you like — every one of them against the same deadline, which a retake never re-opens and never re-closes — the word, and the keep that writes a row, all of it in the house's own tokens and counting the window down to the second (one clock for the whole route, absent once the window has shut); the camera edge below now hands up a front frame too, but this flow still keeps only the back one, and the inset's composition, a live viewfinder and the drawn burning-thread treatment of that countdown are not built; the pool's close is enforced at the write path (`open()` refuses and `turnTheDayOver` discards the frame) rather than on a button, because the grace's real intake, the import sweep, does not exist yet | app state | Answers the ping. Back camera primary, small front inset; two-minute window; the late path is always open and visibly late. The inset is explicitly after the line (camera-like-bereal decision), so back-only is not a shortcut here — it is the settled first-release scope. It is a **route, not a destination**: the day page's one call is the only way in, which is the same reasoning that kept the Pool off the tab bar until it existed. |
| **Pool** | partial — the screen built (`lib/screens/pool_screen.dart`): the trip's photos grouped by day, newest day first, oldest photo first within a day, over the read seam — which capture's store now sits behind, so a photo taken on this phone appears here. It is also the gate's one live consumer: the day being lived keeps its heading, its date and its count and withholds its pictures until you add yours, because the gate is about photographs wherever they are drawn. The taker's initial chip, the dashed "+" tile, opening a photo full-screen and the house treatment not built; nobody else's bytes can arrive until Phase 2 | app state | Plumbing: the whole trip's photos in a plain, fast grid by day (first-calls, "The Pool is plumbing"). Deliberately not a destination and deliberately not a place to spend design effort. It is also what the book is later made from, which is why it holds the whole trip rather than today. |
| **Book** | not built | app state | What the trip turns into: one spread per day, the photograph as the cover's face with the cairn signing the foot (book-round-nine decision), digital only, works with the network off forever. Automatic — it generates itself and there is no editor (book-no-editor decision). Interior designed in round 9; the printed page is not. Deliberately after the first release. |
| **Join & confirm** | partial — paste-the-plan (with a soft *Import a file* pill beside the box, in both first-paste and re-paste modes, opening two doors — a document, or a photo or screenshot read with text recognition: either fills the box and never auto-parses, shows a reading label while it works, and puts a dismissible card above the box when a file cannot be read) and the confirmation screen built (local-only) as a full editor over a draft (edit, time, move, remove and drag a chip; rename or date a day; a date candidate inside a day's own title is asked about rather than bound), and beside them the second door: `JoinScreen` over `join_flow.dart` reads three words back in any order and any spelling within one edit, and answers every case it can see (not a code, this trip's own, retired, the trip has closed) plus the honest one it cannot — a well-formed code for a trip on another phone, which nothing here can reach. Deep link and display-name edit not started | app state | The way in: invite code (or deep link), display-name edit, paste-the-plan (typed or read out of a file), and the confirmation screen where the parser's confidence, unplaced lines and date candidates are put in front of the person to correct before accepting, instead of trusting them. |
| **Settings & members** | partial — built as `TripSheet` (`lib/screens/trip_sheet.dart`) over `trip_settings.dart`, off the Trail's title and never a fourth tab (6e): the roster with its one quiet note per row, the live code with what it can and cannot do, rename, new words, and the gated delete with its refusal in writing; it also says in one sentence where the trip's ending stands, and on an archived trip rename and new words are absent — and the "no code to say, make new words" line with them — since the sheet never offers what the trip can no longer do. Leave and remove are absent rather than disabled — there is nobody else on this phone's roster to remove, and a party of one leaving would leave the trip with nobody; it also draws the app's one acknowledgements surface at its foot (`lib/acknowledgements.dart`), the CC-BY attribution the area gazetteer's GeoNames data obliges | app state | Rename, invites, member list, leave, remove. Its affordances follow the starter-and-container decision (rename flat, delete gated, one narrow removal power, never titled "admin"). |

### App state

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **Riverpod providers** | partial — the paste-and-confirm flow's state (`paste_flow.dart`), the saved-plan stream and the photo seam's providers (`trip_providers.dart`), the day view (`day_view.dart`: which day a date *or* a plan-day number is, and whether it is behind us), the trail view (`trail_view.dart`: the whole trip as nodes, and where the flag goes), the pool view (`pool_view.dart`: the trip's photos grouped by the day already on them), the gate (`day_gate.dart`: one answer to "is this day mine to see", for every surface that draws a photograph), the capture flow (`capture_flow.dart`: where the moment stands, and the whole of the shutter-pause-word walk), the trip's own sheet (`trip_settings.dart`: the roster, the live code and when it dies, and what each of the trip's own acts is allowed to do), the second door (`join_flow.dart`: what saying three words back can answer), where the trip stands against the clock (`trip_lifecycle.dart`: `tripStandingProvider`, the one door to `cairn_model`'s `tripStandingAt`, which every surface and write path asks instead of comparing dates of its own) and the file door into the paste box (`import_flow.dart`: the extractor registry, the routing of a picked file to the extractor that claims it, and the extraction run off the UI thread — it *fills* the box and never parses, so `PasteFlow` gained no state for it) | repositories, `cairn_model`, `itinerary_parser` (the parse use case), `trip_moments` (the schedule), `plan_extraction` (the file door) | Every screen | One source of truth per question. A Drift stream flows through a provider; writing a row updates every watching screen with no manual wiring — which is exactly how a kept photo reaches the Pool with no wire between the two features. The parser's dialect is translated to screen-facing view models here — screens never import it, and no `cairn_model` type reaches one either. |
| **Ping scheduler** | built over the real roster (`ping_schedule.dart`) — the derivation, the day's ping and the register-the-remaining-days pass are real, and the party is now the trip's stored members rather than a stub: `tripPartyProvider` reads the roster, and no trip means no pings rather than an invented member. It still holds one person, because nothing propagates membership between phones; the trip clock is still the device's offset | repositories (roster, trip clock, itinerary arrival/departure), `trip_moments`, local-notifications edge | The one interruption per person per day | Feeds `trip_moments` its inputs and registers every remaining day's local notifications in one offline pass. Registration replaces the whole future deal rather than appending to it, because the deal is re-derived whenever the plan moves and a stale ping firing alongside a fresh one is indistinguishable from two pings a day. The clock is *read* and never watched here: it only says which of the deal is already behind us, and a ping that has fired needs no unregistering — watching it would tear the whole notification set down and put it back on the app root's cadence. |
| **Pure decision cores** (`lib/logic/`) | built — five residents: the re-paste merge (`repaste_merge.dart`), the decision core of editing a plan after it was accepted; `plan_text.dart`, the plan said back as text the parser can read again; `parsed_areas.dart`, the one mapping from the parser's seven provenances to the domain's three (`travellerOwn` > `human` > `parser`); and the tap-to-Maps rules `maps_handoff.dart` (the whole display-and-URL rule: query, three app URLs, meal-label split, placeholder test, badge threshold — wired into the app-state band) and `area_edit.dart`, main's phase-1 scaffolding for re-deriving a day's running areas after an edit, still called from nowhere because the frontend resolves areas onto each stop directly instead | `repositories/` value types, `cairn_model`, `itinerary_parser` — no Flutter, no Riverpod, no IO | The providers that call it | A decision worth unit-testing on its own belongs below the providers, not inside one: the merge is a pure function of (saved plan, repasted plan), so it is testable without a database, a widget or a clock. Its rules are written once, in the file and in `AGENTS.md`; screens never reach it, and `mergeRepaste` is called from exactly one place (`PasteFlow._mergeReparse`). |
| **Import sweep** | not built | camera-roll edge, `photo_day_assignment`, repositories | The completeness of the record | Runs when the app opens — the import promise commits to exactly that and no more (iOS offers no background trigger). Extracts metadata, asks the ladder, queues uploads. |
| **File import** (`lib/app_state/import_flow.dart`) | partial — the flow built: the two doors, the `const planExtractors` registry, magic-bytes-first routing with the extension as tiebreak, `claimsImage` for pictures, the recognition route and the one-tap scanned-PDF door off a `noTextLayer` refusal, the extraction run off the UI thread behind `extractionRunnerProvider`, and a standing the box can draw (reading, or a typed refusal with its sentence). Plain text, csv, docx, xlsx and PDF are registered, and pictures go to recognition; calendar files are not built | file-picker and text-recognition edges, `plan_extraction`, `paste_flow.dart`, `area_gazetteer_loader.dart` | The second way to fill the paste box | Import is not a second parser: it **fills the box and never auto-parses**, so reading it is the same one tap and `PasteFlow.parse()` gains no state — which keeps the merge guard, the month-first flip and every re-read route out of this feature's blast radius. A new format is one extractor plus one registry line; the picker's filter and the pill's format sub-line derive from that list, so nothing else edits. Recognition is deliberately not an extractor — it is a platform call behind `TextRecognitionEdge` — and routing's `matches` runs on the UI thread before the isolate hop, so it sniffs a bounded prefix and never re-reads the whole file. It is also the only trigger for the area gazetteer's one load (`ensureLoaded()`, started here and nowhere else, awaited before the text reaches the box) — never at launch, never on the day/trail path. |
| **Area gazetteer loader** (`lib/app_state/area_gazetteer_loader.dart`) | built — `AreaGazetteerLoader`, a `Notifier<ip.AreaGazetteer?>` that inflates and sorts the three committed assets (`assets/area_gazetteer/{jp,fr,kr}.txt.gz`) once per launch, off the UI thread behind `gazetteerRunnerProvider` (the `extractionRunnerProvider` pattern: `Isolate.run` in the app, a direct call in tests) | `itinerary_parser`'s `AreaGazetteer` interface, `rootBundle` (the one UI-thread read, a platform channel) | `PasteFlow.parse()`'s `gazetteer:` argument | Loads the C10 validator File import needs and nowhere else does. Every failure — missing asset, corrupt asset, dead isolate — is swallowed and leaves the value null, which is phase-1 behaviour rather than a failed import; `test/area_gazetteer_test.dart` pins that a plan typed by hand never triggers a load at all. |
| **Platform glue** | partial — the camera is behind `CameraSource` (`camera_source.dart`), with the real back-then-front pair on a device and a single generated stand-in frame where there is no camera; the document picker is behind `FilePickerEdge` (`file_picker_edge.dart`) and Apple Vision's text recognition behind `TextRecognitionEdge` (`text_recognition_edge.dart`, a hand-written method channel); the tap-to-Maps handoff is behind `LinkOpenerEdge` (`link_opener_edge.dart`, over `url_launcher`) — every URL is a keyless https universal link, so it needs no scheme check; each with a test one beside it; location and Sign in with Apple not started | camera, document picker, text recognition, url_launcher, location, Sign in with Apple edges | Capture, the paste box's import pill, Join, and the Trail/day page tap-to-Maps handoff | The thin controllers that drive dual capture, tag a pinged photo with GPS so it rides rung 1, run the sign-in flow, and open a Maps app. Kept out of widgets so screens stay platform-blind. |

### The seam

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **Repositories** | partial — one repository over the itinerary tables (`ConfirmedItinerary` in and out, spoken in `cairn_model` vocabulary), unchanged by the Today and Trail slices, both of which derive from the one saved-itinerary stream rather than adding a read; plus the photo seam, which is deliberately two halves — `PhotoRepository`, the read-only interface the Pool was built against before a photo could exist, and `PhotoStore`, the Drift implementation that answers it *and* owns the write path (keep a frame, write a word, watch the pool whole or by day). The composition root binds both providers to the one store. The membership seam (`membership_repository.dart`) has the same two halves for the same reason — `MembershipRepository`, the read interface the trip's surfaces and the ping's party are written against and the only way a test can stand a party of eight up, and `MembershipStore`, the Drift implementation that also owns starting the trip, renaming it, minting and revoking codes and deleting it. The remote side has begun: `TripSync` (`itinerary_sync.dart`) reconciles the shared facts — the itinerary, the roster, and the trip's name on its own `name_revised_at` clock — against Supabase, and nothing above it knows it exists, because it makes the store every screen already reads agree with the other phones. The rest of what is listed under [The repositories seam](#the-repositories-seam), not started | Drift, Supabase/R2 client adapter, `cairn_model` | Everything above it — every provider, every service, every screen | See [The repositories seam](#the-repositories-seam). The only node that knows both storage backends exist. |

### Storage

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **Drift store** | partial — the itinerary tables (`itinerary_days`, `itinerary_stops`, `itinerary_set_asides`), `photos`, the trip itself: `trip_facts` (one row: which trip, what it is called, who started it), `trip_members` (the roster, with no role column and never one) and `trip_invite_codes` (minted and revoked, with no expiry column — a code dies with its trip and that rule is not stored twice), and `plan_drafts` (one row, the paste box's pending import, local-only — see [`AGENTS.md`](../AGENTS.md)). Schema v9: v2 dropped the scaffold's disposable `trip_drafts` demo, v3 added photos, v4 added the trip's three, v5 gave a pre-mint trip a real uuid, v6 gave every day the merge clock the shared copy is reconciled on and added `sync_states` — the cursor, not the cargo, and the one table here holding no shared fact at all — v7 added `plan_drafts` so an imported plan survives the process before it is accepted, v8 added the photographs' `photo_outbox` (with `photos.file_path` loosened for rows whose bytes live on another phone, `content_type` for the upload to sign, and the pull's cursor on `sync_states`), and v9 added `itinerary_stops.kind` / `area_text` / `area_source` (what a stop is, the area it searches in, and the provenance that decides who outranks whom) and `app_preferences` (one row, this phone's chosen maps app) | `cairn_model` (rows typed against the vocabulary), device disk | Repositories; transitively every reactive read in the app | Typed SQLite with real joins and watchable queries — "photos per day" is one query, and its stream is what makes the UI reactive. Choice validated in `learning/riverpod-drift-demo/` (native backend on iOS, not the demo's wasm detour) and recorded in [`docs/decisions/2026-08-25-riverpod-and-drift.md`](decisions/2026-08-25-riverpod-and-drift.md). |
| **Supabase/R2 client adapter** | partial — the shared facts' half is built (`lib/storage/remote/`): `SharedFacts` is the interface, `PostgrestSharedFacts` speaks it over plain HTTP (no `supabase_flutter`; PostgREST is an ordinary REST API and the package would bring GoTrue, Realtime, Storage and a Podfile's worth of native dependencies). Auth is built too and lives beside it: `SessionSource` is the interface, `GotrueSessions` mints and keeps a GoTrue **anonymous** account over the same plain HTTP, which is what every RLS policy's `auth.uid()` reads. Sign in with Apple — the real identity route — is the unbuilt part, and the edge functions and R2 are not built | Supabase Auth, Postgres (PostgREST under RLS), both edge functions, R2 (presigned PUT/GET) | Repositories — nothing else in the app may import a Supabase or HTTP symbol | Wraps the session JWT, the RLS-filtered queries, the edge-function calls, and the direct-to-R2 byte transfers behind one interface the repositories consume. Where the project lives is still a `--dart-define` (`CAIRN_SUPABASE_URL` / `CAIRN_SUPABASE_ANON_KEY`), but as an *override*: both default to the hosted project's URL and its **publishable** anon key, which are checked in (`lib/storage/remote/shared_facts.dart`), so an ordinary build reaches the backend with nothing passed. The invariant that survived is the narrower one — **no secret is ever checked in**: never a `service_role` key, never the database password. Refusing before it sends anything is still the behaviour, but only for a build that overrides the defines to empty (`--dart-define=CAIRN_SUPABASE_URL=`). |

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
| **Postgres schema + RLS** | partial — built and verified on a throwaway local Postgres 17 (167-probe RLS suite); hosted migrations include `0014`'s flat, name-only member rename with its closed-trip refusal in force, where only the permitted paths have been walked (one account, so no refusal observed there); the remaining starter succession and delete-photo gate are not yet implemented | Supabase Auth (`auth.uid()`); written against the model vocabulary | Client adapter, both edge functions, and cross-device agreement on the trip clock | `profiles`, `trips` (+ timezone/window columns and `name_revised_at`), `trip_members`, `trip_invites`, `photos` (day-numbered since `0011`, and captioned), `day_unlocks` (likewise), `photo_tombstones`, `day_pages`, `day_page_photos`, and the itinerary's four (`trip_itineraries`, `trip_itinerary_days`, `trip_itinerary_stops`, `trip_itinerary_set_asides`); `is_trip_member`/`is_trip_starter`, `may_read_trip_photos`, `day_page_is_open`, `redeem_trip_invite`, `sync_trip_name`, `sync_trip_itinerary`, and the `trip_roster` view. Membership is the root of every access check, and every *photo* read reaches it through `may_read_trip_photos` — one seat, so the leaver rule lands in one place. |
| **Supabase Auth (GoTrue)** | partial — **anonymous accounts are live** on the hosted project and are how the phone signs in (`gotrue_sessions.dart`); Apple and Google are dashboard steps and are not enabled | (platform service) | Postgres (`auth.uid()` in every policy), client adapter, edge functions | Accounts. Sign in with Apple first; display name editable at join because providers supply legal names. |
| **`r2-upload-url` edge fn** | partial — code exists and its decisions are now tested offline (`handler_test.ts`), never deployed; **the phone now calls it** (`photoUploadTicket` in the adapter, driven by the outbox), so far only against a fake | Postgres (re-checks membership, the trip's close, and whether a `photos` row already claims this id — all as the caller), R2 (mints a 5-minute presigned PUT, bounded to a declared type and size) | The only write path for photo bytes — and the outbox's whole retry story leans on its flat refusal of a claimed id | Exists solely because the R2 secret cannot live in the app binary. Split in two on purpose: `handler.ts` decides and imports nothing remote, `index.ts` builds the clients — which is the only way an edge function nothing has deployed can be exercised at all. |
| **`r2-download-url` edge fn** | partial — code exists and its refusals are tested offline (`handler_test.ts`), never deployed and never run against a project | Postgres, all as the caller: it reads each `photos` row through RLS (so authorisation is *inherited* from `may_read_trip_photos`, never re-decided) and calls `day_page_is_open(trip, day number, uid)` **before** signing, R2 (a 15-minute presigned GET) | The gate itself: a version that skips the check is the single worst potential leak in the app | The bucket is private; every read needs a signature; gating the signature is what makes the shut gate real rather than a curtain. Batched, with a verdict per id and **no reason attached to a refusal** — a reason would map the corpus. It signs only the row's own stored `r2_object_key`; a trip, day or key named by the caller is not read at all — and since `0011` a row may only *store* a key inside its own `trips/<trip>/photos/<id>/` folder (`photos_object_key_own_prefix_check`), which is what makes that sentence an invariant rather than a convention. Same split as the upload function, for the same reason. |
| **Cloudflare R2** | not built — bucket not created, so no byte has ever moved and neither function has ever been run; plan settled, and the authorisation shape settled on 2026-08-28 as the time-limited signed link (no Worker proxy, no R2 binding) | nothing | Both edge functions — the PUT bounded to a declared type and size, the GET bounded to 15 minutes; the app's byte transfers; the 10 GB free tier is a real ceiling, and the only line in the backend that ever bills — measured in [docs/storage-and-cost.md](storage-and-cost.md) | Photo bytes and day-page composites at zero egress. Holds **originals**, untouched; a derived variant may sit beside one but never replaces it. Postgres is the index; R2 is never listed — the `photos` row *is* the pointer. |

### Platform edges — the camera and the document picker wired; the rest not built

Services know the edges; the edges know nothing of Cairn.

| Node | State | What breaks if it changes | Why it is on the map |
| --- | --- | --- | --- |
| **Camera roll (PhotoKit)** | not built | The import sweep, and the honesty of the import promise | iOS never wakes a third-party app for a new photo — no background trigger, no entitlement. The sweep runs on open; the interface says exactly that. |
| **Camera (dual capture)** | partial — `BackCameraSource.takeOne()` now takes **both** frames, back first and front second, and hands back a `CapturedFrame` carrying `backPath` and `frontPath`; nothing above the seam reads the second one yet, and no composition is built | Capture | Back primary + front inset, taken as a back-then-front sequence — the spike (`learning/dual-camera-spike/`) established that is what "like BeReal" actually means, and true simultaneous capture is explicitly not being built. One camera is opened and disposed at a time, never two; a device with no front camera is a `CameraRefused`, and a refusal after the first shot discards the back file rather than leaving an orphan. The seam's cleanup is per path, though, so while `capture_flow.dart` still discards `path` alone, a retake or an abandoned capture leaves the front file behind — the consumer slice that reads `frontPath` is the one that closes that. Composition and keeping the second frame land after the first release. |
| **File picker (UIDocumentPicker / PHPicker)** | built behind `FilePickerEdge` (`lib/app_state/file_picker_edge.dart`) — `file_picker`'s document and image modes, and nothing else | The way a plan arrives as a file rather than as pasted text | The paste box's second door. Two doors, not one: documents and the photo library are different pickers on iOS. The document door offers exactly the formats this build can actually read, through UTTypes derived from the extractor registry, and nothing wider; the image one needs `NSPhotoLibraryUsageDescription` because `file_picker` builds `PHPickerConfiguration(photoLibrary:)`, the authorization-requiring form. |
| **Text recognition (Apple Vision)** | built behind `TextRecognitionEdge` (`lib/app_state/text_recognition_edge.dart`) over the hand-written `cairn/text_recognition` channel to `ios/Runner/TextRecognition.swift`; `FakeTextRecognition` is the only implementation any automated test exercises, so **a green suite and a green simulator run are no evidence OCR works** — recognition quality is judged on a device | A screenshot or a photographed printout becoming plan text, and the scanned-PDF door off a `noTextLayer` refusal | Recognition is a platform call, so it is an edge and deliberately **not** an extractor in `planExtractors` — the same reasoning that put the camera behind `CameraSource`. `VNRecognizeTextRequest`, accurate mode, language correction on, languages asked of Vision at runtime; a scanned PDF is capped at 100 pages and reports progress per page. |
| **Local notifications** | not built — the schedule is derived and handed to a `NotificationEdge`, but the only implementation records what it was given rather than registering it with iOS; this is the one genuinely unbuilt piece of the ping | The ping reaching anyone | Registered in one offline pass from the schedule. Ordinary alert level — **never** time-sensitive, never pierces Do Not Disturb (notification-alert-level decision). Delivery is the OS's to refuse. |
| **Location** | not built | Rung-1 day assignment for pinged photos | A GPS tag at capture time is what lets the app's own photos take the best rung of the ladder. |
| **Sign in with Apple** | not built — an anonymous GoTrue account stands in, and links to a provider in place when this lands, keeping the uuid | The whole account path | First auth route. Web/PWA were ruled out (iOS evicts PWA storage); native + Apple sign-in is the way in. |

### Domain — the bottom of the map

Five **sibling** packages. None imports another; none imports anything above
itself; all are pure Dart, tested with `dart test` from their own directories.
The four non-model packages deliberately do **not** import `cairn_model` —
each speaks its own dialect, and the repositories translate. The model is the
vocabulary for the layers *above* the packages, not a dependency of its peers.

| Node | State | Knows about | What breaks if it changes | Why it exists |
| --- | --- | --- | --- | --- |
| **`cairn_model`** | built (merged, #7) | nothing — zero dependencies | Everything planned above it is written against this vocabulary: Drift rows, repository interfaces, providers, screen types. Renaming a concept here ripples through every unbuilt layer — which is exactly why it was built first. | One definition of Trip, TripClock, TripDay, Stop, Member, PhotoRef, DayPool, GateState, CalendarDate, ClockTime and the typed ids, so the database, state layer and interface stop inventing three private ones. Encodes: clock fixed at day start, gate as one enum, contributors survive photo deletion, no roles. |
| **`itinerary_parser`** | built | nothing — the optional `gazetteer` parameter is an interface (`AreaGazetteer`) the package declares itself and never reads a file or asset for | The confirmation screen's inputs; day/stop structure; the star rule (a stop is starred exactly when it carries a time); each stop's `StopKind` and, where the deterministic area extractor found one, an `AreaHint` for tap-to-Maps | Deterministic, offline parse of a pasted plan into days and stops. Built to ask, not guess: confidence, unplaced lines and a date candidate lifted out of a day's own title (never bound) exist so the confirm screen can put uncertainty in front of the user. Phase 2 added an optional gazetteer: given one, an area drawn from a vocabulary run must also be a real place name before it may attach — `gazetteer: null` stays phase-1 behaviour forever, which is what the package's own C7t ground-truth floors are pinned without one to guarantee. |
| **`trip_moments` v2** | built — v2 merged in #8, v1 retired | `crypto` (SHA-256) | Cross-device agreement on ping times. The derivation is a compatibility contract: change the hash, seed format, window maths or arithmetic and two app versions on one trip silently disagree. Any such change must bump the `trip_moments/v2` namespace. | One ping per person per day, dealt as a collision-free permutation over the party, reshuffled daily, in the trip's clock, window 08:00–22:30, offline and serverless. Takes the roster, clock and first/last-day windows as caller-supplied inputs — and offers **no fallback when devices hold different rosters**; keeping rosters agreed is the app layer's job. |
| **`photo_day_assignment`** | built | `timezone_finder`, `timezone` (embedded IANA data) | Which day every imported photo lands on — silently wrong here means the Trail, Pool and Book are wrong and nobody notices | GPS-derived timezone over bare EXIF, with a documented degradation ladder and a confidence on every answer. The authority for "which day is this instant"; `cairn_model` deliberately offers no rival answer. Read surfaces group on the day number already on a photo and never re-run the ladder — the answer was settled when the photo entered the pool, and a person may have overridden it by hand since. Standing trap: `findLocation(longitude, latitude)` — longitude first. |
| **`plan_extraction`** | partial — the contract, the plain-text extractor, slice C's docx/xlsx/csv extractors (xlsx and csv sharing one row model, `plan_rows.dart`; docx says a table one line per row, its untyped cells joined — the same rule reached the other way round) and slice B's PDF extractor (with the page-furniture cleanup a print carries) built; the calendar format not built, and screenshot OCR deliberately an edge rather than an extractor | `archive` + `xml`, `excel`, `csv`, and `pdfrx_engine` (PDFium behind pure-Dart FFI; on iOS PDFium is linked by the root pubspec's `pdfium_flutter` and not by this package) | Every file-import slice codes against it: `PickedBytes` in, a sealed `ExtractedText` / `ExtractionFailure` out. Changing the contract changes every extractor at once | Import is not a second parser — bytes in, honest lines of plan text out, so every format reduces to text `itinerary_parser` already reads. Failures are typed (`unreadable`, `empty`, `passwordProtected`, `noTextLayer`) and carry the sentence a person is shown, because a refusal a person cannot act on is the failure mode here. The registry is not in this package: it is a `const` list in `lib/app_state/import_flow.dart`, one line per format. `extract` returns a `FutureOr` because PDFium is not re-entrant and offers no synchronous entry point; every other extractor still answers directly. |

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
   server: `day_page_is_open` in SQL, keyed on `(trip, day number, user)`
   since `0011` — a photograph's day is its *number*, not its date, so a day
   whose date is still open still gates — which `r2-download-url` calls before
   signing a GET. Change what opens a day and both must move together,
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
10. **Where a trip stands is decided once, and the close is enforced on both
    sides.** `cairn_model.tripStandingAt` is the only thing that turns
    `(now, endsAt)` into underway / grace / archived; the app reaches it
    through `tripStandingProvider` and nothing above that provider compares
    dates itself, exactly as with the gate (#2). The `endsAt` it is handed is
    decided once too: `cairn_model.tripEndsAtFrom` turns the plan's day dates
    in plan order plus the trip's offset into an instant, and every caller on
    the seam goes through it — `tripEndsAtFor` in the app-state band, and
    both `TripSync._endsAt` and the `end_date` `_createSharedTrip` publishes
    in the repositories band — because a trip that has ended on screen and not
    on the wire is the coupling this list exists to name. A row that claimed
    an end the phone did not agree with would shut the pool and refuse every
    reconcile on a trip still being lived, so a plan whose last day is undated
    publishes no end at all and waits in `awaitingTripRow`. A trip ends at the end of its last day, so a plan whose last day is
    undated has no known end and is underway. The *close* is then a coupling
    like #2 and #9: seventy-two hours after the last day seals, on the phone
    (`graceAfterATrip`) and in SQL (`trip_grace_after_end()`), with
    `supabase/tests/rls_probe.py` reading the Dart constant to compare them.
    Both halves shut the pool — `CaptureFlow.turnTheDayOver` and
    `photos_insert_trip_member`, the latter backed by a trigger that forbids
    a photo being repointed at another trip — and both halves shut the plan
    — `TripSync._reconcile` and `sync_trip_itinerary` — because eight phones
    means one wrong clock. The trip's *name* shuts the same way since the
    rename ruling: `canRenameTrip` refuses on a read-only standing, and
    `guard_member_trip_rename` asks `trip_closes_at` whenever the name moves,
    before it lets even the starter past. What the close does not take, on either side, is a
    person's hold on their own photograph. See
    `docs/decisions/2026-08-26-the-ending.md`.

---

## Honesty about the gaps

Drawn as open on the map, not as settled. None of these is a contradiction —
in every case the decision record is clear and the code is behind it,
acknowledged and queued (`docs/roadmap.md`, "Work already queued").

- **The starter-and-container decisions are implemented on the phone and
  partly on the server.** `cairn_model`'s `trip_powers.dart` is the whole permission
  model — rename and mint flat, delete the starter's only while the trip holds
  nobody else's photos, revoke by the minter or the starter, and the removal
  power passing silently to the longest-standing member when the starter
  leaves — and the trip's own surface asks it before every act. The migrations
  in `supabase/` now let any current member rename through a name-only clocked
  path (`0014`), but still have starter-only delete with no photo condition
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
- **The download path exists in code and has never run.** `r2-download-url`
  is written and its refusals are exercised offline, but there is no bucket,
  no deployment and no project it has been pointed at, so not one of them has
  been *observed*. `tool/photo_pipe_probe.dart` is the harness that would
  observe them — three real accounts over the real stack, which is the only
  place an RLS refusal has ever been watchable — and it is unrun for the same
  reason. Written-and-unrun is a smaller blank than not-built, and it is still
  the map's most dangerous one.
- **Sync and conflict policy is settled for the itinerary, the roster and the
  trip's name, and undecided for everything else.** Those shared facts
  reconcile last-write-wins per day — and the name on its own
  `name_revised_at` clock — with no conflict UI and no CRDT — a deliberate
  choice, and it costs what last-write-wins always costs: a phone with a fast
  clock wins edits it should lose. Of the photos' three written notes, the
  outbox ordering is now built (the push half, `photo_sync.dart`; the caption
  is a single-owner field whose latest write wins, no conflict machinery);
  the `day_pages` insert→update fallback and the deletion refetch remain
  notes, and no reconciliation of rows against R2 objects exists in any
  direction.
- **The shared facts' sync is live on an ordinary build — since 27 August 2026
  and not before — and one test is the only thing that says so.** It was
  written, tested and correct for weeks while a `String.fromEnvironment` with
  no default meant no binary anybody would run could create the shared `trips`
  row; the clock is now the phone's own IANA zone and an unnamed trip
  publishes under a placeholder the phone maps back to local null
  (`docs/decisions/2026-08-27-the-trip-clock-is-the-phones.md`).
  A green `flutter test` still proves nothing about the hosted project:
  every widget test binds `NoSession` and an in-memory database, deliberately,
  because a sync started under `testWidgets` hangs the test. The live check is
  `test/hosted_smoke_test.dart`, skipped unless asked for
  (`--dart-define=CAIRN_HOSTED_SMOKE=true`). What it does *not* cover: more
  than one account at a time, so no RLS refusal has ever been observed on the
  hosted project — only the permitted paths. The 167 adversarial checks still
  run against a throwaway local Postgres, and must.
- **The shared roster replaces this phone's, and this phone is now whoever
  signed in.** `localMemberIdProvider` (`lib/app_state/ping_schedule.dart`) is
  the account id when there is a session and the string `'me'` when there is
  not; `main()` resolves it before it builds the app — out of the session
  vault, with no network round trip on the boot path — so nothing is ever
  credited to the stand-in and then re-credited. The identity is fixed for the
  life of the launch: an account minted too slowly on a first launch is stored
  and picked up on the next one rather than adopted mid-session — with one
  narrow exception, the accept path's bounded last chance to adopt a
  late-landing account while no trip exists yet (`bootstrap.dart`'s docs are
  the authority on both halves of this). A trip still *started* under `'me'` —
  the plane, or a configured build offline past accept — cannot become a
  `trips` row on that launch (`created_by` references `profiles.id`, a uuid),
  but it is no longer stranded for good: the next launch that knows its
  account heals the roster to it (`MembershipStore.adoptAccountIdentity`,
  `test/stand_in_identity_test.dart`), and the sync proceeds from there. The
  three-second budget (`resolveMemberId`) is deliberate — it is what keeps a
  bad network off the launch screen — and the person is still given no signal
  on the launch it happens. And the roster the server hands back names
  people by their profile's `display_name`, which nothing on the phone writes,
  so an anonymous account reads as `New traveller` rather than `You`. Both
  close when sign-in asks for a name.
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
  through a controller — on a device, one back frame and then one front frame —
  and never shows the live preview behind the shutter. That is a visual-treatment question the design round
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
  changes when the trip clock lands. It now rolls over at midnight with the
  rest of the app's time-derived verdicts, because it reads `nowProvider`
  and the app root asks that clock again on resume and on a cadence
  (`lib/app.dart`); it was read once per launch until 2026-09-03, which left
  the late door open on a day that had ended.
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
  tier between trips is built and deployed — `ops/keepalive-worker/`, a
  Cloudflare Worker outside the app's bands entirely; `supabase/README.md`'s
  Free-tier limits section is the authority on it. (CI exists since #13 and covers the
  packages, the JS-safety golden, the RLS probe, the learning demo and the app.)
- **The hosted Supabase project is real; a real R2 bucket still is not.**
  Migrations `0001`-`0010` are applied to the hosted project and an ordinary
  build points at it (`0011` is applied nowhere but the local probe), but only the permitted paths have ever been walked there — the
  adversarial verification (the RLS probe) still runs against a throwaway
  local Postgres, and must keep running there. No R2 bucket exists.

---

## What to do with this map

Before changing a node, read its row: the "what breaks" column is the blast
radius, and the invariants list is the couplings the import graph won't show
you. Before *adding* an arrow, check its direction — if it points upward,
the design is wrong, not the rule. And when a gap above closes, update this
file and `architecture.html` in the same change; a map that looks more
finished than the project is worse than no map.
