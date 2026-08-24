# The map

`docs/decisions/` records *why* Cairn is shaped the way it is.
`docs/design/` records *what it looks like*.
This file records **what is built, what is not, and the order the rest arrives in** —
and, where the order is not obvious, why it is that order.

Last true as of 22 August 2026.

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
- **Authored words.** Captions people write are printed by the book; they can
  land with it. (There is still [no book editor](decisions/2026-08-22-book-no-editor.md),
  in the first release or ever.)
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

**Foundations are done. The first real screens exist.**

The paste-and-confirm flow is built and tested: paste a plan, see what the
parser understood day by day with its doubt surfaced per cause, flip
ambiguous dates month-first in one tap, accept — and the itinerary persists
locally into Drift, surviving a relaunch as the app's launch surface. It
replaced the scaffold's proving screen and disposable `trip_drafts` demo.
The itinerary is local-only until it becomes the shared, propagated fact of
Phase 2; after accepting, the app lands on a deliberate placeholder — Today
and the Trail are still not built. Beneath it: four pure-Dart libraries, a
backend schema, a dual-camera spike, the decision record, and the design
handoffs, all tested.

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
| The Flutter app | **First screens.** The paste-and-confirm flow, persisting the itinerary locally; everything after accepting is a placeholder. |

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

The Trail (the day's real path), the gate holding a day shut until you
contribute, the day page itself, the back-only capture, and the late-photo path
for a missed ping.

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

- Implement the starter, container and invite decisions, including three-word
  codes that expire with the trip.
- Open past days; the gate applies to today only (and remove the "shut forever"
  test that pins the opposite).
- The itinerary as a shared, propagated fact; membership changes reaching every
  phone.
- The trip's close at trip end + 14 days — stored as its own rule.
- Back-only capture wired to today's page.
- The round-eight corrections beyond the asks: holding a chip to move a stop
  between days, renaming in place, laying days out by hand when nothing
  parsed. (The parser fix for hedged times and the round-eight API extension
  landed in #15; the paste-and-confirm screens are built on them.)

**Explicitly after the first release:**

- The book (automatic; photograph-fronted cover), and the printed page design
  that must be drawn in parallel before it.
- Authored words at capture time.
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

---

## How to keep this file honest

Update it when a phase actually changes state, not when work is merely planned.
A roadmap that lists intentions is worse than no roadmap, because it reads as
progress. If something here has stopped being true, correcting it is more
valuable than adding to it.
