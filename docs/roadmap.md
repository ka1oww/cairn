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
shared pool, arranged along the day's real path through the itinerary. A day's
page stays shut to you until you have put something in it. At the end of the
trip, the whole thing composes into a book everybody keeps.

That is the entire product. Everything below is in service of it.

---

## Where this is now

**Foundations are done. There is no app.**

There is no `lib/`, no `ios/`, no `android/`, no root `pubspec.yaml`. What exists
is four pure-Dart libraries, a backend schema, the complete decision record, and
the design handoffs. All of it is tested; none of it can be opened on a phone.

| Piece | State |
| --- | --- |
| Every product decision | **Settled.** See `docs/decisions/`. |
| `packages/itinerary_parser` | Landed. Parses pasted trip plans into days and stops. |
| `packages/photo_day_assignment` | Landed. Decides which day a photo belongs to. |
| `packages/trip_moments` | Rewritten to the decided ping model. In review. |
| `packages/cairn_model` | The shared vocabulary. In review. |
| `supabase/` | Three blockers fixed, decisions encoded, verified on real Postgres. In review. |
| The Flutter app | **Does not exist.** |

---

## The order, and why it is that order

### Phase 1 — Cairn on one phone

Create the app, wire in the four packages, stand up the local database, and get
a real screen running on a real iPhone.

**Why this comes before anything shared:** almost all of Cairn works offline by
design. The ping times are derived on the device from a hash — no server is
consulted, ever. The itinerary is parsed on the device. Photos are placed on
days on the device. That means the majority of this app can be built, used and
judged before a single account exists or a single cent is spent.

It is also the first moment the project stops being an argument and becomes a
thing you can hold. That matters more than it sounds for a project with no
deadline and no customer.

*Needs from you: Xcode, and your phone on a cable. No paid program yet.*

### Phase 2 — Cairn on eight phones

Accounts, trip membership, the shared photo pool, and photo bytes moving to and
from object storage.

**Why second:** the gate, the pool and the day page are all inherently
multi-person. They cannot be honestly built or judged with one device. This is
also the first phase that costs anything to keep alive, so it should not start
before Phase 1 proves the thing is worth keeping alive.

*Needs from you: a Supabase account and a Cloudflare account. Keys live in a
local file that is never committed.*

### Phase 3 — the trip surfaces

The Trail (the day's real path), the gate holding a day shut until you
contribute, the day page itself, and the late-photo path for a missed ping.

**Why third:** these are the parts people actually see and the parts most likely
to change once you have used them. Building them on top of a working pool means
changing them is cheap. Building them first means rebuilding them.

### Phase 4 — the book

The end-of-trip artefact: the day pages composed into something everyone keeps,
digital first with print-ready geometry underneath.

**Why last of the building phases:** the book is a composition of the day pages.
It cannot be designed before they exist without designing them twice.

*Still waiting on you: the reference you mentioned sending.*

### Phase 5 — into your friends' hands

Apple's paid program, TestFlight, and the Google Play testing track for the
Android friend.

**Why genuinely last, and not a moment sooner:** both fees are metered from the
day you pay, and **a TestFlight build expires 90 days after it is uploaded.**
Paying early buys nothing and burns the clock. The correct time to pay Apple is
close to the trip.

*Costs, when the time comes: Apple $99/year, Google $25 once.*

---

## What only Zhehang can do

Nothing here can be delegated, and several of these block a whole phase.

- **Xcode**, and accepting its licence. Blocks Phase 1.
- **The Supabase and Cloudflare accounts.** Blocks Phase 2. Keys never enter this
  repository, a pull request, or an agent's hands.
- **Paying Apple and Google.** Blocks Phase 5. Deliberately deferred.
- **Sending design prompts to Claude Design**, and returning the handoffs.
- **Merging pull requests**, and deciding anything the record does not already
  settle.

---

## Work already queued, roughly by phase

Not a schedule. An inventory, so nothing is quietly forgotten.

**Foundations, awaiting merge:** the domain model; the ping rewrite; the backend
correctness pass.

**Near-term:** run the tests on every pull request (nothing currently does);
implement the starter, container and invite decisions; the parser fix for hedged
times.

**Phase 2–3:** the gate and the day panel; autofill the itinerary from a
Wanderlog export; Google sign-in with accounts keyed to their own id rather than
Apple's; raise the photo upload long edge to 2560.

**Phase 4–5:** the book's page design; the end-of-trip handover of the book and
everyone's photos; Android delivery; standing ops so Cairn survives the quiet
months between trips.

**Undecided and deliberately parked:** what happens to in-transit photos on a
trip that crosses several timezones in one day.

---

## Things that will bite, written down before they do

Each of these has already cost time, or is certain to.

- **iOS never wakes a third-party app because a new photo appeared.** There is no
  background trigger and no entitlement that buys one. The import runs when the
  app is open, and the interface says exactly that. See
  `docs/decisions/2026-08-22-auto-import-honesty.md`.
- **A TestFlight build expires 90 days after upload.** Relevant to *when* you pay,
  not just whether.
- **Supabase's free tier pauses a project after about a week of inactivity**, and
  after a year the dashboard restore path is gone. A trip that is months away
  means the project will sleep. That is what the dormancy work is for.
- **Google closed the shared-albums API to third-party apps in March 2025.** Any
  design that assumes an existing shared album is a dead end.
- **Cloudflare R2's free tier is 10 GB.** Eight people photographing a fortnight
  will approach it. The upload long edge is a real decision, not a detail.
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
