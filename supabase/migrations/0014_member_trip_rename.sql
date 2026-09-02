-- A trip's name is flat: any current member may change it. Everything else
-- on the trip row keeps the protection it had in 0004: only the starter may
-- retime or otherwise rewrite the container, and only the starter may delete
-- it. The split is enforced twice below: RLS admits a member to the UPDATE,
-- and the trigger bounds that member's write to (name, name_revised_at).
--
-- Flat, and still refused once the trip has closed: what a trip was called is
-- part of what it closed as. That refusal is on the *rename*, not on the
-- member path, so it reaches every door -- the trigger asks `trip_closes_at`
-- before it lets even the starter through, and `sync_trip_name` asks again
-- so a closed trip's name is unchanged rather than merely un-returned.

alter table public.trips
  add column if not exists name_revised_at timestamptz;

-- Existing names predate their own clock. `updated_at` is the closest fact
-- the row has to when its current spelling landed, and is only a backfill:
-- after this migration every rename supplies the clock that authored it.
update public.trips
set name_revised_at = updated_at
where name_revised_at is null;

alter table public.trips
  alter column name_revised_at set default now(),
  alter column name_revised_at set not null;

create or replace function public.guard_member_trip_rename()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_closes_at timestamptz;
begin
  -- Migrations and service-role maintenance continue to bypass client RLS
  -- and must not acquire a narrower power through this trigger.
  if current_user <> 'authenticated' then
    return new;
  end if;

  -- A closed trip is the record, and what it was called is part of what it
  -- closed as (`cairn_model`'s `canRenameTrip`). Written twice for the same
  -- reason `sync_trip_itinerary` and `photos_insert_trip_member` are: the
  -- phone refuses first (`TripSync._reconcile` returns `SyncStanding.archived`
  -- before reaching the network) and this is the half that holds when one of
  -- eight phones has a wrong clock.
  --
  -- Asked before the starter is let through, and scoped to a rename rather
  -- than to the whole UPDATE, because both halves of that are the decision.
  -- The starter's `trips_update_starter` path is otherwise exactly as 0004
  -- wrote it -- this adds no condition to retiming or to anything else they
  -- could already do -- but the name is not theirs to change after the close
  -- either, and leaving them a bare PATCH round `sync_trip_name` would have
  -- made the refusal a property of one function instead of a property of the
  -- record. Null is "a trip this caller cannot see", never "never closes".
  if new.name is distinct from old.name
     or new.name_revised_at is distinct from old.name_revised_at then
    v_closes_at := public.trip_closes_at(old.id);
    if v_closes_at is not null and now() >= v_closes_at then
      raise exception 'this trip has closed'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  -- Past the close, the starter's UPDATE policy is unchanged. The rest of
  -- this trigger only narrows the additional path opened to an ordinary
  -- member.
  if public.is_trip_starter(old.id, auth.uid()) then
    return new;
  end if;

  if not public.is_trip_member(old.id, auth.uid()) then
    raise exception 'only a current member may rename this trip'
      using errcode = 'insufficient_privilege';
  end if;

  -- An allowlist, not a denylist, and the direction is the whole point: a
  -- later migration that adds a column to `trips` has no reason to remember
  -- this guard, and an enumerated list of protected columns would hand that
  -- new column to every member silently. Comparing the rows with the three
  -- writable keys removed fails closed instead. `updated_at` is among them
  -- because `trips_touch_updated_at` overwrites it after this trigger runs
  -- (triggers of one timing fire in name order, and `trips_guard_member_rename`
  -- sorts first), so a member cannot author it whatever they send.
  if to_jsonb(new) - 'name' - 'name_revised_at' - 'updated_at'
       is distinct from
     to_jsonb(old) - 'name' - 'name_revised_at' - 'updated_at' then
    raise exception 'a member may rename a trip but may not rewrite its clock or ownership'
      using errcode = 'insufficient_privilege';
  end if;

  if new.name_revised_at <= old.name_revised_at then
    raise exception 'a rename must carry a newer revision'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists trips_guard_member_rename on public.trips;
create trigger trips_guard_member_rename
  before update on public.trips
  for each row execute function public.guard_member_trip_rename();

-- Keep `trips_update_starter` exactly as 0004 defined it. PostgreSQL ORs
-- permissive policies: this second path admits a current member, while the
-- trigger above makes that path name-only. The one thing the trigger takes
-- from the starter's path is a rename after the close, which is a rule about
-- the record rather than a power the starter holds.
drop policy if exists "trips_update_member_rename" on public.trips;
create policy "trips_update_member_rename"
  on public.trips for update
  to authenticated
  using (public.is_trip_member(trips.id, auth.uid()))
  with check (public.is_trip_member(trips.id, auth.uid()));

-- One atomic round trip for the offline last-write-wins rule. The caller's
-- clock is the ordering, exactly as for itinerary days: strictly newer wins;
-- stale input loses and receives the trip's current name back. SECURITY
-- INVOKER is load-bearing, so the UPDATE still passes through the policy and
-- trigger above and a non-member gains nothing by calling the function.
create or replace function public.sync_trip_name(
  p_trip_id uuid,
  p_name text,
  p_name_revised_at timestamptz
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_answer jsonb;
  v_closes_at timestamptz;
begin
  if not public.is_trip_member(p_trip_id, auth.uid()) then
    raise exception 'not a member of this trip'
      using errcode = 'insufficient_privilege';
  end if;

  -- Refused before the UPDATE, so a closed trip's name is unchanged and not
  -- merely un-returned rather than half-written and rolled back. The trigger
  -- refuses the same rename whoever sends it, including through a bare PATCH
  -- that goes round this function; asking here too is what makes the message
  -- the caller sees the function's own.
  v_closes_at := public.trip_closes_at(p_trip_id);
  if v_closes_at is not null and now() >= v_closes_at then
    raise exception 'this trip has closed';
  end if;

  update public.trips
  set name = p_name,
      name_revised_at = p_name_revised_at
  where id = p_trip_id
    and name_revised_at < p_name_revised_at
  returning jsonb_build_object(
    'name', name,
    'name_revised_at', name_revised_at
  ) into v_answer;

  if v_answer is null then
    select jsonb_build_object(
      'name', t.name,
      'name_revised_at', t.name_revised_at
    )
    into v_answer
    from public.trips t
    where t.id = p_trip_id;
  end if;

  if v_answer is null then
    raise exception 'trip not found'
      using errcode = 'no_data_found';
  end if;

  return v_answer;
end;
$$;

revoke all on function public.sync_trip_name(uuid, text, timestamptz) from public;
grant execute on function public.sync_trip_name(uuid, text, timestamptz)
  to authenticated, service_role;
