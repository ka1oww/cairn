# The map

`docs/decisions/` records *why* Cairn is shaped the way it is.
`docs/design/` records *what it looks like*.
This file records **what is built, what is not, and the order the rest arrives in** —
and, where the order is not obvious, why it is that order.

Last true as of 25 August 2026.

---

## What Cairn is, when it is finished

Eight friends go on a trip together. Each person's phone buzzes once a day, at a
different moment from everyone else's, and asks for a photo. Because only one
person is holding a phone at that moment, they photograph the others — the
camera turns around without anyone being told to turn it. The photos land in a
shared pool, arranged along the day's real path through the itinerary. Today's
page stays shut to you until you have put something in it — a day that is over
belongs to the whole party. At the end of the
trip, the whole thing composes into a book everybody keeps.

That is the entire product. Everything below is in service of it.

---

## The line: what the first release is

Not everything above is the first release. The line was drawn on 22 August —
see [the first-release decision](decisions/2026-08-22-first-release.md) — and
it makes the rest of this file orderable:

**In — whatever makes one real trip work for eight people, and nothing else:**

- Eight people can join with three spoken words
- The itinerary is pasted once, and everyone can read today
- Everyone's pocket buzzes at their own minute
- Taking a photo opens today's page
- The photos land in one pool everybody can see

**Explicitly after it — deliberate choices, not omissions:**

- **The book.** The payoff — but it is made *after* the trip, from photos
  already sitting in a pool. It does not need to exist while anyone is
  travelling, which is what makes the line drawable at all.
- **Writing a word later.** The one line typed at the breath shipped with
  capture — the [no-book-editor decision](decisions/2026-08-22-book-no-editor.md)
  put it on "a screen that already exists", and that screen is now built. What
  is after the line is going back to your own print afterwards and writing on
  it. (There is still no book editor, in the first release or ever.)
- **The cat.** [Parked, not cut](decisions/2026-08-22-cat-deferred.md).
- **The handover.** The end-of-trip save of the book and the full-size set to
  each person's own phone. The grace window means nothing is lost by it
  arriving after the first trip starts — but it is the highest-severity blank
  in the backend and lands early in version two.
- **The two-frame camera.** First release captures back-only, the accepted
  fallback; the front inset follows. See
  [the camera decision](decisions/2026-08-22-camera-like-bereal.md).
- **The countdown.**

**The test the line is held to:** when a friend on the trip asks what this
does, one sentence answers it — if the answer needs two sentences, something
on the "in" list belongs on the "out" list.

**The target:** [December](decisions/2026-08-22-december-target.md), chosen
rather than discovered — no trip is actually in the calendar. First release
estimated mid-to-late October; the slack is the point.

---

## Where this is now

**Foundations are done. The app has a way in, a trip with all three of its
destinations in it, and — for the first time — something to put in them.**

The paste-and-confirm flow is built and tested: paste a plan, see what the
parser understood day by day with its doubt surfaced per cause, flip
ambiguous dates month-first in one tap, accept — and the itinerary persists
locally into Drift, surviving a relaunch. It replaced the scaffold's proving
screen and disposable `trip_drafts` demo.

**Today is built on top of it**, and it replaced that slice's placeholder as
the launch surface: the app now opens on the day page for today's date —
which day of the trip it is, the day itself, and the day's stops in the
order they were pasted, with a star and a time only where the plan pinned
one to a clock. There is no separate day-detail screen and there never will
be: `DayPage` is the whole of it, and the Trail opens that same widget for
every node it draws. The drawn edges are built with it — a day with
nothing planned, a date the plan skips, before the trip starts, after it
ends, and a plan pasted with no dates at all.

**The Trail is built on top of both**, and with it the real container. The
trip is a winding path of one node per day in itinerary order, a flag on the
day you are standing in, ink road behind you and dashes ahead; tapping any
node — past, ahead, or a day whose date was never given — opens that day's
page, which is the same day page and not a second one. Today and the Trail
became tabs, with the Pool left out rather than shown as a disabled stub
until it existed — which it now does. The edges are built with it: before the trip
starts, after it ends, a one-day trip, and a date the plan skips (which gets
a day page but no node, because the drawings number the path over the plan's
own days).

