-- One row per photo in the shared pool. The bytes live in R2; this row is
-- the index that (a) the app queries to render the pool/trail, and (b) RLS
-- protects, since the R2 key itself carries no access control.
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
  r2_object_key text not null unique,
  r2_thumbnail_key text unique,
  content_type text not null,
  byte_size bigint not null check (byte_size > 0),
  width integer check (width > 0),
  height integer check (height > 0),

  -- Raw EXIF capture time, kept for provenance/debugging even though it is
  -- not what day assignment is based on.
  captured_at timestamptz,

  -- EXIF GPS, when present. Nullable: not every photo carries GPS (e.g.
  -- airplane mode, a screenshot dropped into the pool).
  captured_latitude double precision check (captured_latitude between -90 and 90),
  captured_longitude double precision check (captured_longitude between -180 and 180),

  -- IANA zone the coordinate resolved to at capture time (e.g.
  -- "Asia/Tokyo"), so trip_day can be recomputed later without redoing the
  -- geo lookup.
  capture_timezone text,

  -- The derived day this photo belongs to on the trip trail.
  trip_day date,
  trip_day_is_manual boolean not null default false,

  created_at timestamptz not null default now()
);

create index if not exists photos_trip_id_trip_day_idx on public.photos (trip_id, trip_day);
create index if not exists photos_contributor_id_idx on public.photos (contributor_id);

alter table public.photos enable row level security;

drop policy if exists "photos_select_trip_member" on public.photos;
create policy "photos_select_trip_member"
  on public.photos for select
  to authenticated
  using (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = photos.trip_id
        and trip_members.user_id = auth.uid()
    )
  );

-- A photo must be tagged with whoever is uploading it, and that person
-- must be a member of the trip they're uploading into.
drop policy if exists "photos_insert_trip_member" on public.photos;
create policy "photos_insert_trip_member"
  on public.photos for insert
  to authenticated
  with check (
    contributor_id = auth.uid()
    and exists (
      select 1 from public.trip_members
      where trip_members.trip_id = photos.trip_id
        and trip_members.user_id = auth.uid()
    )
  );

-- Only the contributor or the trip owner can edit a photo row (in
-- practice: correcting trip_day by hand).
drop policy if exists "photos_update_contributor_or_owner" on public.photos;
create policy "photos_update_contributor_or_owner"
  on public.photos for update
  to authenticated
  using (
    contributor_id = auth.uid()
    or exists (
      select 1 from public.trip_members
      where trip_members.trip_id = photos.trip_id
        and trip_members.user_id = auth.uid()
        and trip_members.role = 'owner'
    )
  );

drop policy if exists "photos_delete_contributor_or_owner" on public.photos;
create policy "photos_delete_contributor_or_owner"
  on public.photos for delete
  to authenticated
  using (
    contributor_id = auth.uid()
    or exists (
      select 1 from public.trip_members
      where trip_members.trip_id = photos.trip_id
        and trip_members.user_id = auth.uid()
        and trip_members.role = 'owner'
    )
  );
