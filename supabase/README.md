# Backend: Supabase (accounts, trip membership, photo index) + R2 (photo bytes)

This directory is the entire backend. It is deliberately tiny: it holds the
shared photo pool, trip membership, the itinerary, and the one clock every
phone on a trip has to agree on. The day trail, the stars, the ping schedule
and the record of who has answered today's ping are all computed and kept on
the phone. The phone is the source of truth; the app works fully offline
except for pool sync and for reconciling those shared facts.

**Storing a shared fact is not computing on the server**, and the line between
the two is the one thing to hold on to when reading this file. The itinerary
is *stored* here because eight phones have to agree on which days the trip has
and what is on them ([the decision](../docs/decisions/2026-08-22-grill-round-one.md)
§2). Nothing here derives a trail, a star, a ping or a gate from it; every one
of those is worked out on each phone from the plan it holds, and moving any of
them server-side would need its own decision.

**A hosted project now exists and every migration here is applied to it**
(`https://nswcgzhynclrrunekskh.supabase.co`, region `ap-southeast-1`). The app
points at it by default — see
[Pointing the app at it](#pointing-the-app-at-it) — and
[Verification](#verification-what-was-actually-run) at the bottom says what has
actually been exercised against it and what has not. R2, the edge function and
the real sign-in providers are still untouched.

## The model

| Table | Why it exists |
| --- | --- |
| `profiles` | One row per person, and the durable home of the name credited under every photo. Auto-created by a trigger on `auth.users` insert. Has **no foreign key to `auth.users`**, on purpose — see [Deletion](#deletion-the-login-goes-the-credit-stays). |
| `trips` | A named container, plus the shared trip clock (timezone, dates, waking window). The plan itself hangs off it in the three tables below. **`trips.id` is minted by the phone, not here**; see [Who names a trip](#who-names-a-trip). |
| `trip_members` | The root of every access-control check in this schema. A row is reachable by a user if and only if they have a matching `(trip_id, user_id)` row here. Carries **no role column**; see [Roles are flat](#roles-are-flat-except-one-thing). |
| `trip_invites` | Invite codes — three spoken words each — kept in their own table rather than a column on `trips` so a code can be rotated, revoked, or usage-limited without touching trip identity, and a trip can have more than one outstanding code. Carries **no expiry column**; a code dies when its trip closes and at no other time. See [How someone joins](#how-someone-joins-a-trip). |
| `photos` | One row per photo in the pool. The bytes live in R2; this row is the index the app queries and the thing RLS protects. |
| `day_unlocks` | The gate, as a durable fact: "this person contributed to this day". Written only by a trigger on `photos`, and never deleted by anything. See [The gate](#the-gate). |
| `day_pages` | A day's finished, composed page — one image per trip per day, made lazily at share or bind time. This was `daily_moments` and modelled a four-up panel; the four-up is retired. |
| `day_page_photos` | Which photos went into a composed page, and in what order. Ordered by `ordinal`, not seated in a 1-to-4 slot. |
| `trip_itineraries` | One row per trip, holding the plan's two clocks: when its *shape* last moved, and when the set-aside pocket last did. Not columns on `trips`, because a phone holds a plan revision before the trip's shared row exists. See [The itinerary](#the-itinerary-a-shared-fact-merged-per-day). |
| `trip_itinerary_days` | One row per day of the plan: its number, its date if the person has resolved one, its place, and **the instant it was last changed and by whom**. That instant is the merge atom. |
| `trip_itinerary_stops` | The stops under a day, in the day's own order. Deliberately carries **no clock and no starred flag**: a stop cannot win or lose a merge independently of its day, and a stop is starred exactly when it has a time. |
| `trip_itinerary_set_asides` | The lines the parser could not place, and the ones somebody took out of a day. Nothing a person pasted is ever deleted, so the pocket travels with the plan. One atom, one clock. |
| `trip_roster` (view) | Not a table: `trip_members` joined to `profiles`, so a phone reads every co-member and their name in one statement. `security_invoker`, so the member's own RLS decides what it returns. It hands over `joined_at` and **never a trip day number** — which day an instant falls on is a function of the itinerary and the trip clock, and that is the phone's arithmetic. |

Full column-level rationale is in the migration files themselves as
comments — read those alongside this table, they're short.

### How someone joins a trip

**Three spoken words**, not a magic link. A code is two words and a two-digit
number — `otter maple 42` — because it is a thing somebody says across a
table rather than a thing they spell out
([the decision](../docs/decisions/2026-08-22-grill-round-one.md) §5). Any
member of a trip can create a row in `trip_invites`, optionally with a use
limit; `code` defaults to `generate_invite_code()`, which draws two distinct
words and a number. A joiner calls `redeem_trip_invite(code)`.

It is **forgiving of order and of spelling**. `maple otter 42` is the same
code as `otter maple 42`, and so is `mapel oter 42`: the words come from a
fixed vocabulary chosen so that no two of its words are within two edits of
each other, so one letter of slack can only ever land on the word it was
reaching for. `invite_code_key(text)` is the one place that turns anything
somebody said into the single canonical spelling; uniqueness and lookup are
both defined over its result, never over the text as written.

That vocabulary and that distance are **a second copy of
`packages/cairn_model/lib/src/invite_code.dart`** — a code minted on one side
of the seam is typed into the other, so the two have to agree letter for
letter. `tests/rls_probe.py` reads the word list out of the Dart and compares
it with `invite_code_words()` rather than trusting them to stay in step, and
the distance function is written out here rather than taken from
`fuzzystrmatch`, whose `levenshtein()` prices a swapped pair of letters at two
and would refuse near-spellings the phone accepts.

**A code carries no expiry of its own.** It dies when its trip closes —
the last day's end in the trip's own clock, plus the seventy-two-hour grace,
which is `trip_closes_at(trip_id)` here and `tripClosesAt` in `cairn_model`.
After that every day of the trip is past, so a code that outlived it would open the
whole archive to whoever still remembered three words. There is deliberately
no `expires_at` column: two timestamps for one rule are two chances to
disagree about when a trip is over, which is the thing the
[grace-window decision](../docs/decisions/2026-08-22-grace-window.md) exists
to prevent. The window's length is [the ending](../docs/decisions/2026-08-26-the-ending.md),
and `trip_grace_after_end()` is the second and last copy of that number:
`tests/rls_probe.py` reads `graceAfterATrip` out of the Dart and compares
them.

`redeem_trip_invite` is `SECURITY DEFINER` and is the *only* way to join a trip
you didn't create. It has to be: a non-member cannot be granted `SELECT`
on `trip_invites` (that would let anyone enumerate or brute-force codes by
reading the table) and cannot `INSERT` into `trip_members` directly under
the RLS policies here. The function canonicalises what was said, looks the
code up, refuses it if the trip has closed or the use limit is spent, inserts
the membership row, and increments the use counter, all inside one
elevated-privilege call whose surface area is exactly one text argument.
Text that is not a code and a code nobody minted are refused with the same
sentence, so a guesser is never told which half of their guess was wrong.
Redeeming a code for a trip you are already on is a no-op and spends no use,
so a re-tapped deep link cannot burn a limited code down.

A deep link (`traveling-app://join/<code>`) is just the same code
delivered a second way — no separate mechanism needed.

### The R2 object key, and why listing never touches R2

A photo's key is:

```
trips/<trip_id>/photos/<photo_id>/original.<ext>
```

`original.<ext>` holds the frame exactly as the camera wrote it: the upload
signs a PUT and transforms nothing, so what lands is what the phone took. A
photo id is minted once and `r2_object_key` is `unique`, so no second *row*
can ever claim an original — and **`r2-upload-url` refuses to sign a photo id
a row already holds**, so no second set of *bytes* can either. The refusal is
flat: a claimed original is refused to everyone, its own contributor included.
An original is immutable, which is the whole reason a phone may cache its
bytes forever, and a contributor re-uploading would make every cached copy
silently stale.

This used not to be true, and the gap was the real one. The function checked
only that the caller was a member of the trip, while every member can read
every photo row in that trip — its `id` and its `r2_object_key` included
(`photos_select_trip_member`). So one member could ask for an upload URL under
another member's photo id and PUT arbitrary bytes over their original, leaving
the row untouched: same id, same byline, same size, same capture time, so the
swap was invisible to the index and to every RLS policy. `photos` was well
protected; the object it pointed at was protected by nothing. The two probe
checks under *"a co-member can read what an upload URL is minted from"* pin the
premise, and the function's own tests pin the refusal.

The ordering is what makes a flat refusal cost nothing: bytes first, row
second. A retry of an upload that never landed happens while no row exists and
is still signed; a row is what says "these bytes are the record now".
If a smaller derived variant is generated it is `.../thumbnail.<ext>`
*alongside* the original, never in place of it. A composed day page's key is
`trips/<trip_id>/pages/<day_page_id>.<ext>`.

The app never lists an R2 bucket to show a trip's pool. It queries
`photos where trip_id = $1` (RLS-filtered to members only) and reads
`r2_object_key` off each row, then fetches that exact object. Postgres is
the index; R2 is blob storage. This is also why every `r2_object_key` and
`r2_thumbnail_key` column is `unique` — the row *is* the pointer, so two
rows can never race for the same object.

### Day assignment

EXIF timestamps carry no timezone. A photo taken at 11pm local time can
land on the wrong calendar day if the day boundary is computed from the
raw timestamp read back in a different timezone (e.g. the device's current
zone, or UTC). So `photos.trip_day` — the day the app actually trails the
photo under — is **derived on the phone** from
`(captured_latitude, captured_longitude)` via a timezone-boundary lookup,
not from `captured_at` directly.

The row stores everything needed to redo that computation or challenge it:

- `captured_at` — raw EXIF capture time, kept for provenance. It is also
  what the day's timeline orders by and prints in its margin, so a photo the
  app took itself always carries an exact one.
- `captured_latitude`, `captured_longitude` — raw EXIF GPS, nullable
  (not every photo has it).
- `capture_timezone` — the IANA zone the coordinate resolved to (e.g.
  `Asia/Tokyo`), so the day can be recomputed later without redoing the
  geo lookup.
- `trip_day` — the derived day. **Nullable**, deliberately:
  `packages/photo_day_assignment` can legitimately place nothing (no EXIF
  time and no file time, or a time falling outside the trip). Such a photo
  waits for a person to place it rather than being clamped onto a day it does
  not belong to, and opens no day's gate until it has one.
- `trip_day_is_manual` — set when a person corrects the day by hand
  (the app should always allow this as an escape hatch; timezone-boundary
  lookups are not infallible, especially near international date changes
  mid-trip).

### Who took each photo

`photos.contributor_id` (not nullable, `references profiles`), enforced at
insert time by an RLS `with check` that the inserting user must be
tagging *themselves* (`contributor_id = auth.uid()`), not anyone else.

## Who names a trip

**The phone mints `trips.id`, and this schema keeps it**
(`docs/decisions/2026-08-25-the-trip-mints-its-own-id.md`). A trip is created
offline — the moment somebody pastes an itinerary is the moment they are least
likely to have signal — so the id cannot wait on a round trip to this table.
The app writes a version-4 uuid into Drift's `trip_facts` the instant the trip
is started, and the first sync inserts a `trips` row carrying that id.

Nothing in the schema had to change for this. `id uuid primary key default
gen_random_uuid()` fires **only** when the client omits the column, and
`trips_insert_self` checks `created_by = auth.uid()` and says nothing about
the id. Two rules for whoever writes the sync, both recorded on the column
itself in `0003_trips.sql`:

- **Never reissue an id.** `packages/trip_moments` seeds each person's daily
  ping slot from the trip id, so handing a phone a different id re-deals every
  remaining day of the trip — silently, with nothing raising anywhere.
- **The first sync of a trip is a plain `insert`, never an upsert.** A uuid
  collision between two phones is vanishingly unlikely, but `on conflict do
  update` would merge two parties' trips into one where a plain insert raises.

## The shared trip clock

`trips` carries `timezone`, `country`, `city`, `start_date`, `end_date`,
`ping_window_start` and `ping_window_end`. This is the only part of the trip's
own timing that is not on the phone, and it is there for one reason.

`packages/trip_moments` derives each person's daily ping slot as a pure
function of `(trip id, date)` mapped into a waking window *in the trip's own
timezone*, and `packages/photo_day_assignment` falls back to the trip's
timezone (rung 2 of its ladder) for any photo whose GPS will not resolve. Both
take that timezone as a **caller-supplied parameter**. Before this column
existed, the only source for it was each phone's own parse of its own copy of
the pasted itinerary. Two phones that inferred even slightly different zones —
a different paste, an ambiguous city, a daylight-saving edge — would map the
identical fraction to different absolute instants, and the ping schedule would
drift apart with nothing raising an error.

The app does not ask anyone to pick a zone: it asks for **country and city**
and derives the IANA name from those. Both are kept so the question can be
re-asked and the derivation re-run. The name is validated against
`pg_timezone_names` by a trigger at write time, because the alternative is a
value that fails later, on every device at once.

The waking window defaults to `08:00`–`22:30` — eight people across fourteen
and a half hours is one slot roughly every 110 minutes, and 22:30 rather than
22:00 so the last slot can still catch dinner. Later than that is the
late-photo path, which is always open. It is stored per trip rather than
hard-coded so every phone reads the same bounds.

**One fixed clock per trip, in v1.** Two refinements from the planning record
are deliberately not modelled: the first and last day following the itinerary's
real arrival and departure times, and a day that changes country holding the
clock it started in. Both need the itinerary, and until `0010` the itinerary
was not here to need. It is now — so what stands between the schema and those
two refinements is no longer the data but a decision, and neither is a change
to make quietly. A per-day clock already exists on the phone
(`cairn_model`'s `TripDay.sequence` takes per-day overrides, and
`photo_day_assignment` mirrors them); expressing it here would mean deciding
that a day's clock is a shared fact rather than each phone's reading of one.
Until that decision, a trip that crosses zones runs on the clock it was
created with, and the daylight-saving slide is documented rather than solved.

## The itinerary: a shared fact, merged per day

Until `0010` the plan lived only on the phone that pasted it, and nothing told
another phone the trip had changed. It is stored here now
([the decision](../docs/decisions/2026-08-22-grill-round-one.md) §2). Four
tables and one function, and the function is where the whole design is.

**The day is the merge atom.** A day's date, its place and its whole list of
stops move together, because a person reorders and retimes a day as one act
and merging inside it would produce a day nobody wrote. Two people editing two
different days both keep their work; two people editing the same day, the
later clock wins whole. `trip_itinerary_stops` therefore has no `revised_at`
of its own — a stop cannot win or lose independently of its day.

**Last write wins, on the writing phone's clock.** That is a real cost and it
is accepted rather than hidden: a phone an hour fast wins edits it should
lose. No CRDT, no vector clock, no conflict screen. What keeps it survivable
is the atom size — the damage is one day of one plan, and it is visible to
everyone at once.

**Why a function rather than an upsert.** PostgREST has no client transaction
and cannot express "overwrite this row only if what I hold is newer, and
replace its children with mine only if it was". `sync_trip_itinerary` is one
call that is both directions at once: it takes the pushing phone's whole plan,
merges it, and returns the plan the trip holds afterwards. A phone with no plan
of its own pulls by pushing nothing — an empty `p_days` at `-infinity` wins
nothing and deletes nothing, which is exactly what a joiner needs.

**Deleting a day is why the plan has a shape revision.** A removed day leaves
no row to carry an instant, so "I dropped day 4" and "I have never heard of
day 4" look identical in a push. `trip_itineraries.plan_revised_at` separates
them: it moves when the *set* of day numbers moves, and the function deletes
only days whose own `revised_at` is at or below the pushed shape. A phone six
days behind cannot silently delete a day somebody added yesterday. The
set-aside pocket gets its own clock for a sibling reason — the pocket is one
atom, and *emptying* it has to carry a revision or a stale phone refills it
forever.

**The rule is written twice, and that is deliberate.** Here, in
`sync_trip_itinerary`, and on the phone in
`lib/repositories/itinerary_sync.dart`. It has to be both: the server must
refuse a stale push it is told about, and the phone must know which of its own
days survived the push it just made. A third copy would be the thing to refuse
in review — the same rule the gate and the invite grammar are held to.

**What did not move.** The trail's geometry, the stars, the ping schedule and
the gate are still computed on each phone from the plan it holds. So is which
trip day somebody joined on: `trip_roster` hands over `joined_at` and nothing
else, because turning an instant into a day number needs the itinerary and the
trip clock, and that arithmetic is the phone's.

## Row-level security

Every table has `alter table ... enable row level security;` and explicit
policies — none is left open. The one invariant that matters most: **a
photo row (and by extension its R2 key) is unreachable to anyone who is
not a member of that photo's trip.** That's the `photos_select_trip_member`
policy in `0006_photos.sql`; every other photo policy (insert/update/delete)
additionally narrows within membership.

### Why every check goes through a function

Two `SECURITY DEFINER` helpers, defined in `0004_trip_members.sql`, are what
every policy in this schema asks membership through:

- `is_trip_member(trip_id, user_id)`
- `is_trip_starter(trip_id, user_id)`

That is not style. The first version of this schema wrote `trip_members`' own
SELECT policy as `using (exists (select 1 from trip_members mine where ...))` —
a policy on a table whose `USING` clause reads that same table. Postgres
re-applies the policy to the inner read, and to the inner read of that, and
aborts with `infinite recursion detected in policy for relation
"trip_members"`. Because every other table gated membership the same way, the
failure propagated everywhere: no member could read a photo, a roster, a trip
or a page. It applied cleanly and was invisible to inspection, because
recursion is a runtime property.

**Why the function form cannot recurse.** A `SECURITY DEFINER` function
executes as its owner, and a table's owner is not subject to that table's
row-level security — policies apply to everyone *except* the owner, unless the
table is marked `FORCE ROW LEVEL SECURITY`. So the read of `trip_members`
inside the function body runs with no policy attached, and the chain terminates
one level down instead of never.

**The consequence, and the one thing not to do:** never add
`alter table public.trip_members force row level security` (or the same on
`trips`). Forcing makes the owner subject to the policies too, which puts the
policy back inside the function body and brings the recursion straight back.
`supabase/tests/recursion_mechanism.py` demonstrates exactly this, both
directions.

### Which policy enforces which decision

| Decision | Where it lives |
| --- | --- |
| **Roles are flat** | `trip_members` has no `role` column, and **no UPDATE policy at all** (`0004`). There is nothing to promote into and no statement that can rewrite a membership row. |
| **…except that the person who started the trip can remove someone** | `trip_members_delete_self_or_starter` (`0004`): `user_id = auth.uid() or is_trip_starter(...)`. The starter is `trips.created_by`, a fact about the trip rather than a row that can be deleted. |
| **Nobody edits anyone else's photos or placements** | `photos_update_contributor` and `photos_delete_contributor` (`0006`) test `contributor_id = auth.uid()` and nothing else — the trip's starter included. |
| **A person can delete their own photo** | `photos_delete_contributor` (`0006`). A hard delete, no tombstone row: the day leaves no visible gap. |
| **…and the day stays open** | `day_unlocks` (`0007`) has **no DELETE policy and no INSERT policy**. An unlock is written by a trigger when a photo lands and cannot be removed by anyone — not its owner, not the starter. "No re-lock" is the only behaviour the table permits, rather than a rule the app has to remember. |
| **The gate holds a day's page shut until you have contributed to it** | `day_page_is_open(trip, day, user)` (`0007`). Not an RLS policy, on purpose — see below. |
| **A member joining mid-trip sees every past day freely** | The *absence* of any day predicate in `photos_select_trip_member` (`0006`), plus the first branch of `day_page_is_open`: any day already finished on the trip's clock is open to every member. |
| **Credit survives the person** | `profile_is_visible_to` (`0009`) resolves a name for anyone you travel with **or** anyone credited on a photo or trip in a trip you are in — because membership is exactly the thing that ends. |
| **The trip's clock is one shared clock** | `trips_update_starter` / `trips_delete_starter` (`0004`) keep the trip row with the person who authored it, and `validate_trip_timezone` (`0003`) refuses a zone that is not real. |
| **The plan is the trip's, and any member may change it** | Every policy on the four itinerary tables (`0010`) is plain membership through `is_trip_member`, with no starter branch and no contributor branch. Editing the plan is flat, like inviting and like naming: a trip is a thing eight people are on, not a thing one of them owns. |
| **A closed trip takes no new photographs** | `photos_insert_trip_member` (`0006`) also requires `now() < trip_closes_at(...)`, and the `photos_lock_trip_id` trigger (`0006`) stops a row being repointed at a closed trip round it. Deliberately *not* on the update and delete policies: a person's hold on their own photograph — correcting its day, removing it — survives the close ([the ending](../docs/decisions/2026-08-26-the-ending.md)). |
| **A closed trip's plan is the record** | `sync_trip_itinerary` (`0010`) raises on `trip_closes_at` before its first write, so neither half of the round trip runs and the stored plan is unchanged rather than merely un-returned. The phone refuses first (`TripSync._reconcile`); this is the half that holds when one of eight phones has a wrong clock. |
| **A phone can only reach the plan through the merge** | `sync_trip_itinerary` is `security invoker` and re-checks membership itself, so it grants nothing the tables do not; the tables' own policies are what stop a non-member writing round it. |

### Why the gate is not an RLS policy

It cannot be. A shut gate is required to **show the shape of the day** — the
times and the names, with the images withheld — so the rows have to stay
readable to someone who has not contributed. What is withheld is the *bytes*.

So `day_page_is_open` is the check the not-yet-written `r2-download-url` edge
function must make before it signs a GET, exactly as `r2-upload-url` re-checks
membership before it signs a PUT. It lives in SQL so that check is one call
against the same tables rather than a second copy of the rule written in
TypeScript. It reads "today" in the *trip's* timezone, so every phone agrees on
which day is still in progress.

Knowing an `r2_object_key` is useless on its own — the bucket is private and
every read needs a signature — which is what makes gating the signature rather
than the row a real gate and not a curtain.

### Roles are flat, except one thing

Inviting, composing a day page, renaming nothing, deleting your own photo: all
flat. The one asymmetry is that the person who started the trip can remove
someone, because the join code is three spoken words and a wrong join has to be
undoable.

Two places extend that literal wording, both noted here so they can be
overruled cheaply:

- **The trip row itself (`trips_update_starter`, `trips_delete_starter`).**
  Deleting a trip cascades every photo in it; changing its timezone silently
  re-times everyone's pings. Flatness in the decision record is about what
  members may do to each other's contributions — "nobody edits anyone else's
  photos or placements" — not about who may retime or destroy the container.
  The cost of this reading is that a member cannot rename the trip.
- **Invites are flat** (they were owner-only). Anyone who joined by code
  already knows a working code and can repeat it aloud, so restricting who may
  *create* one bought almost no safety while making the starter a bottleneck —
  itself an asymmetry the decision record does not grant them.

## Deletion: the login goes, the credit stays

`profiles.id` **is** the `auth.users` id, so `auth.uid()` can be compared to it
directly in every policy — but there is no foreign key between them. That one
missing constraint is the whole tombstone model.

The old shape (`id references auth.users on delete cascade`) broke the
requirement twice over. Deleting the login cascaded into `profiles` and erased
the display name, so every photo that person contributed lost its byline; and
three `on delete restrict` references to `profiles` then blocked that cascade
outright, so anyone who had ever taken a photo, started a trip or minted an
invite — in practice every real user — could not be deleted at all.

With the constraint gone:

- Deleting the `auth.users` row removes the login and leaves the profile
  standing, with its name, under every photo it is credited on.
- The three `restrict` FKs stay, and are now doing the right job: they stop the
  *profile* being deleted while it still credits something.
- `profiles` has no INSERT policy (rows come only from `handle_new_user`) and
  **no DELETE policy**, so no client can forge or remove one.
- `deletion_requested_at` is stamped by the person asking to be forgotten;
  `deleted_at` is stamped by the sweep once the grace period expires and the
  login is actually gone.

Account deletion is therefore: stamp `deletion_requested_at`; thirty days
later, delete the `auth.users` row (scrubbing its email), and stamp
`deleted_at`. The name-only profile is what remains, and it is deliberate — it
is the credit.

## Applying this to a fresh Supabase project

1. **Create a project** in the Supabase dashboard (this is the one step
   that genuinely cannot be scripted from outside — account + project
   creation is a dashboard/CLI-with-auth action, not SQL).
2. Install the Supabase CLI and log in: `supabase login`.
3. Link this repo to the new project: `supabase link --project-ref <ref>`.
4. Apply the migrations in order:
   ```sh
   supabase db push
   ```
   This runs every file in `supabase/migrations/` in filename order
   (hence the `0001_`, `0002_`, ... prefixes) inside a transaction per
   file, tracked in the `supabase_migrations` schema so re-running is
   idempotent — `db push` skips migrations it has already recorded, and
   each file's own `create table if not exists`/`drop policy if exists`
   guards make a manual re-run safe too.
5. **Dashboard steps that are not expressible in SQL**, all one-time:
   - **Enable Sign in with Apple**: Authentication -> Providers -> Apple.
     Requires a Services ID, a Sign in with Apple key, and your app's
     bundle ID from the Apple Developer portal — entered into the
     dashboard, not migrated.
   - **Enable Google**: Authentication -> Providers -> Google, with an iOS
     and a web OAuth client id from Google Cloud. The trip includes people on
     Android, so both providers are needed.
   - **Set the Site URL / redirect URLs** under Authentication -> URL
     Configuration to match the app's custom URL scheme, once that's
     decided.
   - Nothing else needs a dashboard click; every table, policy, function,
     and trigger above is in the migrations.
6. **Deploy the R2-upload-URL edge function** (see below) and set its
   secrets:
   ```sh
   supabase functions deploy r2-upload-url
   supabase secrets set R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... \
     R2_SECRET_ACCESS_KEY=... R2_BUCKET_NAME=...
   ```
7. **Tell the app where the project is, at build time** — see the next
   section. The defaults already point at the hosted project, so this step is
   only for a *different* one.

## Pointing the app at it

An ordinary `flutter run` reaches the hosted project with nothing passed.
Three defines steer it, all read at compile time:

| Define | Default | What it does |
| --- | --- | --- |
| `CAIRN_SUPABASE_URL` | the hosted project | Where the backend is. **Pass it empty to turn the backend off entirely** — the sync goes dormant and the phone is purely local. Note that this is *not* what keeps `flutter test` off the network: the suite passes no defines, so `SharedFactsConfig.fromEnvironment` inside it is this project. What stops it reaching out is that `bootstrapApp` defaults its `sessions` to `NoSession` and `_startSharedFactsSync` returns early on one, so nothing ever signs in and nothing is sent. |
| `CAIRN_SUPABASE_ANON_KEY` | the hosted project's publishable key | Identifies the project. Grants nothing on its own: every table here is behind RLS keyed on `auth.uid()`, so a request with no session reaches zero rows. |
| `CAIRN_TRIP_TIMEZONE` | *the phone's own zone* | Pins the trip's IANA clock, overriding what the phone answers. **An override, not a requirement** — see below. |

```sh
flutter run --dart-define=CAIRN_TRIP_TIMEZONE=Asia/Tokyo
```

**The service-role key and the database password belong in neither a define
nor this repository.** The anon key does: it is the *publishable* one, designed
to ship inside a client. That distinction is the only one that matters here —
the service-role key bypasses every policy on this page.

### Why `CAIRN_TRIP_TIMEZONE` is an override and not a gate

It used to be a gate, and that was defect D3: with no default, an ordinary
`flutter build ios` produced a binary that could never create the shared
`trips` row, so no itinerary had ever reached this project from a real build —
and no screen said so. The full reasoning is in
[`docs/decisions/2026-08-27-the-trip-clock-is-the-phones.md`](../docs/decisions/2026-08-27-the-trip-clock-is-the-phones.md);
what matters here is what the server now receives.

**The zone is the phone's own IANA name**, read from the platform
(`ios/Runner/DeviceTimeZone.swift`, behind `lib/app_state/device_time_zone.dart`).
A *name*, deliberately, and never the device's UTC offset: `trips.timezone` is
validated against `pg_timezone_names` by a trigger at write time, and
`Etc/GMT±N` carries no daylight saving and cannot spell the half-hour zones
India, Iran, South Australia, Newfoundland and Nepal keep. The define survives
because pinning the *destination's* zone on a plan made at home is strictly
better than the phone's answer — the phone's answer is the zone the plan was
pasted in, which is not always the zone the trip is lived in. The row is
created once and the clock is not re-read, so a phone that flies does not
rewrite it.

**A trip may be published before it is named.** `trips.name` is `not null`, so
an unnamed trip goes up as `This trip` (`unnamedTripPlaceholder`), and the
phone **refuses to adopt that word back** as a name — otherwise the roster
apply would rename the trip on the next reconcile, and, worse, would revert a
rename typed on this phone, since nothing ever pushes a rename *up*. The cost
is that the server's copy of the name goes stale; closing that needs a name
clock and a decision about `trips_update_starter` (starter-only) against the
phone's flat `canRenameTrip`, which the roadmap carries as unreconciled.

**One thing can still stop the row being created, and only one:** the plan must
carry at least one resolved date at each end, because `start_date` and
`end_date` are `not null` and inventing a date is the guess the whole paste
flow exists to refuse. `SyncStanding.awaitingTripRow` names exactly that gap —
and, since 27 August 2026, the trip sheet and the Trail say so to the person
holding the phone rather than sitting silent.

### How the phone signs in today

Sign in with Apple is the first real route and is not built. Until it is, the
app uses a **GoTrue anonymous account**: `GotrueSessions`
(`lib/storage/remote/gotrue_sessions.dart`) mints one on first launch and keeps
its refresh token — and the account's id beside it — in the app's support
directory, so the same account comes back on every launch, and a phone with no
signal still knows which account it is without asking. It is a real `auth.users` row, so `handle_new_user` mints
the profile every policy on this page compares against.

Anonymous sign-ins therefore have to be **on** for the project:
Authentication -> Providers -> Anonymous sign-ins (or
`PATCH /v1/projects/<ref>/config/auth` with
`{"external_anonymous_users_enabled": true}`). It is on for the hosted project
as of 2026-08-26.

The signed-in account's id *is* this phone's member id: `main()` resolves it
before it builds the app and hands it to `bootstrapApp`, which overrides
`localMemberIdProvider`. That is one change and not two on purpose — the sync
replaces the local roster with the server's wholesale, and a phone still
calling itself `me` would then be asking the gate, the ping schedule and every
"may I" about somebody the trip does not hold.

Resolving it does **not** mean waiting for the network. `resolveMemberId`
(`lib/bootstrap.dart`) reads the id out of the vault, which is a local file, so
an ordinary launch reaches its first frame with no round trip at all and the
token refresh happens behind it, on the sync's first reconcile. Only a
first-ever launch has an account to mint, and that one waits at most three
seconds — a separate budget from `GotrueSessions`'s ten-second request
timeout — before running as the local stand-in. The identity is then **fixed
for the life of the launch**: a session that lands after the budget is written
to the vault and picked up next launch, never adopted mid-session, because a
surface that drew itself as `me` and then became a uuid would credit a photo to
somebody the roster does not hold. A phone that cannot reach the server at all,
on a launch with nothing stored, keeps the stand-in and runs entirely offline.

### Running the live smoke test

```sh
flutter test test/hosted_smoke_test.dart --dart-define=CAIRN_HOSTED_SMOKE=true
```

Skipped without that define, so CI never reaches out. It signs in, creates a
trip, pushes a plan, pulls it back onto a second `AppDatabase` and deletes the
trip again — no doubles anywhere in it.

### Two traps in offering Apple and Google together

Supabase auto-links identities that share a **verified** email, so the same
person signing in with both providers on the same address gets one
`auth.users` row and one profile, with no linking code. Two things break that:

- **Apple's "Hide My Email"** hands back a `@privaterelay.appleid.com`
  address, which will not match a Gmail — no auto-link, a second account, and
  split photo credit. Prefer Apple as the primary provider (it is mandatory on
  the iOS App Store if any third-party login is offered), or detect the relay
  domain and prompt to link deliberately with `linkIdentity()`.
- **Apple returns a name only on the very first authorization.** After that it
  is omitted, so `handle_new_user` falls back to `New traveller`. The app
  should prompt for a display name after first sign-in regardless — it is
  expected to be edited anyway, since providers hand back full legal names.

## R2 bucket setup and how the app gets an upload URL

1. Create an R2 bucket in the Cloudflare dashboard (e.g. `travelapp-photos`).
   Leave it **private** — no public bucket access, no public dev URL.
2. Create an R2 API token scoped to *only* that bucket, with Object
   Read & Write permission. This produces the access key ID / secret
   access key pair used as `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`
   above.
3. That secret is set as a Supabase Edge Function secret, **not** shipped
   in the app binary. The app never talks to R2 directly for uploads:
   - The client authenticates to Supabase, then calls the `r2-upload-url`
     edge function (`supabase/functions/r2-upload-url/`) with
     `{ tripId, photoId, contentType, contentLength }` and its session JWT.
     `photoId` is a client-minted uuid in the hyphenated form `photos.id`
     reads back — `PhotoId.mint` on the phone, `UUID_RE` in the function, one
     spelling compared by `test/photo_id_format_test.dart`.
   - The function asks Postgres three questions, all **as that user**, via the
     same tables and the same RLS the rest of the schema relies on (the
     caller's JWT against the anon client, never the service role, so there is
     exactly one source of truth for "is this person allowed to write here"):
     is the caller a member of this trip; has the trip closed
     (`trip_closes_at`, the same condition `photos_insert_trip_member`
     imposes, so bytes cannot land for a trip that can never accept the
     matching row); and does a `photos` row already hold this id — see the
     object-key section above for why that last one is the important refusal.
   - It also refuses a declared size over 64 MiB. Storage is the only line in
     this backend that ever invoices, and the measured JPEG median is 3.08 MB
     with the largest photograph in the corpus at 7.00 MB
     (`../docs/storage-and-cost.md`), so the ceiling is nine times the largest
     real one. It is a sanity bound and not a quota: a member who wants to
     fill the bucket does it with ordinary photographs.
   - It then mints a presigned S3-compatible `PUT` URL (R2 is
     S3-API-compatible) scoped to the exact object key
     `trips/<tripId>/photos/<photoId>/original.<ext>`, valid for 5
     minutes, and returns it. **The declared content type and content length
     are signed into that URL** (`allHeaders: true` in `index.ts` — aws4fetch
     leaves both out of the signature by default, which is what made the
     content-type allowlist advisory), so R2 refuses a PUT that declares
     anything else. The client must therefore send both headers, and a
     `content-length` rather than chunked transfer-encoding.
   - The client `PUT`s the file bytes directly to that URL (R2, not
     through Supabase — keeps Supabase's own bandwidth/compute out of
     the hot path), then inserts the corresponding `photos` row itself,
     which is separately checked by `photos_insert_trip_member`.
   - **The function is split in two, and the split is what makes it testable.**
     `handler.ts` holds every decision behind three injected dependencies and
     imports nothing remote; `index.ts` builds the real ones out of
     `supabase-js`, `aws4fetch` and `Deno.env`. `handler_test.ts` drives the
     whole request/response boundary offline (`deno test`), which is the only
     way to exercise an edge function that has never been deployed. What it
     cannot cover: whether the PostgREST queries in `index.ts` really answer
     the three questions, and whether R2 honours a signed `content-length`.
     Both need a deployment, and there has not been one.
4. **Downloads are not built yet**, and this is the highest-severity blank in
   the backend. The bucket stays private, so reads need a presigned `GET` from
   a sibling `r2-download-url` function. When it is written it **must**:
   - re-check membership as the caller, exactly as the upload function does,
     and
   - call `day_page_is_open(trip_id, trip_day, uid)` before signing, which is
     where the gate actually bites.

   Copy the upload function's *split* as well as its skeleton: decisions in a
   `handler.ts` that imports nothing remote, clients in `index.ts`. The gate is
   the single worst thing in this app to get wrong and the only way to test it
   before a deployment is to keep it reachable offline.

   The R2 keys are derivable from ids that flow through sync, so a download
   function that signs any key for any authenticated caller would let any user
   read any trip's photos. R2 presigned URLs allow 1 second to 7 days; 1–6
   hours is the sensible range for a pool people scroll repeatedly, cached per
   phone by `r2_object_key` (which is immutable, so cached bytes never go
   stale).

## Free-tier limits (verified 2026-08-21)

- **Supabase Free plan**: 500 MB database storage, 5 GB/month egress, 2 active
  projects, and **a free project pauses after about one week of inactivity**
  and has to be manually resumed from the dashboard. This is the one that will
  actually bite: this app is used in bursts (before/during/after a trip), so a
  project can easily go quiet for a week between trips and come back paused.
  The keep-alive that prevents it **cannot** live in `pg_cron` — that runs
  inside the database, so a paused project's cron is paused too and it cannot
  wake itself. It also should not live in GitHub Actions, which disables
  scheduled workflows after 60 days without repository activity, which is
  exactly what a passion project between trips looks like. Cloudflare Workers
  Cron Triggers are the right host, with a dead-man's switch so a keep-alive
  that dies is noticed before the project pauses. Source:
  [supabase.com/pricing](https://supabase.com/pricing).

  **Built (2026-08-26):** `ops/keepalive-worker/` is that Worker. It runs
  three times a week (`0 1 * * 1,3,5`, Monday, Wednesday and Friday 01:00
  UTC — `wrangler.jsonc`'s `triggers.crons`, a cadence chosen so a single
  missed run still leaves at most a four-day silence) and makes one
  authenticated `GET .../rest/v1/trips?select=id&limit=1` call against the
  hosted project, throwing out of the `scheduled` handler (so Cloudflare
  records a failed invocation) on any non-2xx response. The cron trigger is
  the only way in — there is deliberately no `fetch` handler, because a
  public URL proxying into the hosted project could be driven by anyone and
  burning the free-tier request quota that way would take the scheduled run
  down with it. Deploy with `wrangler deploy` from that directory; a
  failed scheduled run means the project may be paused — check the
  Worker's dashboard/logs, and resume the project from the Supabase
  dashboard if so. `SUPABASE_URL` and `SUPABASE_ANON_KEY` are copied into
  `wrangler.jsonc` as plain `vars` (both public-safe — see that file's
  comment) rather than read from `lib/storage/remote/shared_facts.dart` at
  request time, because a Worker has no checkout of this repo to read from;
  keep the two in sync by hand if the hosted project ever changes.
  **Not built yet:** the dead-man's switch mentioned above — that would need
  signing up for a new external alerting service, which this pass
  deliberately did not do. Cloudflare's own Worker failure notifications
  (dashboard-configurable, no new sign-up) are the natural first step if
  this is worth doing later.
- **Cloudflare R2 Free tier**: 10 GB-month of Standard storage, 1,000,000
  Class A operations/month (writes/lists), 10,000,000 Class B
  operations/month (reads), and **zero egress fees regardless of tier** —
  R2 doesn't charge for bandwidth out at all, free or paid. This is why R2
  holds the photos and not Supabase: a shared photo pool is almost
  entirely downloads, and Supabase's own storage product charges for
  egress past its bundled allowance while R2 never does. Source:
  [developers.cloudflare.com/r2/pricing](https://developers.cloudflare.com/r2/pricing/).

The bill has been measured rather than estimated, and the numbers are in
[docs/storage-and-cost.md](../docs/storage-and-cost.md) — read that before
quoting a figure here. In short: an original off a phone is about 3 MB, so at
the ping's own volume a fortnight for eight people is 0.31 GB and the free
10 GB holds roughly thirty-two such trips at once; at five trips a year that
allowance lasts into year six. The heavier reading, once the import sweep lets
a day's whole camera roll into the pool, is 3.14 GB a trip and a few dollars a
*year*, not a month. Storage is the only line in this backend that will ever
bill — egress is free, and operations are three orders of magnitude inside
their allowances. The two things that actually bite are operational: the
pause, and unbounded accumulation over years.

## What this model does not handle yet

Being honest about the edges:

- **No download path is built.** Only `r2-upload-url` exists. See the
  requirements above — this is where the worst potential leak lives, because
  it is a blank the next person fills in.
- **No derived-variant pipeline.** `photos.r2_thumbnail_key` and `day_pages`
  allow for a smaller derived image and a composed page being uploaded, but
  nothing here generates either — that's phone-side image work. Note what such
  a pipeline may and may not do: a derived variant is written *alongside*
  `r2_object_key` and never over it, because the pool stores the original
  (`docs/decisions/2026-08-22-grill-round-one.md` §3) and the trip's handover
  promise is a full-size set. The phone needs no variant to *show* a photo
  small — `lib/screens/photo_frame.dart` decodes the original down to the box
  it is drawn in — so a variant here is a bandwidth optimisation for other
  people's photos, and an optional one.
- **Nothing reconciles rows against R2 objects.** An upload that lands and
  whose row insert never happens leaves an orphan object, invisible to every
  client and costing storage forever; a row whose upload never landed shows a
  broken tile to everyone; and deleting a `photos` row does not delete its R2
  object. The sync should order the outbox upload-then-insert, and a
  periodic sweep should reconcile objects against rows in both directions.
- **No handling for a trip's last member leaving.** If the person who started
  a trip removes themselves, nobody can remove anyone else afterwards; the
  trip is otherwise fully usable. Worth a product answer before it happens.
- **Invite code collisions are unhandled, and now worth handling.** Three
  spoken words are 117 words paired distinctly with a two-digit number — a
  little over six hundred thousand codes, sized against two people on the same
  trip minting minutes apart rather than against a guesser. That is small
  enough that a collision on the canonical-spelling index is an ordinary
  event rather than an astronomical one, so a client **must** retry the insert
  on a unique-violation instead of treating it as an error. The phone already
  does (`MembershipRepository.mintInvite` redraws); nothing here does it for
  a caller that inserts directly.
- **`day_pages` regeneration has no conflict resolution.** If two members'
  phones both compose the same day's page near-simultaneously, the
  `unique (trip_id, page_date)` constraint means the second `insert` fails —
  the client needs to catch that and fall back to an `update` rather than
  treat it as an error. Not encoded in SQL because "which one wins" is a
  product/UX choice.
- **No rate limiting on `redeem_trip_invite`, and the code space is now small
  enough for that to matter.** Eight characters were ~850 billion
  combinations; three spoken words are a little over six hundred thousand, and
  each guess covers a whole neighbourhood of near-spellings. An authenticated
  caller with no cooldown can walk the entire space. The code was made sayable
  on purpose and that trade is the decision's, not an oversight — but the
  throttle it assumes does not exist yet, at the database level or above it.
  This is the largest open gap in this directory.
- **Deletions are invisible to a pull cursor.** `updated_at` lets an *edit*
  sync; a row someone deleted on another phone is only noticed by refetching.
  Fine at this size (a roster is eight rows, a trip's photos are one query),
  but it is a real limit of the cursor, not an oversight. The itinerary is the
  one place it is already solved, and solved narrowly:
  `trip_itineraries.plan_revised_at` is a *shape* revision, so a deleted day
  is expressible without a tombstone table. Nothing else here has one.
- **The itinerary merge is last-write-wins on the writing phone's clock.** A
  phone whose clock is an hour fast wins edits it should lose, and there is no
  detection of it and no conflict UI. That is the accepted price of the slice
  (no CRDTs); what makes it survivable is that the day is the atom, so the
  damage is one day of one plan and it is visible to everyone at once.
- **Nothing pushes the itinerary to a phone; a phone asks.** There is no
  Realtime subscription and no trigger that notifies. A change reaches another
  phone when that phone next reconciles, which the app does on its own local
  changes and on a timer. A trip's plan therefore has a propagation delay
  measured in minutes, deliberately: a websocket held open for a fortnight is
  the one thing a phone abroad on a battery cannot afford.

## Verification: what was actually run

Everything below was run against **Postgres 17** (which is what Supabase
provisions new projects on), driven the way PostgREST drives a request — `set
local role authenticated` plus the JWT claims GUC, as a role with no
`BYPASSRLS`. The suite lives in [`tests/`](tests/) and can be re-run against any
throwaway Postgres; see that directory's README. It has been run green on two
independently built clusters — 17.10 and a Homebrew 17.11 — so the results are
not an artefact of one machine's setup.

- All ten migrations apply cleanly, and apply again cleanly on a second run.
- 113 adversarial checks pass (`tests/rls_probe.py`), covering: trip creation
  with `RETURNING`, cross-trip isolation in both directions, the removal
  asymmetry, photo edit/delete ownership, the gate opening and never
  re-locking, a mid-trip joiner's access to past days, credit surviving both
  departure and account deletion, invite enumeration, timezone validation, and
  `updated_at` bumping on edit — plus the three-word invite grammar: the
  server's vocabulary compared word for word against the Dart the phone uses,
  order- and spelling-forgiving redemption, a code refused once its trip has
  closed, and one still admitting people inside the grace; the close itself —
  a late photograph still landing inside the grace, a member of a closed trip
  refused, that person's hold on their own photograph surviving it, a photo
  that cannot be repointed at another trip, and a closed trip's plan taking
  neither a push nor a pull — and the itinerary
  merge: a stale push losing, the day it did not lose left untouched, a fresh
  push replacing a day's stops with it, a phone unable to delete a day added
  after the shape it last saw, a current phone able to drop one, an emptied
  set-aside pocket staying empty against a stale phone that still holds the
  line, a non-member reading zero days and unable to push or write round the
  function, and the roster view answering a member with every co-member's name
  and a non-member with nobody, and the merged plan coming back ordered by the
  day *number* rather than by the text of it; and, as premises rather than
  policies, the two facts `r2-upload-url`'s refusals rest on — a co-member can
  read another member's photo `id` and `r2_object_key`, so a photo id is
  never evidence of who may write that object, and `trip_closes_at` answers a
  member and returns null to a stranger, which is a refusal and not "never
  closes".
- **The edge function's own refusals are tested, offline**
  (`deno test supabase/functions/r2-upload-url/handler_test.ts`, 22 checks):
  a non-member and a closed trip get no URL and nothing is signed, a photo id
  a row already holds is refused with 409, a retry before the row exists is
  still signed, an undashed id and a size past the 64 MiB ceiling are refused,
  and the declared type and size are what reach the signer. That is possible
  only because the function is split — see the section above. It proves
  nothing about R2 or about the PostgREST queries in `index.ts`.
- The recursion fix is checked at the mechanism level
  (`tests/recursion_mechanism.py`): the whole schema is applied by an ordinary
  role that is neither superuser nor `BYPASSRLS`, the policies resolve, and
  then turning on `FORCE ROW LEVEL SECURITY` brings the recursion straight
  back — confirming that table ownership, not test-harness privilege, is what
  makes the helper functions safe.

**What the hosted project has actually done** (2026-08-26). All ten migrations
are applied to it, and the following ran against it for real, from the app's
own code: an anonymous sign-in through GoTrue; `handle_new_user` minting the
profile; a `trips` insert with the phone-minted id; `handle_new_trip` seeding
`trip_members`; the `trip_roster` view; and `sync_trip_itinerary` in both
directions, including a day edited by one caller and pulled down by another.
`test/hosted_smoke_test.dart` is that path as a test, and since 27 August 2026
it assembles the `trips` row with the app's own `tripRowFor` rather than a
hand-written stand-in — only the clock is pinned, because `flutter test` has no
method-channel host to answer the real one. The same walk was made by the built
iOS app on a simulator, which pushed its Drift plan up and pulled a remote edit
back down. That simulator walk predates the defect D3 fix and was made with
`--dart-define=CAIRN_TRIP_TIMEZONE` passed; **no build reading the phone's own
zone has yet reached this project**, because that path needs a device or
simulator run and none has been made since.

**What it still does not prove.** The environment in `tests/supabase_env.sql`
is a reconstruction of the parts a migration sees, not a Supabase clone; it is
still what the adversarial checks above run against, because a single anonymous
account cannot pose as the eight adversaries they need. Nothing has exercised
**more than one account at once** on the hosted project, so no RLS *refusal*
has been observed there — only the permitted paths. GoTrue's real providers
(identity linking, Apple's private relay), the edge functions, R2 and
`pg_cron` were not exercised at all, and no photo has ever moved.
`r2-upload-url`'s decisions are tested offline, which is a different claim:
nothing has deployed it, called it, or signed a URL R2 has seen.

### A trap worth knowing before adding a test

**RLS refuses by filtering, not by raising.** A `SELECT`, `UPDATE` or `DELETE`
you are not allowed to perform returns zero rows and no error; only `INSERT`
(and an `UPDATE`'s `WITH CHECK`) raises. While the recursion was live, a probe
asserting "a non-member's insert is rejected" *passed* — because the statement
aborted on the recursion before any policy was consulted. It was testing
nothing. Assert on the state of the table afterwards, not on whether a
statement threw.
