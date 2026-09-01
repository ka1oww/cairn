-- A trip's name is flat: any current member may change it. Everything else
-- on the trip row keeps the protection it had in 0004: only the starter may
-- retime or otherwise rewrite the container, and only the starter may delete
-- it. The split is enforced twice below: RLS admits a member to the UPDATE,
-- and the trigger bounds that member's write to (name, name_revised_at).

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
begin
  -- Migrations and service-role maintenance continue to bypass client RLS
  -- and must not acquire a narrower power through this trigger.
  if current_user <> 'authenticated' then
    return new;
  end if;

  -- The starter's UPDATE policy is unchanged. This trigger only narrows the
  -- additional path opened to an ordinary member.
  if public.is_trip_starter(old.id, auth.uid()) then
    return new;
  end if;

  if not public.is_trip_member(old.id, auth.uid()) then
    raise exception 'only a current member may rename this trip'
      using errcode = 'insufficient_privilege';
  end if;

  if new.id is distinct from old.id
     or new.created_by is distinct from old.created_by
     or new.timezone is distinct from old.timezone
     or new.country is distinct from old.country
     or new.city is distinct from old.city
     or new.start_date is distinct from old.start_date
     or new.end_date is distinct from old.end_date
     or new.ping_window_start is distinct from old.ping_window_start
     or new.ping_window_end is distinct from old.ping_window_end
     or new.created_at is distinct from old.created_at then
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
-- trigger above makes that path name-only.
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
begin
  if not public.is_trip_member(p_trip_id, auth.uid()) then
    raise exception 'not a member of this trip'
      using errcode = 'insufficient_privilege';
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
