-- 0013: the tap-to-Maps areas ride the sync.
--
-- 0012 added `kind` / `area_text` / `area_source` to
-- `trip_itinerary_stops` and said, in its own comments, that
-- `sync_trip_itinerary` would gain them when 0012 was deployed. 0012 is
-- deployed (hosted, 2026-08-31); this is that second half. Until it runs,
-- the function from 0010 inserts and returns the old column set, so a stop
-- corrected on one phone is stored with its area stripped on push and
-- handed back without one on pull -- a correction that never leaves the
-- phone that made it.
--
-- Recreated in full rather than patched, per 0012's stated policy: the body
-- below is 0010's verbatim, with the three columns added in exactly two
-- places -- the stops insert list fed from the pushed JSON, and the
-- pull-side `jsonb_build_object`. `create or replace`, so re-applying is a
-- no-op; nothing else in 0010 is touched, and the argument list is
-- unchanged so no `drop function` is needed and no grant is lost.
--
-- Two details that look like nothing and are not:
--
--   * `kind` is `not null default 'place'` on the table, so a push from a
--     phone predating 0012 -- which sends no `kind` key at all -- must not
--     insert a null. `coalesce(s->>'kind', 'place')` says the default in
--     the one place the default cannot apply, because an explicit null in
--     an insert list defeats a column default.
--   * The pull always emits all three keys, including when they are null.
--     That is what `RemoteStop.carriesAreas` reads: the phone treats a stop
--     row with no `area_text` key at all as "this server does not know
--     about areas" and leaves a local correction standing, and a key
--     present with a null value as "this server says there is no area".
--     Dropping a null key here would silently make every clear-an-area
--     unclearable.

