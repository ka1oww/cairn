-- The itinerary, as a shared stored fact.
--
-- Everything else about the trail is still computed on the phone -- the day
-- nodes, the stars, the gate, the ping schedule -- and must stay there
-- (AGENTS.md). This migration moves one thing and one thing only: the *plan*
-- somebody pasted, so that eight phones hold the same one. Storing a shared
-- fact is not computing on the server
-- (docs/decisions/2026-08-22-grill-round-one.md §2), and this is the change
-- 0003_trips.sql's own comment was waiting for -- read it: it says the two
-- clock refinements it declined "need the itinerary, which stays on the
-- phone". They no longer do.
--
-- ---------------------------------------------------------------------------
-- THE MERGE RULE, WRITTEN ONCE
-- ---------------------------------------------------------------------------
--
-- Two phones can edit the same plan with no connection between them, so a
-- merge rule is unavoidable. This one is **last write wins, per day**:
--
--   * every day carries `revised_at`, stamped by the phone that changed it;
--   * a push overwrites a stored day only when its `revised_at` is strictly
--     newer, so a day nobody touched is never rewritten by a phone that
--     merely still has an older copy of it;
--   * a day's stops are replaced with the day, never merged into it -- the
--     day is the atom, which is what "per day" means;
--   * the set-aside pocket has no days, so it is one more atom of its own,
--     with its own `pocket_revised_at` on the header row.
--
-- The cost of last-write-wins is stated plainly rather than hidden: **the
-- ordering is the writing phone's clock**, so two phones whose clocks
-- disagree resolve a genuine simultaneous edit by whose watch is fast. That
-- is the trade the decision permits for this slice; a vector clock or a CRDT
-- is deliberately not built, and neither is a conflict UI.
--
-- The rule exists in exactly two places, like the gate and the invite
-- grammar: here, in `sync_trip_itinerary`, and on the phone in
-- `lib/repositories/itinerary_sync.dart`, which applies the same comparison
-- when it merges what this function hands back. A third copy is the thing to
-- refuse in review.

-- ---------------------------------------------------------------------------
-- The header: one row per trip that has an itinerary
-- ---------------------------------------------------------------------------
--
-- It exists for the two revisions that belong to the plan as a whole rather
-- than to any day in it.
--
--   * `plan_revised_at` is the *shape* revision -- when the set of day
--     numbers last changed. It is what makes a deletion expressible at all:
--     a day absent from a push is only removed when the pushing phone's view
--     of the shape is at least as new as that day, so a day another phone
--     added a moment ago survives a push from a phone that has not seen it.
--     Deletions are otherwise invisible to a cursor (supabase/README.md), and
--     re-pasting a shorter plan is an ordinary thing to do.
--   * `pocket_revised_at` is the set-aside pocket's own clock, kept here
--     rather than on the lines so that *emptying* the pocket still carries a
--     revision. A revision stored only on rows disappears with the last row,
--     and a stale phone would then win by having anything at all.
create table if not exists public.trip_itineraries (
  trip_id uuid primary key references public.trips (id) on delete cascade,
  plan_revised_at timestamptz not null default '-infinity',
  pocket_revised_at timestamptz not null default '-infinity',
  updated_at timestamptz not null default now()
);

drop trigger if exists trip_itineraries_touch_updated_at on public.trip_itineraries;
create trigger trip_itineraries_touch_updated_at
  before update on public.trip_itineraries
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- The days
-- ---------------------------------------------------------------------------
create table if not exists public.trip_itinerary_days (
  trip_id uuid not null references public.trips (id) on delete cascade,

  -- 1-based position in the trip: the itinerary's one ordering, and the same
  -- number `DayPage.planDay(n)` opens a day by on the phone.
  day_number integer not null check (day_number >= 1),

  -- Null on purpose, and not the same "unknown" `photos.trip_day` means. The
  -- parser never guesses a date it cannot resolve and a person is allowed to
  -- accept a plan with a day's date still open
  -- (docs/decisions/2026-08-22-paste-confirmation.md). A day dated on one
  -- phone therefore dates it for everyone -- which is most of the point of
  -- this table.
  day_date date,

  place text,

  -- The merge clock. See THE MERGE RULE above. Stamped by the phone that
  -- changed the day, NOT by a `touch_updated_at` trigger: a server-stamped
  -- column would order writes by when they arrived rather than by when they
  -- were made, so a phone that comes back from a week offline would win over
  -- every edit made while it was away.
  revised_at timestamptz not null,

  -- Whose edit this version is. Credit and debugging only; nothing decides
  -- anything from it, because editing the plan is flat (see the policies).
  revised_by uuid references public.profiles (id) on delete set null,

  primary key (trip_id, day_number)
);

create index if not exists trip_itinerary_days_revised_at_idx
  on public.trip_itinerary_days (trip_id, revised_at);

