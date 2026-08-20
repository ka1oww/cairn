# Backend: Supabase (accounts, trip membership, photo index) + R2 (photo bytes)

This directory is the entire backend. It is deliberately tiny: it holds the
shared photo pool and trip membership, and nothing else. The itinerary, the
day trail, the stars, both notification types, and the shared instant the
daily moment fires at are all computed on the phone. The phone is the
source of truth; the app works fully offline except for pool sync.

No Supabase project has been created and nothing here has been applied
anywhere. This is code and documentation only, meant to be reviewed and
then applied by hand.

## The model

| Table | Why it exists |
| --- | --- |
| `profiles` | One row per signed-in user. Exists so other tables can show a display name/avatar without ever exposing `auth.users` (email, provider identity) to client queries. Auto-created by a trigger on `auth.users` insert. |
| `trips` | A named container. Holds no itinerary data -- that stays on the phone. |
| `trip_members` | The root of every access-control check in this schema. A row is reachable by a user if and only if they have a matching `(trip_id, user_id)` row here. |
| `trip_invites` | Invite codes, kept in their own table rather than a column on `trips` so a code can be rotated, expired, or usage-limited without touching trip identity, and a trip can have more than one outstanding code. |
| `photos` | One row per photo in the pool. The bytes live in R2; this row is the index the app queries and the thing RLS protects. |
| `daily_moments` | The four-up daily-moment panel, modelled as **one artefact** (one R2 object, one row) -- not four photo rows -- because it is a single composed image, not four separate contributions. |
| `daily_moment_sources` | Optional provenance: which up-to-four `photos` rows fed a given `daily_moments` artefact, and in which slot. Nullable/`on delete set null` so losing a source photo never invalidates an already-composed moment. |

Full column-level rationale is in the migration files themselves as
comments -- read those alongside this table, they're short.

### How someone joins a trip

**Invite code**, not a magic link. A trip owner creates a row in
`trip_invites` (an 8-character code from an unambiguous alphabet --
`0/O`, `1/I/L` removed -- since it's meant to be read aloud or typed by
hand), optionally with an expiry or a use limit. A joiner calls
`redeem_trip_invite(code)`.

That function is `SECURITY DEFINER` and is the *only* way to join a trip
you didn't create. It has to be: a non-member cannot be granted `SELECT`
on `trip_invites` (that would let anyone enumerate or brute-force codes by
reading the table) and cannot `INSERT` into `trip_members` directly under
the RLS policies here. The function looks the code up, validates
expiry/use-limit, inserts the membership row, and increments the use
counter, all inside one elevated-privilege call whose surface area is
exactly one text argument.

A deep link (`traveling-app://join/<code>`) is just the same code
delivered a second way -- no separate mechanism needed.

### The R2 object key, and why listing never touches R2

A photo's key is:

```
trips/<trip_id>/photos/<photo_id>/original.<ext>
```

and, if a thumbnail is generated, `.../thumbnail.<ext>` alongside it. A
daily moment's key is `trips/<trip_id>/moments/<moment_id>.<ext>`.

The app never lists an R2 bucket to show a trip's pool. It queries
`photos where trip_id = $1` (RLS-filtered to members only) and reads
`r2_object_key` off each row, then fetches that exact object. Postgres is
the index; R2 is blob storage. This is also why every `r2_object_key` and
`r2_thumbnail_key` column is `unique` -- the row *is* the pointer, so two
rows can never race for the same object.

### Day assignment

EXIF timestamps carry no timezone. A photo taken at 11pm local time can
land on the wrong calendar day if the day boundary is computed from the
raw timestamp read back in a different timezone (e.g. the device's current
zone, or UTC). So `photos.trip_day` -- the day the app actually trails the
photo under -- is **derived on the phone** from
`(captured_latitude, captured_longitude)` via a timezone-boundary lookup,
not from `captured_at` directly.

The row stores everything needed to redo that computation or challenge it:

- `captured_at` -- raw EXIF capture time, kept for provenance.
- `captured_latitude`, `captured_longitude` -- raw EXIF GPS, nullable
  (not every photo has it).
- `capture_timezone` -- the IANA zone the coordinate resolved to (e.g.
  `Asia/Tokyo`), so the day can be recomputed later without redoing the
  geo lookup.
- `trip_day` -- the derived day.
- `trip_day_is_manual` -- set when a person corrects the day by hand
  (the app should always allow this as an escape hatch; timezone-boundary
  lookups are not infallible, especially near international date changes
  mid-trip).

### Who took each photo

`photos.contributor_id` (not nullable, `references profiles`), enforced at
insert time by an RLS `with check` that the inserting user must be
tagging *themselves* (`contributor_id = auth.uid()`), not anyone else.

## Row-level security

Every table has `alter table ... enable row level security;` and explicit
policies -- none is left open. The one invariant that matters most: **a
photo row (and by extension its R2 key) is unreachable to anyone who is
not a member of that photo's trip.** That's the `photos_select_trip_member`
policy in `0007_photos.sql`; every other photo policy (insert/update/
delete) additionally narrows within membership.

### Demonstrating a non-member is refused (manual check)