create or replace function public.sync_trip_itinerary(
  p_trip_id uuid,
  p_plan_revised_at timestamptz,
  p_days jsonb,
  p_pocket_revised_at timestamptz,
  p_pocket jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_days jsonb := coalesce(p_days, '[]'::jsonb);
  v_pocket jsonb := coalesce(p_pocket, '[]'::jsonb);
  v_plan timestamptz := coalesce(p_plan_revised_at, '-infinity');
  v_pocket_at timestamptz := coalesce(p_pocket_revised_at, '-infinity');
  v_won integer[];
  v_stored_pocket_at timestamptz;
  v_closes_at timestamptz;
  v_result jsonb;
begin
  if not public.is_trip_member(p_trip_id, auth.uid()) then
    raise exception 'not a member of this trip'
      using errcode = 'insufficient_privilege';
  end if;

  -- An archived trip is not reconciled at all -- neither half of the round
  -- trip. The phone refuses first (`TripSync._reconcile` returns
  -- `SyncStanding.archived` before reaching the network), and this is the
  -- other half of that, for the reason `photos_insert_trip_member` has one:
  -- eight phones means one wrong clock, and a phone still running a build
  -- from before the ending would push its plan over a fixed record. Refused
  -- before the first insert below, so a closed trip's plan is unchanged and
  -- not merely un-returned -- and the pull is refused with it, because after
  -- the close there is nothing left to reconcile in either direction.
  v_closes_at := public.trip_closes_at(p_trip_id);
  if v_closes_at is not null and now() >= v_closes_at then
    raise exception 'this trip has closed';
  end if;

  insert into public.trip_itineraries (trip_id, plan_revised_at, pocket_revised_at)
  values (p_trip_id, v_plan, v_pocket_at)
  on conflict (trip_id) do update
    set plan_revised_at = greatest(public.trip_itineraries.plan_revised_at, excluded.plan_revised_at),
        pocket_revised_at = greatest(public.trip_itineraries.pocket_revised_at, excluded.pocket_revised_at);

  -- ---- days: last write wins, per day -------------------------------------
  insert into public.trip_itinerary_days
    (trip_id, day_number, day_date, place, revised_at, revised_by)
  select p_trip_id,
         (d->>'day_number')::integer,
         (d->>'day_date')::date,
         d->>'place',
         (d->>'revised_at')::timestamptz,
         auth.uid()
  from jsonb_array_elements(v_days) d
  on conflict (trip_id, day_number) do update
    set day_date = excluded.day_date,
        place = excluded.place,
        revised_at = excluded.revised_at,
        revised_by = excluded.revised_by
  where excluded.revised_at > public.trip_itinerary_days.revised_at;

  -- The days this push actually won: the ones whose stored revision is now
  -- exactly the one that was pushed. A day the guard above refused keeps its
  -- newer revision, so it is not in this set and its stops are left alone --
  -- which is what makes the day, and not the stop, the merge atom.
  select coalesce(array_agg(t.day_number), '{}')
    into v_won
  from public.trip_itinerary_days t
  join jsonb_array_elements(v_days) d
    on (d->>'day_number')::integer = t.day_number
   and (d->>'revised_at')::timestamptz = t.revised_at
  where t.trip_id = p_trip_id;

  delete from public.trip_itinerary_stops s
  where s.trip_id = p_trip_id
    and s.day_number = any(v_won);

  insert into public.trip_itinerary_stops
    (trip_id, day_number, position, stop_text, time_of_day,
     kind, area_text, area_source)
  select p_trip_id,
         (d->>'day_number')::integer,
         (s->>'position')::integer,
         s->>'stop_text',
         (s->>'time_of_day')::time,
         coalesce(s->>'kind', 'place'),
         s->>'area_text',
         s->>'area_source'
  from jsonb_array_elements(v_days) d
  cross join lateral jsonb_array_elements(coalesce(d->'stops', '[]'::jsonb)) s
  where (d->>'day_number')::integer = any(v_won);

  -- ---- days the push dropped ----------------------------------------------
  --
  -- Absent from the push AND no newer than the pushing phone's view of the
  -- plan's shape. The second half is what the guard actually buys: a phone
  -- that has merely fallen behind -- one that has not reshaped the plan
  -- itself, and so still carries an old plan_revised_at -- cannot delete the
  -- day somebody added this morning simply by not having it.
  --
  -- It is not an unconditional promise, and should not be read as one. The
  -- moment the pushing phone reshapes the plan its own plan_revised_at
  -- becomes now, which is newer than any day it has never heard of, and the
  -- push does delete that day. That is last-write-wins on the plan's shape,
  -- accepted for this slice exactly as it is accepted per day: the phone that
  -- wrote last decides, and a phone that reshapes a plan it has not yet
  -- pulled will drop somebody else's new day.
  delete from public.trip_itinerary_days t
  where t.trip_id = p_trip_id
    and t.revised_at <= v_plan
    and not exists (
      select 1 from jsonb_array_elements(v_days) d
      where (d->>'day_number')::integer = t.day_number
    );

  -- ---- the pocket: one atom, replaced whole -------------------------------
  select i.pocket_revised_at into v_stored_pocket_at
  from public.trip_itineraries i
  where i.trip_id = p_trip_id;

  if v_pocket_at >= coalesce(v_stored_pocket_at, '-infinity') then
    delete from public.trip_itinerary_set_asides a where a.trip_id = p_trip_id;
    insert into public.trip_itinerary_set_asides
      (trip_id, position, source_line_number, line_text, explanation)
    select p_trip_id,
           (l->>'position')::integer,
           (l->>'source_line_number')::integer,
           l->>'line_text',
           l->>'explanation'
    from jsonb_array_elements(v_pocket) l;
  end if;

  -- ---- and hand the merged plan back --------------------------------------
  select jsonb_build_object(
    'plan_revised_at', i.plan_revised_at,
    'pocket_revised_at', i.pocket_revised_at,
    'days', coalesce((
      select jsonb_agg(day order by (day->>'day_number')::integer)
      from (
        select jsonb_build_object(
          'day_number', t.day_number,
          'day_date', t.day_date,
          'place', t.place,
          'revised_at', t.revised_at,
          'stops', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'position', s.position,
                'stop_text', s.stop_text,
                'time_of_day', s.time_of_day,
                'kind', s.kind,
                'area_text', s.area_text,
                'area_source', s.area_source
              ) order by s.position
            )
            from public.trip_itinerary_stops s
            where s.trip_id = t.trip_id and s.day_number = t.day_number
          ), '[]'::jsonb)
        ) as day
        from public.trip_itinerary_days t
        where t.trip_id = p_trip_id
      ) days
    ), '[]'::jsonb),
    'set_asides', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'position', a.position,
          'source_line_number', a.source_line_number,
          'line_text', a.line_text,
          'explanation', a.explanation
        ) order by a.position
      )
      from public.trip_itinerary_set_asides a
      where a.trip_id = p_trip_id
    ), '[]'::jsonb)
  )
  into v_result
  from public.trip_itineraries i
  where i.trip_id = p_trip_id;

  return v_result;
end;
$$;

revoke all on function public.sync_trip_itinerary(uuid, timestamptz, jsonb, timestamptz, jsonb) from public;
grant execute on function public.sync_trip_itinerary(uuid, timestamptz, jsonb, timestamptz, jsonb)
  to authenticated, service_role;
