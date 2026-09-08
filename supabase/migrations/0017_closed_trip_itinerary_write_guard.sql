-- A closed trip's plan is the record -- all four tables of it, not one.
--
-- ---------------------------------------------------------------------------
-- THE GAP
-- ---------------------------------------------------------------------------
--
-- 0016 moved the trip's close onto the itinerary and, because that put the
-- close on a table clients may write, put the refusal on the table too:
-- `trip_itinerary_days_guard_closed_trip` refuses every insert, update and
-- delete on `trip_itinerary_days` once the owning trip has closed. That guard
-- was written for the re-opening attack it names -- date a day forward, watch
-- `greatest` lift the close -- and it covers exactly the table that attack
-- goes through.
--
-- The itinerary is four tables (0010): `trip_itineraries` (the plan's own two
-- revision clocks), `trip_itinerary_days`, `trip_itinerary_stops` and
-- `trip_itinerary_set_asides`. The other three carry no `day_date`, so none of
-- them can move the close -- but "a closed trip's plan is the record" is not a
-- statement about the close, it is a statement about the plan. Until this
-- migration a member of an archived trip could `PATCH
-- /rest/v1/trip_itinerary_stops?trip_id=eq.<t>&day_number=eq.3&position=eq.0`
-- and rewrite what the trip did that afternoon; could empty the set-aside
-- pocket, which is where "nothing the person pasted is ever deleted" is
-- actually kept; or could wind `trip_itineraries.plan_revised_at` forward and
-- make every phone's stored plan lose the next merge it is offered. The days
-- were fixed and everything hanging off them was not, which is the record
-- being half a record.
--
-- 0010's policies on all four tables are plain `is_trip_member` with no close
-- condition, and `sync_trip_itinerary` -- which raises on `trip_closes_at`
-- before its first write -- is not the door: a bare PATCH round it is, exactly
-- as it was for the days.
--
-- ---------------------------------------------------------------------------
-- ONE BODY, FOUR TABLES
-- ---------------------------------------------------------------------------
--
-- 0016's guard reads nothing but `trip_id`, which every one of the four tables
-- carries, so the rule is already table-agnostic and the only table-specific
-- thing about it was its name. Rather than stamp three more copies of a body
-- whose subtleties are all load-bearing -- the `current_user` branch, the
-- DELETE-with-no-parent branch, the BEFORE ROW timing -- this renames it to
-- what it always was and hangs all four triggers off the one function. A
-- second copy of this rule is the thing to refuse in review.
--
-- The trigger on `trip_itinerary_days` keeps its name
-- (`trip_itinerary_days_guard_closed_trip`); only what it executes changes,
-- and it changes to the same statements. The three new triggers are named the
-- same way, per table.
--
-- Both allowing branches matter more here than they did on the days, not less:
--
--   * `trip_itinerary_stops` hangs off `trip_itinerary_days` by `on delete
--     cascade`, so the merge's own day deletion on an OPEN trip arrives at the
--     stops' trigger as a cascade -- run under the referencing table's owner,
--     not `authenticated`, so the first branch returns before any derivation
--     runs. An open trip is unaffected either way (its close has not passed),
--     but the cascade path is the one that must not acquire a narrower power
--     through a trigger, and it does not.
--   * Deleting a closed trip still works, for both reasons 0016 measured: the
--     cascade runs as the table owner, and the `trips` row is already gone so
--     the derivation is null. That holds for all four tables, and
--     `trip_itinerary_stops` reaches it through two cascades rather than one
--     (`trips` -> `trip_itinerary_days` -> `trip_itinerary_stops`).
--
-- One of the twelve write paths this covers is already shut by RLS and is
-- covered anyway: `trip_itineraries` has a SELECT, an INSERT and an UPDATE
-- policy in 0010 and no DELETE policy at all, so a client's delete is filtered
-- to zero rows and never reaches the trigger. The trigger takes DELETE on it
-- regardless, because a missing policy is a thing a later migration adds and
-- the guard should not have to be remembered when it does. `rls_probe.py`
-- asserts that path on the row's survival rather than on the refusal, so the
-- distinction stays visible.
--
-- The cost is unchanged in kind and larger in count: the derivation is now
-- asked once per itinerary ROW written rather than once per day, so pushing a
-- fourteen-day plan with a hundred stops asks it a hundred and fourteen times
-- instead of fourteen. It is the same index-only one-row read
-- (`trip_itinerary_days_day_date_idx`, 0016) that
-- `photos_insert_trip_member`'s WITH CHECK already makes per photograph, and
-- `rls_probe.py` plans it as a member.
--
-- No app change: the message and code are still `sync_trip_itinerary`'s own
-- ('this trip has closed', P0001), which the phone already reads as
-- `SyncStanding.refused`.

-- The body is 0016's, unchanged in every line that decides anything. Read that
-- migration's comment for why each branch is there; this one only widens where
-- it is asked.
create or replace function public.guard_closed_trip_itinerary_write()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_trip_id uuid;
  v_closes_at timestamptz;
begin
  -- Migrations and service-role maintenance continue to bypass client RLS and
  -- must not acquire a narrower power through this trigger. This is also the
  -- branch every `on delete cascade` into these tables takes, because
  -- referential-integrity triggers run as the referencing table's owner.
  if current_user <> 'authenticated' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  -- `new` is unassigned on DELETE in PL/pgSQL, so this cannot be a coalesce
  -- over both.
  if tg_op = 'DELETE' then
    v_trip_id := old.trip_id;
  else
    v_trip_id := new.trip_id;
  end if;

  v_closes_at := public.trip_closes_at(v_trip_id);
  if v_closes_at is not null and now() >= v_closes_at then
    raise exception 'this trip has closed';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- The days' trigger is re-pointed rather than left beside a duplicate: same
-- name, same timing, same statements, same body.
drop trigger if exists trip_itinerary_days_guard_closed_trip
  on public.trip_itinerary_days;
create trigger trip_itinerary_days_guard_closed_trip
  before insert or update or delete on public.trip_itinerary_days
  for each row execute function public.guard_closed_trip_itinerary_write();

drop trigger if exists trip_itineraries_guard_closed_trip
  on public.trip_itineraries;
create trigger trip_itineraries_guard_closed_trip
  before insert or update or delete on public.trip_itineraries
  for each row execute function public.guard_closed_trip_itinerary_write();

drop trigger if exists trip_itinerary_stops_guard_closed_trip
  on public.trip_itinerary_stops;
create trigger trip_itinerary_stops_guard_closed_trip
  before insert or update or delete on public.trip_itinerary_stops
  for each row execute function public.guard_closed_trip_itinerary_write();

drop trigger if exists trip_itinerary_set_asides_guard_closed_trip
  on public.trip_itinerary_set_asides;
create trigger trip_itinerary_set_asides_guard_closed_trip
  before insert or update or delete on public.trip_itinerary_set_asides
  for each row execute function public.guard_closed_trip_itinerary_write();

-- Nothing references 0016's name any more. Dropped rather than left behind, so
-- a later reader cannot attach a fifth trigger to the copy that stopped being
-- maintained. The probe applies every migration twice, so 0016 will recreate
-- it on the second pass and this will drop it again -- which is exactly the
-- state a single pass leaves, and is why the drop is guarded.
drop function if exists public.guard_closed_trip_itinerary_day();
