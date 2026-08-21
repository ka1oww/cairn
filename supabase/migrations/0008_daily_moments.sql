-- The daily moment's four-up panel is ONE artefact -- a single composed
-- image assembled on the phone and uploaded once -- not four photo rows.
-- daily_moments is that artefact's index entry, structurally parallel to
-- photos but distinct because a moment isn't a contribution to the pool,
-- it's a derived, trip-wide object with at most one per trip per day.
create table if not exists public.daily_moments (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  moment_date date not null,

  r2_object_key text not null unique,
  content_type text not null,
  byte_size bigint not null check (byte_size > 0),

  generated_at timestamptz not null default now(),

  unique (trip_id, moment_date)
);

create index if not exists daily_moments_trip_id_idx on public.daily_moments (trip_id);

alter table public.daily_moments enable row level security;

drop policy if exists "daily_moments_select_trip_member" on public.daily_moments;
create policy "daily_moments_select_trip_member"
  on public.daily_moments for select
  to authenticated
  using (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = daily_moments.trip_id
        and trip_members.user_id = auth.uid()
    )
  );

-- Any trip member's device can be the one that assembles and uploads a
-- given day's moment (it's a collaborative, derived artefact -- not owned
-- by a single contributor the way a photo is), and any member can
-- regenerate/replace it.
drop policy if exists "daily_moments_insert_trip_member" on public.daily_moments;
create policy "daily_moments_insert_trip_member"
  on public.daily_moments for insert
  to authenticated
  with check (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = daily_moments.trip_id
        and trip_members.user_id = auth.uid()
    )
  );

drop policy if exists "daily_moments_update_trip_member" on public.daily_moments;
create policy "daily_moments_update_trip_member"
  on public.daily_moments for update
  to authenticated
  using (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = daily_moments.trip_id
        and trip_members.user_id = auth.uid()
    )
  );

drop policy if exists "daily_moments_delete_trip_member" on public.daily_moments;
create policy "daily_moments_delete_trip_member"
  on public.daily_moments for delete
  to authenticated
  using (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = daily_moments.trip_id
        and trip_members.user_id = auth.uid()
    )
  );

-- Optional provenance: which four (up to four) photos fed a given moment,
-- and in what slot. Nullable/on-delete-set-null because losing a source
-- photo shouldn't retroactively invalidate an already-composed artefact.
create table if not exists public.daily_moment_sources (
  daily_moment_id uuid not null references public.daily_moments (id) on delete cascade,
  slot smallint not null check (slot between 1 and 4),
  photo_id uuid references public.photos (id) on delete set null,
  primary key (daily_moment_id, slot),
  unique (daily_moment_id, photo_id)
);

alter table public.daily_moment_sources enable row level security;

drop policy if exists "daily_moment_sources_select_trip_member" on public.daily_moment_sources;
create policy "daily_moment_sources_select_trip_member"
  on public.daily_moment_sources for select
  to authenticated
  using (
    exists (
      select 1 from public.daily_moments
      join public.trip_members
        on trip_members.trip_id = daily_moments.trip_id
      where daily_moments.id = daily_moment_sources.daily_moment_id
        and trip_members.user_id = auth.uid()
    )
  );

drop policy if exists "daily_moment_sources_insert_trip_member" on public.daily_moment_sources;
create policy "daily_moment_sources_insert_trip_member"
  on public.daily_moment_sources for insert
  to authenticated
  with check (
    exists (
      select 1 from public.daily_moments
      join public.trip_members
        on trip_members.trip_id = daily_moments.trip_id
      where daily_moments.id = daily_moment_sources.daily_moment_id
        and trip_members.user_id = auth.uid()
    )
  );

drop policy if exists "daily_moment_sources_delete_trip_member" on public.daily_moment_sources;
create policy "daily_moment_sources_delete_trip_member"
  on public.daily_moment_sources for delete
  to authenticated
  using (
    exists (
      select 1 from public.daily_moments
      join public.trip_members
        on trip_members.trip_id = daily_moments.trip_id
      where daily_moments.id = daily_moment_sources.daily_moment_id
        and trip_members.user_id = auth.uid()
    )
  );
