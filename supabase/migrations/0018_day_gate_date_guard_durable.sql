-- Close the two remaining date-guard bypasses: deleting a day and
-- re-inserting it, and moving a future date earlier while it is still
-- future. Both reach the same forgery 0015's guard exists to refuse --
-- the walked branch opening before the date the day used to carry has
-- passed -- without taking the one path 0015 watches. Closing them durably
-- also means the guard must hang off the trip rather than the day row, the
-- recording trigger must fire on delete and on every update (not only one
-- that touches `day_date`, since a day-number move vacates its old number
-- just as a delete does), and the gate must keep asking the guard about a
-- day number the plan no longer claims rather than exempting it. A hold is
-- also capped at the trip's own derived close (`trip_closes_at`, `0016`), so
-- an ordinary edit that shifts a whole plan earlier -- or corrects a mistyped
-- far-future date -- cannot lock a day shut for longer than the trip already
-- lasts. This is a forward migration; every earlier migration is a recorded
-- fact and stays byte-for-byte unchanged.

-- ---------------------------------------------------------------------------
-- The guard outlives the day row it was recorded for
-- ---------------------------------------------------------------------------
--
-- 0015 hung `day_gate_date_guards` off `trip_itinerary_days` with `on delete
-- cascade`, and recorded it only from an UPDATE of `day_date`. So deleting the
-- day -- an ordinary plan edit any member may make -- swept the guard away, and
-- re-inserting the same day number dated in the past (or not at all) reached
-- the permissive "walked" branch with nothing left to hold it shut. The guard
-- is a fact about a date the day used to carry, not about the row's current
-- existence, so it now hangs off the trip instead: deleting a trip still sweeps
-- its guards, deleting a day no longer can.
alter table public.day_gate_date_guards
  drop constraint if exists day_gate_date_guards_trip_id_day_number_fkey;
alter table public.day_gate_date_guards
  drop constraint if exists day_gate_date_guards_trip_id_fkey;
alter table public.day_gate_date_guards
  add constraint day_gate_date_guards_trip_id_fkey
  foreign key (trip_id) references public.trips (id) on delete cascade;

-- ---------------------------------------------------------------------------
-- Every earlier date move, and every way a row stops claiming its day
-- ---------------------------------------------------------------------------
--
-- The recording rule widens in three directions, and none changes what the
-- gate already refused -- each only reaches a forgery the old condition let
-- past:
--
--   * An earlier move: the old condition recorded a guard only when the new
--     date fell into the past or to null. Moving a future date *earlier
--     while it is still future* recorded nothing, so the day opened at its
--     shortened date -- before the date it previously carried had passed.
--     The rule is now every earlier move of a day that was current or
--     future; a later move needs no guard, because the walked branch cannot
--     open early on a date that has not arrived.
--   * DELETE: the trigger never fired at all, so a delete plus a re-insert
--     was an UPDATE-shaped edit that skipped the guard entirely. A day
--     deleted while still current or future now records its date, which is
--     what the re-insert then finds. Deleting an already-past or undated day
--     records nothing: those were permissive before the delete and stay
--     permissive.
--   * A day-number move: firing only on an UPDATE of `day_date` let a write
--     that changed `day_number` alone through untouched -- the row stops
--     claiming its old day number, exactly as a delete does, and needs the
--     same guard on the number and date it is leaving. So the trigger fires
--     on every UPDATE, not only one that touches `day_date`, and a
--     day-number change is treated as vacating the old number regardless of
--     what date rides along with it.
--   * A trip move: `trip_itinerary_days.trip_id` is refused below, the way
--     `photos_lock_trip_id` and `day_pages_lock_trip_id` already refuse it,
--     so this branch is never reached through the lock. It is written anyway,
--     because a row that leaves its trip has vacated `(trip_id, day_number)`
--     exactly as a delete has, and a recording rule that depends on another
--     trigger's presence is one dropped trigger away from the forgery.
--
-- A hold is capped at the trip's own close (`trip_closes_at`, `0016`), never
-- at the raw date the day used to carry. Review of an earlier draft found the
-- uncapped version had a real cost: moving a whole plan a week earlier, or
-- correcting a mistyped year, rewrites every day's `day_date` downward in one
-- `sync_trip_itinerary` upsert, so the trigger fires once per day and records
-- `not_before = <the old date>` for every one of them -- and because a hold
-- only ever grows, none of that is repairable by any later edit. A far-future
-- typo (`2127`) corrected back would have locked its day for a hundred years.
-- Capping at the close means the worst a hold can do is what deleting the
-- trip already does -- shut every day until the trip's own end, never longer
-- -- while the two bypasses this migration exists to close
-- (delete-then-reinsert, shorten-while-future) are unaffected: both move a
-- day to a date nearer to today, well inside the trip's own close.
--
-- The cap applies to the hold being *written*, never to one already standing.
-- This trigger fires AFTER ROW, so `v_close_date` is the close as it stands
-- after the edit -- which the same edit may have depressed, since the close
-- follows the plan's furthest date down to the `trips.end_date` floor. A
-- conflict update that re-capped the standing hold at that close
-- (`least(greatest(old, new), close)`) let a member walk a recorded hold
-- down: shorten the furthest day first, then touch the guarded day again, and
-- the hold followed the close it had just lowered. So the update is
-- `greatest(standing, least(new, close))`: the new hold is capped, and the
-- result never falls below what was already recorded. `tests/rls_probe.py`
-- pins that on the capped path specifically, and `supabase/README.md`'s gate
-- section states the bound and its residual edge.
--
-- The trip lookup deliberately happens first and may find nothing: when a trip
-- is deleted, its rows cascade and the trip is already gone by the time this
-- runs, so no guard is written for a trip that no longer exists -- the
-- foreign key above would refuse it anyway, and the trip's own cascade sweeps
-- whatever earlier edits left.
create or replace function public.record_day_gate_date_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date;
  v_close_date date;
  v_vacated boolean := false;
