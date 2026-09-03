# The map

`docs/decisions/` records *why* Cairn is shaped the way it is.
`docs/design/` records *what it looks like*.
This file records **what is built, what is not, and the order the rest arrives in** —
and, where the order is not obvious, why it is that order.

Last true as of 1 September 2026, reconciled claim by claim against a full bug
sweep run on a simulator against the live backend and the subsequent hosted
cleanup and member-rename rollout. Where this file used to
claim something that turned out not to be true, the claim has been replaced
rather than annotated.

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

## The one-line state of it

**Everything Cairn has built works. What is not built is the part that makes it
a group.** As of today the itinerary does leave the phone on an ordinary build —
that was fixed on 27 August and had been silently broken since the sync was
written — but **no photograph has any way to reach another phone, and no phone
has any way to buzz.** Neither is broken; both are unwritten. On today's build,
for the seven people who are not the planner, Cairn is a very good single-player
app.

That sentence is the honest headline, and the rest of this file should be read
against it.

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

Of those five, **one and a half are built**: the itinerary is pasted and now
genuinely reaches the server (nobody else can read it yet, because nobody else
can join). Joining, buzzing, and the shared pool are all unwritten.

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
- **The two-frame camera.** The camera edge's half has landed — one
  `takeOne()` now takes the back frame and then the front one, sequentially —
  but nothing above the seam reads the second file, so the first release still
  *keeps* back-only, the accepted fallback. What follows is composing the
  inset and keeping it. See
  [the camera decision](decisions/2026-08-22-camera-like-bereal.md).
- **The countdown.** The *drawn* one — the dashed thread burning down the edge
  with its coral bead (10a/10b). The reading itself came forward with the
  two-minute window: the capture screen counts the time left down to the
  second in the house's own type, because at two minutes it is the only
  feedback the person has and stopped being decoration. What is still after
  the line is the treatment.

**The test the line is held to:** when a friend on the trip asks what this
does, one sentence answers it — if the answer needs two sentences, something
on the "in" list belongs on the "out" list.

**The target:** [December](decisions/2026-08-22-december-target.md), chosen
rather than discovered — no trip is actually in the calendar. First release
estimated mid-to-late October; the slack is the point.

### The 31 October tripwire, stated at zero

The captain set a condition on the seven's half of the product: **by 31 October
the ping must fire on a real phone, and a photograph must cross between two real
phones — or that half gets cut.**

**Both conditions currently sit at zero, and neither is close in the sense of
"nearly working".**

- *The ping firing on a real phone* needs an implementation of
  `NotificationEdge` against iOS. There is none, and there is **no notification
  dependency in `pubspec.yaml` at all** — not `flutter_local_notifications`,
  not Firebase, nothing. What exists is the schedule that decides the minute,
  which is correct and tested.
- *A photograph crossing between two phones* needs photo methods on
  `SharedFacts` and an R2 client. Neither exists. `SharedFacts` has four
  methods and none of them mentions a photograph; every occurrence of "R2" in
  `lib/` is inside a comment describing an adapter that was never written.

Both are **unwritten rather than broken**, which is better news than the
alternative — the server-side table (`supabase/migrations/0006_photos.sql`) and
the gate rule are already in place and tested, so what was built was built
well. But nothing about either is partly done, and no estimate here should be
read as though it were.

---

## Where this is now

**Foundations are done. The app has a way in, a trip with all three of its
destinations in it, and — for the first time — something to put in them.**

