-- Trip membership. This table is the root of every access-control check in
-- the schema: a row is reachable if (and only if) the requesting user has
-- a matching row here.
create table if not exists public.trip_members (
  trip_id uuid not null references public.trips (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (trip_id, user_id)
);

create index if not exists trip_members_user_id_idx on public.trip_members (user_id);

alter table public.trip_members enable row level security;

-- A user can see the roster of any trip they themselves belong to.
drop policy if exists "trip_members_select_co_member" on public.trip_members;
create policy "trip_members_select_co_member"
  on public.trip_members for select
  to authenticated
  using (
    exists (
      select 1 from public.trip_members mine
      where mine.trip_id = trip_members.trip_id
        and mine.user_id = auth.uid()
    )
  );

-- Direct inserts are restricted to trip owners adding someone they already
-- know the user_id of. The normal join path is the invite code, which goes
-- through the SECURITY DEFINER redeem_trip_invite() function in
-- 0006_trip_invites.sql and therefore bypasses this policy entirely.
drop policy if exists "trip_members_insert_by_owner" on public.trip_members;
create policy "trip_members_insert_by_owner"
  on public.trip_members for insert
  to authenticated
  with check (
    exists (
      select 1 from public.trip_members owner_row
      where owner_row.trip_id = trip_members.trip_id
        and owner_row.user_id = auth.uid()
        and owner_row.role = 'owner'
    )
  );

-- Owners can change a member's role; a member can always update their own
-- row (there is currently nothing on the row for a non-owner to change,
-- but this keeps the policy honest rather than owner-only by accident).
drop policy if exists "trip_members_update_owner_or_self" on public.trip_members;
create policy "trip_members_update_owner_or_self"
  on public.trip_members for update
  to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.trip_members owner_row
      where owner_row.trip_id = trip_members.trip_id
        and owner_row.user_id = auth.uid()
        and owner_row.role = 'owner'
    )
  )
  with check (
    user_id = auth.uid()
    or exists (
      select 1 from public.trip_members owner_row
      where owner_row.trip_id = trip_members.trip_id
        and owner_row.user_id = auth.uid()
        and owner_row.role = 'owner'
    )
  );

-- A member can remove themselves (leave the trip); an owner can remove
-- anyone.
drop policy if exists "trip_members_delete_owner_or_self" on public.trip_members;
create policy "trip_members_delete_owner_or_self"
  on public.trip_members for delete
  to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.trip_members owner_row
      where owner_row.trip_id = trip_members.trip_id
        and owner_row.user_id = auth.uid()
        and owner_row.role = 'owner'
    )
  );

-- Now that trip_members exists, add the trips policies deferred from
-- 0003_trips.sql.
drop policy if exists "trips_select_member" on public.trips;
create policy "trips_select_member"
  on public.trips for select
  to authenticated
  using (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = trips.id
        and trip_members.user_id = auth.uid()
    )
  );

drop policy if exists "trips_insert_self" on public.trips;
create policy "trips_insert_self"
  on public.trips for insert
  to authenticated
  with check (created_by = auth.uid());

drop policy if exists "trips_update_owner" on public.trips;
create policy "trips_update_owner"
  on public.trips for update
  to authenticated
  using (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = trips.id
        and trip_members.user_id = auth.uid()
        and trip_members.role = 'owner'
    )
  );

drop policy if exists "trips_delete_owner" on public.trips;
create policy "trips_delete_owner"
  on public.trips for delete
  to authenticated
  using (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = trips.id
        and trip_members.user_id = auth.uid()
        and trip_members.role = 'owner'
    )
  );

-- Whoever creates a trip is automatically its owner. This is enforced in
-- the database (not left to the client) so "a trip always has at least
-- one owner member" holds regardless of how trips get created.
create or replace function public.handle_new_trip()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.trip_members (trip_id, user_id, role)
  values (new.id, new.created_by, 'owner')
  on conflict (trip_id, user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_trip_created on public.trips;
create trigger on_trip_created
  after insert on public.trips
  for each row execute function public.handle_new_trip();