begin
  if tg_op = 'UPDATE'
     and new.trip_id is not distinct from old.trip_id
     and new.day_number is not distinct from old.day_number
     and new.day_date is not distinct from old.day_date then
    return new;
  end if;

  select (now() at time zone t.timezone)::date,
         (public.trip_closes_at(t.id) at time zone t.timezone)::date
    into v_today, v_close_date
    from public.trips t
   where t.id = old.trip_id;

  if v_today is not null
     and old.day_date is not null
     and old.day_date >= v_today then
    if tg_op = 'DELETE' then
      v_vacated := true;
    elsif new.trip_id is distinct from old.trip_id then
      v_vacated := true;
    elsif new.day_number is distinct from old.day_number then
      v_vacated := true;
    elsif new.day_date is null or new.day_date < old.day_date then
      v_vacated := true;
    end if;
  end if;

  if v_vacated then
    insert into public.day_gate_date_guards (trip_id, day_number, not_before)
    values (old.trip_id, old.day_number, least(old.day_date, v_close_date))
    on conflict (trip_id, day_number) do update
      set not_before = greatest(
        public.day_gate_date_guards.not_before,
        least(excluded.not_before, v_close_date)
      );
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists trip_itinerary_days_record_gate_date_guard
  on public.trip_itinerary_days;
create trigger trip_itinerary_days_record_gate_date_guard
  after update or delete on public.trip_itinerary_days
  for each row execute function public.record_day_gate_date_guard();

-- ---------------------------------------------------------------------------
-- A day stays in the trip where it was planned
-- ---------------------------------------------------------------------------
--
-- `0010`'s UPDATE policy admits any trip the caller belongs to on both sides,
-- so a member of two trips could move a current or future day of one into
-- the other: the row stops claiming `(trip_id, day_number)` exactly as a
-- delete does, and a re-insert under the vacated key would then find no
-- guard. The app never moves a day between trips -- `sync_trip_itinerary`
-- upserts on `(trip_id, day_number)` -- so the write is refused outright.
-- Same shape as `photos_lock_trip_id` (`0006`) and `day_pages_lock_trip_id`
-- (`0015`): WITH CHECK sees only the proposed row, so immutability belongs in
-- a BEFORE UPDATE trigger comparing old and new. It fires before the
-- recording trigger above, which still treats a trip change as vacating in
-- case this lock is ever dropped.
create or replace function public.trip_itinerary_days_lock_trip_id()
returns trigger
language plpgsql
as $$
begin
  if new.trip_id is distinct from old.trip_id then
    raise exception 'trip_itinerary_days.trip_id cannot be changed once set';
  end if;
  return new;
end;
$$;

drop trigger if exists trip_itinerary_days_lock_trip_id
  on public.trip_itinerary_days;
create trigger trip_itinerary_days_lock_trip_id
  before update on public.trip_itinerary_days
  for each row execute function public.trip_itinerary_days_lock_trip_id();

-- ---------------------------------------------------------------------------
-- The walked branch still asks the guard about a day the plan no longer claims
-- ---------------------------------------------------------------------------
--
-- Deleting a day now leaves a guard behind, and an earlier draft of this
-- migration opened any absent day number *before* consulting it -- an
-- explicit `not exists (day row)` branch that let a delete-then-reinsert walk
-- straight past the very guard the delete had just recorded. There is no such
-- branch: an absent day still asks the guard, exactly as 0015 already did,
-- through the same `coalesce(..., true)` that reads a missing day's date as
-- "before today" once there is no guard row to hold it. A day number the plan
-- has never claimed still opens, because nothing has ever recorded a guard
-- for it -- the permissive property is preserved by the absence of a guard
-- row, not by a shortcut around the guard check.
--
-- The body below is byte-for-byte unchanged from 0015's: this `create or
-- replace` exists only to re-validate it against the post-0017 schema (the
-- `language sql` double-apply trap `AGENTS.md` describes), and to give the
-- comment above it somewhere to live.
create or replace function public.day_page_is_open(
  p_trip_id uuid,
  p_day_number integer,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with clock as (
    select (now() at time zone t.timezone)::date as today
      from public.trips t
     where t.id = p_trip_id
  )
  select public.is_trip_member(p_trip_id, p_user_id)
    and (
      (
        coalesce(
          (select d.day_date
             from public.trip_itinerary_days d
            where d.trip_id = p_trip_id
              and d.day_number = p_day_number)
          < (select today from clock),
          true
        )
        and not exists (
          select 1
            from public.day_gate_date_guards g
           where g.trip_id = p_trip_id
             and g.day_number = p_day_number
             and g.not_before >= (select today from clock)
        )
      )
      or exists (
        select 1
          from public.day_unlocks u
         where u.trip_id = p_trip_id
           and u.day_number = p_day_number
           and u.user_id = p_user_id
      )
    );
$$;