-- ---------------------------------------------------------------------------
-- The stops under a day
-- ---------------------------------------------------------------------------
--
-- No `revised_at` here, deliberately: the day is the merge atom, so a stop
-- has no clock of its own and cannot be merged independently of the day it
-- sits under. It also carries no `is_starred` column -- a stop is starred
-- exactly when it has a time, and that rule lives in
-- `cairn_model.Stop.isStarred` (the local Drift table refuses the same
-- column for the same reason).
create table if not exists public.trip_itinerary_stops (
  trip_id uuid not null,
  day_number integer not null,

  -- 0-based order within the day, as pasted or as dragged.
  position integer not null check (position >= 0),

  stop_text text not null,

  -- `10:12`, or null for an untimed stop. A bare wall-clock time, never an
  -- instant: what hour a stop reads at is the day's own clock's business.
  time_of_day time,

  primary key (trip_id, day_number, position),
  foreign key (trip_id, day_number)
    references public.trip_itinerary_days (trip_id, day_number)
    on delete cascade
);

-- ---------------------------------------------------------------------------
-- The set-aside pocket
-- ---------------------------------------------------------------------------
--
-- "Nothing the person pasted is ever deleted" (AGENTS.md): a line the parser
-- could not place, or one somebody took out of a day by hand, goes here with
-- the reason it carries. It syncs for a blunt reason as much as a principled
-- one -- the phone replaces its three itinerary tables together, so a pull
-- that applied days alone would wipe the pocket on every sync.
create table if not exists public.trip_itinerary_set_asides (
  trip_id uuid not null references public.trips (id) on delete cascade,

  -- 0-based order the lines are shown in.
  position integer not null check (position >= 0),

  -- 1-based line number in the original paste.
  source_line_number integer not null,

  line_text text not null,

  -- The person-showable sentence for why it is here.
  explanation text not null,

  primary key (trip_id, position)
);

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
--
-- Membership, through the helpers, as everything in this schema does
-- (0004_trip_members.sql -- never an inline subquery, or the whole schema
-- recurses).
--
-- **Editing the plan is flat.** Any member may change any day. That is the
-- same reading as `trips_update_starter`'s counterpart on the phone -- the
-- starter-and-container decision keeps *renaming* flat and reserves only
-- retiming and destroying the container -- and a plan eight people are
-- walking is exactly the kind of thing they correct for each other. The one
-- asymmetry in the product is removing a person, and it stays that.
alter table public.trip_itineraries enable row level security;
alter table public.trip_itinerary_days enable row level security;
alter table public.trip_itinerary_stops enable row level security;
alter table public.trip_itinerary_set_asides enable row level security;

drop policy if exists "trip_itineraries_select_member" on public.trip_itineraries;
create policy "trip_itineraries_select_member"
  on public.trip_itineraries for select
  to authenticated
  using ( public.is_trip_member(trip_itineraries.trip_id, auth.uid()) );

drop policy if exists "trip_itineraries_write_member" on public.trip_itineraries;
create policy "trip_itineraries_write_member"
  on public.trip_itineraries for insert
  to authenticated
  with check ( public.is_trip_member(trip_itineraries.trip_id, auth.uid()) );

