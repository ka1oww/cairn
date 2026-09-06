-- The trip's close follows the itinerary, not a snapshot frozen at first sync.
--
-- ---------------------------------------------------------------------------
-- THE DEFECT
-- ---------------------------------------------------------------------------
--
-- `trips.start_date`, `trips.end_date` and `trips.timezone` are written
-- exactly once, by `_createSharedTrip` in
-- `lib/repositories/itinerary_sync.dart`. `TripSync._reconcile` reconciles the
-- name and the roster and never sends the dates again, so `trips.end_date` is
-- the plan as it stood the first time the trip reached the server and nothing
-- afterwards moves it.
--
-- The itinerary does move. `sync_trip_itinerary` merges `trip_itinerary_days`
-- per day (0010), and a day's `day_date` is exactly the thing a person changes
-- when the trip is postponed, extended or cut short -- which is an ordinary
-- thing to do, and which the paste flow supports by design.
--
-- `trip_closes_at` read the frozen column. So a trip postponed by a week after
-- first sync stayed live on every phone and was refused by the server from the
-- OLD last day plus the grace onward: no itinerary push, no photograph, no
-- join, no rename. Four gates, one wrong date, and a P0001 the person can do
-- nothing about. The four are `sync_trip_itinerary` (0010),
-- `photos_insert_trip_member` (0006), `redeem_trip_invite` (0005) and
-- `guard_member_trip_rename` / `sync_trip_name` (0014) -- and all four already
-- asked the same function, which is why this is one migration and no app
-- change. `r2-upload-url`'s `index.ts` calls the same function over RPC and
-- inherits the repair with them.
--
-- ---------------------------------------------------------------------------
-- THE RULE, AND WHY IT IS THE PHONE'S RULE
-- ---------------------------------------------------------------------------
--
-- `cairn_model`'s `tripEndsAtFrom` is the phone's half and has always read the
-- plan rather than a snapshot: **a trip ends at the end of its last day**, the
-- last entry of the plan's own days in plan order, and a last day with no date
-- is an ending nobody knows yet. This migration says the same sentence in SQL
-- over `trip_itinerary_days`, so the seam has one rule written twice and not
-- two rules that disagree -- the same shape `trip_grace_after_end()` and
-- `graceAfterATrip` already have, and the same shape `day_page_is_open` and
-- `GateState.decide` have.
--
-- The one place the two halves cannot say the same thing is the unknown
-- ending. The phone reads an unknown ending as `TripStanding.underway` -- open
-- forever, which is harmless on a screen. The server cannot: an unbounded
-- close is an invite code that never dies, and a code outliving its trip opens
-- the whole archive to whoever still remembers three words
-- (`docs/decisions/2026-08-22-grill-round-one.md` section 5). So the server
-- keeps the only calendar fact it has left underneath the plan, and that
-- choice is written out rather than left to be discovered:
--
--     THE PLAN'S LAST DAY IS THE LATER OF THE FURTHEST DATE THE ITINERARY
--     STATES AND `trips.end_date`.
--
-- Always, for every trip, with no condition on the plan at all. `greatest`
-- ignores nulls in Postgres, which is the mechanism: a plan that states no
-- date anywhere falls through to `trips.end_date` alone. Bounded, never
-- unbounded, and never earlier than the window the trip already had.
--
-- `trips.end_date` is therefore an UNCONDITIONAL FLOOR under the derivation,
-- not a fallback the plan can withdraw. Two invariants come out of that, and
-- together they are the point of the whole design:
--
--     THE SERVER'S CLOSE IS NEVER EARLIER THAN THE PHONE'S ENDING.
--     THE SERVER'S CLOSE IS NEVER EARLIER THAN THE CLOSE BEFORE THIS MIGRATION.
--
-- The first is what makes a trip a phone draws as live never one the server
-- refuses; losing it is how the defect above felt to a person. The second is
-- what makes every close-move REPAIRABLE, and it is the reason the floor is
-- unconditional rather than withdrawn whenever the plan states its own end.
-- `sync_trip_itinerary` asks `trip_closes_at` at the top of the function,
-- before it merges a single day. So if a phone pushed a plan whose last day
-- landed in the past -- a year mis-typed on day one, which `setDayDate`'s fill
-- then carries down every day after it -- and the close followed the plan
-- down, that push would succeed against the still-open stored plan and every
-- push afterwards would be refused, including another phone's correction.
-- Delete-and-repaste would be the only way back, which is the recovery this
-- work exists to avoid. With the floor unconditional the server is never more
-- closed than it was before 0016, so a correcting push always gets through.
--
-- The cost of that, stated plainly and not buried: A PLAN THAT IS SHORTENED NO
-- LONGER CLOSES THE TRIP EARLIER. The close follows the plan upward only.
-- Shortening is deliberately not supported by this derivation, because letting
-- the close move earlier is the same one-way door -- there is no way to tell a
-- plan somebody shortened on purpose from a plan somebody mis-dated, and only
-- one of those two is recoverable once the gate has shut. A trip cut short
-- keeps the window its frozen `end_date` already gave it and closes there.
--
-- The floor is also what makes this migration need no backfill and survive a
-- live trip: every trip that has never synced an itinerary, and every trip
-- mid-flight, keeps exactly the answer it had until its own plan says a later
-- one.
--
-- What this does hand a member is the ability to move the close LATER by
-- editing the plan, since editing the plan is flat (0010's policies) and
-- always has been. That is the decision, not an oversight: the plan is the
-- trip, and the person who can postpone the trip is the person who can
-- postpone the trip.
--
-- ---------------------------------------------------------------------------
-- THE ZONE, STATED
-- ---------------------------------------------------------------------------
--
-- The derived date is resolved in **`trips.timezone`** -- the trip's own IANA
-- clock, checked against `pg_timezone_names` where it is written (0003) -- and
-- in nothing else. Not UTC, because a trip's last day ends at midnight where
-- its travellers are and a UTC midnight would close a Tokyo trip nine hours
-- early. Not the caller's `TimeZone` GUC, because eight phones dial in from
-- eight zones and the trip has one ending, not eight.
--
-- `trip_itinerary_days` deliberately carries no zone of its own: the phone can
-- hold a per-day clock and `trips` holds one for the trip (0003's comment, and
-- `TripDay.sequence` on the phone's side). Reading the day's date and the
-- trip's zone is therefore the same approximation `0005` already made, applied
-- to a date that is now allowed to move.

-- ---------------------------------------------------------------------------
-- The access path
-- ---------------------------------------------------------------------------
--
-- `trip_closes_at` is called inside `photos_insert_trip_member`'s WITH CHECK,
-- so it runs once per photograph inserted. The derivation reads
-- `trip_itinerary_days` once -- `max(day_date)` filtered on `trip_id` -- and
-- the index below is what turns that into an index-only scan over one trip's
-- days instead of a scan of every trip's.
--
-- Without the index the primary key still confines the scan to the trip (its
-- leading column is `trip_id`), so this is a narrowing rather than a rescue --
-- but the aggregate reads every day of the trip through the heap to get there,
-- and a `max` deserves the one row it is entitled to.
--
-- The other read of this table on the ending's path is not the derivation's:
-- the plan's last day *in plan order* is `(trip_id, day_number desc) limit 1`,
-- the primary key walked backwards, and it is what the phone's half compares
-- against. The probe plans both.
create index if not exists trip_itinerary_days_day_date_idx
  on public.trip_itinerary_days (trip_id, day_date);

-- The last calendar date the trip's plan is known to run to, or null for a
-- trip this caller cannot see.
--
-- Split out of `trip_closes_at` rather than inlined into it so that the two
-- halves of the ending can be read -- and asserted -- separately: this is
-- "where does the plan end", and `trip_closes_at` is "and then the grace".
create or replace function public.trip_last_planned_day(p_trip_id uuid)
returns date
language sql
stable
as $$
  select greatest(
    -- The furthest date the itinerary states. Null when it states none.
    (select max(d.day_date)
       from public.trip_itinerary_days d
      where d.trip_id = t.id),
    -- The floor, unconditionally. `trips.end_date` is not null (0003), so the
    -- close can never fall below the one this migration replaced, and a
    -- mis-dated plan is always repairable by a later push.
    t.end_date
  )
  from public.trips t
  where t.id = p_trip_id;
$$;

-- Same narrowing as `trip_closes_at` below, and for the same reason: this one
-- reads `trips` and `trip_itinerary_days`, so it is left to signed-in callers
-- and those tables' own row-level security decides what they see. Both tables
-- gate SELECT on `is_trip_member`, so a caller who cannot see the trip cannot
-- see its days either and gets null from both arms -- "a trip this caller
-- cannot see", never "never closes", exactly as before.
revoke all on function public.trip_last_planned_day(uuid) from public;
grant execute on function public.trip_last_planned_day(uuid) to authenticated, service_role;

-- The instant a trip stops accepting new contributions, and with it the
-- instant its invite codes stop opening anything.
--
-- Unchanged in shape from 0005 -- the last day ends at the next midnight in
-- the trip's own clock, and the grace follows -- and changed in exactly one
-- input: the last day is now the plan's, not the snapshot's. Everything that
-- asked this function keeps asking it and needs no edit.
--
-- Null for a trip this caller cannot see, which is not the same as "never
-- expires" and is never read as one.
create or replace function public.trip_closes_at(p_trip_id uuid)
returns timestamptz
language sql
stable
as $$
  select ((public.trip_last_planned_day(t.id) + 1)::timestamp at time zone t.timezone)
         + public.trip_grace_after_end()
  from public.trips t
  where t.id = p_trip_id;
$$;

revoke all on function public.trip_closes_at(uuid) from public;
grant execute on function public.trip_closes_at(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- A CLOSED TRIP'S PLAN IS THE RECORD, AND THAT IS A PROPERTY OF THE RECORD
-- ---------------------------------------------------------------------------
--
-- Tying the close to `trip_itinerary_days` puts it on a table clients may
-- write. 0010's four policies there are plain `is_trip_member` with no close
-- condition, because until now the close could not be moved from that table at
-- all -- it was a pure function of columns only the starter could write. It can
-- be now, so the refusal has to move with it: a member of a closed trip could
-- otherwise `PATCH /rest/v1/trip_itinerary_days?trip_id=eq.<t>&day_number=eq.3`
-- with a future date, watch `greatest` lift the close, and re-open an archived
-- record -- photographs on to it, pushes accepted again, the name changeable,
-- and an invite code minted before the close (which has no `expires_at` and
-- dies only at `trip_closes_at`) admitting a stranger to the whole archive,
-- which is what `docs/decisions/2026-08-22-grill-round-one.md` section 5 exists
-- to prevent.
--
-- So the refusal sits on the table, exactly as 0014 put the rename's refusal on
-- `trips` rather than inside `sync_trip_name`: a bare PATCH round
-- `sync_trip_itinerary` is refused with it, and the rule is a property of the
-- record instead of a property of one function. `sync_trip_itinerary` is
-- SECURITY INVOKER, so it passes through this trigger and an open trip is
-- unaffected -- including the merge's own day deletions.
--
-- BEFORE ROW is the whole mechanism: the trigger sees the close as it stood
-- *before* this write, so a trip that has already closed is refused while a
-- trip that is still open is left alone, whatever the write would do to the
-- close afterwards. The message and code are `sync_trip_itinerary`'s own
-- ('this trip has closed', P0001) so the phone's existing handling --
-- `SyncStanding.refused` -- is unchanged and no app change is needed.
--
-- Two branches allow rather than refuse, and neither is obvious.
--
--   * **A null close allows.** `trips.id` is guaranteed by this table's own
--     foreign key, so null means the caller cannot see the trip (RLS) rather
--     than "never closes"; the SELECT policy already refuses them, and
--     refusing here as well would invent a failure mode 0005's readers never
--     had.
--   * **A DELETE whose parent trip is already gone allows**, which is what
--     keeps `canDeleteTrip` working. Discarding a record is not editing it
--     (`trip_powers.dart`, and `docs/decisions/2026-08-26-the-ending.md`), and
--     the starter may delete a *closed* trip -- but `trip_itinerary_days` goes
--     by `on delete cascade`, so that deletion arrives here as a DELETE on a
--     closed trip, which is the one shape this trigger exists to refuse. Two
--     independent things let it through, and both were measured rather than
--     assumed: PostgreSQL's referential-integrity trigger switches to the
--     referencing table's owner before it runs the cascade, so `current_user`
--     is no longer `authenticated` and the first branch returns; and the
--     `trips` row is already gone by then, so the derivation is null anyway.
--     Either alone would do. This is written down because the next reader
--     will otherwise take both branches for dead code and tidy one away.
--
-- The cost, plainly: this runs once per row on the itinerary merge's own write
-- path, so pushing a fourteen-day plan asks the derivation fourteen times. It
-- is the same one-row read `photos_insert_trip_member` already makes per
-- photograph, over the same index this migration adds, and `rls_probe.py`
-- plans the trigger's own read as a member alongside the other two.
create or replace function public.guard_closed_trip_itinerary_day()
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
  -- must not acquire a narrower power through this trigger. 0014's guard opens
  -- the same way, and for the same reason.
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

drop trigger if exists trip_itinerary_days_guard_closed_trip
  on public.trip_itinerary_days;
create trigger trip_itinerary_days_guard_closed_trip
  before insert or update or delete on public.trip_itinerary_days
  for each row execute function public.guard_closed_trip_itinerary_day();
