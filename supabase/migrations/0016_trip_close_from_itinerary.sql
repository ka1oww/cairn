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
-- bounds the unknown case with the only calendar fact it has left, and that
-- choice is written out rather than left to be discovered:
--
--   * **when the itinerary's last day carries a date**, that is the plan
--     stating its own end and it is authoritative in both directions -- a
--     postponed or extended plan closes later, a shortened one closes earlier;
--   * **when it does not** (a wholly undated plan, an undated tail, or a trip
--     whose itinerary has not reached the server at all), the close falls back
--     to whichever is later of the furthest date the itinerary does state and
--     `trips.end_date`. Never unbounded, and never earlier than the window
--     that trip already had.
--
-- That fallback is what makes the invariant below true, and the invariant is
-- the point of the whole design:
--
--     THE SERVER'S CLOSE IS NEVER EARLIER THAN THE PHONE'S ENDING.
--
-- A trip a phone draws as live is never one the server refuses. Losing that is
-- how the defect above felt to a person, and it is the thing to refuse in
-- review.
--
-- It is also why the fallback is a *floor* rather than a replacement.
-- `greatest` ignores nulls in Postgres -- the opposite of `+` -- so a trip with
-- no itinerary rows falls through to `trips.end_date` alone and closes exactly
-- where it closed before this migration. That is deliberate, and it is what
-- makes this migration need no backfill and survive a live trip: every trip
-- that has never synced an itinerary, and every trip mid-flight, keeps the
-- answer it had until its own plan says otherwise.
--
-- What this does hand a member is the ability to move the close by editing the
-- plan, since editing the plan is flat (0010's policies) and always has been.
-- That is the decision, not an oversight: the plan is the trip, and the person
-- who can postpone the trip is the person who can postpone the trip.
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
-- `trip_itinerary_days` twice: the furthest date the plan states, and whether
-- the highest-numbered day carries one.
--
--   * the second reads `(trip_id, day_number desc) limit 1`, which is the
--     table's primary key walked backwards -- one row, no sort;
--   * the first is `max(day_date)` filtered on `trip_id`, and the index below
--     is what turns it into an index-only scan over that one trip's days
--     instead of a scan of every trip's.
--
-- Without the index the primary key still confines the scan to the trip (its
-- leading column is `trip_id`), so this is a narrowing rather than a rescue --
-- but the aggregate reads every day of the trip through the heap to get there,
-- and a `max` deserves the one row it is entitled to.
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
    -- The floor, and only while the plan does not state its own end. When the
    -- highest-numbered day carries a date the plan has said where it ends and
    -- the frozen column has no vote -- which is what lets a shortened plan
    -- actually close earlier. `greatest` ignores nulls, so this arm simply
    -- disappears when the plan is authoritative.
    case
      when (select d.day_date
              from public.trip_itinerary_days d
             where d.trip_id = t.id
             order by d.day_number desc
             limit 1) is not null
      then null::date
      else t.end_date
    end
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