**The Pool is the third tab**, and the container now holds the whole of
surface 2e's structure. It is the trip's photos in one shared place, grouped
by the day each was assigned to and read newest first, with a count over the
lot. It is plumbing by decision ([first calls](decisions/2026-08-21-first-calls.md),
"The Pool is plumbing") and it is built as one: structure and states in the
theme's own colours, and none of the sticker treatment, the taker's initial
chip or the dashed "+" tile, each of which waits on something that does not
exist yet. Both its states are real — an empty pool is a written line rather
than a skeleton grid, and a photo whose bytes are not on this phone is a tile
waiting for them rather than a broken one, which is a permanent state of a
pool eight people share.

**Capture fills it, back-camera-only** — which is the line's own scope and not
a shortcut, since the front inset is explicitly after the line. The whole loop
is real: the schedule is dealt from `trip_moments` for every dated day of the
plan, the day you are standing in says where your moment stands, an open or a
late window offers the way in, the shutter takes a frame, the breath offers
exactly one retake and one line of words, and keeping it writes a row into the
photo index with the frame beside it on disk — where the Pool, reading the same
store, draws it. A missed slot is never a lockout: the door stays open till
midnight and what you take then lands at the hour it was taken.

Two pieces of it are honestly unfinished. Nothing is registered with iOS yet,
so no pocket actually buzzes; and where there is no camera (the Simulator) the
app draws its own frame, so a green run there is not evidence the real camera
path works.

**The gate now says what the record says.** Today's photographs stay shut to
you until you have put something into today, and a day that is over is open to
everyone who was on the trip for it — answered or not, and whether they joined
before it or the morning after. It is one rule (`cairn_model`'s
`GateState.decide`) with one answer in the app, so no surface can hold a
private opinion about it; the deliberate "shut forever" test that pinned the
opposite is gone rather than worked around, as
[grill round one](decisions/2026-08-22-grill-round-one.md) §1 asked. Its reach
is honestly small today: the Pool is the only surface that draws a photograph,
so it is the only one with anything to withhold, and with no roster every photo
on this phone is this phone's own — so the day being lived opens as soon as you
answer it and there is nobody else's picture to hold back yet.

**The trip is now a stored thing rather than an implied one.** Accepting a
plan starts a trip: a roster in Drift, the fact of who started it, and three
words to say to somebody so they can join. The permission model is
`cairn_model`'s and nothing above it re-decides it — renaming and minting are
flat, deleting is the starter's alone and only while the trip holds nobody
else's photos, revoking belongs to whoever minted the code or to the starter,
and the removal power passes silently to the longest-standing member if the
starter leaves. There is no role column in the schema and there must never be
one. The sheet over it hangs off the Trail's title and never a fourth tab: the
roster with one quiet note per row, the live code with what it can and cannot
do, rename, new words, and a delete that states its own refusal in writing.
The pings are dealt across that roster now, so the stub member is gone.

Two halves of it are honestly unfinished, and they are the same half twice: a
phone can only ever write its own row, so the roster holds one person, and a
code — real, canonical, revocable, dying with the trip — cannot admit anybody,
because nothing carries a membership to another phone. Saying a code back is
built and answers every case this phone can see; for a well-formed code
belonging to somebody else's trip it says so plainly rather than spinning.
That last step is Phase 2 and nothing else.

The itinerary is local-only until it becomes the shared, propagated fact of
Phase 2. A pool of one phone's
photos is likewise only half the Pool — nobody else's bytes can arrive until
Phase 2 moves them, and that is also what the gate is waiting on to matter.
Still not built: the day page's photo timeline, the Trail's filled node, and
the gate's face on the day page — the rule is there, the page has no
photographs to withhold yet.
Beneath it: four pure-Dart libraries, a backend schema, a
dual-camera spike, the decision record, and the design handoffs, all
tested.