drop policy if exists "trip_itineraries_update_member" on public.trip_itineraries;
create policy "trip_itineraries_update_member"
  on public.trip_itineraries for update
  to authenticated
  using ( public.is_trip_member(trip_itineraries.trip_id, auth.uid()) )
  with check ( public.is_trip_member(trip_itineraries.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_days_select_member" on public.trip_itinerary_days;
create policy "trip_itinerary_days_select_member"
  on public.trip_itinerary_days for select
  to authenticated
  using ( public.is_trip_member(trip_itinerary_days.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_days_insert_member" on public.trip_itinerary_days;
create policy "trip_itinerary_days_insert_member"
  on public.trip_itinerary_days for insert
  to authenticated
  with check ( public.is_trip_member(trip_itinerary_days.trip_id, auth.uid()) );

-- The explicit WITH CHECK matters for the same reason it does on `photos`:
-- without it Postgres silently reuses USING, which reads as if the trip were
-- unconstrained and would let a day be moved into a trip you do not belong
-- to.
drop policy if exists "trip_itinerary_days_update_member" on public.trip_itinerary_days;
create policy "trip_itinerary_days_update_member"
  on public.trip_itinerary_days for update
  to authenticated
  using ( public.is_trip_member(trip_itinerary_days.trip_id, auth.uid()) )
  with check ( public.is_trip_member(trip_itinerary_days.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_days_delete_member" on public.trip_itinerary_days;
create policy "trip_itinerary_days_delete_member"
  on public.trip_itinerary_days for delete
  to authenticated
  using ( public.is_trip_member(trip_itinerary_days.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_stops_select_member" on public.trip_itinerary_stops;
create policy "trip_itinerary_stops_select_member"
  on public.trip_itinerary_stops for select
  to authenticated
  using ( public.is_trip_member(trip_itinerary_stops.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_stops_insert_member" on public.trip_itinerary_stops;
create policy "trip_itinerary_stops_insert_member"
  on public.trip_itinerary_stops for insert
  to authenticated
  with check ( public.is_trip_member(trip_itinerary_stops.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_stops_update_member" on public.trip_itinerary_stops;
create policy "trip_itinerary_stops_update_member"
  on public.trip_itinerary_stops for update
  to authenticated
  using ( public.is_trip_member(trip_itinerary_stops.trip_id, auth.uid()) )
  with check ( public.is_trip_member(trip_itinerary_stops.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_stops_delete_member" on public.trip_itinerary_stops;
create policy "trip_itinerary_stops_delete_member"
  on public.trip_itinerary_stops for delete
  to authenticated
  using ( public.is_trip_member(trip_itinerary_stops.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_set_asides_select_member" on public.trip_itinerary_set_asides;
create policy "trip_itinerary_set_asides_select_member"
  on public.trip_itinerary_set_asides for select
  to authenticated
  using ( public.is_trip_member(trip_itinerary_set_asides.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_set_asides_insert_member" on public.trip_itinerary_set_asides;
create policy "trip_itinerary_set_asides_insert_member"
  on public.trip_itinerary_set_asides for insert
  to authenticated
  with check ( public.is_trip_member(trip_itinerary_set_asides.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_set_asides_update_member" on public.trip_itinerary_set_asides;
create policy "trip_itinerary_set_asides_update_member"
  on public.trip_itinerary_set_asides for update
  to authenticated
  using ( public.is_trip_member(trip_itinerary_set_asides.trip_id, auth.uid()) )
  with check ( public.is_trip_member(trip_itinerary_set_asides.trip_id, auth.uid()) );

drop policy if exists "trip_itinerary_set_asides_delete_member" on public.trip_itinerary_set_asides;
create policy "trip_itinerary_set_asides_delete_member"
  on public.trip_itinerary_set_asides for delete
  to authenticated
  using ( public.is_trip_member(trip_itinerary_set_asides.trip_id, auth.uid()) );

-- ---------------------------------------------------------------------------
-- The one call: push and pull are the same round trip
-- ---------------------------------------------------------------------------
--
-- A phone hands over the plan it holds and gets back the plan the trip holds
-- once its own was merged in. Both directions in one call, for three reasons:
--
--   1. It is atomic. PostgREST has no client-side transaction, so a push
--      spelled as separate upserts and deletes can be interleaved with
--      another phone's -- the exact hazard `redeem_trip_invite` exists to
--      avoid for joining.
--   2. It makes the stale-write guard expressible. `on conflict do update
--      ... where excluded.revised_at > stored.revised_at` cannot be written
--      through PostgREST's upsert at all.
--   3. A phone with no plan of its own -- somebody who joined by code --
--      pulls by pushing nothing: empty days and `-infinity` as its shape
--      revision, which wins nothing and deletes nothing.
--
-- `security invoker`, unlike `redeem_trip_invite`: joining has to reach a
-- table the joiner may not read, and this does not. Every statement below is
-- filtered by the policies above as the calling member, which is the
-- property that makes the explicit membership check at the top a courtesy
-- (an honest error instead of a silent no-op) rather than the enforcement.
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
  v_result jsonb;
begin
  if not public.is_trip_member(p_trip_id, auth.uid()) then
    raise exception 'not a member of this trip'
      using errcode = 'insufficient_privilege';
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
    (trip_id, day_number, position, stop_text, time_of_day)
  select p_trip_id,
         (d->>'day_number')::integer,
         (s->>'position')::integer,
         s->>'stop_text',
         (s->>'time_of_day')::time
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
                'time_of_day', s.time_of_day
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

-- ---------------------------------------------------------------------------
-- The roster, as one read
-- ---------------------------------------------------------------------------
--
-- Membership already propagates: `trip_members_select_co_member` (0004) lets
-- every member read the whole roster, and `profile_is_visible_to` (0009) lets
-- them resolve each name. What was missing is nothing in the schema -- it is
-- that no phone ever asked. This view exists only so the phone asks with one
-- statement instead of an embedded resource whose shape depends on PostgREST
-- version, and it invents no access: it is `security_invoker`, so both
-- policies apply to the caller exactly as they would to the tables.
--
-- `joined_on_day` is deliberately NOT here. Which day of the trip somebody
-- joined on is a function of the itinerary and the trip's clock, and both of
-- those are the phone's to read (AGENTS.md: the schedule and the trail stay
-- computed on-device). The server hands over the instant; the phone counts
-- the days.
drop view if exists public.trip_roster;
create view public.trip_roster
with (security_invoker = true)
as
  select m.trip_id,
         m.user_id,
         p.display_name,
         m.joined_at
  from public.trip_members m
  join public.profiles p on p.id = m.user_id;

grant select on public.trip_roster to authenticated, service_role;
