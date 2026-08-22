-- Trip membership, and the two functions every access-control check in this
-- schema is written in terms of.
--
-- A row here is the whole authorization model: a trip's rows are reachable if
-- and only if the requesting user has a matching row in this table.
--
-- NOTE ON THE MISSING `role` COLUMN. This table used to carry
-- `role text check (role in ('owner','member'))`. It is gone, on purpose.
-- The decision record is that roles are flat, with exactly one asymmetry:
-- the person who started the trip can remove someone (the join code is three
-- spoken words, so a wrong join has to be undoable), and nobody edits anyone
-- else's photos or placements. That single asymmetry is already a property of
-- the trip row -- `trips.created_by` -- so a role column adds nothing except
-- a value to tamper with. The committed version let any member run
-- `update trip_members set role = 'owner' where user_id = auth.uid()`,
-- because its UPDATE policy checked only *which row* you were touching and
-- never pinned *what you were writing into it*. Pinning the column in a
-- WITH CHECK would have closed that; deleting the column makes the escalation
-- unrepresentable, and removes the "trip with zero owners" hazard along with
-- it, since the starter is a fact about the trip rather than a membership row
-- that can be deleted.
create table if not exists public.trip_members (
  trip_id uuid not null references public.trips (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (trip_id, user_id)
);

create index if not exists trip_members_user_id_idx on public.trip_members (user_id);

-- There is deliberately no updated_at here: this table has no UPDATE policy
-- (see below), so a row is only ever inserted or deleted and there is nothing
-- for a bump column to record. The roster is small; clients refetch it whole.

alter table public.trip_members enable row level security;

-- ---------------------------------------------------------------------------
-- The membership predicates
-- ---------------------------------------------------------------------------
--
-- Every policy below, and in every later migration, asks membership through
-- these two functions rather than with an inline subquery. That is not style;
-- it is the fix for a schema that could not answer a single query.
--
-- The committed version wrote trip_members' own SELECT policy as
-- `using (exists (select 1 from trip_members mine where ...))` -- a policy on
-- a table whose USING clause reads that same table. Postgres re-applies the
-- policy to the inner read, and to the inner read of that, and aborts with
-- `infinite recursion detected in policy for relation "trip_members"`. Since
-- every other table gated membership the same way, the failure propagated to
-- photos, trips, invites and day pages: no member could read anything.
--
-- These functions cannot recurse. A `security definer` function executes as
-- its owner, and a table's owner is not subject to that table's row-level
-- security -- policies apply to everyone *except* the owner unless the table
-- is marked `force row level security`. So the read of trip_members inside
-- the function body runs with no policy attached at all, and the chain
-- terminates one level down instead of never. That is the entire mechanism.
--
-- CONSEQUENCE, AND THE ONE THING NOT TO DO: never add
-- `alter table public.trip_members force row level security` (or the same on
-- trips). Forcing RLS makes the owner subject to the policies too, which puts
-- the policy back inside the function body and brings the recursion straight
-- back. These tables are reachable only through PostgREST as `authenticated`,
-- which is not their owner, so forcing buys nothing and costs the fix.
create or replace function public.is_trip_member(p_trip_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.trip_members m
    where m.trip_id = p_trip_id
      and m.user_id = p_user_id
  );
$$;

-- The trip's starter: the only person on a trip who can do something the
-- others cannot, and the only asymmetry in the product.
create or replace function public.is_trip_starter(p_trip_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.trips t
    where t.id = p_trip_id
      and t.created_by = p_user_id
  );
$$;

revoke all on function public.is_trip_member(uuid, uuid) from public;
revoke all on function public.is_trip_starter(uuid, uuid) from public;
grant execute on function public.is_trip_member(uuid, uuid) to authenticated, service_role;
grant execute on function public.is_trip_starter(uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- trip_members policies
-- ---------------------------------------------------------------------------

-- A user can see the roster of any trip they belong to. This is the policy
-- that used to recurse.
drop policy if exists "trip_members_select_co_member" on public.trip_members;
create policy "trip_members_select_co_member"
  on public.trip_members for select
  to authenticated
  using ( public.is_trip_member(trip_members.trip_id, auth.uid()) );

-- Direct inserts are not a client flow -- people join by redeeming a code,
-- through the SECURITY DEFINER redeem_trip_invite() in
-- 0005_trip_invites.sql, which bypasses this policy entirely. It is left open
-- to the trip's starter only, as the counterpart of their power to remove
-- someone: whoever can undo a wrong join can also repair one by hand.
drop policy if exists "trip_members_insert_by_owner" on public.trip_members;
drop policy if exists "trip_members_insert_by_starter" on public.trip_members;
create policy "trip_members_insert_by_starter"
  on public.trip_members for insert
  to authenticated
  with check ( public.is_trip_starter(trip_members.trip_id, auth.uid()) );

-- There is NO update policy, and that is the fix for the privilege
-- escalation. With `role` gone, a membership row is (trip, person, when they
-- joined) and none of the three is a thing anyone should rewrite. No policy
-- means deny-all, so the statement that used to promote a member to owner now
-- matches zero rows however it is spelled.
drop policy if exists "trip_members_update_owner_or_self" on public.trip_members;

-- Anyone can remove themselves (leave the trip). The person who started the
-- trip can also remove someone else -- the one asymmetry in the product, and
-- the undo for a wrong join.
drop policy if exists "trip_members_delete_owner_or_self" on public.trip_members;
drop policy if exists "trip_members_delete_self_or_starter" on public.trip_members;
create policy "trip_members_delete_self_or_starter"
  on public.trip_members for delete
  to authenticated
  using (
    trip_members.user_id = auth.uid()
    or public.is_trip_starter(trip_members.trip_id, auth.uid())
  );

-- ---------------------------------------------------------------------------
-- The trips policies deferred from 0003_trips.sql
-- ---------------------------------------------------------------------------

-- `created_by = auth.uid()` is not redundant with the membership test, and
-- leaving it out broke the first thing the app ever does.
--
-- PostgREST (and therefore supabase-js `.insert()`) issues
-- `insert ... returning *` by default, and RETURNING projects the new row
-- through the SELECT policy. The owner's membership row is created by the
-- AFTER INSERT trigger at the bottom of this file, which has not fired at the
-- moment RETURNING is evaluated -- so a membership-only SELECT policy was
-- false, and "create a trip and read its id back" failed with
-- `new row violates row-level security policy for table "trips"` while having
-- silently created the trip. Testing the creator directly is both the fix and
-- plainly correct on its own terms: you can always see the trip you started.
drop policy if exists "trips_select_member" on public.trips;
create policy "trips_select_member"
  on public.trips for select
  to authenticated
  using (
    trips.created_by = auth.uid()
    or public.is_trip_member(trips.id, auth.uid())
  );

drop policy if exists "trips_insert_self" on public.trips;
create policy "trips_insert_self"
  on public.trips for insert
  to authenticated
  with check (created_by = auth.uid());

-- The trip row is the shared clock and the container every photo hangs off,
-- so it stays with the person who authored it. Flat roles are about what
-- members may do to each other's contributions -- nobody edits anyone else's
-- photos or placements -- not about who may retime the whole trip or delete
-- it out from under eight people. Renaming is the only thing lost by this,
-- and the alternative (any member may edit) puts the one value that must not
-- diverge in eight pairs of hands.
drop policy if exists "trips_update_owner" on public.trips;
drop policy if exists "trips_update_starter" on public.trips;
create policy "trips_update_starter"
  on public.trips for update
  to authenticated
  using (trips.created_by = auth.uid())
  with check (created_by = auth.uid());

drop policy if exists "trips_delete_owner" on public.trips;
drop policy if exists "trips_delete_starter" on public.trips;
create policy "trips_delete_starter"
  on public.trips for delete
  to authenticated
  using (trips.created_by = auth.uid());

-- Whoever creates a trip is automatically a member of it. This is enforced in
-- the database (not left to the client) so "the person who started a trip is
-- on it" holds regardless of how trips get created.
create or replace function public.handle_new_trip()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.trip_members (trip_id, user_id)
  values (new.id, new.created_by)
  on conflict (trip_id, user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_trip_created on public.trips;
create trigger on_trip_created
  after insert on public.trips
  for each row execute function public.handle_new_trip();
