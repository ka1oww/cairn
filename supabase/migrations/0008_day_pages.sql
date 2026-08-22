-- A day's finished page: one composed image per trip per day, the thing the
-- book is bound from and the thing that gets shared.
--
-- This table was `daily_moments`, and it was written for a product that no
-- longer exists. The original mechanic buzzed every phone at one instant and
-- bound the four replies into a four-up panel, so the table modelled exactly
-- that: a moment, one per trip per day, with a sources table whose slots ran
-- one to four. The moment decision reversed all of it. Each person is now
-- pinged once a day at their own time, there is no shared instant, the trip
-- can be eight people rather than four, and the day's artefact is a vertical
-- timeline of however many photos happened, in the order they happened.
--
-- What survives is the shape, not the name: one artefact per day is still one
-- of Cairn's load-bearing properties, so one composed image per trip per day
-- is still right. Renamed to say what it now is, and the four-up's fingerprints
-- -- `moment`, the 1..4 slot -- are gone rather than left to mislead.
--
-- WHEN A ROW APPEARS. Only when a day's page has actually been composed and
-- uploaded, which happens lazily, at share or bind time. Nothing here records
-- that a ping fired, or who has answered so far today: by decision, that is
-- the phone's own database. The server holds finished artefacts. This is why
-- r2_object_key and byte_size can stay `not null` -- there is no such thing
-- here as a page that has not been made yet.
create table if not exists public.day_pages (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  page_date date not null,

  r2_object_key text not null unique,
  content_type text not null,
  byte_size bigint not null check (byte_size > 0),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (trip_id, page_date)
);

create index if not exists day_pages_trip_id_idx on public.day_pages (trip_id);

drop trigger if exists day_pages_touch_updated_at on public.day_pages;
create trigger day_pages_touch_updated_at
  before update on public.day_pages
  for each row execute function public.touch_updated_at();

alter table public.day_pages enable row level security;

drop policy if exists "daily_moments_select_trip_member" on public.day_pages;
drop policy if exists "day_pages_select_trip_member" on public.day_pages;
create policy "day_pages_select_trip_member"
  on public.day_pages for select
  to authenticated
  using ( public.is_trip_member(day_pages.trip_id, auth.uid()) );

-- Any member's device can be the one that composes and uploads a given day's
-- page, and any member can recompose it. It is a derived, trip-wide artefact
-- -- not a contribution owned by one person the way a photo is -- so this
-- stays flat.
drop policy if exists "daily_moments_insert_trip_member" on public.day_pages;
drop policy if exists "day_pages_insert_trip_member" on public.day_pages;
create policy "day_pages_insert_trip_member"
  on public.day_pages for insert
  to authenticated
  with check ( public.is_trip_member(day_pages.trip_id, auth.uid()) );

drop policy if exists "daily_moments_update_trip_member" on public.day_pages;
drop policy if exists "day_pages_update_trip_member" on public.day_pages;
create policy "day_pages_update_trip_member"
  on public.day_pages for update
  to authenticated
  using ( public.is_trip_member(day_pages.trip_id, auth.uid()) )
  with check ( public.is_trip_member(day_pages.trip_id, auth.uid()) );

drop policy if exists "daily_moments_delete_trip_member" on public.day_pages;
drop policy if exists "day_pages_delete_trip_member" on public.day_pages;
create policy "day_pages_delete_trip_member"
  on public.day_pages for delete
  to authenticated
  using ( public.is_trip_member(day_pages.trip_id, auth.uid()) );

-- Which photos went into a composed page, and in what order.
--
-- `ordinal` replaces the old `slot smallint check (slot between 1 and 4)`.
-- The cap was the four-up's, and the concept was too: a slot is a seat in a
-- grid, and there is no grid any more. A page is a timeline, so what is
-- recorded is the order the photos appear down it, of which there can be as
-- many as there were photos that day.
--
-- The list is provenance, not the page's definition -- the day's photos are
-- always `select ... from photos where trip_id = $1 and trip_day = $2` -- but
-- a composed image is a fixed thing, and this records what was actually in it
-- at the time. `on delete set null` because a photo deleted afterwards must
-- not invalidate an artefact that already exists, and must not take the row
-- above it down either.
create table if not exists public.day_page_photos (
  day_page_id uuid not null references public.day_pages (id) on delete cascade,
  ordinal smallint not null check (ordinal > 0),
  photo_id uuid references public.photos (id) on delete set null,
  primary key (day_page_id, ordinal),
  unique (day_page_id, photo_id)
);

alter table public.day_page_photos enable row level security;

drop policy if exists "daily_moment_sources_select_trip_member" on public.day_page_photos;
drop policy if exists "day_page_photos_select_trip_member" on public.day_page_photos;
create policy "day_page_photos_select_trip_member"
  on public.day_page_photos for select
  to authenticated
  using (
    exists (
      select 1 from public.day_pages p
      where p.id = day_page_photos.day_page_id
        and public.is_trip_member(p.trip_id, auth.uid())
    )
  );

-- The photo has to belong to the same trip as the page it is being listed
-- on. The old policy checked only that the *page* was in a trip you belonged
-- to, so a member of two trips could list one trip's photo as a source of the
-- other's page. No bytes leaked -- reading that photo still needs membership
-- of its own trip -- but the provenance would have pointed across trips,
-- which is precisely the thing provenance is for.
drop policy if exists "daily_moment_sources_insert_trip_member" on public.day_page_photos;
drop policy if exists "day_page_photos_insert_trip_member" on public.day_page_photos;
create policy "day_page_photos_insert_trip_member"
  on public.day_page_photos for insert
  to authenticated
  with check (
    exists (
      select 1
      from public.day_pages p
      where p.id = day_page_photos.day_page_id
        and public.is_trip_member(p.trip_id, auth.uid())
        and (
          day_page_photos.photo_id is null
          or exists (
            select 1 from public.photos ph
            where ph.id = day_page_photos.photo_id
              and ph.trip_id = p.trip_id
          )
        )
    )
  );

drop policy if exists "daily_moment_sources_delete_trip_member" on public.day_page_photos;
drop policy if exists "day_page_photos_delete_trip_member" on public.day_page_photos;
create policy "day_page_photos_delete_trip_member"
  on public.day_page_photos for delete
  to authenticated
  using (
    exists (
      select 1 from public.day_pages p
      where p.id = day_page_photos.day_page_id
        and public.is_trip_member(p.trip_id, auth.uid())
    )
  );
