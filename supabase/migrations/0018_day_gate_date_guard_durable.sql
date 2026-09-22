-- Close the two remaining date-guard bypasses: deleting a day and
-- re-inserting it, and moving a future date earlier while it is still
-- future. Both reach the same forgery 0015's guard exists to refuse --
-- the walked branch opening before the date the day used to carry has
-- passed -- without taking the one path 0015 watches. This is a forward
-- migration; every earlier migration is a recorded fact and stays
-- byte-for-byte unchanged.

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
-- Every earlier date move, and the delete that stands in for one
-- ---------------------------------------------------------------------------
--
-- The recording rule widens in two directions, and neither changes what the
-- gate already refused -- both only reach the forgeries the old condition let
-- past:
--
--   * UPDATE: the old condition recorded a guard only when the new date fell
--     into the past or to null. Moving a future date *earlier while it is
--     still future* recorded nothing, so the day opened at its shortened date
--     -- before the date it previously carried had passed. The rule is now
--     every earlier move of a day that was current or future; a later move
--     needs no guard, because the walked branch cannot open early on a date
--     that has not arrived.
--   * DELETE: the trigger never fired, so a delete plus a re-insert was an
--     UPDATE-shaped edit that skipped the guard entirely. A day deleted while
--     still current or future now records its date, which is what the re-insert
--     then finds. Deleting an already-past or undated day records nothing:
--     those were permissive before the delete and stay permissive.
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
begin
  select (now() at time zone t.timezone)::date
    into v_today
    from public.trips t
   where t.id = old.trip_id;

  if tg_op = 'DELETE' then
    if v_today is not null
       and old.day_date is not null
       and old.day_date >= v_today then
      insert into public.day_gate_date_guards (trip_id, day_number, not_before)
      values (old.trip_id, old.day_number, old.day_date)
      on conflict (trip_id, day_number) do update
        set not_before = greatest(
          public.day_gate_date_guards.not_before,
          excluded.not_before
        );
    end if;
    return old;
  end if;

  if new.day_date is not distinct from old.day_date then
    return new;
  end if;

  if v_today is not null
     and old.day_date is not null
     and old.day_date >= v_today
     and (new.day_date is null or new.day_date < old.day_date) then
    insert into public.day_gate_date_guards (trip_id, day_number, not_before)
    values (old.trip_id, old.day_number, old.day_date)
    on conflict (trip_id, day_number) do update
      set not_before = greatest(
        public.day_gate_date_guards.not_before,
        excluded.not_before
      );
  end if;

  return new;
end;
$$;

drop trigger if exists trip_itinerary_days_record_gate_date_guard
  on public.trip_itinerary_days;
create trigger trip_itinerary_days_record_gate_date_guard
  after update of day_date or delete on public.trip_itinerary_days
  for each row execute function public.record_day_gate_date_guard();

-- ---------------------------------------------------------------------------
-- The walked branch asks the guard only about a day the plan still claims
-- ---------------------------------------------------------------------------
--
-- Deleting a day now leaves a guard behind, and the guard must not shut a day
-- number the plan no longer claims: an absent day reads as walked to the phone
-- (`lib/app_state/day_gate.dart`) and to this function before 0018, and
-- photographs already filed under that day number stay in the pool. What the
-- guard is for is the opposite state -- the plan claiming a day whose date is
-- past or open -- which is exactly the state a delete-then-reinsert leaves
-- behind, and there the guard holds exactly as it did for a re-dated day.
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
      not exists (
        select 1
          from public.trip_itinerary_days d
         where d.trip_id = p_trip_id
           and d.day_number = p_day_number
      )
      or (
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