There is no running service to run automated tests against yet, so here is
the exact manual check to run once a project exists, using the Supabase
SQL editor (run as `postgres`, which can freely switch role) or two
separate authenticated API clients:

1. Create two users, A and B (e.g. via Supabase Auth test users, or by
   temporarily inserting rows manually and using
   [`set_config('request.jwt.claims', ...)`](https://supabase.com/docs/guides/database/postgres/row-level-security#testing-policies-with-supabase-client-libraries)
   to impersonate each in the SQL editor).
2. As A: `insert into trips (name, created_by) values ('Test trip', '<A's uid>') returning id;`
   -- A is now the trip's owner (via the `on_trip_created` trigger).
3. As A: insert a `photos` row for that trip with `contributor_id = '<A's uid>'`.
4. As B (who has never redeemed an invite to this trip), run:
   ```sql
   select * from photos where trip_id = '<the trip id>';
   ```
   **Expected: zero rows**, not an error -- RLS filters rather than
   raising, so this is what "unreachable" looks like from a client's
   perspective.
5. As B, attempt:
   ```sql
   insert into photos (trip_id, contributor_id, r2_object_key, content_type, byte_size)
   values ('<the trip id>', '<B's uid>', 'trips/x/photos/y/original.jpg', 'image/jpeg', 1);
   ```
   **Expected: rejected** by `photos_insert_trip_member` (no matching
   `trip_members` row for B).
6. As B, call `select redeem_trip_invite('<A's invite code>');`, then repeat
   step 4. **Expected: now B sees the row** -- membership, not identity,
   is what the policy gates on.

This same shape (member sees rows, non-member sees zero rows and gets
insert/update/delete rejected) holds for `trips`, `trip_members`,
`trip_invites` (owner-only there), `daily_moments`, and
`daily_moment_sources`. A future pass could wire steps 1-6 up as a
`pgTAP` suite (Supabase supports this natively) instead of a documented
manual runbook -- flagged in "What this doesn't handle yet" below.

## Applying this to a fresh Supabase project

1. **Create a project** in the Supabase dashboard (this is the one step
   that genuinely cannot be scripted from outside -- account + project
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
   idempotent -- `db push` skips migrations it has already recorded, and
   each file's own `create table if not exists`/`drop policy if exists`
   guards make a manual re-run safe too.
5. **Dashboard steps that are not expressible in SQL**, all one-time:
   - **Enable Sign in with Apple**: Authentication -> Providers -> Apple.
     Requires a Services ID, a Sign in with Apple key, and your app's
     bundle ID from the Apple Developer portal -- entered into the
     dashboard, not migrated.
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

## R2 bucket setup and how the app gets an upload URL

1. Create an R2 bucket in the Cloudflare dashboard (e.g. `travelapp-photos`).
   Leave it **private** -- no public bucket access, no public dev URL.
2. Create an R2 API token scoped to *only* that bucket, with Object
   Read & Write permission. This produces the access key ID / secret
   access key pair used as `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`
   above.
3. That secret is set as a Supabase Edge Function secret, **not** shipped
   in the iOS app binary. The app never talks to R2 directly for uploads:
   - The client authenticates to Supabase (Sign in with Apple -> Supabase
     session JWT), then calls the `r2-upload-url` edge function
     (`supabase/functions/r2-upload-url/`) with `{ tripId, photoId,
     contentType }` and its session JWT.
   - The function re-checks trip membership **as that user**, via the
     same `trip_members` table and implicitly the same RLS the rest of
     the schema relies on (it uses the caller's JWT against the anon
     client to do this check, not the service role, so there is exactly
     one source of truth for "is this person allowed to write here").
   - It then mints a presigned S3-compatible `PUT` URL (R2 is
     S3-API-compatible) scoped to the exact object key
     `trips/<tripId>/photos/<photoId>/original.<ext>`, valid for 5
     minutes, and returns it.
   - The client `PUT`s the file bytes directly to that URL (R2, not
     through Supabase -- keeps Supabase's own bandwidth/compute out of
     the hot path), then inserts the corresponding `photos` row itself,
     which is separately checked by `photos_insert_trip_member`.
   - This is the one edge function in this project. It exists only
     because the R2 secret can't live in the app binary; everything else
     -- data model, access control, invite flow -- is plain Postgres.
4. **Downloads** go straight from the client to R2's public-but-unguessable
   object URLs is *not* how this is set up -- the bucket stays private, and
   reads should go through R2 as well via a short-lived presigned `GET`
   (the same `r2-upload-url` function pattern, or a sibling
   `r2-download-url` function, would mint one). This is called out
   explicitly in "what this doesn't handle yet" below since only the
   upload path is built here.

## Free-tier limits (verified 2026-08-21)

- **Supabase Free plan**: 500 MB database storage, 1 GB file storage
  (unused here -- R2 holds the bytes), and **a free project pauses after
  about one week of inactivity** and has to be manually resumed from the
  dashboard. This is the one that will actually bite: this app is used in
  bursts (before/during/after a trip), so a project can easily go quiet
  for a week between trips and come back paused. There is no way to
  prevent this on the free tier short of a cron ping; budget for either
  accepting a manual "resume" click before each trip, or upgrading to Pro
  ($25/mo, no auto-pause) once this stops being a toy. Source:
  [supabase.com/pricing](https://supabase.com/pricing).
- **Cloudflare R2 Free tier**: 10 GB-month of Standard storage, 1,000,000
  Class A operations/month (writes/lists), 10,000,000 Class B
  operations/month (reads), and **zero egress fees regardless of tier** --
  R2 doesn't charge for bandwidth out at all, free or paid. This is why R2
  holds the photos and not Supabase: a shared photo pool is almost
  entirely downloads, and Supabase's own storage product charges for
  egress past its bundled allowance while R2 never does. Source:
  [developers.cloudflare.com/r2/pricing](https://developers.cloudflare.com/r2/pricing/).

Both figures were fetched live as part of writing this document rather
than assumed from the original brief; the numbers above matched what the
brief estimated ("roughly a gigabyte" / "roughly ten gigabytes"), so
nothing needed correcting.

## What this model does not handle yet

Being honest about the edges, since this is a first pass:

- **No download path is built.** Only `r2-upload-url` exists. Reading a
  photo back needs either a sibling presigned-`GET` function or a
  different strategy (e.g. Cloudflare Access / signed R2 URLs with longer
  TTLs cached client-side). Left out because the brief scoped this pass to
  the data model and RLS, and a naive symmetric download function would
  have been speculative without knowing the app's caching strategy.
- **No thumbnail generation pipeline.** `photos.r2_thumbnail_key` and
  `daily_moments` assume a thumbnail/composed image gets uploaded, but
  nothing here generates one -- that's phone-side image work, out of
  scope for this backend pass, and not touched.
- **No account deletion / GDPR-style data export flow.** `profiles` cascades
  from `auth.users` deletion, and `photos.contributor_id` is
  `on delete restrict`, which means **a user cannot currently be deleted
  from `auth.users` while they still have photos** in a trip -- deleting
  their account would need to first decide what happens to their
  contributions (reassign to a "deleted user" placeholder? delete their
  photos too? transfer trip ownership if they're the sole owner?). That
  product decision was not made here, so it was left as a hard `restrict`
  rather than silently picking a default that could surprise someone
  later.
- **No handling for a trip's last owner leaving.** `trip_members_delete_
  owner_or_self` lets an owner remove themselves with no check that
  someone else becomes owner first. A trip with zero owners still has
  members with full photo access under current policies, but no one can
  manage invites or update/delete the trip itself. Worth a trigger or a
  `before delete` check once there's a product answer for "who becomes
  owner."
- **Invite code collisions are unhandled.** `generate_invite_code()` picks
  from a 32-character, 8-position alphabet (~1.1 trillion combinations),
  so a collision on the `unique` constraint is astronomically unlikely but
  not impossible; a production client should retry the insert once on a
  unique-violation rather than assume it never happens.
- **`daily_moments` regeneration has no conflict resolution.** If two
  members' phones both decide to compose and upload the same day's moment
  near-simultaneously, the `unique (trip_id, moment_date)` constraint means
  the second `insert` fails -- the client needs to catch that and fall back
  to an `update` (replace) rather than treat it as an error. Not encoded
  in SQL because "which one wins" is a product/UX choice, not a schema one.
- **No automated test suite**, only the manual RLS check above. pgTAP
  would be the natural next step if this backend graduates past a toy.
- **No rate limiting or abuse protection** on `redeem_trip_invite` -- it's
  callable by any authenticated user with no cooldown, so a brute-force
  guess against the ~1.1 trillion-combination code space is
  computationally infeasible but not throttled at the database level.
  Worth revisiting if this ever needs to resist a determined attacker
  rather than just accidental collisions.

## Verifying the migrations apply cleanly

**Honest caveat: this was verified by careful manual inspection, not by
actually running the migrations against Postgres.** This worktree has
neither the Supabase CLI, Docker, nor a local `psql`/Postgres binary
available, so `supabase db push` / `supabase start` could not be run here.

What was checked instead:

- Every `create table`/`create policy`/`create function` statement only
  references objects created in the same file or an earlier-numbered one
  -- verified by reading the migrations in filename order and tracing each
  cross-table reference (documented inline in the files themselves, e.g.
  `0003_trips.sql` explicitly defers its RLS policies to `0004_trip_
  members.sql` because they need `trip_members` to exist first).
- Every file's parentheses and `$$...$$` dollar-quoted function bodies are
  balanced (checked programmatically, not just by eye).
- Every `create policy` is preceded by a matching `drop policy if exists`
  on the same table, so a migration can be re-applied without erroring
  (Postgres has no `create policy if not exists`).
- Every table has `enable row level security` immediately after creation,
  before any policy is attached, so there is no window where a table is
  RLS-enabled-but-policy-less-and-therefore-open (RLS-enabled with zero
  policies is deny-all, the safe default) versus RLS-disabled-and-open.

The next person to apply this should run `supabase db push` against a
throwaway project first and treat that as the actual gate before pointing
it at anything real.