| Piece | State |
| --- | --- |
| Every product decision | **Settled.** See `docs/decisions/`. |
| `packages/itinerary_parser` | Landed. Parses pasted trip plans into days and stops. |
| `packages/photo_day_assignment` | Landed. Decides which day a photo belongs to. |
| `packages/trip_moments` | Landed. Deals one ping per person across the party. |
| `packages/cairn_model` | Landed. The shared vocabulary. |
| `supabase/` | Landed. Blockers fixed, decisions encoded, verified on real Postgres. Nothing hosted yet. |
| CI | Landed. Package tests, the JS-safety golden, the RLS probe — and now the app — run on every pull request. |
| `learning/dual-camera-spike` | Landed. Settled the capture as a back-then-front sequence. |
| The Flutter app | **The way in, Today, the Trail, the Pool, capture and the trip itself.** The paste-and-confirm flow persisting the itinerary locally, the day page it lands on, the trip's path, the three-tab container holding them, the shared pool and the screen over it, the daily moment that fills it (schedule, camera behind a seam, the pause and the word, written into a local photo index the Pool reads), the gate's rule landed with them and the Pool obeys it (the day page's own gated half still waits on the photo timeline) — and now the trip as a stored fact: roster, starter, flat-but-gated powers, three-word codes that die with the trip, and the sheet off the Trail's title. Nothing registered with iOS yet; no code can reach another phone yet. |

---

## The order, and why it is that order

Phases 1–3 plus the TestFlight step of phase 5 *are* the first release. Phase 4
is deliberately after the line.

### Phase 1 — Cairn on one phone

Create the app, wire in the four packages, stand up the local database, and get
a real screen running on a real iPhone.

**Why this comes before anything shared:** almost all of Cairn works offline by
design. The ping times are derived on the device from a hash — no server is
consulted, ever. The itinerary is parsed on the device. Photos are placed on
days on the device. That means the majority of this app can be built, used and
judged before a single account exists or a single cent is spent.

It is also the first moment the project stops being an argument and becomes a
thing you can hold. That matters more than it sounds for a project whose
deadline is a chosen anchor rather than a booked trip.

*Needs from you: Xcode, and your phone on a cable. No paid program yet — a free
Apple ID signs onto your own phone, seven days at a time.*

### Phase 2 — Cairn on eight phones

Accounts, trip membership, the shared photo pool, photo bytes moving to and
from object storage, and the itinerary as a shared fact — edited once,
propagated to every phone, so the ping schedule is never dealt from a stale
roster or a stale plan
([grill round one](decisions/2026-08-22-grill-round-one.md) §2).

The pool stores **originals**; resizing is for display only (§3 of the same
decision). Sizing the storage bill is work still to do, but it is work, not a
decision.

**Why second:** the gate, the pool and the day page are all inherently
multi-person. They cannot be honestly built or judged with one device. This is
also the first phase that costs anything to keep alive, so it should not start
before Phase 1 proves the thing is worth keeping alive.

*Needs from you: a Supabase account and a Cloudflare account. Keys live in a
local file that is never committed.*

### Phase 3 — the trip surfaces

The day page's *other* half — the photo timeline that makes the day an
artefact, its plan half having landed early with Today — and with it the gate's
face on that page, the rule itself having landed early too; the back-only
capture, and the late-photo path for a missed ping. The Trail's own path landed early alongside Today;
what is left of it here is the node a day's photos fill, which is the whole
reward of that screen and cannot be drawn before photos exist. The Pool's
structure landed early the same way, over a read seam with nothing behind it;
what is left of it here is the photograph in the tile, and the taker's initial
chip once a roster exists.

**Why third:** these are the parts people actually see and the parts most likely
to change once you have used them. Building them on top of a working pool means
changing them is cheap. Building them first means rebuilding them.

At the end of this phase sits **the weekend test with friends** — the gate
before any real trip, and the moment the app first has to reach someone else's
phone. That is when Apple gets paid, not before and not later:
[paying later](decisions/2026-08-22-paying-later.md).

### Phase 4 — the book, after the line

The end-of-trip artefact: the day pages composed into something everyone keeps.
Automatic — it generates itself and
[nobody edits it](decisions/2026-08-22-book-no-editor.md). The photograph is
the cover's face, the cairn signs the foot
([book round nine](decisions/2026-08-22-book-round-nine.md)).

**Why after the first release, and why that costs nothing:** the book is made
after the trip, from photos already in the pool — and
[the book never expires](decisions/2026-08-22-grace-window.md), so it can land
as a pull request while the first trip's photos wait. The trip closing and the
book's availability are **two separate rules** (trip end + 14 days; forever) —
never one timestamp.

The interior is designed (round 9); the **printed page is not**, needs no code,
and should be drawn in parallel long before this phase so it never becomes the
critical path.

### Phase 5 — into your friends' hands

Apple's paid program and TestFlight arrive at the weekend test (see Phase 3).
The Google Play testing track for the Android friend follows with Android
delivery.

**Why the fees sit exactly there:** both are metered from the day you pay, and
**a TestFlight build expires 90 days after it is uploaded.** Paying early buys
nothing and burns the clock; paying late costs the weekend the test was meant
to fill.

*Costs, when the time comes: Apple $99/year, Google $25 once.*

---

## What only Zhehang can do

Nothing here can be delegated, and several of these block a whole phase.

- **Xcode**, and accepting its licence. Blocks Phase 1.
- **The Supabase and Cloudflare accounts.** Blocks Phase 2. Keys never enter this
  repository, a pull request, or an agent's hands.
- **Paying Apple** at the weekend test, **and Google** at Android delivery.
- **Sending design prompts to Claude Design**, and returning the handoffs.
- **Showing the app to any of the eight.** Nothing has been shown yet, and a
  late "this is obviously wrong" is the discovery the December slack exists to
  absorb — but only if it happens early.
- **Merging pull requests**, and deciding anything the record does not already
  settle.

---

## Work already queued, sorted by the line

Not a schedule. An inventory, so nothing is quietly forgotten.

**First release:**

- Carry a membership to another phone, which is the one thing standing between
  a real invite code and somebody actually joining. Everything on this side of
  it is built — roster, roles, three-word codes that die with the trip, and the
  door that reads them back — and honestly says so when it cannot reach a trip.
- Finish reconciling the schema with the settled decisions. The three-word
  grammar is on the server now — `supabase/migrations/0005_trip_invites.sql`
  mints two words and a number, forgives order and spelling by the same rule
  the phone forgives them by, and kills a code at the trip's close instead of
  at a per-invite `expires_at` (the single timestamp the grace-window decision
  exists to prevent), with `tests/rls_probe.py` reading the Dart vocabulary to
  keep the two halves from drifting. What is still unreconciled: `max_uses`,
  which the phone has no notion of, and starter-only rename/delete with no
  photo condition and no succession.
- Throttle `redeem_trip_invite`. Three spoken words are a little over six
  hundred thousand codes where eight characters were ~850 billion, and each
  guess covers a neighbourhood of near-spellings. Sayable was the point and
  the trade is the decision's; the rate limit it assumes is not written yet,
  at the database level or above it.
- The itinerary as a shared, propagated fact; membership changes reaching every
  phone.
- The trip's close at trip end + 14 days as a *stored* rule. It is derived
  correctly on the phone now (`cairn_model`'s `tripClosesAt`, which is what
  kills an invite code), but it is derived from the plan each time rather than
  being a fact of the trip everybody's phone agrees on — and the server knows
  nothing of it.
- The trip's own clock. Nothing stores one, so the trip is read at the
  device's UTC offset in the two places that admit it, and the timezone power
  the starter-and-container decision settled has nothing to act on yet.
- Register the ping with iOS. The schedule is derived and handed to a
  `NotificationEdge`; nothing implements that edge against the OS, so the last
  inch of the ping — the buzz — is the piece still missing.
- Fetch other people's bytes into the pool. The Pool draws what this phone
  took; a photo somebody else took is a tile waiting for bytes until Phase 2
  moves them.
- Show the frame on today's page and on the Trail's nodes, and put the live
  viewfinder behind the shutter.
- Authored words: the one line typed at the breath is built. What is *not* is
  writing a word later on your own print, which the design places on the day
  page rather than in capture. (This item used to sit below the line; the
  no-book-editor decision puts the caption on "a screen that already exists"
  and the design round puts it at the breath, so the capture half came with
  capture. Only the write-it-later half is still after the line.)
- The round-eight corrections beyond the asks: holding a chip to move a stop
  between days, renaming in place, laying days out by hand when nothing
  parsed. (The parser fix for hedged times and the round-eight API extension
  landed in #15; the paste-and-confirm screens are built on them.)

**Explicitly after the first release:**

- The book (automatic; photograph-fronted cover), and the printed page design
  that must be drawn in parallel before it.
- The end-of-trip handover of the book and everyone's photos.
- The two-frame camera (the front inset).
- The cat.
- The countdown.
- Android delivery through the Play testing track.
- Autofill the itinerary from a Wanderlog export.
- Google sign-in with accounts keyed to their own id rather than Apple's.
- Standing ops so Cairn survives the quiet months between trips.
- Sizing the storage bill for originals from eight people.

**Undecided and deliberately parked:** what happens to in-transit photos on a
trip that crosses several timezones in one day.

---

## Things that will bite, written down before they do

Each of these has already cost time, or is certain to.

- **iOS never wakes a third-party app because a new photo appeared.** There is no
  background trigger and no entitlement that buys one. The import runs when the
  app is open, and the interface says exactly that. See
  `docs/decisions/2026-08-22-auto-import-honesty.md`.
- **A free Apple ID's provisioning profile expires every seven days**, and **a
  TestFlight build expires 90 days after upload.** Relevant to *when* you pay,
  not just whether.
- **The trip's ending is two rules, not one.** Close to new photos at trip end
  + 14 days; the book makeable forever. A single "expiry" timestamp silently
  re-bundles what was deliberately split. See
  `docs/decisions/2026-08-22-grace-window.md`.
- **Supabase's free tier pauses a project after about a week of inactivity**, and
  after a year the dashboard restore path is gone. A trip that is months away
  means the project will sleep. That is what the dormancy work is for.
- **Google closed the shared-albums API to third-party apps in March 2025.** Any
  design that assumes an existing shared album is a dead end.
- **Cloudflare R2's free tier is 10 GB, and the pool keeps originals.** Eight
  people photographing a fortnight will exceed a free allowance sized for
  thumbnails. Cheap, not free — but the bill has never actually been sized, and
  that measurement is queued work.
- **Row-level security refuses by filtering to zero rows, not by raising.** A test
  asserting "this was rejected" can pass while testing nothing. This already
  burned one analysis. Assert on the state of the table afterwards, never on
  whether a statement threw. See `supabase/tests/README.md`.
- **Dart's `int` bitwise operators are 32-bit when compiled to JavaScript.** The
  ping derivation uses arithmetic rather than shifts for exactly this reason, and
  a golden test pins it. See `packages/trip_moments/`.
- **The Simulator has no camera, so the app draws its own frame there.** That is
  what makes the capture flow walkable without a cable, and it is also a trap:
  a green simulator run says the flow is right and says *nothing* about whether
  the camera path works. The real back camera has to be judged on a device, and
  only on a device.
- **The person holding the phone is `me`, and their name is "You".** There is
  no sign-in, so there is no account id to be. The roster row is real and every
  photo is credited to it; only the id and the display name are local
  constants, and they are the last stand-ins in the app state. They go when
  sign-in lands, and every row written before then still says `me`.
- **A photo row is an index; the photograph is a file beside it.** Locally that
  is Drift plus a file in the app's documents directory, mirroring Postgres
  plus R2 on the server. Deleting the row does not delete the photograph, and
  nothing yet reconciles the two in either direction.

---

## How to keep this file honest

Update it when a phase actually changes state, not when work is merely planned.
A roadmap that lists intentions is worse than no roadmap, because it reads as
progress. If something here has stopped being true, correcting it is more
valuable than adding to it.