The paste-and-confirm flow is built and tested: paste a plan, see what the
parser understood day by day with its doubt surfaced per cause, flip
ambiguous dates month-first in one tap, accept — and the itinerary persists
locally into Drift, surviving a relaunch. It replaced the scaffold's proving
screen and disposable `trip_drafts` demo — the sidestep in which a drafted
trip held no id at all. A trip now mints its own uuid the moment it is
started, with no connection and nothing to ask, and keeps it when it first
syncs ([the trip's own id](decisions/2026-08-25-the-trip-mints-its-own-id.md)).

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
pool eight people share. **What no state of it can say yet is that somebody
else took a photograph**, because nothing moves one (see the tripwire above).

**Capture fills it, back-camera-only** — which is the line's own scope and not
a shortcut, since the front inset is explicitly after the line. The whole loop
is real: the schedule is dealt from `trip_moments` for every dated day of the
plan, the day you are standing in says where your moment stands, an open or a
late window offers the way in, the shutter takes a frame, the breath offers
unlimited retakes against the same deadline — a retake never re-opens the
window — and one line of words, and keeping it writes a row into the
photo index with the frame beside it on disk — where the Pool, reading the same
store, draws it. A missed slot is never a lockout: the door stays open till
midnight and what you take then lands at the hour it was taken.

Two pieces of it are honestly unfinished. **Nothing is registered with iOS and
no notification library is in the project at all**, so no pocket buzzes; and
where there is no camera (the Simulator) the app draws its own frame, so a
green run there is not evidence the real camera path works — and *that fallback
is silent*, which is a hazard on a real phone as well as a convenience on a
simulator (see the bites, below).

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
because **nothing on this phone ever asks the server to redeem a code.** Saying
a code back is built and answers every case this phone can see; for a
well-formed code belonging to somebody else's trip it says so plainly rather
than spinning. That last step is Phase 2 and nothing else.

**The itinerary really does leave the phone now — and that was not true until
27 August 2026.** The hosted project exists, migrations `0001`-`0010`, `0012`
and `0014` are applied to it (`0011`, the photo transport delta, and `0013`,
its area-sync companion, are not), an ordinary build
points at it, and the phone signs in as an anonymous GoTrue
account until Apple lands. But until today, `CAIRN_TRIP_TIMEZONE` was a
compile-time constant with **no default**, so an ordinary `flutter build ios`
produced a binary that could never create the shared `trips` row, never pushed
a plan, and **never said so on any screen**. This file previously said the
itinerary "syncs for real"; that was true of the code and false of every binary
anybody would have run. Both halves are fixed and both are recorded in
[the trip's clock](decisions/2026-08-27-the-trip-clock-is-the-phones.md): the
clock is now the phone's own IANA zone, an unnamed trip publishes rather than
waiting for a title, and a plan that has *not* reached the server now says so
on the Trail and in the trip sheet, in the app's own voice. What remains false
about "syncs for real" is the audience: **no itinerary has ever been read by a
second phone**, because nothing carries a membership to one. A pool of one
phone's photos is likewise only half the Pool, and that is what the gate is
waiting on to matter.

The 27 August proof rows are gone from the hosted project as of 1 September:
the “Bug sweep trip”, its itinerary and its one unambiguous linked anonymous
account were deleted. Six anonymous accounts created that day had no link to
the trip and were deliberately left alone rather than guessed to be residue.

Still not built: the day page's photo timeline, the Trail's filled node, and
the gate's face on the day page — the rule is there, the page has no
photographs to withhold yet.

**The paste box now has two doors beside it.** A plan can arrive as a file
rather than as pasted text: the pill under the box opens the document picker,
the picked bytes are routed to the one extractor that claims them (magic bytes
first, the extension only as tiebreak), and the text lands *in the box* rather
than parsing on its own — so every route out of the box, including the re-paste
merge over a running trip, works exactly as it already did. Five formats read
today: plain text, `.docx`, `.xlsx`, `.csv` and `.pdf`. Spreadsheets and CSVs
lift their typed cells into one shared row model and are said back in the
parser's own dialect when a date column is there to drive it; when it is not,
every cell becomes a faithful row-major line, which is never worse than pasting
the same table as text. A file that is damaged, encrypted or not what its name
claims is refused in a sentence rather than decoded into junk — six
deliberately broken files were checked and none of them leaked a stack trace, a
class name or a path.

**And screenshots read**, which this file used to list as the slice after: real
Apple Vision behind a seam reads a plan photographed or screenshotted, through
either door, and a scanned PDF with no text layer gets a one-tap offer to read
it the same way. Recognition quality is judged on a device and never by the
suite.

**The one import path that is genuinely bad is the flagship one.** The
repository's own real Wanderlog print — a three-day Asahikawa guide — extracts
correctly (622 lines, the three real `Day N` headers among them) and then
**parses into 32 days and 555 stops**, because the page cleanup does not strip
Wanderlog's `Save` button label (30 lines end in it, merged onto the end of a
place name) or its `9/9 – 9/10` opening-hours ranges (12 lines, which read as
dates). The confirm screen is honest about it — "3 read clean. 29 need your
eye." — so nothing lies, but the only sane action a person has is to give up
and paste the text by hand. This file used to describe that path as working;
it does not work.

Beneath it: five pure-Dart libraries, a backend schema, a
dual-camera spike, the decision record, and the design handoffs, all
tested.

| Piece | State |
| --- | --- |
| Every product decision | **Settled.** See `docs/decisions/`. |
| `packages/itinerary_parser` | Landed. Parses pasted trip plans into days and stops. Fed real Wanderlog chrome it invents days — see the queued fix. |
| `packages/photo_day_assignment` | Landed. Decides which day a photo belongs to. |
| `packages/trip_moments` | Landed. Deals one ping per person across the party. Nothing delivers what it deals. |
| `packages/cairn_model` | Landed. The shared vocabulary. |
| `packages/plan_extraction` | Landed. Bytes in, plan text out — the file-import contract and its `.txt`/`.docx`/`.xlsx`/`.csv`/`.pdf` extractors. Extraction is correct on the Wanderlog print; the cleanup does not strip two of its chrome shapes. |
| `supabase/` | Landed. Blockers fixed, decisions encoded, verified on real Postgres. Hosted, with migrations `0001`-`0010`, `0012` and `0014` applied (`0011` and `0013` are written and locally probed, not hosted). **No photo transport, and no phone-side call that redeems an invite.** |
| CI | Landed. Package tests, the JS-safety golden, the RLS probe — and the app — run on every pull request. |
| `learning/dual-camera-spike` | Landed. Settled the capture as a back-then-front sequence. |
| The Flutter app | **The way in, Today, the Trail, the Pool, capture and the trip itself.** Paste-and-confirm persisting the itinerary locally, with two doors beside the box — a document (`.txt`, `.docx`, `.xlsx`, `.csv`, `.pdf`) or a photo/screenshot through Apple Vision — filling it and never auto-parsing; the day page it lands on, the trip's path, the three-tab container, the shared pool and the screen over it, the daily moment that fills it (schedule, camera behind a seam, the pause and the word, written into a local photo index the Pool reads), the gate's rule landed with them, the trip as a stored fact (roster, starter, flat-but-gated powers, three-word codes that die with the trip, the sheet off the Trail's title), and the itinerary reaching the hosted project on an ordinary build with the app saying when it has not. **Nothing registered with iOS; no photograph can move; no code can admit anybody.** |

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

*Needs from you: choose one of the three connected devices when it is time to
walk the device-only paths. Xcode 26.6 is already installed and licensed. No
paid program yet — a free Apple ID signs onto your own phone, seven days at a
time.*

### Phase 2 — Cairn on eight phones

Accounts, trip membership, the shared photo pool, photo bytes moving to and
from object storage, and the itinerary as a shared fact — edited once,
propagated to every phone, so the ping schedule is never dealt from a stale
roster or a stale plan
([grill round one](decisions/2026-08-22-grill-round-one.md) §2).

**The itinerary half has landed and, since 27 August, is live on an ordinary
build.** The itinerary and the roster are stored, merged last-write-wins per
day, and reconciled by `lib/repositories/itinerary_sync.dart` over a first
slice of the Supabase adapter — against a hosted project, signed in as an
anonymous GoTrue account (`supabase/README.md`). Everything else in this phase
is untouched, and two pieces of it are the whole reason the phase exists:

- **Nothing carries a membership to a second phone.** The invite code is real,
  canonical, revocable and dies with the trip; no code on this phone ever calls
  `redeem_trip_invite`. Until that call exists, a roster of one is all the sync
  can converge on and the trip is not a group.
- **No photograph has any transport.** `SharedFacts` declares four methods and
  none is about a photo; there is no R2 client. The table and its policies are
  written and tested on the server side, and nothing on the phone can reach
  them.

The pool stores **originals**; resizing is for display only (§3 of the same
decision). The bill has now been measured rather than guessed at:
[what the pool costs](storage-and-cost.md). At the ping's own volume a
fortnight for eight is 0.31 GB and R2's free 10 GB holds about thirty-two such
trips; let people import their rolls as well and the archive runs to a few
dollars a year. Not free, and not a reason to keep anything smaller than the
original.

**Why second:** the gate, the pool and the day page are all inherently
multi-person. They cannot be honestly built or judged with one device. This is
also the first phase that costs anything to keep alive, so it should not start
before Phase 1 proves the thing is worth keeping alive.

*Needs from you: a Cloudflare account — the Supabase one exists and its
project is live. No secret is ever committed (`supabase/README.md`).*

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
book's availability are **two separate rules** (trip end + 72 hours; forever) —
never one timestamp. See
[the ending](decisions/2026-08-26-the-ending.md), which carries the number.

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

- **Xcode is no longer a blocker.** Xcode 26.6 is installed and licensed,
  `flutter doctor` passes its Xcode check, and three devices are connected.
- **The Cloudflare account.** Blocks Phase 2; the Supabase one is done and its
  project is live. No secret — the service-role key, the database password —
  ever enters this repository, a pull request, or an agent's hands
  (`supabase/README.md` is the authority on which key is which).
- **Paying Apple** at the weekend test, **and Google** at Android delivery.
- **Sending design prompts to Claude Design**, and returning the handoffs.
- **Showing the app to any of the eight.** Nothing has been shown yet, and a
  late "this is obviously wrong" is the discovery the December slack exists to
  absorb — but only if it happens early.
- **Merging pull requests**, and deciding anything the record does not already
  settle.

---

## Work already queued, sorted by the line

Not a schedule. An inventory, so nothing is quietly forgotten. The first three
are the ones that stand between Cairn and being a group at all.

**First release:**

- **Move a photograph between phones.** Never built: `SharedFacts` has no photo
  method, and no R2 client exists in `lib/` — only comments describing the
  adapter that would be one. The server half is written and tested
  (`supabase/migrations/0006_photos.sql`, the upload-URL edge function). Until
  this exists a person's Pool shows only their own photographs, forever, with
  no error and no explanation. One half of the 31 October tripwire.
- **Make a phone buzz.** Never built: `NotificationEdge` has exactly one
  implementation, `RecordingNotificationEdge`, which appends to a list — and
  there is no notification dependency in `pubspec.yaml` at all. The schedule it
  would deliver is correct and tested. The other half of the tripwire.
- **Carry a membership to another phone**, which is the one thing standing
  between a real invite code and somebody actually joining. Everything on this
  side of it is built — roster, powers, three-word codes that die with the
  trip, and the door that reads them back — and honestly says so when it cannot
  reach a trip. What is missing is the call: nothing ever asks the server to
  redeem a code.
- **Stop the undated re-paste from misfiling photographs.** Reproduced: on a
  plan whose days carry **no dates**, re-pasting an edited plan pairs repasted
  days to current days *by position*, and because `mergeRepaste` never
  renumbers (deliberately — `photos.dayNumber` is the only link a photograph
  has to a day), a photograph stays on a number whose content has moved
  underneath it. Delete the first of three undated days and day 1 keeps its
  Tokyo photographs while becoming Kyoto; day 3 duplicates day 2. Nobody is
  told and nothing errors. **The dated case is correct and was checked** —
  date-matching pins every day. The same position pass is also how a genuinely
  new undated day rides in without being asked about. The fix is a decision
  about what position-pairing may claim, not a patch.
- **Fix the Wanderlog print's parse.** Extraction is right and the parser is
  fed chrome the cleanup does not strip: Wanderlog's `Save` button label, which
  the PDF merges onto the end of a place name, and its `9/9 – 9/10`
  opening-hours ranges, which read as dates. Three real days become 32 days and
  555 stops. This is the flagship import path and the fixture is in the
  repository.
- **The Maps hand-off.** Named in the brief as half the planner's job and
  **never built and never decided**: no `url_launcher` in `pubspec.yaml`, no
  maps URL anywhere in `lib/`, and no decision file about it. It needs a
  decision before it needs code.
- Finish reconciling the schema with the settled decisions. The three-word
  grammar is on the server now — `supabase/migrations/0005_trip_invites.sql`
  mints two words and a number, forgives order and spelling by the same rule
  the phone forgives them by, and kills a code at the trip's close instead of
  at a per-invite `expires_at` (the single timestamp the grace-window decision
  exists to prevent), with `tests/rls_probe.py` reading the Dart vocabulary to
  keep the two halves from drifting. What is still unreconciled is
  `max_uses`, which the phone has no notion of. Rename is reconciled by
  migration `0014`: any current member gets the name-only path and the
  starter's broader row powers remain unchanged.
- Throttle `redeem_trip_invite`. Three spoken words are a little over six
  hundred thousand codes where eight characters were ~850 billion, and each
  guess covers a neighbourhood of near-spellings. Sayable was the point and
  the trade is the decision's; the rate limit it assumes is not written yet,
  at the database level or above it.
- Real sign-in: an account somebody owns and a display name that is theirs. The
  anonymous GoTrue account is real and its id *is* this phone's member id, so
  the roster and the gate ask about the right person; what is still a local
  constant is the display name (`'You'`), and a trip started offline under
  `'me'` can never become a `trips` row and is a local trip for good.
- **Put the refresh token in the Keychain.** `gotrue_sessions.dart` writes
  `cairn_session.json` — `user_id` and `refresh_token` as plain JSON — into
  Application Support, which is in iCloud and iTunes backups and is not the
  Keychain. The account is anonymous with only that phone's own membership
  behind it, so the blast radius is small; it is still the wrong place.
- The trip's close at trip end + 72 hours as a *stored* rule. Both halves
  derive it correctly now — `cairn_model`'s `tripStandingAt` on the phone, and
  `trip_closes_at()` on the server, which is what kills an invite code and
  what shuts `photos_insert_trip_member` — but each derives it from what it
  holds rather than from a fact of the trip everybody's phone agrees on. The
  phone's half reads the *device's* offset, so two travellers in different
  zones can disagree about the hour it shuts.
- **Finish the trip's own clock.** The shared `trips` row now carries one — the
  creating phone's IANA zone, or a zone the build pinned
  ([the trip's clock](decisions/2026-08-27-the-trip-clock-is-the-phones.md)) —
  but nothing on the phone *reads* it back, so the two places that admit a
  clock still use the device's offset, and the timezone power the
  starter-and-container decision settled still has nothing to act on. The row
  is also written once and never revised, so a trip's clock does not follow the
  trip; whether it should is undecided.
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
- The countdown's drawn treatment (the burning thread). The reading itself
  came forward with the two-minute window and is built.
- Android delivery through the Play testing track.
- Autofill the itinerary from a Wanderlog *export* — distinct from reading a
  Wanderlog *print*, which is built and, today, produces an unusable plan.
- Google sign-in with accounts keyed to their own id rather than Apple's.
- Standing ops so Cairn survives the quiet months between trips.

**Undecided and deliberately parked:** what happens to in-transit photos on a
trip that crosses several timezones in one day.

---

## Things that will bite, written down before they do

Each of these has already cost time, or is certain to.

- **A feature can be complete and switched off, and nothing will say so.** This
  is what happened to the itinerary sync: every line of it was written, tested
  and correct, and one `String.fromEnvironment` with no default meant no
  ordinary build had ever pushed a plan — with no banner, no spinner and no
  error, because a standing the code knew perfectly well was never allowed
  above the repository seam. The lesson generalises past this one bug: **a
  build-time constant that gates a whole capability, and a state a person
  cannot see, are the same defect twice.** See
  `docs/decisions/2026-08-27-the-trip-clock-is-the-phones.md`.
- **Re-pasting an undated plan can move photographs onto another day's
  content.** Reproduced; the fix is queued above. A dated plan is safe. The
  paste flow pushes hard toward dating — dating day 1 fills the whole plan
  down — but nothing requires it, and the app happily runs an undated trip.
- **iOS never wakes a third-party app because a new photo appeared.** There is no
  background trigger and no entitlement that buys one. The import runs when the
  app is open, and the interface says exactly that. See
  `docs/decisions/2026-08-22-auto-import-honesty.md`.
- **A free Apple ID's provisioning profile expires every seven days**, and **a
  TestFlight build expires 90 days after upload.** Relevant to *when* you pay,
  not just whether.
- **The trip's ending is two rules, not one.** Close to new photos at trip end
  + 72 hours; the book makeable forever. A single "expiry" timestamp silently
  re-bundles what was deliberately split. See
  `docs/decisions/2026-08-26-the-ending.md`, which carries the number, and
  `docs/decisions/2026-08-22-grace-window.md`, which is why it is split.
- **Supabase's free tier pauses a project after about a week of inactivity**, and
  after a year the dashboard restore path is gone. A trip that is months away
  means the project will sleep. That is what the dormancy work is for.
- **Google closed the shared-albums API to third-party apps in March 2025.** Any
  design that assumes an existing shared album is a dead end.
- **Cloudflare R2's free tier is 10 GB, and the pool keeps originals.** Now
  measured rather than guessed: an original off a phone is about 3 MB, so the
  ping's own volume — one photograph per person per day — puts 0.31 GB into a
  fortnight's pool for eight and sits well inside the free allowance. What
  moves that by an order of magnitude is the import sweep, not the trip: at ten
  imported photographs each a day the same trip is 3.14 GB and the archive
  starts billing in year one. Cheap either way, and never free in the sense of
  unbounded. See [what the pool costs](storage-and-cost.md), and note the trap
  that measurement fell into first — most files in a photo library are not
  photographs a camera took, and sizing from their median understates the bill
  about fourteenfold.
- **Row-level security refuses by filtering to zero rows, not by raising.** A test
  asserting "this was rejected" can pass while testing nothing. This already
  burned one analysis. Assert on the state of the table afterwards, never on
  whether a statement threw. See `supabase/tests/README.md`.
- **No RLS refusal has ever been observed on the hosted project.** Only one
  account has ever touched it, so only the permitted paths have run there. The
  113 passing assertions are against a throwaway local Postgres 17. A green
  probe is evidence about the schema, not about production.
- **Dart's `int` bitwise operators are 32-bit when compiled to JavaScript.** The
  ping derivation uses arithmetic rather than shifts for exactly this reason, and
  a golden test pins it. See `packages/trip_moments/`.
- **The Simulator has no camera, so the app draws its own frame there — and the
  fallback is silent.** That is what makes the capture flow walkable without a
  cable, and it is two traps, not one. A green simulator run says the flow is
  right and says *nothing* about whether the camera path works; the real back
  camera has to be judged on a device. And `DeviceCameraSource._hasBackCamera()`
  wraps `availableCameras()` in a bare `catch (_) { return false; }`, so on a
  *real* phone any unexpected throw substitutes a generated 360×480 two-tone
  PNG for somebody's photograph, into the real pool, with nothing shown. This
  has not been reproduced on a device — on iOS `availableCameras()` does not
  require authorization and a denial surfaces honestly later — so it is a
  latent hazard on an unknown path, named rather than claimed.
- **The person holding the phone has a real id and a placeholder name.** The
  anonymous GoTrue account's id *is* this phone's member id, resolved on the
  boot path from a local file rather than over the network, so the roster and
  the gate ask about the right person. The display name is still the constant
  `'You'`, and a trip started before any account exists is credited to `'me'` —
  visibly not an `auth.users` id, so a push carrying it is refused loudly
  rather than writing a stranger's row.
- **A photo row is an index; the photograph is a file beside it.** Locally that
  is Drift plus a file in the app's documents directory, mirroring Postgres
  plus R2 on the server. Deleting the row does not delete the photograph, and
  nothing yet reconciles the two in either direction.
- **A green suite proves the app, not the product.** Every automated test binds
  a fake: `NoSession` for the network, `FakeTextRecognition` for Vision,
  `StandInCameraSource` for the camera, a direct call for the extraction
  isolate. The real camera, real recognition quality, real notification
  delivery, real photo transport, and anything involving a second phone are all
  unestablished by any suite in this repository, and the only test that touches
  the hosted project is skipped unless asked for by define.

---

## How to keep this file honest

Update it when a phase actually changes state, not when work is merely planned.
A roadmap that lists intentions is worse than no roadmap, because it reads as
progress. If something here has stopped being true, correcting it is more
valuable than adding to it.

Two rules learned the hard way on 27 August 2026, when a sweep found several
claims here that were true of the code and false of the product:

- **Say "never built" when nothing was built.** "Not yet" and "still Phase 2"
  read as partly done. `NotificationEdge` and photo transport had both been
  described as pending for weeks; neither had a line of implementation.
- **A claim about a capability is a claim about a build somebody would run.**
  "The itinerary syncs for real" was written about code that worked and a
  binary that could not. Where the two differ, this file records the binary.
