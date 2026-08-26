-- One row per photo in the shared pool. The bytes live in R2; this row is
-- the index that (a) the app queries to render the pool and the day's
-- timeline, and (b) RLS protects, since the R2 key itself carries no access
-- control.
--
-- Day assignment: EXIF timestamps carry no timezone, so "which day" cannot
-- be derived from captured_at alone -- a photo taken at 11pm local time in
-- one timezone can land on the wrong calendar day if read back in another.
-- The app derives trip_day from (captured_latitude, captured_longitude) via
-- a timezone-boundary lookup done on the phone, then stores the result
-- here alongside everything needed to redo that computation later or let
-- a person override it by hand.
create table if not exists public.photos (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  contributor_id uuid not null references public.profiles (id) on delete restrict,

  -- Where the bytes are. Keyed by trip and photo id so listing a trip's
  -- photos is a `select ... where trip_id = $1` against this table --
  -- never an R2 ListObjects call. See supabase/README.md for the exact
  -- key shape.
  --
  -- This key holds the **original**, exactly as the camera wrote it: the
  -- pool stores originals and resizing is for display only
  -- (docs/decisions/2026-08-22-grill-round-one.md §3), which is what the
  -- trip's full-size handover promise rests on. Nothing may re-encode,
  -- strip or downsize the object behind this key, and nothing may write it
  -- twice: an original is immutable, which is also why a client can cache
  -- its bytes forever. `unique` enforces the half of that a database can --
  -- no second row may claim an original -- and the other half is a rule a
  -- client keeps, since r2-upload-url will re-sign a key it has signed
  -- before. See supabase/README.md.
  r2_object_key text not null unique,

  -- An optional smaller derived variant, written *alongside* the original
  -- and never over it. Nullable because it is an optimisation, not a
  -- requirement: a phone shows a photo small by decoding the original down
  -- to the box it draws in (lib/screens/photo_frame.dart), so this key only
  -- ever saves bandwidth fetching somebody else's photo. Nothing generates
  -- one yet.
  r2_thumbnail_key text unique,

  content_type text not null,

  -- The original's size and pixel dimensions, never a variant's. This is
  -- the column the storage bill is counted in -- see
  -- docs/storage-and-cost.md, where it is measured rather than guessed.
  byte_size bigint not null check (byte_size > 0),
  width integer check (width > 0),
  height integer check (height > 0),

  -- Raw EXIF capture time, kept for provenance/debugging even though it is
  -- not what day assignment is based on. It is also what the day's timeline
  -- orders by and prints in the margin, so a photo the app took itself
  -- always carries an exact one.
  captured_at timestamptz,

  -- EXIF GPS, when present. Nullable: not every photo carries GPS (e.g.
  -- airplane mode, a screenshot dropped into the pool).
  captured_latitude double precision check (captured_latitude between -90 and 90),
  captured_longitude double precision check (captured_longitude between -180 and 180),

  -- IANA zone the coordinate resolved to at capture time (e.g.
  -- "Asia/Tokyo"), so trip_day can be recomputed later without redoing the
  -- geo lookup.
  capture_timezone text,

  -- The derived day this photo belongs to on the trip trail. Nullable
  -- deliberately: packages/photo_day_assignment can legitimately place
  -- nothing (no EXIF time and no file time, or a time that falls outside the
  -- trip), and such a photo waits for a person to place it by hand rather
  -- than being clamped onto a day it does not belong to. It contributes to
  -- no day, and opens no day's gate, until it has one.
  trip_day date,
  trip_day_is_manual boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists photos_trip_id_trip_day_idx on public.photos (trip_id, trip_day);
create index if not exists photos_contributor_id_idx on public.photos (contributor_id);
create index if not exists photos_trip_id_updated_at_idx on public.photos (trip_id, updated_at);

drop trigger if exists photos_touch_updated_at on public.photos;
create trigger photos_touch_updated_at
  before update on public.photos
  for each row execute function public.touch_updated_at();

alter table public.photos enable row level security;

-- Membership, and only membership. There is deliberately no day-based
-- predicate here: someone who joins on day three can scroll days one and two
-- freely, and the gate never retroactively holds a past day shut against a
-- late joiner. The gate is a different mechanism entirely -- it withholds the
-- *bytes* of a day still in progress, not the rows -- see
-- 0007_day_unlocks.sql, and note that a shut gate has to render the day's
-- times and names, which it could not do if this policy hid the rows.
drop policy if exists "photos_select_trip_member" on public.photos;
create policy "photos_select_trip_member"
  on public.photos for select
  to authenticated
  using ( public.is_trip_member(photos.trip_id, auth.uid()) );

-- A photo must be tagged with whoever is uploading it, that person must be a
-- member of the trip they're uploading into, and **the trip must still be
-- open**.
--
-- The third condition is the server's half of the ending
-- (`docs/decisions/2026-08-26-the-ending.md`): a trip takes photographs until
-- a grace after its last day ends, and then its record is fixed. The phone
-- refuses the same write at `CaptureFlow.turnTheDayOver`, which is where a
-- person meets it; this is what makes it true of the trip rather than true of
-- one phone, because there are seven others and one of them has a wrong
-- clock.
--
-- `trip_closes_at` is null only for a trip this caller cannot see, and a null
-- fails the comparison -- which is the right answer twice over, since a
-- caller who cannot see the trip is not a member of it either.
--
-- Deliberately *not* added to the update and delete policies below. Those are
-- a person's own photograph: removing one of yourself you hate, or correcting
-- which day it landed on, stays yours after the close for the same reason the
-- phone still lets a starter discard a whole archived trip. What the close
-- shuts is the door for new contributions, not a person's hold on their own.
drop policy if exists "photos_insert_trip_member" on public.photos;
create policy "photos_insert_trip_member"
  on public.photos for insert
  to authenticated
  with check (
    contributor_id = auth.uid()
    and public.is_trip_member(photos.trip_id, auth.uid())
    and now() < public.trip_closes_at(photos.trip_id)
  );

-- Your own photo, and only your own -- in practice, correcting trip_day by
-- hand. Nobody edits anyone else's photos or placements, the trip's starter
-- included; their one extra power is removing a person, not curating the
-- pool.
--
-- The explicit WITH CHECK matters twice over. It stops a photo being handed
-- to someone else (the new row must still be yours), and it stops one being
-- moved into a trip you do not belong to. Without it Postgres silently
-- reuses USING as the check, which reads as if the trip were unconstrained.
drop policy if exists "photos_update_contributor_or_owner" on public.photos;
drop policy if exists "photos_update_contributor" on public.photos;
create policy "photos_update_contributor"
  on public.photos for update
  to authenticated
  using ( photos.contributor_id = auth.uid() )
  with check (
    contributor_id = auth.uid()
    and public.is_trip_member(photos.trip_id, auth.uid())
  );

-- A person can always delete their own photo -- someone must be able to
-- remove a photograph of themselves they hate. The day does not re-lock when
-- they do, and leaves no gap: see 0007_day_unlocks.sql.
drop policy if exists "photos_delete_contributor_or_owner" on public.photos;
drop policy if exists "photos_delete_contributor" on public.photos;
create policy "photos_delete_contributor"
  on public.photos for delete
  to authenticated
  using ( photos.contributor_id = auth.uid() );
