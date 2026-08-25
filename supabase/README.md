# Backend: Supabase (accounts, trip membership, photo index) + R2 (photo bytes)

This directory is the entire backend. It is deliberately tiny: it holds the
shared photo pool, trip membership, and the one clock every phone on a trip
has to agree on. The itinerary, the day trail, the stars, the ping schedule
and the record of who has answered today's ping are all computed and kept on
the phone. The phone is the source of truth; the app works fully offline
except for pool sync.

No Supabase project has been created and nothing here has been applied to a
hosted project. It has, however, been run: see
[Verification](#verification-what-was-actually-run) at the bottom, which is not
the same claim the previous version of this file made.

## The model

| Table | Why it exists |
| --- | --- |
| `profiles` | One row per person, and the durable home of the name credited under every photo. Auto-created by a trigger on `auth.users` insert. Has **no foreign key to `auth.users`**, on purpose — see [Deletion](#deletion-the-login-goes-the-credit-stays). |
| `trips` | A named container, plus the shared trip clock (timezone, dates, waking window). Holds no itinerary data — that stays on the phone. |
| `trip_members` | The root of every access-control check in this schema. A row is reachable by a user if and only if they have a matching `(trip_id, user_id)` row here. Carries **no role column**; see [Roles are flat](#roles-are-flat-except-one-thing). |
| `trip_invites` | Invite codes, kept in their own table rather than a column on `trips` so a code can be rotated, expired, or usage-limited without touching trip identity, and a trip can have more than one outstanding code. |
| `photos` | One row per photo in the pool. The bytes live in R2; this row is the index the app queries and the thing RLS protects. |
| `day_unlocks` | The gate, as a durable fact: "this person contributed to this day". Written only by a trigger on `photos`, and never deleted by anything. See [The gate](#the-gate). |
| `day_pages` | A day's finished, composed page — one image per trip per day, made lazily at share or bind time. This was `daily_moments` and modelled a four-up panel; the four-up is retired. |
| `day_page_photos` | Which photos went into a composed page, and in what order. Ordered by `ordinal`, not seated in a 1-to-4 slot. |

Full column-level rationale is in the migration files themselves as
comments — read those alongside this table, they're short.

### How someone joins a trip

**Invite code**, not a magic link. Any member of a trip can create a row in
`trip_invites` (an 8-character code from an unambiguous alphabet —
`0/O`, `1/I/L` removed — since it's meant to be read aloud or typed by
hand), optionally with an expiry or a use limit. A joiner calls
`redeem_trip_invite(code)`.

That function is `SECURITY DEFINER` and is the *only* way to join a trip
you didn't create. It has to be: a non-member cannot be granted `SELECT`
on `trip_invites` (that would let anyone enumerate or brute-force codes by
reading the table) and cannot `INSERT` into `trip_members` directly under
the RLS policies here. The function looks the code up, validates
expiry/use-limit, inserts the membership row, and increments the use
counter, all inside one elevated-privilege call whose surface area is
exactly one text argument. Redeeming a code for a trip you are already on is a
no-op and spends no use, so a re-tapped deep link cannot burn a limited code
down.

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
can ever claim an original — but note `r2-upload-url` will re-sign a key it
has signed before, so a client that re-uploads under the same photo id
overwrites an original. Nothing does that today; a client that starts to is
breaking this rule, not extending it.
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
clock it started in. Both need the itinerary, which stays on the phone by
decision, so expressing them here would mean syncing the itinerary. Until then
a trip that crosses zones runs on the clock it was created with, and the
daylight-saving slide is documented rather than solved.

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
     `{ tripId, photoId, contentType }` and its session JWT.
   - The function re-checks trip membership **as that user**, via the
     same `trip_members` table and the same RLS the rest of the schema
     relies on (it uses the caller's JWT against the anon client to do this
     check, not the service role, so there is exactly one source of truth for
     "is this person allowed to write here").
   - It then mints a presigned S3-compatible `PUT` URL (R2 is
     S3-API-compatible) scoped to the exact object key
     `trips/<tripId>/photos/<photoId>/original.<ext>`, valid for 5
     minutes, and returns it.
   - The client `PUT`s the file bytes directly to that URL (R2, not
     through Supabase — keeps Supabase's own bandwidth/compute out of
     the hot path), then inserts the corresponding `photos` row itself,
     which is separately checked by `photos_insert_trip_member`.
4. **Downloads are not built yet**, and this is the highest-severity blank in
   the backend. The bucket stays private, so reads need a presigned `GET` from
   a sibling `r2-download-url` function. When it is written it **must**:
   - re-check membership as the caller, exactly as the upload function does,
     and
   - call `day_page_is_open(trip_id, trip_day, uid)` before signing, which is
     where the gate actually bites.

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
- **Invite code collisions are unhandled.** `generate_invite_code()` picks
  from a 31-character, 8-position alphabet (~850 billion combinations),
  so a collision on the `unique` constraint is astronomically unlikely but
  not impossible; a production client should retry the insert once on a
  unique-violation rather than assume it never happens.
- **`day_pages` regeneration has no conflict resolution.** If two members'
  phones both compose the same day's page near-simultaneously, the
  `unique (trip_id, page_date)` constraint means the second `insert` fails —
  the client needs to catch that and fall back to an `update` rather than
  treat it as an error. Not encoded in SQL because "which one wins" is a
  product/UX choice.
- **No rate limiting on `redeem_trip_invite`** — callable by any authenticated
  user with no cooldown. Brute-forcing the code space is computationally
  infeasible but not throttled at the database level.
- **Deletions are invisible to a pull cursor.** `updated_at` lets an *edit*
  sync; a row someone deleted on another phone is only noticed by refetching.
  Fine at this size (a roster is eight rows, a trip's photos are one query),
  but it is a real limit of the cursor, not an oversight.

## Verification: what was actually run

Everything below was run against **Postgres 17** (which is what Supabase
provisions new projects on), driven the way PostgREST drives a request — `set
local role authenticated` plus the JWT claims GUC, as a role with no
`BYPASSRLS`. The suite lives in [`tests/`](tests/) and can be re-run against any
throwaway Postgres; see that directory's README. It has been run green on two
independently built clusters — 17.10 and a Homebrew 17.11 — so the results are
not an artefact of one machine's setup.

- All nine migrations apply cleanly, and apply again cleanly on a second run.
- 55 adversarial checks pass (`tests/rls_probe.py`), covering: trip creation
  with `RETURNING`, cross-trip isolation in both directions, the removal
  asymmetry, photo edit/delete ownership, the gate opening and never
  re-locking, a mid-trip joiner's access to past days, credit surviving both
  departure and account deletion, invite enumeration, timezone validation, and
  `updated_at` bumping on edit.
- The recursion fix is checked at the mechanism level
  (`tests/recursion_mechanism.py`): the whole schema is applied by an ordinary
  role that is neither superuser nor `BYPASSRLS`, the policies resolve, and
  then turning on `FORCE ROW LEVEL SECURITY` brings the recursion straight
  back — confirming that table ownership, not test-harness privilege, is what
  makes the helper functions safe.

**What this does not prove.** No hosted Supabase project has been touched, and
the environment in `tests/supabase_env.sql` is a reconstruction of the parts a
migration sees, not a Supabase clone. The RLS engine, `auth.uid()`,
`SECURITY DEFINER` ownership and `RETURNING`'s interaction with the SELECT
policy are all core Postgres and reproduce identically on a real project. GoTrue
(identity linking, Apple's private relay), the edge functions, R2 and `pg_cron`
were not exercised at all. Run `supabase db push` against a throwaway project
before pointing anything real at this.

### A trap worth knowing before adding a test

**RLS refuses by filtering, not by raising.** A `SELECT`, `UPDATE` or `DELETE`
you are not allowed to perform returns zero rows and no error; only `INSERT`
(and an `UPDATE`'s `WITH CHECK`) raises. While the recursion was live, a probe
asserting "a non-member's insert is rejected" *passed* — because the statement
aborted on the recursion before any policy was consulted. It was testing
nothing. Assert on the state of the table afterwards, not on whether a
statement threw.
